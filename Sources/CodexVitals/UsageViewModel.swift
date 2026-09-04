import AppKit
import Combine
import Foundation

/// Central state holder observed by all SwiftUI views.
@MainActor
final class UsageViewModel: ObservableObject {

    // MARK: - Published State

    @Published var accounts: [Account] = []
    @Published var isLoading = false
    @Published var isAddingAccount = false
    @Published var addingAccountProvider: AccountProvider?
    @Published var reloggingAccountID: String?
    @Published var switchingAccountID: String?
    @Published var removingAccountID: String?
    @Published var accountActionError: String?
    @Published var codexLoginStatus: CodexLoginStatus = .empty
    @Published var activeCodexProfileKey: String?
    @Published var isCodexInstalled = false
    @Published var lastRefresh: Date?
    @Published var error: String?

    @Published var searchText = ""
    @Published var groupByWorkspace = false {
        didSet { UserDefaults.standard.set(groupByWorkspace, forKey: "groupByWorkspace") }
    }
    @Published var listDensity: ListDensity = .compact {
        didSet { UserDefaults.standard.set(listDensity.rawValue, forKey: "listDensity") }
    }
    @Published var accountSortMode: AccountSortMode = .stored() {
        didSet {
            guard oldValue != accountSortMode else { return }
            accountSortMode.save()
        }
    }
    @Published var autoRefreshInterval: AutoRefreshInterval = .stored {
        didSet {
            guard oldValue != autoRefreshInterval else { return }
            autoRefreshInterval.save()
            restartRefreshTimer()
        }
    }
    @Published private(set) var resetNotificationsEnabled = UserDefaults.standard.bool(
        forKey: "usageResetNotificationsEnabled"
    )
    @Published private(set) var isRequestingResetNotificationPermission = false
    @Published private(set) var resetNotificationStatusMessage: String?
    @Published var waitingForResetCollapsed = false
    @Published var freeWaitingCollapsed = true

    // MARK: - Internals

    private let service = UsageService()
    private let claudeService = ClaudeAccountService()
    private let captureService = CodexAccountCaptureService()
    private let switchService = CodexAccountSwitchService()
    private let removalService = LocalAccountRemovalService()
    private let resetNotificationService: any UsageResetNotifying
    private var refreshTimer: Timer?
    private var reloginTask: Task<Void, Never>?
    private var switchTask: Task<Void, Never>?
    private var pendingDebouncedRefreshTask: Task<Void, Never>?
    private var pendingRefreshAfterCurrent = false
    private var pendingForceMetadataRefreshAfterCurrent = false
    private var pendingResetNotificationCheck = false
    private let resetNotificationsEnabledKey = "usageResetNotificationsEnabled"

    // MARK: - Init

    init(resetNotificationService: any UsageResetNotifying = UsageResetNotificationService()) {
        self.resetNotificationService = resetNotificationService
        if UserDefaults.standard.object(forKey: "groupByWorkspace") != nil {
            groupByWorkspace = UserDefaults.standard.bool(forKey: "groupByWorkspace")
        }
        UserDefaults.standard.removeObject(forKey: "accountInformationMode")
        listDensity = .compact
        if let snap = AccountSnapshotStore.load() {
            accounts = snap.accounts
            lastRefresh = snap.lastRefresh
        }
        codexLoginStatus = CodexLoginStatusStore.load()
        refreshCodexAvailability()
    }

    // MARK: - Derived Lists

    private var visibleAccounts: [Account] {
        Self.visibleAccounts(from: accounts)
    }

    static func visibleAccounts(from accounts: [Account]) -> [Account] {
        accounts
    }

    private var searchFiltered: [Account] {
        guard !searchText.isEmpty else { return visibleAccounts }
        return visibleAccounts.filter { Self.matchesSearch($0, searchText: searchText) }
    }

    private var usesManualAccountOrder: Bool {
        accountSortMode == .manual
    }

    static func matchesSearch(_ account: Account, searchText: String) -> Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return account.searchText.localizedCaseInsensitiveContains(trimmed)
    }

    /// Smart score for default ordering of active rows.
    static func smartScore(_ a: Account) -> Double {
        a.limitingQuotaRemaining
    }

    /// Urgency for priority ordering.
    static func expiringScore(_ a: Account) -> Double {
        guard let weeklyWindow = a.weeklyQuotaWindow else {
            return smartScore(a)
        }
        let w = weeklyWindow.remainingPercent
        let h = min(max(0, a.hoursUntilWeeklyReset), 168)
        let urgencyMultiplier = 1 + (168 - h) / 168 * 2
        let sessionHealthFactor = min((a.fiveHourQuotaWindow?.remainingPercent ?? 100) / 30, 1.0)
        return w * urgencyMultiplier * sessionHealthFactor
    }

    static func sortedExhaustedAccounts(_ accounts: [Account]) -> [Account] {
        accounts.sorted { compareExhausted($0, $1) }
    }

    private static func exhaustedPlanRank(_ account: Account) -> Int {
        if account.hasError { return 2 }
        if account.isFreePlan { return 1 }
        return 0
    }

    private static func compareExhausted(_ a: Account, _ b: Account) -> Bool {
        let planRankA = exhaustedPlanRank(a)
        let planRankB = exhaustedPlanRank(b)
        if planRankA != planRankB {
            return planRankA < planRankB
        }
        if a.nextWaitingResetSeconds != b.nextWaitingResetSeconds {
            return a.nextWaitingResetSeconds < b.nextWaitingResetSeconds
        }
        return a.email.localizedCaseInsensitiveCompare(b.email) == .orderedAscending
    }

    private static func compareSmart(_ a: Account, _ b: Account) -> Bool {
        let sa = smartScore(a), sb = smartScore(b)
        if sa != sb { return sa > sb }
        let aShort = a.fiveHourQuotaWindow?.remainingPercent ?? 100
        let bShort = b.fiveHourQuotaWindow?.remainingPercent ?? 100
        if aShort != bShort { return aShort > bShort }
        let aWeekly = a.weeklyQuotaWindow?.remainingPercent ?? 100
        let bWeekly = b.weeklyQuotaWindow?.remainingPercent ?? 100
        return aWeekly > bWeekly
    }

    private static func comparePriority(_ a: Account, _ b: Account) -> Bool {
        let ea = expiringScore(a), eb = expiringScore(b)
        if ea != eb { return ea > eb }
        return compareSmart(a, b)
    }

    /// Priority accounts with useful balance and weekly reset under 24 hours.
    var priorityAccounts: [Account] {
        let usable = searchFiltered.filter { $0.isUsableForCodex && $0.isWeeklyPriority }
        if usesManualAccountOrder { return [] }
        return usable.sorted { Self.comparePriority($0, $1) }
    }

    /// Active accounts not in the priority strip, sorted by smart score.
    var normalActiveAccounts: [Account] {
        let ids = Set(priorityAccounts.map(\.id))
        let usable = searchFiltered.filter { $0.isUsableForCodex && !ids.contains($0.id) }
        if usesManualAccountOrder { return sortByManualOrder(usable) }
        return usable.sorted { Self.compareSmart($0, $1) }
    }

    var exhaustedAccounts: [Account] {
        if usesManualAccountOrder {
            return sortByManualOrder(searchFiltered.filter { !$0.isUsableForCodex })
        }
        return Self.sortedExhaustedAccounts(searchFiltered.filter { !$0.isUsableForCodex })
    }

    var nonFreeExhaustedAccounts: [Account] {
        if usesManualAccountOrder {
            return sortByManualOrder(searchFiltered.filter { !$0.isUsableForCodex && !$0.isFreeWaitingForReset })
        }
        return Self.sortedExhaustedAccounts(searchFiltered.filter { !$0.isUsableForCodex && !$0.isFreeWaitingForReset })
    }

    var freeWaitingAccounts: [Account] {
        if usesManualAccountOrder {
            return sortByManualOrder(searchFiltered.filter(\.isFreeWaitingForReset))
        }
        return Self.sortedExhaustedAccounts(searchFiltered.filter(\.isFreeWaitingForReset))
    }

    var groupedPriorityAccounts: [(String, [Account])] {
        Self.groupByWorkspace(priorityAccounts)
    }

    var groupedNormalActiveAccounts: [(String, [Account])] {
        Self.groupByWorkspace(normalActiveAccounts)
    }

    var groupedExhaustedAccounts: [(String, [Account])] {
        Self.groupByWorkspace(nonFreeExhaustedAccounts)
    }

    var hasAnyAccount: Bool {
        !priorityAccounts.isEmpty || !normalActiveAccounts.isEmpty || !exhaustedAccounts.isEmpty
    }

    static func groupByWorkspace(_ accounts: [Account]) -> [(String, [Account])] {
        var order: [String] = []
        var map: [String: [Account]] = [:]
        for a in accounts {
            if map[a.workspace] == nil { order.append(a.workspace) }
            map[a.workspace, default: []].append(a)
        }
        return order.map { ($0, map[$0]!) }
    }

    static func groupByProvider(_ accounts: [Account]) -> [(provider: AccountProvider, accounts: [Account])] {
        AccountProvider.allCases.compactMap { provider in
            let matching = accounts.filter { $0.accountProvider == provider }
            return matching.isEmpty ? nil : (provider, matching)
        }
    }

    var errorsCount: Int { Self.errorCount(in: accounts) }

    static func errorCount(in accounts: [Account]) -> Int {
        accounts.filter(\.hasError).count
    }

    func workspaceDisplayName(for workspace: String, provider: AccountProvider) -> String {
        accounts.first(where: {
            $0.workspace == workspace && $0.accountProvider == provider
        })?.displayWorkspaceName ?? workspace
    }

    func workspaceHasDisplayAlias(_ workspace: String, provider: AccountProvider) -> Bool {
        accounts.first(where: {
            $0.workspace == workspace && $0.accountProvider == provider
        })?.hasDisplayWorkspaceAlias ?? false
    }

    private func sortByManualOrder(_ accounts: [Account]) -> [Account] {
        let order = accountOrderMap
        return accounts.sorted { a, b in
            let ia = order[Self.orderKey(for: a)] ?? Int.max
            let ib = order[Self.orderKey(for: b)] ?? Int.max
            if ia != ib { return ia < ib }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    private var accountOrderMap: [String: Int] {
        Dictionary(uniqueKeysWithValues: accounts.enumerated().map { index, account in
            (Self.orderKey(for: account), index)
        })
    }

    private static func orderKey(for account: Account) -> String {
        account.profileKey ?? account.id
    }

    // MARK: - Actions

    func refresh(forceMetadataRefresh: Bool = false, notifyOnReset: Bool = false) {
        pendingDebouncedRefreshTask?.cancel()
        pendingDebouncedRefreshTask = nil

        guard !isLoading else {
            pendingRefreshAfterCurrent = true
            pendingForceMetadataRefreshAfterCurrent = pendingForceMetadataRefreshAfterCurrent || forceMetadataRefresh
            pendingResetNotificationCheck = pendingResetNotificationCheck || notifyOnReset
            return
        }

        runRefresh(forceMetadataRefresh: forceMetadataRefresh, notifyOnReset: notifyOnReset)
    }

    private func runRefresh(forceMetadataRefresh: Bool, notifyOnReset: Bool) {
        let previousAccounts = accounts
        let previousRefresh = lastRefresh
        isLoading = true
        error = nil
        codexLoginStatus = CodexLoginStatusStore.load()
        refreshCodexAvailability()

        Task {
            async let codexAccounts = service.loadAll(forceMetadataRefresh: forceMetadataRefresh)
            async let claudeResult = claudeService.loadAccounts(
                previousAccounts: previousAccounts,
                previousFetchedAt: previousRefresh
            )
            let (loadedCodexAccounts, loadedClaudeResult) = await (codexAccounts, claudeResult)
            let loadedAccounts = loadedCodexAccounts + loadedClaudeResult.accounts
            if let claudeError = loadedClaudeResult.errorMessage {
                accountActionError = claudeError
            }
            let now = Date()
            let resetEvents = notifyOnReset && resetNotificationsEnabled
                ? UsageResetDetector.detect(
                    previousAccounts: previousAccounts,
                    previousFetchedAt: previousRefresh,
                    currentAccounts: loadedAccounts,
                    currentFetchedAt: now
                )
                : []
            accounts = loadedAccounts
            lastRefresh = now
            AccountSnapshotStore.save(accounts: accounts, lastRefresh: now)
            codexLoginStatus = CodexLoginStatusStore.load()
            refreshCodexAvailability()
            isLoading = false
            restartRefreshTimer()
            if !resetEvents.isEmpty {
                await resetNotificationService.deliver(events: resetEvents)
            }
            if pendingRefreshAfterCurrent {
                let shouldForceMetadata = pendingForceMetadataRefreshAfterCurrent
                let shouldNotifyOnReset = pendingResetNotificationCheck
                pendingRefreshAfterCurrent = false
                pendingForceMetadataRefreshAfterCurrent = false
                pendingResetNotificationCheck = false
                refresh(
                    forceMetadataRefresh: shouldForceMetadata,
                    notifyOnReset: shouldNotifyOnReset
                )
            }
        }
    }

    func setResetNotificationsEnabled(_ enabled: Bool) {
        if !enabled {
            UserDefaults.standard.set(false, forKey: resetNotificationsEnabledKey)
            resetNotificationsEnabled = false
            resetNotificationStatusMessage = nil
            return
        }

        guard !isRequestingResetNotificationPermission else { return }
        isRequestingResetNotificationPermission = true
        resetNotificationStatusMessage = nil
        Task {
            let granted = await resetNotificationService.requestAuthorization()
            UserDefaults.standard.set(granted, forKey: resetNotificationsEnabledKey)
            resetNotificationsEnabled = granted
            isRequestingResetNotificationPermission = false
            if !granted {
                resetNotificationStatusMessage = "Notifications are disabled in System Settings"
            }
        }
    }

    func refreshResetNotificationAuthorization() {
        guard resetNotificationsEnabled else { return }
        Task {
            let status = await resetNotificationService.authorizationStatus()
            let isAuthorized = status == .authorized || status == .provisional
            guard !isAuthorized else {
                resetNotificationStatusMessage = nil
                return
            }
            UserDefaults.standard.set(false, forKey: resetNotificationsEnabledKey)
            resetNotificationsEnabled = false
            resetNotificationStatusMessage = "Notifications are disabled in System Settings"
        }
    }

    private func schedulePostCaptureRefresh() {
        pendingDebouncedRefreshTask?.cancel()
        pendingDebouncedRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingDebouncedRefreshTask = nil
            self.refresh(forceMetadataRefresh: true)
        }
    }

    func needsRelogin(_ account: Account) -> Bool {
        if account.isClaudeAccount {
            return [
                ClaudeAccountStatus.tokenExpired.rawValue,
                ClaudeAccountStatus.reloginRequired.rawValue,
                ClaudeAccountStatus.noCredentials.rawValue,
            ].contains(account.providerStatus)
        }
        return !codexLoginStatus.contains(account)
            || UsageService.requiresRelogin(account.errorMessage)
    }

    func isRelogging(_ account: Account) -> Bool {
        reloggingAccountID == account.id
    }

    func isSwitchingAccount(_ account: Account) -> Bool {
        switchingAccountID == account.id
    }

    func isActiveAccount(_ account: Account) -> Bool {
        if account.isClaudeAccount {
            return account.providerIsActive == true
        }
        guard isCodexInstalled else { return false }
        guard let activeCodexProfileKey,
              let profileKey = account.profileKey else {
            return false
        }
        return activeCodexProfileKey == profileKey
    }

    func showsSwitchControls(for account: Account) -> Bool {
        account.isClaudeAccount ? account.providerProfileID != nil : isCodexInstalled
    }

    func canSwitchAccount(_ account: Account) -> Bool {
        guard showsSwitchControls(for: account) else { return false }
        return account.canSwitchProviderAccount
    }

    var hasPendingAccountAction: Bool {
        isAddingAccount
            || reloggingAccountID != nil
            || switchingAccountID != nil
            || removingAccountID != nil
    }

    func addAccount() {
        addCodexAccount()
    }

    func addCodexAccount() {
        guard !hasPendingAccountAction else { return }
        pendingDebouncedRefreshTask?.cancel()
        pendingDebouncedRefreshTask = nil
        isAddingAccount = true
        addingAccountProvider = .codex
        accountActionError = nil

        reloginTask = Task {
            do {
                _ = try await captureService.captureNewAccount()
                guard !Task.isCancelled else { return }
                codexLoginStatus = CodexLoginStatusStore.load()
                isAddingAccount = false
                addingAccountProvider = nil
                reloginTask = nil
                schedulePostCaptureRefresh()
            } catch is CancellationError {
                isAddingAccount = false
                addingAccountProvider = nil
                reloginTask = nil
                accountActionError = nil
            } catch {
                isAddingAccount = false
                addingAccountProvider = nil
                reloginTask = nil
                accountActionError = error.localizedDescription
            }
        }
    }

    func addClaudeAccount() {
        guard !hasPendingAccountAction else { return }
        pendingDebouncedRefreshTask?.cancel()
        pendingDebouncedRefreshTask = nil
        isAddingAccount = true
        addingAccountProvider = .claude
        accountActionError = nil

        reloginTask = Task {
            do {
                _ = try await claudeService.addAccount()
                guard !Task.isCancelled else { return }
                isAddingAccount = false
                addingAccountProvider = nil
                reloginTask = nil
                refresh(forceMetadataRefresh: true)
            } catch is CancellationError {
                isAddingAccount = false
                addingAccountProvider = nil
                reloginTask = nil
                accountActionError = nil
            } catch {
                isAddingAccount = false
                addingAccountProvider = nil
                reloginTask = nil
                accountActionError = error.localizedDescription
                refresh()
            }
        }
    }

    func relogin(_ account: Account) {
        guard !hasPendingAccountAction else { return }
        pendingDebouncedRefreshTask?.cancel()
        pendingDebouncedRefreshTask = nil
        reloggingAccountID = account.id
        accountActionError = nil

        reloginTask = Task {
            do {
                if account.isClaudeAccount {
                    guard let profileID = account.providerProfileID else {
                        throw ClaudeNativeError.profileMissing
                    }
                    _ = try await claudeService.reauthenticate(profileID: profileID)
                } else {
                    _ = try await captureService.captureAccount(for: account)
                }
                guard !Task.isCancelled else { return }
                if !account.isClaudeAccount {
                    codexLoginStatus = CodexLoginStatusStore.load()
                }
                reloggingAccountID = nil
                reloginTask = nil
                if account.isClaudeAccount {
                    refresh(forceMetadataRefresh: true)
                } else {
                    schedulePostCaptureRefresh()
                }
            } catch is CancellationError {
                reloggingAccountID = nil
                reloginTask = nil
                accountActionError = nil
            } catch {
                reloggingAccountID = nil
                reloginTask = nil
                accountActionError = error.localizedDescription
            }
        }
    }

    func cancelRelogin() {
        reloginTask?.cancel()
        Task { await claudeService.cancelLogin() }
        reloginTask = nil
        reloggingAccountID = nil
        isAddingAccount = false
        addingAccountProvider = nil
        accountActionError = nil
    }

    func setAlias(_ alias: String?, for account: Account) {
        if account.isClaudeAccount {
            guard let profileID = account.providerProfileID else {
                accountActionError = "Claude account profile is missing."
                return
            }
            Task {
                do {
                    let normalizedAlias = Account.normalizedAlias(alias)
                    try await claudeService.updateAlias(profileID: profileID, alias: normalizedAlias)
                    if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                        accounts[index].alias = normalizedAlias
                        AccountSnapshotStore.save(accounts: accounts, lastRefresh: lastRefresh)
                    }
                } catch {
                    accountActionError = error.localizedDescription
                }
            }
            return
        }
        guard let profileKey = account.profileKey else {
            accountActionError = "Account has no local profile to label."
            return
        }

        do {
            let normalizedAlias = Account.normalizedAlias(alias)
            try AccountProfileStore.updateAlias(profileKey: profileKey, alias: normalizedAlias)
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].alias = normalizedAlias
                AccountSnapshotStore.save(accounts: accounts, lastRefresh: lastRefresh)
            }
        } catch {
            accountActionError = error.localizedDescription
        }
    }

    func setPlanRenewalDate(_ date: Date?, for account: Account) {
        guard account.isClaudeAccount,
              let profileID = account.providerProfileID else {
            accountActionError = "Claude account profile is missing."
            return
        }

        Task {
            do {
                try await claudeService.updatePlanRenewalDate(profileID: profileID, date: date)
                if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                    accounts[index].planRenewalDate = date
                    AccountSnapshotStore.save(accounts: accounts, lastRefresh: lastRefresh)
                }
            } catch {
                accountActionError = error.localizedDescription
            }
        }
    }

    func setWorkspaceAlias(
        _ alias: String?,
        for workspace: String,
        provider: AccountProvider
    ) {
        let workspaceKey = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspaceKey.isEmpty else {
            accountActionError = "Workspace has no local name to label."
            return
        }

        let normalizedAlias = Account.normalizedAlias(alias)
        if provider == .claude {
            Task {
                do {
                    try await claudeService.updateWorkspaceAlias(
                        workspace: workspaceKey,
                        alias: normalizedAlias
                    )
                    applyWorkspaceAlias(
                        normalizedAlias,
                        workspace: workspaceKey,
                        provider: provider
                    )
                } catch {
                    accountActionError = error.localizedDescription
                }
            }
            return
        }

        do {
            try AccountProfileStore.updateWorkspaceAlias(workspace: workspaceKey, alias: normalizedAlias)
            applyWorkspaceAlias(normalizedAlias, workspace: workspaceKey, provider: provider)
        } catch {
            accountActionError = error.localizedDescription
        }
    }

    private func applyWorkspaceAlias(
        _ alias: String?,
        workspace: String,
        provider: AccountProvider
    ) {
        var changed = false
        for index in accounts.indices where
            accounts[index].workspace == workspace
                && accounts[index].accountProvider == provider {
            accounts[index].workspaceAlias = alias
            changed = true
        }
        if changed {
            AccountSnapshotStore.save(accounts: accounts, lastRefresh: lastRefresh)
        }
    }

    func canReorderAccount(_ account: Account) -> Bool {
        let hasStoredProfile = account.isClaudeAccount
            ? account.providerProfileID != nil
            : account.profileKey != nil
        return searchText.isEmpty && hasStoredProfile
    }

    @discardableResult
    func reorderAccount(
        draggedAccountID: String,
        targetAccountID: String,
        placeAfterTarget: Bool
    ) -> Bool {
        guard searchText.isEmpty else {
            accountActionError = "Clear search before reordering accounts."
            return false
        }

        guard draggedAccountID != targetAccountID,
              let draggedAccount = accounts.first(where: { $0.id == draggedAccountID }),
              let targetAccount = accounts.first(where: { $0.id == targetAccountID }),
              draggedAccount.accountProvider == targetAccount.accountProvider,
              canReorderAccount(draggedAccount),
              canReorderAccount(targetAccount) else {
            return false
        }
        if groupByWorkspace && draggedAccount.workspace != targetAccount.workspace {
            accountActionError = "Accounts can be reordered only within the same workspace while grouping is enabled."
            return false
        }
        guard reorderSection(for: draggedAccount) == reorderSection(for: targetAccount) else {
            accountActionError = "Accounts can be reordered only within the same usage section."
            return false
        }

        let provider = draggedAccount.accountProvider
        let rows = movableAccountRows(provider: provider)
        let currentIDs = rows.map(\.id)
        let reorderedIDs = Self.reorderedIDs(
            currentIDs,
            moving: draggedAccountID,
            relativeTo: targetAccountID,
            placeAfterTarget: placeAfterTarget
        )
        guard reorderedIDs != currentIDs else { return false }

        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let reorderedRows = reorderedIDs.compactMap { rowsByID[$0] }
        switch provider {
        case .codex:
            let orderedProfileKeys = reorderedRows.compactMap(\.profileKey)
            guard !orderedProfileKeys.isEmpty else { return false }
            do {
                try AccountProfileStore.updateDefaultOrder(orderedProfileKeys)
                applyManualOrder(provider: provider, orderedKeys: orderedProfileKeys)
                return true
            } catch {
                accountActionError = error.localizedDescription
                return false
            }
        case .claude:
            let orderedProfileIDs = reorderedRows.compactMap(\.providerProfileID)
            guard !orderedProfileIDs.isEmpty else { return false }
            Task {
                do {
                    try await claudeService.updateOrder(profileIDs: orderedProfileIDs)
                    applyManualOrder(provider: provider, orderedKeys: orderedProfileIDs)
                } catch {
                    accountActionError = error.localizedDescription
                }
            }
            return true
        }
    }

    static func reorderedIDs(
        _ ids: [String],
        moving movingID: String,
        relativeTo targetID: String,
        placeAfterTarget: Bool
    ) -> [String] {
        guard let sourceIndex = ids.firstIndex(of: movingID),
              let targetIndex = ids.firstIndex(of: targetID),
              sourceIndex != targetIndex else {
            return ids
        }

        var reordered = ids
        let moving = reordered.remove(at: sourceIndex)
        var destination = targetIndex + (placeAfterTarget ? 1 : 0)
        if sourceIndex < destination {
            destination -= 1
        }
        reordered.insert(moving, at: min(max(0, destination), reordered.count))
        return reordered
    }

    private func applyManualOrder(provider: AccountProvider, orderedKeys: [String]) {
        reorderAccountsInMemory(provider: provider, orderedKeys: orderedKeys)
        accountSortMode = .manual
        AccountSnapshotStore.save(accounts: accounts, lastRefresh: lastRefresh)
    }

    private func reorderSection(for account: Account) -> Int {
        if account.isFreeWaitingForReset { return 2 }
        if !account.isUsableForCodex { return 1 }
        return 0
    }

    func setAccountSortMode(_ mode: AccountSortMode) {
        accountSortMode = mode
    }

    private func movableAccountRows(provider: AccountProvider) -> [Account] {
        let rows: [Account]
        if groupByWorkspace {
            rows = groupedPriorityAccounts.flatMap { $0.1 }
                + groupedNormalActiveAccounts.flatMap { $0.1 }
                + groupedExhaustedAccounts.flatMap { $0.1 }
                + freeWaitingAccounts
        } else {
            rows = priorityAccounts + normalActiveAccounts + nonFreeExhaustedAccounts + freeWaitingAccounts
        }
        return rows.filter { $0.accountProvider == provider }
    }

    private func reorderAccountsInMemory(
        provider: AccountProvider,
        orderedKeys: [String]
    ) {
        var order: [String: Int] = [:]
        for (index, key) in orderedKeys.enumerated() where order[key] == nil {
            order[key] = index
        }
        let reorderedProviderAccounts = accounts
            .filter { $0.accountProvider == provider }
            .sorted { a, b in
            let leftKey = provider == .claude ? a.providerProfileID : a.profileKey
            let rightKey = provider == .claude ? b.providerProfileID : b.profileKey
            let ia = leftKey.flatMap { order[$0] } ?? Int.max
            let ib = rightKey.flatMap { order[$0] } ?? Int.max
            if ia != ib { return ia < ib }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }

        var providerIndex = 0
        accounts = accounts.map { account in
            guard account.accountProvider == provider else { return account }
            defer { providerIndex += 1 }
            return reorderedProviderAccounts[providerIndex]
        }
    }

    func switchAccount(to account: Account) {
        guard showsSwitchControls(for: account),
              canSwitchAccount(account),
              !hasPendingAccountAction,
              !needsRelogin(account) else { return }
        switchingAccountID = account.id
        accountActionError = nil

        switchTask = Task.detached { [switchService, claudeService] in
            do {
                if account.isClaudeAccount {
                    guard let profileID = account.providerProfileID else {
                        throw ClaudeNativeError.profileMissing
                    }
                    try await claudeService.switchAccount(profileID: profileID)
                } else {
                    let result = try await switchService.switchToAccount(account)
                    await MainActor.run {
                        self.activeCodexProfileKey = result.sourceProfileKey
                    }
                }
                await MainActor.run {
                    self.switchingAccountID = nil
                    self.switchTask = nil
                    if account.isClaudeAccount {
                        self.refresh()
                    }
                }
            } catch {
                await MainActor.run {
                    self.switchingAccountID = nil
                    self.switchTask = nil
                    self.accountActionError = error.localizedDescription
                }
            }
        }
    }

    func isRemoving(_ account: Account) -> Bool {
        removingAccountID == account.id
    }

    func removeAccount(_ account: Account) {
        guard !hasPendingAccountAction else { return }
        removingAccountID = account.id
        accountActionError = nil

        if account.isClaudeAccount {
            Task {
                do {
                    guard let profileID = account.providerProfileID else {
                        throw ClaudeNativeError.profileMissing
                    }
                    try await claudeService.removeAccount(profileID: profileID)
                    removingAccountID = nil
                    refresh()
                } catch {
                    removingAccountID = nil
                    accountActionError = error.localizedDescription
                }
            }
            return
        }

        Task.detached { [removalService] in
            do {
                _ = try removalService.remove(account)
                await MainActor.run {
                    self.removingAccountID = nil
                    self.codexLoginStatus = CodexLoginStatusStore.load()
                    self.refresh()
                }
            } catch {
                await MainActor.run {
                    self.removingAccountID = nil
                    self.accountActionError = error.localizedDescription
                }
            }
        }
    }

    func toggleListDensity() {
        listDensity = .compact
    }

    func toggleWaitingForResetCollapsed() {
        waitingForResetCollapsed.toggle()
    }

    func toggleFreeWaitingCollapsed() {
        freeWaitingCollapsed.toggle()
    }

    func toggleGroupByWorkspace() { groupByWorkspace.toggle() }

    // MARK: - Timer

    private func refreshCodexAvailability() {
        isCodexInstalled = switchService.isCodexInstalled
        activeCodexProfileKey = isCodexInstalled ? switchService.currentSourceProfileKey() : nil
    }

    private func restartRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard !isLoading, let interval = autoRefreshInterval.seconds else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(notifyOnReset: true) }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }
}
