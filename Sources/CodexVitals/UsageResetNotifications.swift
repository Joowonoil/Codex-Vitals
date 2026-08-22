import Foundation
import UserNotifications

protocol UsageResetNotifying: AnyObject {
    func requestAuthorization() async -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    func deliver(events: [UsageResetEvent]) async
}

struct UsageResetEvent: Equatable, Sendable {
    let accountKey: String
    let provider: AccountProvider
    let accountName: String
    let windowLabel: String
}

enum UsageResetDetector {
    private static let minimumRemainingIncrease = 0.5
    private static let resetTimeTolerance: TimeInterval = 60

    static func detect(
        previousAccounts: [Account],
        previousFetchedAt: Date?,
        currentAccounts: [Account],
        currentFetchedAt: Date
    ) -> [UsageResetEvent] {
        guard let previousFetchedAt else { return [] }

        var previousByKey: [String: Account] = [:]
        for account in previousAccounts {
            previousByKey[accountKey(account)] = account
        }

        return currentAccounts.flatMap { current -> [UsageResetEvent] in
            let key = accountKey(current)
            guard !current.hasError,
                  let previous = previousByKey[key],
                  !previous.hasError else {
                return []
            }

            let previousWindows = Dictionary(
                uniqueKeysWithValues: windows(for: previous).map { ($0.key, $0) }
            )

            return windows(for: current).compactMap { currentWindow in
                guard let previousWindow = previousWindows[currentWindow.key] else { return nil }

                let previousResetAt = previousFetchedAt.addingTimeInterval(
                    previousWindow.window.resetAfterSeconds
                )
                let currentResetAt = currentFetchedAt.addingTimeInterval(
                    currentWindow.window.resetAfterSeconds
                )
                let resetHasPassed = currentFetchedAt.timeIntervalSince(previousResetAt)
                    >= -resetTimeTolerance
                let cycleAdvanced = currentResetAt.timeIntervalSince(previousResetAt)
                    > resetTimeTolerance
                let remainingRecovered = currentWindow.window.remainingPercent
                    > previousWindow.window.remainingPercent + minimumRemainingIncrease

                guard resetHasPassed, cycleAdvanced, remainingRecovered else { return nil }
                return UsageResetEvent(
                    accountKey: key,
                    provider: current.accountProvider,
                    accountName: current.displayName,
                    windowLabel: currentWindow.label
                )
            }
        }
    }

    private static func accountKey(_ account: Account) -> String {
        let providerKey = account.providerProfileID ?? account.profileKey ?? account.id
        return "\(account.accountProvider.rawValue):\(providerKey)"
    }

    private static func windows(for account: Account) -> [(key: String, label: String, window: QuotaWindow)] {
        var result = account.usageWindows.enumerated().map { index, window in
            let duration = Int(window.limitSeconds.rounded())
            let key = window.kind == .custom ? "quota:\(duration):\(index)" : "quota:\(duration)"
            return (key: key, label: window.label, window: window)
        }
        if let fable = account.fableQuotaWindow {
            result.append((key: "fable", label: "Fable 5", window: fable))
        }
        return result
    }
}

enum UsageResetNotificationSummary {
    static func title(for events: [UsageResetEvent]) -> String {
        events.count == 1 ? "Usage limit reset" : "\(events.count) usage limits reset"
    }

    static func body(for events: [UsageResetEvent]) -> String {
        var groupOrder: [String] = []
        var groups: [String: (provider: AccountProvider, name: String, windows: [String])] = [:]

        for event in events {
            if groups[event.accountKey] == nil {
                groupOrder.append(event.accountKey)
                groups[event.accountKey] = (event.provider, event.accountName, [])
            }
            if groups[event.accountKey]?.windows.contains(event.windowLabel) == false {
                groups[event.accountKey]?.windows.append(event.windowLabel)
            }
        }

        let visibleKeys = groupOrder.prefix(3)
        var lines = visibleKeys.compactMap { key -> String? in
            guard let group = groups[key] else { return nil }
            return "\(group.provider.displayName) · \(group.name): \(group.windows.joined(separator: ", "))"
        }
        let remainingAccounts = groupOrder.count - visibleKeys.count
        if remainingAccounts > 0 {
            lines.append("+ \(remainingAccounts) more account\(remainingAccounts == 1 ? "" : "s")")
        }
        return lines.joined(separator: "\n")
    }
}

final class UsageResetNotificationService: NSObject, UsageResetNotifying, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func deliver(events: [UsageResetEvent]) async {
        guard !events.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = UsageResetNotificationSummary.title(for: events)
        content.body = UsageResetNotificationSummary.body(for: events)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "usage-reset-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        await withCheckedContinuation { continuation in
            center.add(request) { _ in continuation.resume() }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
