import XCTest
@testable import CodexVitals

final class UsageResetNotificationTests: XCTestCase {
    func testDetectsConfirmedFiveHourWeeklyAndFableRecoveryAfterReset() {
        let previousDate = Date(timeIntervalSince1970: 1_000_000)
        let currentDate = previousDate.addingTimeInterval(6 * 60 * 60)
        var previous = account(
            provider: .claude,
            fiveHourRemaining: 0,
            fiveHourReset: 5 * 60 * 60,
            weeklyRemaining: 0,
            weeklyReset: 5 * 60 * 60
        )
        previous.fableQuotaWindow = QuotaWindow(
            limitSeconds: QuotaWindow.weeklySeconds,
            remainingPercent: 10,
            resetAfterSeconds: 5 * 60 * 60
        )
        var current = account(
            provider: .claude,
            fiveHourRemaining: 95,
            fiveHourReset: 4 * 60 * 60,
            weeklyRemaining: 100,
            weeklyReset: 7 * 24 * 60 * 60
        )
        current.fableQuotaWindow = QuotaWindow(
            limitSeconds: QuotaWindow.weeklySeconds,
            remainingPercent: 100,
            resetAfterSeconds: 7 * 24 * 60 * 60
        )

        let events = UsageResetDetector.detect(
            previousAccounts: [previous],
            previousFetchedAt: previousDate,
            currentAccounts: [current],
            currentFetchedAt: currentDate
        )

        XCTAssertEqual(events.map(\.windowLabel), ["5h", "1w", "Fable 5"])
    }

    func testDoesNotNotifyBeforePreviousResetTime() {
        let previousDate = Date(timeIntervalSince1970: 1_000_000)
        let currentDate = previousDate.addingTimeInterval(60 * 60)
        let previous = account(fiveHourRemaining: 10, fiveHourReset: 5 * 60 * 60)
        let current = account(fiveHourRemaining: 90, fiveHourReset: 6 * 60 * 60)

        let events = UsageResetDetector.detect(
            previousAccounts: [previous],
            previousFetchedAt: previousDate,
            currentAccounts: [current],
            currentFetchedAt: currentDate
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testDoesNotNotifyForFailedOrUnchangedUsage() {
        let previousDate = Date(timeIntervalSince1970: 1_000_000)
        let currentDate = previousDate.addingTimeInterval(6 * 60 * 60)
        let previous = account(fiveHourRemaining: 0, fiveHourReset: 5 * 60 * 60)
        let unchanged = account(fiveHourRemaining: 0, fiveHourReset: 4 * 60 * 60)
        let failed = account(
            fiveHourRemaining: 100,
            fiveHourReset: 4 * 60 * 60,
            hasError: true
        )

        XCTAssertTrue(UsageResetDetector.detect(
            previousAccounts: [previous],
            previousFetchedAt: previousDate,
            currentAccounts: [unchanged],
            currentFetchedAt: currentDate
        ).isEmpty)
        XCTAssertTrue(UsageResetDetector.detect(
            previousAccounts: [previous],
            previousFetchedAt: previousDate,
            currentAccounts: [failed],
            currentFetchedAt: currentDate
        ).isEmpty)
    }

    func testConfirmedResetIsNotReportedAgainOnTheNextSnapshot() {
        let resetDate = Date(timeIntervalSince1970: 1_100_000)
        let firstFetch = resetDate.addingTimeInterval(60 * 60)
        let nextFetch = firstFetch.addingTimeInterval(5 * 60)
        let recovered = account(
            fiveHourRemaining: 95,
            fiveHourReset: 4 * 60 * 60
        )
        let unchangedNextSnapshot = account(
            fiveHourRemaining: 95,
            fiveHourReset: 4 * 60 * 60 - 5 * 60
        )

        let events = UsageResetDetector.detect(
            previousAccounts: [recovered],
            previousFetchedAt: firstFetch,
            currentAccounts: [unchangedNextSnapshot],
            currentFetchedAt: nextFetch
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testSummaryGroupsWindowsByAccount() {
        let events = [
            UsageResetEvent(
                accountKey: "codex:one",
                provider: .codex,
                accountName: "Lab One",
                windowLabel: "5h"
            ),
            UsageResetEvent(
                accountKey: "codex:one",
                provider: .codex,
                accountName: "Lab One",
                windowLabel: "1w"
            ),
            UsageResetEvent(
                accountKey: "claude:two",
                provider: .claude,
                accountName: "Research",
                windowLabel: "Fable 5"
            ),
        ]

        XCTAssertEqual(UsageResetNotificationSummary.title(for: events), "3 usage limits reset")
        XCTAssertEqual(
            UsageResetNotificationSummary.body(for: events),
            "Codex · Lab One: 5h, 1w\nClaude · Research: Fable 5"
        )
    }

    private func account(
        provider: AccountProvider = .codex,
        fiveHourRemaining: Double,
        fiveHourReset: TimeInterval,
        weeklyRemaining: Double = 70,
        weeklyReset: TimeInterval = 6 * 24 * 60 * 60,
        hasError: Bool = false
    ) -> Account {
        Account(
            id: "person@example.com|account-1",
            profileKey: provider == .codex ? "openai-codex:person@example.com" : nil,
            email: "person@example.com",
            alias: "Lab One",
            workspace: "Lab",
            plan: provider == .codex ? "plus" : "claude",
            sessionFree: fiveHourRemaining,
            weeklyFree: weeklyRemaining,
            sessionResetSeconds: fiveHourReset,
            weeklyResetSeconds: weeklyReset,
            quotaWindows: [
                QuotaWindow(
                    limitSeconds: QuotaWindow.fiveHourSeconds,
                    remainingPercent: fiveHourRemaining,
                    resetAfterSeconds: fiveHourReset
                ),
                QuotaWindow(
                    limitSeconds: QuotaWindow.weeklySeconds,
                    remainingPercent: weeklyRemaining,
                    resetAfterSeconds: weeklyReset
                ),
            ],
            hasError: hasError,
            errorMessage: hasError ? "Unavailable" : nil,
            provider: provider,
            providerProfileID: provider == .claude ? "claude-profile-1" : nil,
            providerStatus: hasError ? "unavailable" : "ok"
        )
    }
}
