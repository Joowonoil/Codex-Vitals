#if DEBUG
import AppKit
import SwiftUI
import UserNotifications

@MainActor
enum SanitizedScreenshotRenderer {
    static func render() throws {
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = repository.appendingPathComponent("docs/screenshot.png")
        guard let icon = NSImage(
            contentsOf: repository.appendingPathComponent("Support/AppIcon-1024.png")
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        let viewModel = UsageViewModel(resetNotificationService: ScreenshotNotificationService())
        configure(viewModel)
        let rootView = SanitizedProductScreenshot(viewModel: viewModel, icon: icon)
            .environment(\.colorScheme, .light)
        let size = NSSize(width: 652, height: 360)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hostingView
        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        let scale = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: output, options: .atomic)
        window.close()
    }

    private static func configure(_ viewModel: UsageViewModel) {
        let codexKeys = ["codex-primary", "codex-research", "codex-team"]
        viewModel.accounts = [
            account(
                id: "alex@example.com|sample-1",
                profileKey: codexKeys[0],
                email: "alex@example.com",
                alias: "Personal",
                workspace: "Personal",
                plan: "pro",
                fiveHour: 78,
                weekly: 64,
                fiveHourReset: 9_800,
                weeklyReset: 345_600,
                provider: .codex,
                planDaysRemaining: 5
            ),
            account(
                id: "research01@example.com|sample-2",
                profileKey: codexKeys[1],
                email: "research01@example.com",
                alias: "Research One",
                workspace: "Lab",
                plan: "pro_lite",
                fiveHour: 100,
                weekly: 92,
                fiveHourReset: 14_400,
                weeklyReset: 432_000,
                provider: .codex,
                planDaysRemaining: 23,
                singleWindowSeconds: 30 * 24 * 60 * 60
            ),
            account(
                id: "team@example.com|sample-3",
                profileKey: codexKeys[2],
                email: "team@example.com",
                alias: "Shared Workspace",
                workspace: "Business",
                plan: "team",
                fiveHour: 48,
                weekly: 86,
                fiveHourReset: 7_200,
                weeklyReset: 518_400,
                provider: .codex,
                planDaysRemaining: 1
            ),
            account(
                id: "claude-native:sample-1",
                profileKey: nil,
                email: "claude@example.com",
                alias: "Claude Main",
                workspace: "Claude",
                plan: "Max 5x",
                fiveHour: 81,
                weekly: 73,
                fiveHourReset: 12_600,
                weeklyReset: 302_400,
                provider: .claude,
                providerProfileID: "claude-sample-1",
                providerIsActive: true,
                fable: 60
            ),
            account(
                id: "claude-native:sample-2",
                profileKey: nil,
                email: "paper@example.com",
                alias: "Paper Agent",
                workspace: "Research",
                plan: "Pro",
                fiveHour: 100,
                weekly: 98,
                fiveHourReset: 16_200,
                weeklyReset: 475_200,
                provider: .claude,
                providerProfileID: "claude-sample-2"
            ),
        ]
        viewModel.codexLoginStatus = CodexLoginStatus(
            accountIDs: [],
            sourceProfileKeys: Set(codexKeys),
            emailsWithoutAccountID: []
        )
        viewModel.isCodexInstalled = true
        viewModel.activeCodexProfileKey = codexKeys[0]
        viewModel.searchText = ""
        viewModel.groupByWorkspace = false
    }

    private static func account(
        id: String,
        profileKey: String?,
        email: String,
        alias: String,
        workspace: String,
        plan: String,
        fiveHour: Double,
        weekly: Double,
        fiveHourReset: TimeInterval,
        weeklyReset: TimeInterval,
        provider: AccountProvider,
        providerProfileID: String? = nil,
        providerIsActive: Bool = false,
        fable: Double? = nil,
        planDaysRemaining: Int? = nil,
        singleWindowSeconds: Double? = nil
    ) -> Account {
        let windows: [QuotaWindow]
        if let singleWindowSeconds {
            windows = [
                QuotaWindow(
                    limitSeconds: singleWindowSeconds,
                    remainingPercent: weekly,
                    resetAfterSeconds: weeklyReset
                )
            ]
        } else {
            windows = [
                QuotaWindow(
                    limitSeconds: QuotaWindow.fiveHourSeconds,
                    remainingPercent: fiveHour,
                    resetAfterSeconds: fiveHourReset
                ),
                QuotaWindow(
                    limitSeconds: QuotaWindow.weeklySeconds,
                    remainingPercent: weekly,
                    resetAfterSeconds: weeklyReset
                ),
            ]
        }

        return Account(
            id: id,
            profileKey: profileKey,
            email: email,
            alias: alias,
            workspace: workspace,
            plan: plan,
            sessionFree: fiveHour,
            weeklyFree: weekly,
            sessionResetSeconds: fiveHourReset,
            weeklyResetSeconds: weeklyReset,
            quotaWindows: windows,
            fableQuotaWindow: fable.map {
                QuotaWindow(
                    limitSeconds: QuotaWindow.weeklySeconds,
                    remainingPercent: $0,
                    resetAfterSeconds: 388_800
                )
            },
            planRenewalDate: planDaysRemaining.flatMap {
                Calendar.current.date(byAdding: .day, value: $0, to: Date())
            },
            hasError: false,
            errorMessage: nil,
            provider: provider,
            providerProfileID: providerProfileID,
            providerIsActive: providerIsActive,
            providerStatus: "ok"
        )
    }
}

private final class ScreenshotNotificationService: UsageResetNotifying {
    func requestAuthorization() async -> Bool { false }
    func authorizationStatus() async -> UNAuthorizationStatus { .denied }
    func deliver(events: [UsageResetEvent]) async {}
}

private struct SanitizedProductScreenshot: View {
    @ObservedObject var viewModel: UsageViewModel
    let icon: NSImage

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.15)
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
        }
        .frame(width: 652, height: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.22), lineWidth: 0.8)
        }
        .padding(2)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
            Text("Codex Vitals")
                .font(Theme.appTitleFont)
            Spacer(minLength: 0)
            HStack(spacing: 1) {
                headerIcon("magnifyingglass")
                headerIcon("person.badge.plus", color: Theme.healthyAccent)
                headerIcon("rectangle.3.group")
                headerIcon("arrow.clockwise")
                Rectangle()
                    .fill(Theme.controlBorder)
                    .frame(width: 0.5, height: 14)
                    .padding(.horizontal, 1)
                headerIcon("gearshape")
                headerIcon("power")
            }
            .padding(3)
            .background(Theme.toolbarSurface)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay { Capsule().stroke(Theme.toolbarBorder, lineWidth: 0.6) }
            .shadow(color: .black.opacity(0.045), radius: 2.5, y: 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 48)
    }

    private func headerIcon(_ name: String, color: Color = .secondary) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(color)
            .frame(width: 26, height: 24)
    }
}
#endif
