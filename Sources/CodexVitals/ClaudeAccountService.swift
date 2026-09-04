import Darwin
import Foundation

struct ClaudeNativeLoadResult {
    let accounts: [Account]
    let errorMessage: String?
}

actor ClaudeAccountService {
    static let minimumUsageRefreshInterval: TimeInterval = 15 * 60

    private struct CachedUsage {
        let windows: [QuotaWindow]
        let fableWindow: QuotaWindow?
        let fetchedAt: Date
    }

    private let keychain: any ClaudeKeychainStoring
    private let accountStore: ClaudeAccountStore
    private let configStore: any ClaudeGlobalConfigStoring
    private let usageClient: any ClaudeUsageProviding
    private let fileManager: FileManager
    private var loginProcess: Process?
    private var usageCache: [String: CachedUsage] = [:]
    private var nextAllowedUsageRefresh: [String: Date] = [:]

    init(
        keychain: any ClaudeKeychainStoring = ClaudeKeychainStore(),
        accountStore: ClaudeAccountStore = ClaudeAccountStore(),
        configStore: any ClaudeGlobalConfigStoring = ClaudeGlobalConfigStore(),
        usageClient: any ClaudeUsageProviding = ClaudeUsageClient(),
        fileManager: FileManager = .default
    ) {
        self.keychain = keychain
        self.accountStore = accountStore
        self.configStore = configStore
        self.usageClient = usageClient
        self.fileManager = fileManager
    }

    func loadAccounts(
        previousAccounts: [Account] = [],
        previousFetchedAt: Date? = nil,
        now: Date = Date()
    ) async -> ClaudeNativeLoadResult {
        seedUsageCache(from: previousAccounts, fetchedAt: previousFetchedAt)
        var integrationError: String?
        do {
            try recoverInterruptedSwitchIfNeeded()
            _ = try captureCurrentActiveIfAvailable()
        } catch {
            integrationError = error.localizedDescription
        }

        let profiles: [ClaudeNativeProfile]
        do {
            profiles = try accountStore.load().filter(\.isVisible)
        } catch {
            return ClaudeNativeLoadResult(accounts: [], errorMessage: error.localizedDescription)
        }

        let activeOAuthAccount = (try? configStore.read())?.oauthAccount
        var indexedAccounts: [(Int, Account)] = []
        for start in stride(from: 0, to: profiles.count, by: 4) {
            let end = min(start + 4, profiles.count)
            await withTaskGroup(of: (Int, Account).self) { group in
                for index in start..<end {
                    let profile = profiles[index]
                    let isActive = activeOAuthAccount.map(profile.matches(oauthAccount:)) ?? false
                    group.addTask { [self] in
                        (index, await loadAccount(profile, isActive: isActive, now: now))
                    }
                }
                for await result in group {
                    indexedAccounts.append(result)
                }
            }
        }
        let accounts = indexedAccounts.sorted { $0.0 < $1.0 }.map(\.1)
        return ClaudeNativeLoadResult(
            accounts: accounts,
            errorMessage: profiles.isEmpty ? nil : integrationError
        )
    }

    @discardableResult
    func addAccount() async throws -> ClaudeNativeProfile {
        try captureCurrentActiveBeforeLogin()
        try await runLogin(email: nil)
        let profile = try captureLoggedInAccount(expectedProfile: nil)
        try accountStore.setHidden(profileID: profile.id, hidden: false)
        invalidateUsageState(profileID: profile.id)
        return try accountStore.profile(id: profile.id) ?? profile
    }

    @discardableResult
    func reauthenticate(profileID: String) async throws -> ClaudeNativeProfile {
        guard let expected = try accountStore.profile(id: profileID) else {
            throw ClaudeNativeError.profileMissing
        }
        try captureCurrentActiveBeforeLogin()
        try await runLogin(email: expected.email)
        let actual = try captureLoggedInAccount(expectedProfile: expected)
        guard actual.id == expected.id else {
            throw ClaudeNativeError.wrongAccount(expected: expected.email, actual: actual.email)
        }
        try accountStore.setHidden(profileID: actual.id, hidden: false)
        invalidateUsageState(profileID: actual.id)
        return try accountStore.profile(id: actual.id) ?? actual
    }

    func cancelLogin() {
        terminateLoginProcess()
    }

    func updateAlias(profileID: String, alias: String?) throws {
        try accountStore.updateAlias(profileID: profileID, alias: alias)
    }

    func updateWorkspaceAlias(workspace: String, alias: String?) throws {
        try accountStore.updateWorkspaceAlias(workspace: workspace, alias: alias)
    }

    func updatePlanRenewalDate(profileID: String, date: Date?) throws {
        try accountStore.updatePlanRenewalDate(profileID: profileID, date: date)
    }

    func updateOrder(profileIDs: [String]) throws {
        try accountStore.updateOrder(profileIDs)
    }

    func removeAccount(profileID: String) throws {
        guard let profile = try accountStore.profile(id: profileID) else {
            throw ClaudeNativeError.profileMissing
        }
        if let active = try currentConfigIfPresent()?.oauthAccount,
           profile.matches(oauthAccount: active) {
            try accountStore.setHidden(profileID: profileID, hidden: true)
            invalidateUsageState(profileID: profileID)
            return
        }

        let credential = try keychain.read(
            service: ClaudeKeychainStore.profileService,
            account: profileID
        )
        let previous = try keychain.read(
            service: ClaudeKeychainStore.profileService,
            account: previousCredentialAccount(profileID)
        )
        do {
            try keychain.delete(service: ClaudeKeychainStore.profileService, account: profileID)
            try keychain.delete(
                service: ClaudeKeychainStore.profileService,
                account: previousCredentialAccount(profileID)
            )
            try accountStore.remove(profileID: profileID)
            invalidateUsageState(profileID: profileID)
        } catch {
            if let credential {
                try? keychain.write(
                    service: ClaudeKeychainStore.profileService,
                    account: profileID,
                    value: credential
                )
            }
            if let previous {
                try? keychain.write(
                    service: ClaudeKeychainStore.profileService,
                    account: previousCredentialAccount(profileID),
                    value: previous
                )
            }
            throw error
        }
    }

    func switchAccount(profileID: String) throws {
        guard let target = try accountStore.profile(id: profileID),
              let targetCredential = try keychain.read(
                service: ClaudeKeychainStore.profileService,
                account: profileID
              ) else {
            throw ClaudeNativeError.profileMissing
        }
        let targetEnvelope = try ClaudeCredentialEnvelope(rawValue: targetCredential)
        guard let targetOAuthAccount = target.oauthAccount else {
            throw ClaudeNativeError.invalidAccountMetadata
        }

        let configSnapshot = try configStore.read()
        let activeAccountName = keychain.activeAccountName
        let originalCredential = try keychain.read(
            service: ClaudeKeychainStore.activeService,
            account: activeAccountName
        )
        let originalEnvelope = try originalCredential.map(ClaudeCredentialEnvelope.init(rawValue:))
        if target.matches(oauthAccount: configSnapshot.oauthAccount ?? [:]) {
            if let originalCredential {
                try writeProfileCredential(originalCredential, profileID: target.id)
            }
            return
        }

        try syncOutgoingAccount(
            configSnapshot: configSnapshot,
            activeCredential: originalCredential
        )
        if let originalCredential {
            try keychain.write(
                service: ClaudeKeychainStore.safetyService,
                account: ClaudeKeychainStore.safetyAccount,
                value: originalCredential
            )
        }
        let composed = try targetEnvelope.mergingLiveSharedFields(from: originalEnvelope)
        do {
            try keychain.write(
                service: ClaudeKeychainStore.activeService,
                account: activeAccountName,
                value: composed
            )
            try configStore.writeCredentialShadowIfPresent(composed)
            try configStore.writeOAuthAccount(targetOAuthAccount)
            try verifySwitch(target: target, expectedCredential: composed)
            try keychain.delete(
                service: ClaudeKeychainStore.safetyService,
                account: ClaudeKeychainStore.safetyAccount
            )
        } catch {
            do {
                try restoreSwitch(
                    configSnapshot: configSnapshot,
                    activeCredential: originalCredential
                )
            } catch {
                throw ClaudeNativeError.switchVerificationFailed
            }
            throw error
        }
    }

    private func loadAccount(
        _ profile: ClaudeNativeProfile,
        isActive: Bool,
        now: Date
    ) async -> Account {
        if let nextRefresh = nextAllowedUsageRefresh[profile.id], now < nextRefresh {
            return cachedAccount(profile, isActive: isActive, now: now)
                ?? account(profile, isActive: isActive, status: .unavailable, windows: [])
        }

        do {
            let credential: String?
            if isActive {
                credential = try keychain.read(
                    service: ClaudeKeychainStore.activeService,
                    account: keychain.activeAccountName
                )
                if let credential {
                    try writeProfileCredential(credential, profileID: profile.id)
                }
            } else {
                credential = try keychain.read(
                    service: ClaudeKeychainStore.profileService,
                    account: profile.id
                )
            }
            guard let credential else {
                return account(
                    profile,
                    isActive: isActive,
                    status: .noCredentials,
                    windows: []
                )
            }

            let result = try await usageClient.fetchUsage(
                credential: credential,
                expectedAccountUUID: profile.accountUUID,
                refreshIfNeeded: !isActive
            )
            if result.credential != credential {
                try writeProfileCredential(result.credential, profileID: profile.id)
            }
            let windows = usageWindows(result.response, now: now)
            let fableWindow = fableQuotaWindow(result.response, now: now)
            if !windows.isEmpty {
                usageCache[profile.id] = CachedUsage(
                    windows: windows,
                    fableWindow: fableWindow,
                    fetchedAt: now
                )
            }
            nextAllowedUsageRefresh[profile.id] = now.addingTimeInterval(
                Self.minimumUsageRefreshInterval
            )
            return account(
                profile,
                isActive: isActive,
                status: windows.isEmpty ? .unavailable : .ok,
                windows: windows,
                fableWindow: fableWindow
            )
        } catch let error as ClaudeNativeError {
            let status: ClaudeAccountStatus
            switch error {
            case .refreshRejected:
                status = .reloginRequired
            case .invalidCredentials:
                status = .noCredentials
            case .keychainUnavailable:
                status = .keychainUnavailable
            case let .rateLimited(retryAfter):
                deferUsageRefresh(profileID: profile.id, now: now, retryAfter: retryAfter)
                return cachedAccount(profile, isActive: isActive, now: now)
                    ?? account(profile, isActive: isActive, status: .unavailable, windows: [])
            case .networkUnavailable:
                deferUsageRefresh(profileID: profile.id, now: now)
                return cachedAccount(profile, isActive: isActive, now: now)
                    ?? account(profile, isActive: isActive, status: .unavailable, windows: [])
            case let .serviceUnavailable(statusCode) where statusCode >= 500:
                deferUsageRefresh(profileID: profile.id, now: now)
                return cachedAccount(profile, isActive: isActive, now: now)
                    ?? account(profile, isActive: isActive, status: .unavailable, windows: [])
            default:
                status = .unavailable
            }
            return account(profile, isActive: isActive, status: status, windows: [])
        } catch {
            return account(profile, isActive: isActive, status: .unavailable, windows: [])
        }
    }

    private func account(
        _ profile: ClaudeNativeProfile,
        isActive: Bool,
        status: ClaudeAccountStatus,
        windows: [QuotaWindow],
        fableWindow: QuotaWindow? = nil
    ) -> Account {
        let fiveHour = windows.first { $0.kind == .fiveHour }
        let weekly = windows.first { $0.kind == .weekly }
        let hasUsage = (status == .ok || status == .cached) && !windows.isEmpty
        return Account(
            id: "claude-native:\(profile.id)",
            profileKey: nil,
            email: profile.email,
            alias: profile.alias,
            workspace: profile.workspaceName,
            workspaceAlias: profile.workspaceAlias,
            plan: profile.planDisplayName ?? "Claude",
            sessionFree: fiveHour?.remainingPercent ?? 0,
            weeklyFree: weekly?.remainingPercent ?? 0,
            sessionResetSeconds: fiveHour?.resetAfterSeconds ?? 0,
            weeklyResetSeconds: weekly?.resetAfterSeconds ?? 0,
            quotaWindows: hasUsage ? windows : [],
            fableQuotaWindow: hasUsage ? fableWindow : nil,
            planRenewalDate: profile.planRenewalDate,
            hasError: !hasUsage,
            errorMessage: status.errorMessage,
            provider: .claude,
            providerAccountNumber: nil,
            providerProfileID: profile.id,
            providerIsActive: isActive,
            providerStatus: status.rawValue
        )
    }

    private func seedUsageCache(from accounts: [Account], fetchedAt: Date?) {
        guard let fetchedAt else { return }
        for account in accounts where account.isClaudeAccount && !account.hasError {
            guard let profileID = account.providerProfileID,
                  usageCache[profileID] == nil,
                  !account.usageWindows.isEmpty else {
                continue
            }
            usageCache[profileID] = CachedUsage(
                windows: account.usageWindows,
                fableWindow: account.fableQuotaWindow,
                fetchedAt: fetchedAt
            )
        }
    }

    private func cachedAccount(
        _ profile: ClaudeNativeProfile,
        isActive: Bool,
        now: Date
    ) -> Account? {
        guard let cached = usageCache[profile.id] else { return nil }
        let elapsed = max(0, now.timeIntervalSince(cached.fetchedAt))
        return account(
            profile,
            isActive: isActive,
            status: .cached,
            windows: cached.windows.map { adjusted($0, elapsed: elapsed) },
            fableWindow: cached.fableWindow.map { adjusted($0, elapsed: elapsed) }
        )
    }

    private func adjusted(_ window: QuotaWindow, elapsed: TimeInterval) -> QuotaWindow {
        QuotaWindow(
            limitSeconds: window.limitSeconds,
            remainingPercent: window.remainingPercent,
            resetAfterSeconds: max(0, window.resetAfterSeconds - elapsed)
        )
    }

    private func deferUsageRefresh(
        profileID: String,
        now: Date,
        retryAfter: TimeInterval? = nil
    ) {
        let delay = max(Self.minimumUsageRefreshInterval, retryAfter ?? 0)
        nextAllowedUsageRefresh[profileID] = now.addingTimeInterval(delay)
    }

    private func invalidateUsageState(profileID: String) {
        usageCache[profileID] = nil
        nextAllowedUsageRefresh[profileID] = nil
    }

    private func usageWindows(_ response: ClaudeUsageResponse, now: Date) -> [QuotaWindow] {
        [
            response.fiveHour.map {
                QuotaWindow(
                    limitSeconds: QuotaWindow.fiveHourSeconds,
                    remainingPercent: 100 - $0.utilization,
                    resetAfterSeconds: resetSeconds($0.resetsAt, now: now)
                )
            },
            response.sevenDay.map {
                QuotaWindow(
                    limitSeconds: QuotaWindow.weeklySeconds,
                    remainingPercent: 100 - $0.utilization,
                    resetAfterSeconds: resetSeconds($0.resetsAt, now: now)
                )
            },
        ].compactMap { $0 }
    }

    private func fableQuotaWindow(_ response: ClaudeUsageResponse, now: Date) -> QuotaWindow? {
        response.fable.map {
            QuotaWindow(
                limitSeconds: QuotaWindow.weeklySeconds,
                remainingPercent: 100 - $0.utilization,
                resetAfterSeconds: resetSeconds($0.resetsAt, now: now)
            )
        }
    }

    private func resetSeconds(_ value: String?, now: Date) -> TimeInterval {
        guard let value else { return 0 }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
        return max(0, date?.timeIntervalSince(now) ?? 0)
    }

    @discardableResult
    private func captureCurrentActiveIfAvailable() throws -> ClaudeNativeProfile? {
        guard let config = try currentConfigIfPresent(),
              let oauthAccount = config.oauthAccount else {
            return nil
        }
        guard let credential = try keychain.read(
            service: ClaudeKeychainStore.activeService,
            account: keychain.activeAccountName
        ) else {
            return nil
        }
        _ = try ClaudeCredentialEnvelope(rawValue: credential)
        let identity = ClaudeIdentity(oauthAccount: oauthAccount)
        let profile = try accountStore.upsert(identity: identity, oauthAccount: oauthAccount)
        try writeProfileCredential(credential, profileID: profile.id)
        return profile
    }

    private func captureCurrentActiveBeforeLogin() throws {
        let config = try currentConfigIfPresent()
        let credential = try keychain.read(
            service: ClaudeKeychainStore.activeService,
            account: keychain.activeAccountName
        )
        guard credential != nil else { return }
        guard config?.oauthAccount != nil else {
            throw ClaudeNativeError.invalidAccountMetadata
        }
        _ = try captureCurrentActiveIfAvailable()
    }

    private func currentConfigIfPresent() throws -> ClaudeGlobalConfigSnapshot? {
        do {
            return try configStore.read()
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileReadNoSuchFileError {
                return nil
            }
            throw error
        }
    }

    private func recoverInterruptedSwitchIfNeeded() throws {
        guard let config = try currentConfigIfPresent(),
              let oauthAccount = config.oauthAccount,
              let safetyCredential = try keychain.read(
                service: ClaudeKeychainStore.safetyService,
                account: ClaudeKeychainStore.safetyAccount
              ) else {
            return
        }
        let identity = ClaudeIdentity(oauthAccount: oauthAccount)
        guard identity.isValid else { return }
        let matchingProfile = try accountStore.load().first {
            $0.id == identity.profileID || $0.matches(oauthAccount: oauthAccount)
        }
        guard let matchingProfile,
              let expectedCredential = try keychain.read(
                service: ClaudeKeychainStore.profileService,
                account: matchingProfile.id
              ) else {
            return
        }
        let activeCredential = try keychain.read(
            service: ClaudeKeychainStore.activeService,
            account: keychain.activeAccountName
        )

        if activeCredential == expectedCredential {
            try keychain.delete(
                service: ClaudeKeychainStore.safetyService,
                account: ClaudeKeychainStore.safetyAccount
            )
            return
        }
        guard safetyCredential == expectedCredential else { return }
        try keychain.write(
            service: ClaudeKeychainStore.activeService,
            account: keychain.activeAccountName,
            value: safetyCredential
        )
        try configStore.writeCredentialShadowIfPresent(safetyCredential)
        try keychain.delete(
            service: ClaudeKeychainStore.safetyService,
            account: ClaudeKeychainStore.safetyAccount
        )
    }

    private func captureLoggedInAccount(
        expectedProfile: ClaudeNativeProfile?
    ) throws -> ClaudeNativeProfile {
        guard let profile = try captureCurrentActiveIfAvailable() else {
            throw ClaudeNativeError.invalidAccountMetadata
        }
        if let expectedProfile, profile.id != expectedProfile.id {
            return profile
        }
        return profile
    }

    private func syncOutgoingAccount(
        configSnapshot: ClaudeGlobalConfigSnapshot,
        activeCredential: String?
    ) throws {
        guard let oauthAccount = configSnapshot.oauthAccount,
              let activeCredential else { return }
        let identity = ClaudeIdentity(oauthAccount: oauthAccount)
        guard identity.isValid else { return }
        let profile = try accountStore.upsert(identity: identity, oauthAccount: oauthAccount)
        try writeProfileCredential(activeCredential, profileID: profile.id)
    }

    private func writeProfileCredential(_ value: String, profileID: String) throws {
        let current = try keychain.read(
            service: ClaudeKeychainStore.profileService,
            account: profileID
        )
        if let current, current != value {
            try keychain.write(
                service: ClaudeKeychainStore.profileService,
                account: previousCredentialAccount(profileID),
                value: current
            )
        }
        try keychain.write(
            service: ClaudeKeychainStore.profileService,
            account: profileID,
            value: value
        )
    }

    private func previousCredentialAccount(_ profileID: String) -> String {
        "\(profileID).previous"
    }

    private func verifySwitch(target: ClaudeNativeProfile, expectedCredential: String) throws {
        let active = try keychain.read(
            service: ClaudeKeychainStore.activeService,
            account: keychain.activeAccountName
        )
        let config = try configStore.read()
        guard active == expectedCredential,
              let oauthAccount = config.oauthAccount,
              target.matches(oauthAccount: oauthAccount) else {
            throw ClaudeNativeError.switchVerificationFailed
        }
    }

    private func restoreSwitch(
        configSnapshot: ClaudeGlobalConfigSnapshot,
        activeCredential: String?
    ) throws {
        if let activeCredential {
            try keychain.write(
                service: ClaudeKeychainStore.activeService,
                account: keychain.activeAccountName,
                value: activeCredential
            )
            try configStore.writeCredentialShadowIfPresent(activeCredential)
        } else {
            try keychain.delete(
                service: ClaudeKeychainStore.activeService,
                account: keychain.activeAccountName
            )
        }
        try configStore.restore(configSnapshot)
    }

    private func runLogin(email: String?) async throws {
        guard let executableURL = resolvedClaudeExecutableURL() else {
            throw ClaudeNativeError.claudeCLIUnavailable
        }
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("CodexVitals-Claude-Login-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: temporaryDirectory) }
        let outputURL = temporaryDirectory.appendingPathComponent("output.log")
        fileManager.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        let process = Process()
        process.executableURL = executableURL
        var arguments = ["auth", "login", "--claudeai"]
        if let email = Account.normalizedAlias(email) {
            arguments += ["--email", email]
        }
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.commandSearchPath(executableURL: executableURL)
        process.environment = environment
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        try process.run()
        loginProcess = process
        defer { loginProcess = nil }

        let deadline = Date().addingTimeInterval(10 * 60)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else {
                    terminate(process)
                    throw ClaudeNativeError.loginTimedOut
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch is CancellationError {
            terminate(process)
            throw CancellationError()
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ClaudeNativeError.loginFailed(Int(process.terminationStatus))
        }
    }

    private func resolvedClaudeExecutableURL() -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".volta/bin/claude"),
            home.appendingPathComponent(".bun/bin/claude"),
            home.appendingPathComponent(".asdf/shims/claude"),
            home.appendingPathComponent(".npm-global/bin/claude"),
        ]
        candidates += Self.baseCommandSearchDirectories.map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("claude")
        }
        let nvmVersions = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmVersions,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates += versions.map { $0.appendingPathComponent("bin/claude") }
        }
        var seen = Set<String>()
        return candidates.first {
            seen.insert($0.standardizedFileURL.path).inserted
                && fileManager.isExecutableFile(atPath: $0.path)
        }
    }

    private func terminateLoginProcess() {
        guard let process = loginProcess else { return }
        terminate(process)
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline {
            Darwin.usleep(25_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private static var baseCommandSearchDirectories: [String] {
        var directories = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        directories += ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        var seen = Set<String>()
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func commandSearchPath(executableURL: URL) -> String {
        var directories = [executableURL.deletingLastPathComponent().path]
        directories += baseCommandSearchDirectories
        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }.joined(separator: ":")
    }
}
