import SwiftUI
import AppKit

private enum AccountAliasPrompt {
    static func edit(account: Account, save: (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = account.hasDisplayAlias ? "Edit Account Alias" : "Set Account Alias"
        alert.informativeText = account.email
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = account.displayAlias ?? ""
        textField.placeholderString = "Display alias"
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            save(Account.normalizedAlias(textField.stringValue))
        }
    }
}

private enum WorkspaceAliasPrompt {
    static func edit(workspace: String, displayName: String, hasAlias: Bool, save: (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = hasAlias ? "Edit Workspace Name" : "Set Workspace Name"
        alert.informativeText = hasAlias ? "Original: \(workspace)" : workspace
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = hasAlias ? displayName : ""
        textField.placeholderString = "Display name"
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            save(Account.normalizedAlias(textField.stringValue))
        }
    }
}

struct AccountListView: View {
    @ObservedObject var vm: UsageViewModel

    var body: some View {
        listBody
    }

    @ViewBuilder
    private var listBody: some View {
        VStack(spacing: 6) {
            ForEach(providerSections, id: \.provider) { section in
                providerSection(section.provider, accountCount: section.accounts.count)
            }
        }
        .padding(.vertical, 4)
    }

    private var displayedAccounts: [Account] {
        vm.priorityAccounts
            + vm.normalActiveAccounts
            + vm.nonFreeExhaustedAccounts
            + vm.freeWaitingAccounts
    }

    private var providerSections: [(provider: AccountProvider, accounts: [Account])] {
        UsageViewModel.groupByProvider(displayedAccounts)
    }

    @ViewBuilder
    private func providerSection(_ provider: AccountProvider, accountCount: Int) -> some View {
        VStack(spacing: 0) {
            ProviderSectionHeader(provider: provider, count: accountCount)
            if vm.groupByWorkspace && provider == .codex {
                groupedProviderContent(provider)
            } else {
                flatProviderContent(provider)
            }
        }
        .background(Theme.providerSectionSurface(for: provider))
    }

    @ViewBuilder
    private func flatProviderContent(_ provider: AccountProvider) -> some View {
        let priority = providerAccounts(vm.priorityAccounts, provider: provider)
        let active = providerAccounts(vm.normalActiveAccounts, provider: provider)
        let exhausted = providerAccounts(vm.exhaustedAccounts, provider: provider)

        if !priority.isEmpty {
            PrioritySeparatorHeader(count: priority.count)
            rows(priority)
        }
        if !active.isEmpty {
            rows(active)
        }
        if !exhausted.isEmpty {
            waitingForResetGroup(count: exhausted.count) {
                rows(providerAccounts(vm.nonFreeExhaustedAccounts, provider: provider))
                freeWaitingGroup(provider)
            }
        }
    }

    @ViewBuilder
    private func groupedProviderContent(_ provider: AccountProvider) -> some View {
        let priority = providerAccounts(vm.priorityAccounts, provider: provider)
        let active = providerAccounts(vm.normalActiveAccounts, provider: provider)
        let exhausted = providerAccounts(vm.exhaustedAccounts, provider: provider)

        if !priority.isEmpty {
            PrioritySeparatorHeader(count: priority.count)
            workspaceGroups(providerGroups(vm.groupedPriorityAccounts, provider: provider))
        }
        if !active.isEmpty {
            workspaceGroups(providerGroups(vm.groupedNormalActiveAccounts, provider: provider))
        }
        if !exhausted.isEmpty {
            waitingForResetGroup(count: exhausted.count) {
                workspaceGroups(providerGroups(vm.groupedExhaustedAccounts, provider: provider))
                freeWaitingGroup(provider)
            }
        }
    }

    @ViewBuilder
    private func workspaceGroups(_ groups: [(String, [Account])]) -> some View {
        ForEach(groups, id: \.0) { ws, accs in
            SectionHeader(
                originalName: ws,
                displayName: vm.workspaceDisplayName(for: ws),
                count: accs.count,
                hasAlias: vm.workspaceHasDisplayAlias(ws),
                setAlias: { vm.setWorkspaceAlias($0, for: ws) }
            )
            rows(accs)
        }
    }

    private func providerAccounts(_ accounts: [Account], provider: AccountProvider) -> [Account] {
        accounts.filter { $0.accountProvider == provider }
    }

    private func providerGroups(
        _ groups: [(String, [Account])],
        provider: AccountProvider
    ) -> [(String, [Account])] {
        groups.compactMap { workspace, accounts in
            let filtered = providerAccounts(accounts, provider: provider)
            return filtered.isEmpty ? nil : (workspace, filtered)
        }
    }

    @ViewBuilder
    private func waitingForResetGroup<Content: View>(
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isCollapsed = vm.waitingForResetCollapsed && vm.searchText.isEmpty
        ExhaustedSeparatorHeader(
            count: count,
            isCollapsed: isCollapsed,
            toggle: { vm.toggleWaitingForResetCollapsed() }
        )
        if !isCollapsed {
            content()
        }
    }

    @ViewBuilder
    private func freeWaitingGroup(_ provider: AccountProvider) -> some View {
        let accounts = providerAccounts(vm.freeWaitingAccounts, provider: provider)
        if !accounts.isEmpty {
            let isCollapsed = vm.freeWaitingCollapsed && vm.searchText.isEmpty
            FreeWaitingGroupHeader(
                count: accounts.count,
                isCollapsed: isCollapsed,
                toggle: { vm.toggleFreeWaitingCollapsed() }
            )
            if !isCollapsed {
                rows(accounts)
            }
        }
    }

    @ViewBuilder
    private func rows(_ accs: [Account]) -> some View {
        ForEach(Array(accs.enumerated()), id: \.element.id) { i, acc in
            accountRow(for: acc)
            if i < accs.count - 1 {
                Rectangle()
                    .fill(Theme.listDivider)
                    .frame(height: 0.5)
                    .padding(.horizontal, 10)
            }
        }
    }

    @ViewBuilder
    private func accountRow(for acc: Account) -> some View {
        AccountCompactRow(
            account: acc,
            needsRelogin: vm.needsRelogin(acc),
            isRelogging: vm.isRelogging(acc),
            isReloginBlocked: vm.hasPendingAccountAction && !vm.isRelogging(acc),
            isSwitchingAccount: vm.isSwitchingAccount(acc),
            isActiveAccount: vm.isActiveAccount(acc),
            showsSwitchControls: vm.showsSwitchControls(for: acc),
            canSwitchAccount: vm.canSwitchAccount(acc),
            isSwitchBlocked: vm.hasPendingAccountAction && !vm.isSwitchingAccount(acc),
            isRemoving: vm.isRemoving(acc),
            isRemoveBlocked: vm.hasPendingAccountAction && !vm.isRemoving(acc),
            allowsRemoval: !acc.isClaudeAccount || !vm.isActiveAccount(acc),
            allowsAlias: true,
            canMoveUp: vm.canMoveAccount(acc, direction: .up),
            canMoveDown: vm.canMoveAccount(acc, direction: .down),
            relogin: { vm.relogin(acc) },
            cancelRelogin: { vm.cancelRelogin() },
            switchAccount: { vm.switchAccount(to: acc) },
            removeAccount: { vm.removeAccount(acc) },
            setAlias: { vm.setAlias($0, for: acc) },
            moveUp: { vm.moveAccount(acc, direction: .up) },
            moveDown: { vm.moveAccount(acc, direction: .down) }
        )
    }
}

// MARK: - Section Headers

struct ProviderSectionHeader: View {
    let provider: AccountProvider
    let count: Int

    var body: some View {
        HStack(spacing: 7) {
            ProviderIconView(provider: provider, usesProviderColor: true)
            Text("\(provider.displayName.uppercased()) (\(count))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.providerText(for: provider))
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 29)
        .background(Theme.providerHeaderSurface(for: provider))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.providerBorder(for: provider))
                .frame(height: 0.5)
        }
    }
}

struct SectionHeader: View {
    let originalName: String
    let displayName: String
    let count: Int
    let hasAlias: Bool
    let setAlias: (String?) -> Void

    var body: some View {
        HStack {
            Text("\(displayName.uppercased()) (\(count))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12).frame(height: 27)
        .background(Theme.sectionSurface)
        .contentShape(Rectangle())
        .contextMenu {
            Button(hasAlias ? "Edit Workspace Name..." : "Set Workspace Name...") {
                WorkspaceAliasPrompt.edit(
                    workspace: originalName,
                    displayName: displayName,
                    hasAlias: hasAlias,
                    save: setAlias
                )
            }
            if hasAlias {
                Button("Clear Workspace Name") {
                    setAlias(nil)
                }
            }
        }
        .help(hasAlias ? "Original workspace: \(originalName)" : "Set workspace display name")
    }
}

struct PrioritySeparatorHeader: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.warningText)
            Text("PRIORITY (\(count))")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
    }
}

struct ExhaustedSeparatorHeader: View {
    let count: Int
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 10)
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("WAITING FOR RESET (\(count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 27)
            .background(Theme.sectionSurface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "Show waiting accounts" : "Hide waiting accounts")
    }
}

struct FreeWaitingGroupHeader: View {
    let count: Int
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 10)
                Text("FREE (\(count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 27)
            .background(Theme.sectionSurface.opacity(0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "Show free accounts" : "Hide free accounts")
    }
}

// MARK: - Expanded Row

struct AccountRow: View {
    let account: Account
    var setAlias: (String?) -> Void = { _ in }
    var canMoveUp = false
    var canMoveDown = false
    var moveUp: () -> Void = {}
    var moveDown: () -> Void = {}
    @State private var hovered = false

    private var exhausted: Bool { account.isWeeklyExhausted }

    var body: some View {
        let windows = account.usageWindows.filter { !exhausted || $0.kind == .weekly }
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 6, height: 6)
                accountIdentity
                Spacer()
                WorkspaceChip(ws: account.displayWorkspaceName, colorKey: account.workspace, compact: false)
            }
            .opacity(exhausted ? 0.5 : 1)

            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                BarRow(
                    label: window.label,
                    pct: window.remainingPercent,
                    resetSeconds: window.resetAfterSeconds,
                    style: window.kind == .weekly && exhausted ? .weeklyExhausted : .normal,
                    urgentReset: window.kind == .weekly && account.isWeeklyResetUrgent
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, windows.count > 1 ? 8 : 6)
        .frame(
            maxWidth: .infinity,
            minHeight: 38 + CGFloat(max(0, windows.count - 1)) * 18,
            alignment: .leading
        )
        .background(hovered ? Color.primary.opacity(0.06) : .clear)
        .onHover { hovered = $0 }
        .contextMenu {
            if !account.isClaudeAccount {
                Button("Move Up") {
                    moveUp()
                }
                .disabled(!canMoveUp)
                Button("Move Down") {
                    moveDown()
                }
                .disabled(!canMoveDown)
                Divider()
                Divider()
            }
            Button(account.hasDisplayAlias ? "Edit Alias..." : "Set Alias...") {
                AccountAliasPrompt.edit(account: account, save: setAlias)
            }
            if account.hasDisplayAlias {
                Button("Clear Alias") {
                    setAlias(nil)
                }
            }
            Divider()
            Button("Copy email") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(account.email, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var accountIdentity: some View {
        if account.hasDisplayAlias {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    PlanBadge(text: account.displayPlanName, compact: false)
                    Text(account.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(account.email)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            HStack(spacing: 5) {
                Text(account.email)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                PlanBadge(text: account.displayPlanName, compact: false)
            }
        }
    }
}

// MARK: - Compact Row

private enum CompactRowLayout {
    static let horizontalPadding: CGFloat = 12
    static let emailMinWidth: CGFloat = 176
    static let actionWidth: CGFloat = 24

    struct Metrics {
        let spacing: CGFloat
        let emailWidth: CGFloat
        let workspaceWidth: CGFloat
        let metricWidth: CGFloat
        let sessionResetWidth: CGFloat
        let weeklyResetWidth: CGFloat
        let quotaAreaWidth: CGFloat
        let planCycleWidth: CGFloat
        let actionWidth: CGFloat
    }

    static func metrics(totalWidth: CGFloat) -> Metrics {
        let spacing: CGFloat = 3
        let contentWidth = max(0, totalWidth - horizontalPadding * 2)
        let workspaceWidth: CGFloat = 58
        let metricWidth: CGFloat = 84
        let sessionResetWidth: CGFloat = 42
        let weeklyResetWidth: CGFloat = 56
        let planCycleWidth: CGFloat = 34
        let quotaAreaWidth = metricWidth * 2
            + weeklyResetWidth * 2
            + spacing
            + 4
        let fixedWidth = 16
            + workspaceWidth
            + actionWidth
            + quotaAreaWidth
            + planCycleWidth
            + spacing * 5

        return Metrics(
            spacing: spacing,
            emailWidth: max(emailMinWidth, contentWidth - fixedWidth),
            workspaceWidth: workspaceWidth,
            metricWidth: metricWidth,
            sessionResetWidth: sessionResetWidth,
            weeklyResetWidth: weeklyResetWidth,
            quotaAreaWidth: quotaAreaWidth,
            planCycleWidth: planCycleWidth,
            actionWidth: actionWidth
        )
    }
}

struct AccountCompactRow: View {
    let account: Account
    let needsRelogin: Bool
    let isRelogging: Bool
    let isReloginBlocked: Bool
    let isSwitchingAccount: Bool
    let isActiveAccount: Bool
    let showsSwitchControls: Bool
    let canSwitchAccount: Bool
    let isSwitchBlocked: Bool
    let isRemoving: Bool
    let isRemoveBlocked: Bool
    let allowsRemoval: Bool
    let allowsAlias: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let relogin: () -> Void
    let cancelRelogin: () -> Void
    let switchAccount: () -> Void
    let removeAccount: () -> Void
    let setAlias: (String?) -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    @State private var hovered = false
    @State private var isShowingRemovalConfirmation = false

    private var exhausted: Bool { account.isWeeklyExhausted }
    private var hasFableQuota: Bool {
        account.isClaudeAccount && account.fableQuotaWindow != nil
    }
    private var rowHeight: CGFloat {
        let baseHeight: CGFloat = account.hasDisplayAlias ? 40 : 34
        return baseHeight + (hasFableQuota ? 22 : 0)
    }
    private var canShowSwapControl: Bool {
        showsSwitchControls
            && canSwitchAccount
            && !isActiveAccount
            && !needsRelogin
            && !isRelogging
    }

    private var rowBackgroundColor: Color {
        if isActiveAccount {
            return Theme.activeRowSurface.opacity(hovered ? 1 : 0.78)
        }
        return hovered ? Theme.rowHoverSurface : .clear
    }

    private var rowBorderColor: Color {
        if isActiveAccount {
            return Theme.activeRowBorder
        }
        return hovered ? Theme.rowHoverBorder : .clear
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = CompactRowLayout.metrics(totalWidth: proxy.size.width)
            let freeResetWidth = layout.quotaAreaWidth
                + layout.planCycleWidth
                + layout.spacing
            HStack(alignment: .center, spacing: layout.spacing) {
                leadingAccountControl

                accountIdentityView
                    .frame(width: layout.emailWidth, alignment: .leading)

                WorkspaceChip(ws: account.displayWorkspaceName, colorKey: account.workspace, compact: true)
                    .frame(width: layout.workspaceWidth, alignment: .leading)

                if needsRelogin || isRelogging {
                    accountActionControl(width: layout.actionWidth)
                    reconnectStatus(width: freeResetWidth, alignment: .leading)
                } else if account.isFreeWaitingForReset {
                    accountActionControl(width: layout.actionWidth)
                    freeResetStatus(width: freeResetWidth, alignment: .leading)
                } else {
                    accountActionControl(width: layout.actionWidth)
                    usageMetrics(layout: layout)
                }
            }
            .padding(.horizontal, CompactRowLayout.horizontalPadding)
            .padding(.vertical, 7)
            .frame(width: proxy.size.width, height: rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .frame(height: rowHeight)
        .background {
            RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous)
                .fill(rowBackgroundColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous)
                .stroke(rowBorderColor, lineWidth: 0.5)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
        .overlay(alignment: .leading) {
            if isActiveAccount {
                Capsule()
                    .fill(Theme.healthyAccent)
                    .frame(width: 2.5, height: max(14, rowHeight - 12))
                    .padding(.leading, 6)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .contextMenu {
            if allowsAlias {
                if !account.isClaudeAccount {
                    Button("Move Up") {
                        moveUp()
                    }
                    .disabled(!canMoveUp)
                    Button("Move Down") {
                        moveDown()
                    }
                    .disabled(!canMoveDown)
                    Divider()
                }
                Button(account.hasDisplayAlias ? "Edit Alias..." : "Set Alias...") {
                    AccountAliasPrompt.edit(account: account, save: setAlias)
                }
                if account.hasDisplayAlias {
                    Button("Clear Alias") {
                        setAlias(nil)
                    }
                }
                Divider()
            }
            Button("Copy email") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(account.email, forType: .string)
            }
            if allowsRemoval {
                Divider()
                Button("Remove Account...", role: .destructive) {
                    isShowingRemovalConfirmation = true
                }
                .disabled(isRemoveBlocked)
            }
        }
        .alert("Remove this account?", isPresented: $isShowingRemovalConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                removeAccount()
            }
        } message: {
            Text(removalConfirmationMessage)
        }
    }

    private var removalConfirmationMessage: String {
        if account.isClaudeAccount {
            return "\(account.email) will be removed from Codex Vitals. The active Claude Code account is not removed."
        }
        return "\(account.email) will be removed from Codex Vitals. A local backup is created before its saved profile is deleted."
    }

    @ViewBuilder
    private var accountIdentityView: some View {
        if account.hasDisplayAlias {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    PlanBadge(text: account.displayPlanName, compact: true)
                    Text(account.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(account.email)
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(account.email)
        } else {
            HStack(spacing: 5) {
                Text(account.email)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                PlanBadge(text: account.displayPlanName, compact: true)
            }
            .help(account.email)
        }
    }

    @ViewBuilder
    private var leadingAccountControl: some View {
        Group {
            if showsSwitchControls && isActiveAccount {
                ProviderIconView(provider: account.accountProvider)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(Theme.healthyAccent)
                            .background(Circle().fill(.black.opacity(0.72)))
                    }
                    .help("Active in \(account.accountProvider.displayName)")
            } else if isRemoving {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            } else if hovered && allowsRemoval {
                Button {
                    isShowingRemovalConfirmation = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .disabled(isRemoveBlocked)
                .help("Remove from list")
                .accessibilityLabel("Remove \(account.email)")
            } else {
                ProviderIconView(provider: account.accountProvider)
                    .opacity(0.76)
            }
        }
        .frame(width: 16, height: 18)
    }

    private func quotaMetrics(layout: CompactRowLayout.Metrics) -> some View {
        HStack(spacing: layout.spacing) {
            Spacer(minLength: 0)
            ForEach(Array(account.usageWindows.prefix(2).enumerated()), id: \.offset) { _, window in
                quotaMetricGroup(window, layout: layout)
            }
        }
        .frame(width: layout.quotaAreaWidth, alignment: .trailing)
    }

    private func usageMetrics(layout: CompactRowLayout.Metrics) -> some View {
        let width = layout.quotaAreaWidth + layout.planCycleWidth + layout.spacing
        return VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: layout.spacing) {
                quotaMetrics(layout: layout)
                planCycleText(width: layout.planCycleWidth)
            }

            if let fableWindow = account.fableQuotaWindow {
                fableQuotaMetric(fableWindow, layout: layout, width: width)
            }
        }
        .frame(width: width, alignment: .trailing)
    }

    private func fableQuotaMetric(
        _ window: QuotaWindow,
        layout: CompactRowLayout.Metrics,
        width: CGFloat
    ) -> some View {
        let dimmed = window.isExhausted
        let meterWidth = width - layout.weeklyResetWidth - 2
        return HStack(spacing: 2) {
            FableQuotaMeter(
                pct: window.remainingPercent,
                dimmed: dimmed,
                width: meterWidth
            )
            ResetTimeBadge(
                text: ResetFormatter.compact(seconds: window.resetAfterSeconds),
                color: .secondary,
                width: layout.weeklyResetWidth,
                help: ResetFormatter.fullTooltip(seconds: window.resetAfterSeconds)
            )
        }
        .frame(width: width, alignment: .trailing)
        .opacity(dimmed ? 0.76 : 1)
    }

    private func quotaMetricGroup(
        _ window: QuotaWindow,
        layout: CompactRowLayout.Metrics
    ) -> some View {
        let dimmed = window.isExhausted || (window.kind == .weekly && exhausted)
        let resetWidth = window.kind == .fiveHour
            ? layout.sessionResetWidth
            : layout.weeklyResetWidth

        return HStack(spacing: 2) {
            compactQuota(
                label: window.label,
                pct: window.remainingPercent,
                gray: dimmed,
                width: layout.metricWidth
            )
            quotaResetText(window, width: resetWidth, dimmed: dimmed)
        }
    }

    private func quotaResetText(
        _ window: QuotaWindow,
        width: CGFloat,
        dimmed: Bool
    ) -> some View {
        let urgent = window.kind == .weekly && account.isWeeklyResetUrgent && !dimmed
        let color: Color = urgent ? Theme.warningText : .secondary
        let text = window.kind == .fiveHour
            ? ResetFormatter.timeOnly(seconds: window.resetAfterSeconds)
            : ResetFormatter.compact(seconds: window.resetAfterSeconds)

        return ResetTimeBadge(
            text: text,
            color: color,
            width: width,
            help: ResetFormatter.fullTooltip(seconds: window.resetAfterSeconds),
            systemImage: urgent ? "clock" : nil
        )
        .opacity(dimmed ? 0.76 : 1)
    }

    @ViewBuilder
    private func planCycleText(width: CGFloat) -> some View {
        Group {
            if let text = PlanCycleFormatter.daysText(for: account),
               let date = account.planRenewalDate {
                PlanCycleBadge(text: text, width: width, help: PlanCycleFormatter.tooltip(for: date))
            } else {
                Color.clear.frame(width: width, height: 1)
            }
        }
    }

    @ViewBuilder
    private func accountActionControl(width: CGFloat) -> some View {
        Group {
            if isRelogging {
                Button(action: cancelRelogin) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Cancel")
            } else if isSwitchingAccount {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
            } else if canShowSwapControl {
                SwitchAccountButton(
                    action: switchAccount,
                    helpText: "Use in \(account.accountProvider.displayName)"
                )
                    .disabled(isSwitchBlocked)
                    .opacity(hovered ? 1 : 0)
                    .allowsHitTesting(hovered)
            } else {
                Color.clear.frame(width: width, height: 1)
            }
        }
        .frame(width: width, height: 18)
    }
}

struct ResetTimeBadge: View {
    let text: String
    let color: Color
    let width: CGFloat
    let help: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 2) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 7.5, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 4)
        .frame(width: width, height: 18, alignment: .center)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.metricSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Theme.metricBorder, lineWidth: 0.5)
        }
        .help(help)
    }
}

struct PlanCycleBadge: View {
    let text: String
    let width: CGFloat
    let help: String

    var body: some View {
        Text(text.lowercased())
            .font(.system(size: 9, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(Theme.warningText)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: width, height: 18, alignment: .center)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Theme.warningSurface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Theme.warningBorder, lineWidth: 0.5)
            }
            .help(help)
    }
}

struct PlanBadge: View {
    let text: String?
    var compact = false

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: compact ? 8.5 : 9, weight: .semibold))
                .foregroundStyle(Theme.workspaceTextColor(for: text))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .padding(.horizontal, compact ? 4 : 5)
                .padding(.vertical, compact ? 1 : 1.5)
                .background(Theme.workspaceColor(for: text))
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(Theme.workspaceBorderColor(for: text), lineWidth: 0.5)
                }
                .fixedSize(horizontal: true, vertical: false)
                .help("Plan: \(text)")
        }
    }
}

struct ReloginAccountButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.warningText.opacity(hovered ? 1 : 0.88))
                .frame(width: 20, height: 18)
            .background(hovered ? .thinMaterial : .ultraThinMaterial)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(Theme.warningText.opacity(hovered ? 0.36 : 0.22), lineWidth: 0.6)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Re-login")
    }
}

struct SwitchAccountButton: View {
    let action: () -> Void
    var helpText = "Use account"
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(hovered ? 0.92 : 0.78))
                .frame(width: 20, height: 18)
                .background(hovered ? .thinMaterial : .ultraThinMaterial)
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.primary.opacity(hovered ? 0.26 : 0.14), lineWidth: 0.6)
                }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(helpText)
    }
}

struct CodexIconView: View {
    var foregroundColor: Color = .primary.opacity(0.82)

    private static let image: NSImage = {
        let codexPNG = Bundle.main.url(forResource: "codex", withExtension: "png")
        let image = codexPNG.flatMap { NSImage(contentsOf: $0) }
            ?? NSWorkspace.shared.icon(forFile: "/Applications/ChatGPT.app")
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(foregroundColor)
            .frame(width: 16, height: 16)
    }
}

struct ProviderIconView: View {
    let provider: AccountProvider
    var usesProviderColor = false

    var body: some View {
        Group {
            switch provider {
            case .codex:
                CodexIconView(
                    foregroundColor: usesProviderColor
                        ? Theme.providerText(for: provider)
                        : .primary.opacity(0.82)
                )
            case .claude:
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        usesProviderColor
                            ? Theme.providerText(for: provider)
                            : Theme.warningText.opacity(0.9)
                    )
                    .frame(width: 16, height: 16)
            }
        }
    }
}

private extension AccountCompactRow {
    func reconnectStatus(width: CGFloat, alignment: Alignment) -> some View {
        Group {
            if isRelogging {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.62)
                    Text("Reconnecting...")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.primary.opacity(0.13), lineWidth: 0.6)
                }
            } else {
                Button(action: relogin) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 8.5, weight: .bold))
                        Text("Reconnect")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(Theme.warningText)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Theme.warningSurface)
                    .clipShape(Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Theme.warningBorder, lineWidth: 0.6)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isReloginBlocked)
            }
        }
        .frame(width: width, alignment: alignment)
        .help(isRelogging ? "Reconnecting account" : "Reconnect this account")
    }

    func freeResetStatus(width: CGFloat, alignment: Alignment) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Free resets \(ResetFormatter.formatFreeReturn(seconds: account.freePlanResetSeconds))")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(width: width, alignment: alignment)
        .help("Free quota resets \(ResetFormatter.fullTooltip(seconds: account.freePlanResetSeconds))")
    }

    func compactQuota(label: String, pct: Double, gray: Bool, width: CGFloat) -> some View {
        QuotaMeter(
            label: label,
            pct: pct,
            fill: gray ? Theme.weeklyExhaustedBar : Theme.barColor(for: pct),
            dimmed: gray,
            width: width
        )
    }
}

struct QuotaMeter: View {
    let label: String
    let pct: Double
    let fill: Color
    let dimmed: Bool
    let width: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 13, alignment: .leading)

            MeterTrack(pct: pct, fill: fill, height: 4, minimumFill: 2)
                .frame(width: 26)

            Text(String(format: "%.0f%%", pct))
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(dimmed ? .secondary : Theme.statusTextColor(for: pct))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 29, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .frame(width: width, height: 18, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(dimmed ? Theme.metricSurface.opacity(0.7) : Theme.metricSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Theme.metricBorder, lineWidth: 0.6)
        }
        .opacity(dimmed ? 0.76 : 1)
    }
}

struct FableQuotaMeter: View {
    let pct: Double
    let dimmed: Bool
    let width: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Text("Fable")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.providerText(for: .claude))
                .lineLimit(1)
                .frame(width: 34, alignment: .leading)

            MeterTrack(
                pct: pct,
                fill: dimmed ? Theme.weeklyExhaustedBar : Theme.barColor(for: pct),
                height: 4,
                minimumFill: 2
            )
            .frame(maxWidth: .infinity)

            Text(String(format: "%.0f%%", pct))
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(dimmed ? .secondary : Theme.statusTextColor(for: pct))
                .lineLimit(1)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(width: width, height: 18)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(dimmed ? Theme.metricSurface.opacity(0.7) : Theme.metricSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Theme.providerBorder(for: .claude), lineWidth: 0.55)
        }
        .help("Fable: \(String(format: "%.0f%%", pct)) remaining")
    }
}

struct MeterTrack: View {
    let pct: Double
    let fill: Color
    var height: CGFloat = 4
    var minimumFill: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let fillWidth = max(minimumFill, geo.size.width * max(0, min(100, pct)) / 100)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.11))
                    .frame(height: height)
                if pct > 0.001 {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [fill.opacity(0.68), fill],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: fillWidth, height: height)
                }
            }
            .frame(height: height)
        }
        .frame(height: height)
    }
}

// MARK: - Workspace Chip

struct WorkspaceChip: View {
    let ws: String
    let colorKey: String
    var compact: Bool = false

    init(ws: String, colorKey: String? = nil, compact: Bool = false) {
        self.ws = ws
        self.colorKey = colorKey ?? ws
        self.compact = compact
    }

    var body: some View {
        Text(ws)
            .font(.system(size: compact ? 9.5 : 11, weight: .medium))
            .foregroundColor(Theme.workspaceTextColor(for: colorKey))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, compact ? 1 : 2)
            .background(Theme.workspaceColor(for: colorKey))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Theme.workspaceBorderColor(for: colorKey), lineWidth: 0.5)
            }
    }
}

// MARK: - Horizontal Bar Row

enum BarRowStyle {
    case normal
    case weeklyExhausted
}

struct BarRow: View {
    let label: String
    let pct: Double
    let resetSeconds: Double
    let style: BarRowStyle
    let urgentReset: Bool

    var body: some View {
        let dimmed = style == .weeklyExhausted
        let fillColor: Color = dimmed ? Theme.weeklyExhaustedBar : Theme.barColor(for: pct)
        let textColor: Color = dimmed ? .secondary : Theme.statusTextColor(for: pct)

        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(textColor)
                .frame(width: 28, alignment: .leading)
                .opacity(dimmed ? 0.5 : 1)

            MeterTrack(pct: pct, fill: fillColor, height: 5, minimumFill: 4)
                .frame(height: 5)
                .padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(dimmed ? Theme.metricSurface.opacity(0.7) : Theme.metricSurface)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Theme.metricBorder, lineWidth: 0.5)
                }
            .opacity(dimmed ? 0.5 : 1)

            Text(String(format: "%.0f%%", pct))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(textColor)
                .frame(width: 38, alignment: .trailing)
                .opacity(dimmed ? 0.5 : 1)

            Text("·")
                .foregroundColor(.secondary.opacity(0.5))
                .opacity(dimmed ? 0.5 : 1)

            HStack(spacing: 4) {
                if urgentReset && !dimmed {
                    Image(systemName: "clock")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.warningText)
                }
                Text(dimmed ? ResetFormatter.formatReset(seconds: resetSeconds) : ResetFormatter.format(seconds: resetSeconds))
                    .font(.system(size: 11))
                    .foregroundColor(urgentReset && !dimmed ? Theme.warningText : .secondary)
                    .help(ResetFormatter.fullTooltip(seconds: resetSeconds))
            }
        }
        .frame(height: 14)
    }
}
