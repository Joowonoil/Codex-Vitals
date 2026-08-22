import AppKit
import Darwin
import SwiftUI

private let statusBarSymbolNames = [
    "waveform.path.ecg",
    "gauge.medium",
    "chart.bar.fill"
]

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let viewModel = UsageViewModel()
    private let authMirrorService = CodexAuthMirrorService()
    private let githubStarPrompt = GitHubStarPromptModel()
    private var appUpdater: AppUpdater!
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let removedProfileKeys = try? CapturedProfileDedupeService.removeAllDuplicates(),
           !removedProfileKeys.isEmpty {
            try? AccountProfileStore.remove(profileKeys: removedProfileKeys)
        }
        authMirrorService.start()
        appUpdater = AppUpdater()
        setupStatusItem()
        setupPopover()
        viewModel.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = authMirrorService.syncActiveAuth()
        authMirrorService.stop()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        let img = statusBarSymbolNames.lazy.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: "Codex Vitals")
        }.first
        img?.isTemplate = true
        button.image = img
        button.action = #selector(togglePopover(_:))
        button.target = self
    }

    // MARK: - Popover

    private func setupPopover() {
        let root = ContentView(
            viewModel: viewModel,
            appUpdater: appUpdater,
            githubStarPrompt: githubStarPrompt
        )
        let controller = NSHostingController(rootView: root)
        controller.preferredContentSize = Self.preferredContentSize
        if #available(macOS 13.0, *) {
            controller.sizingOptions = [.preferredContentSize]
        }

        popover = NSPopover()
        popover.contentSize = Self.preferredContentSize
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = controller
        popover.delegate = self
    }

    private func syncPopoverSizeToSelectedMode() {
        popover.contentViewController?.preferredContentSize = Self.preferredContentSize
        popover.contentSize = Self.preferredContentSize
    }

    private static var preferredContentSize: NSSize {
        NSSize(width: ContentView.preferredWidth, height: ContentView.preferredHeight())
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover(sender)
        } else {
            syncPopoverSizeToSelectedMode()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            githubStarPrompt.presentIfNeeded()
            eventMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    guard !self.isMouseInStatusButton() else { return }
                    self.closePopover(nil)
                }
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removeEventMonitor()
    }

    private func closePopover(_ sender: Any?) {
        popover.performClose(sender)
        removeEventMonitor()
    }

    private func isMouseInStatusButton() -> Bool {
        guard let button = statusItem.button,
              let window = button.window else {
            return false
        }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectInScreen = window.convertToScreen(buttonRectInWindow)
        return buttonRectInScreen.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
    }

    private func removeEventMonitor() {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
#if DEBUG
    if CommandLine.arguments.contains("--render-sanitized-screenshot") {
        app.setActivationPolicy(.prohibited)
        do {
            try SanitizedScreenshotRenderer.render()
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            fputs("Failed to render sanitized screenshot: \(error)\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }
    }
#endif
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // hide from Dock
    app.run()
}
