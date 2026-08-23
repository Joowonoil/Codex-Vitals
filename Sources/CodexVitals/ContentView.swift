import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var appUpdater: AppUpdater
    @ObservedObject var githubStarPrompt: GitHubStarPromptModel
    @State private var isShowingSettings = false

    static let preferredWidth: CGFloat = 652

    static func preferredHeight() -> CGFloat {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        return min(720, floor(visibleHeight * 0.85))
    }

    static func listMaxHeight() -> CGFloat {
        max(280, preferredHeight() - 84)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HeaderView(vm: viewModel, isShowingSettings: $isShowingSettings)
                thinDivider

                if isShowingSettings {
                    SettingsView(viewModel: viewModel, appUpdater: appUpdater)
                        .frame(maxWidth: .infinity, maxHeight: Self.listMaxHeight())
                } else {
                    if viewModel.isLoading && viewModel.accounts.isEmpty {
                        SkeletonView()
                    } else if !viewModel.hasAnyAccount {
                        emptyState
                    } else {
                        ScrollView(.vertical) {
                            AccountListView(vm: viewModel)
                                .frame(maxWidth: .infinity)
                        }
                        .background(Theme.listSurfaceTint)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.panelCornerRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.panelCornerRadius, style: .continuous)
                                .stroke(Theme.listBorder, lineWidth: 0.6)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .frame(maxHeight: Self.listMaxHeight())
                    }
                }

                thinDivider

                if !isShowingSettings && viewModel.errorsCount > 0 {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Theme.warningText)
                            .font(.system(size: 11))
                        Text("\(viewModel.errorsCount) account(s) with errors")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    thinDivider
                }

                if let accountActionError = viewModel.accountActionError {
                    FooterView(message: accountActionError)
                }
            }
            .allowsHitTesting(!githubStarPrompt.isPresented)

            if githubStarPrompt.isPresented {
                GitHubStarPromptView(model: githubStarPrompt)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: githubStarPrompt.isPresented)
        .frame(width: Self.preferredWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(
            Group {
                Button("") { isShowingSettings.toggle() }.keyboardShortcut(",", modifiers: .command)
                Button("") { viewModel.toggleGroupByWorkspace() }.keyboardShortcut("g", modifiers: [.command, .shift])
                Button("") { viewModel.refresh(forceMetadataRefresh: true) }.keyboardShortcut("r", modifiers: .command)
                Button("") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            }.opacity(0)
        )
    }

    private var thinDivider: some View { Divider().opacity(0.15) }

    @ViewBuilder
    private var emptyState: some View {
        if !viewModel.searchText.isEmpty {
            Text("No account matches '\(viewModel.searchText)'")
                .font(.system(size: 14)).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .padding(.horizontal, 16)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 32)).foregroundColor(.secondary)
                Text("No accounts found")
                    .font(.system(size: 14)).foregroundColor(.secondary)
                Menu {
                    Button("Add Codex Account", systemImage: "command") {
                        viewModel.addCodexAccount()
                    }
                    Button {
                        viewModel.addClaudeAccount()
                    } label: {
                        Label {
                            Text("Add Claude Account")
                        } icon: {
                            ClaudeIconView(foregroundColor: .primary)
                        }
                    }
                } label: {
                    Label("Add account", systemImage: "person.badge.plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .controlSize(.small)
                .disabled(viewModel.hasPendingAccountAction)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .padding(.horizontal, 16)
        }
    }
}

private struct GitHubStarPromptView: View {
    @ObservedObject var model: GitHubStarPromptModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.16)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "star.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.yellow.opacity(0.9))
                    .frame(width: 42, height: 42)
                    .background(.thinMaterial)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.7)
                    }

                VStack(spacing: 5) {
                    Text("Enjoying Codex Vitals?")
                        .font(.system(size: 16, weight: .semibold))

                    Text("A GitHub star helps more people discover this open-source project.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button("No Thanks") {
                        model.complete()
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)

                    Button {
                        model.complete()
                        NSWorkspace.shared.open(AppInfo.repositoryURL)
                    } label: {
                        Label("Star on GitHub", systemImage: "star")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.regular)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(width: 330)
            .background(Theme.toolbarSurface)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Theme.toolbarBorder, lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Support Codex Vitals on GitHub")
    }
}

// MARK: - Header

struct HeaderView: View {
    @ObservedObject var vm: UsageViewModel
    @Binding var isShowingSettings: Bool
    @State private var manualRefreshPending = false
    @State private var showsRefreshSuccess = false
    @State private var refreshSuccessTask: Task<Void, Never>?
    @State private var isSearchVisible = false

    var body: some View {
        HStack(spacing: 8) {
            if shouldShowSearchField && !isShowingSettings {
                compactSearchField
            } else {
                appBrandLockup

                if isShowingSettings {
                    Rectangle()
                        .fill(Theme.controlBorder)
                        .frame(width: 0.5, height: 14)

                    Text("Settings")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            toolbarControls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 48)
        .animation(.easeInOut(duration: 0.16), value: shouldShowSearchField)
        .onReceive(vm.$isLoading.dropFirst()) { isLoading in
            handleLoadingChange(isLoading)
        }
    }

    @ViewBuilder
    private var toolbarControls: some View {
        HStack(spacing: 1) {
            if isShowingSettings {
                HeaderActionButton(
                    action: { isShowingSettings = false },
                    helpText: "Close settings",
                    accessibilityText: "Back to accounts"
                ) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }

                toolbarDivider
            } else {
                HeaderActionButton(
                    action: toggleSearch,
                    isSelected: shouldShowSearchField,
                    helpText: shouldShowSearchField ? "Hide search" : "Search",
                    accessibilityText: shouldShowSearchField ? "Hide search" : "Search accounts"
                ) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(shouldShowSearchField ? .primary : .secondary)
                }

                if vm.isAddingAccount {
                    HeaderActionButton(
                        action: { vm.cancelRelogin() },
                        isSelected: true,
                        helpText: "Cancel adding account",
                        accessibilityText: "Cancel adding account"
                    ) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                } else {
                    HeaderAccountMenu(vm: vm)
                }

                HeaderActionButton(
                    action: { vm.toggleGroupByWorkspace() },
                    isSelected: vm.groupByWorkspace,
                    helpText: vm.groupByWorkspace ? "Ungroup workspaces" : "Group by workspace",
                    accessibilityText: vm.groupByWorkspace ? "Ungroup workspaces" : "Group accounts by workspace"
                ) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(vm.groupByWorkspace ? .primary : .secondary)
                }

                HeaderActionButton(
                    action: requestRefresh,
                    isDisabled: vm.isLoading,
                    helpText: showsRefreshSuccess ? "Updated" : "Refresh",
                    accessibilityText: showsRefreshSuccess ? "Usage updated" : "Refresh all accounts"
                ) {
                    if vm.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else if showsRefreshSuccess {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.healthyAccent)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }

                toolbarDivider

                HeaderActionButton(
                    action: { isShowingSettings = true },
                    helpText: "Settings",
                    accessibilityText: "Settings"
                ) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }

            HeaderActionButton(
                action: { NSApp.terminate(nil) },
                helpText: "Quit Codex Vitals",
                accessibilityText: "Quit Codex Vitals"
            ) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(3)
        .background(Theme.toolbarSurface)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(Theme.toolbarBorder, lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.045), radius: 2.5, y: 1)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Theme.controlBorder)
            .frame(width: 0.5, height: 14)
            .padding(.horizontal, 1)
    }

    private func toggleSearch() {
        if shouldShowSearchField && vm.searchText.isEmpty {
            isSearchVisible = false
        } else {
            isSearchVisible = true
        }
    }

    private var shouldShowSearchField: Bool {
        isSearchVisible || !vm.searchText.isEmpty
    }

    private var appBrandLockup: some View {
        HStack(spacing: 7) {
            AppBrandIcon()
                .frame(width: 22, height: 22)

            Text("Codex Vitals")
                .font(Theme.appTitleFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .fixedSize()
        .help("Codex Vitals")
        .transition(.opacity)
    }

    private var compactSearchField: some View {
        HStack(spacing: 6) {
            SearchTextField("Search", text: $vm.searchText)
                .frame(width: searchFieldWidth)
                .frame(minHeight: 16)

            if !vm.searchText.isEmpty {
                Button {
                    vm.searchText = ""
                    isSearchVisible = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.toolbarSurface)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous)
                .stroke(Theme.controlBorder, lineWidth: 0.6)
        }
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    private var searchFieldWidth: CGFloat {
        170
    }

    private func requestRefresh() {
        guard !vm.isLoading else { return }
        manualRefreshPending = true
        showsRefreshSuccess = false
        refreshSuccessTask?.cancel()
        vm.refresh(forceMetadataRefresh: true)
    }

    private func handleLoadingChange(_ isLoading: Bool) {
        guard !isLoading, manualRefreshPending else { return }
        manualRefreshPending = false
        showsRefreshSuccess = true
        refreshSuccessTask?.cancel()
        refreshSuccessTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            showsRefreshSuccess = false
        }
    }
}

private struct HeaderAccountMenu: View {
    @ObservedObject var vm: UsageViewModel
    @State private var isHovered = false

    var body: some View {
        Menu {
            Button("Add Codex Account", systemImage: "command") {
                vm.addCodexAccount()
            }
            Button {
                vm.addClaudeAccount()
            } label: {
                Label {
                    Text("Add Claude Account")
                } icon: {
                    ClaudeIconView(foregroundColor: .primary)
                }
            }
        } label: {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.healthyAccent)
                .frame(width: 26, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous)
                        .fill(isHovered ? Theme.controlHoverSurface : .clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous)
                        .stroke(isHovered ? Theme.controlBorder : .clear, lineWidth: 0.5)
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(vm.hasPendingAccountAction)
        .opacity(vm.hasPendingAccountAction ? 0.55 : 1)
        .scaleEffect(isHovered && !vm.hasPendingAccountAction ? 1.035 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        .help("Add account")
        .accessibilityLabel("Add Codex or Claude account")
    }
}

private struct HeaderActionButton<Label: View>: View {
    let action: () -> Void
    var isSelected = false
    var isDisabled = false
    let helpText: String
    let accessibilityText: String
    let label: Label
    @State private var isHovered = false

    init(
        action: @escaping () -> Void,
        isSelected: Bool = false,
        isDisabled: Bool = false,
        helpText: String,
        accessibilityText: String,
        @ViewBuilder label: () -> Label
    ) {
        self.action = action
        self.isSelected = isSelected
        self.isDisabled = isDisabled
        self.helpText = helpText
        self.accessibilityText = accessibilityText
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .frame(width: 26, height: 24)
                .background {
                    RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous)
                        .fill(controlSurface)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous)
                        .stroke(controlBorder, lineWidth: 0.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: Theme.controlCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
        .scaleEffect(isHovered && !isDisabled ? 1.035 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityLabel(accessibilityText)
    }

    private var controlSurface: Color {
        if isSelected {
            return Theme.controlSelectedSurface
        }
        return isHovered ? Theme.controlHoverSurface : .clear
    }

    private var controlBorder: Color {
        isSelected || isHovered ? Theme.controlBorder : .clear
    }
}

struct AppBrandIcon: View {
    private static let icon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.size = NSSize(width: 20, height: 20)
        return image
    }()

    var body: some View {
        Group {
            if let icon = Self.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.healthyAccent)
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
    }
}

struct SearchTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> ShortcutTextField {
        let field = ShortcutTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 13)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: ShortcutTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            self._text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }
    }
}

final class ShortcutTextField: NSTextField {
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            currentEditor()?.selectAll(nil)
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Footer

struct FooterView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(Theme.warningText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(height: 40)
    }
}

// MARK: - Skeleton

struct SkeletonView: View {
    @State private var pulse = false

    private let rowHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(pulse ? 0.08 : 0.04))
                    .frame(height: rowHeight)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .onAppear {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
