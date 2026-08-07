import XCTest
@testable import CodexVitals

final class AccountListVisibilityTests: XCTestCase {
    @MainActor
    func testErroredAccountsStayVisible() {
        let healthy = makeAccount(id: "ok@example.com|acc-ok", email: "ok@example.com", hasError: false)
        let errored = makeAccount(id: "bad@example.com|acc-bad", email: "bad@example.com", hasError: true)

        let visible = UsageViewModel.visibleAccounts(from: [healthy, errored])

        XCTAssertEqual(visible.map(\.id), [healthy.id, errored.id])
        XCTAssertEqual(UsageViewModel.errorCount(in: visible), 1)
    }

    func testDedupIDFallsBackToProfileKeyWhenAccountIDIsMissing() {
        let first = UsageService.dedupID(
            email: "same@example.com",
            accountID: "",
            profileKey: "openai-codex:team:same@example.com"
        )
        let second = UsageService.dedupID(
            email: "same@example.com",
            accountID: "",
            profileKey: "openai-codex:plus:same@example.com"
        )

        XCTAssertNotEqual(first, second)
    }

    func testExpiredOrRevokedAuthError() {
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Expired or revoked"))
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Token expired"))
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Token invalidated"))
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Token revoked"))
        XCTAssertTrue(UsageService.isExpiredOrRevokedAuthError("Refresh failed - re-login required"))
        XCTAssertFalse(UsageService.isExpiredOrRevokedAuthError("Workspace deactivated"))
    }

    func testRecoverableAuthErrorIsNotARowSwitchAffordance() {
        XCTAssertTrue(UsageService.isRecoverableAuthError("Token expired"))
        XCTAssertFalse(UsageService.isRecoverableAuthError("Token revoked"))
        XCTAssertFalse(UsageService.isRecoverableAuthError("Token invalidated"))
        XCTAssertFalse(UsageService.isRecoverableAuthError("HTTP 403"))
    }

    func testFreePlanSessionZeroUsesDedicatedResetState() {
        let account = Account(
            id: "free@example.com|acc-free",
            profileKey: "free@example.com",
            email: "free@example.com",
            workspace: "free",
            plan: "free",
            sessionFree: 0,
            weeklyFree: 100,
            sessionResetSeconds: 86_400,
            weeklyResetSeconds: 0,
            planRenewalDate: nil,
            hasError: false,
            errorMessage: nil
        )

        XCTAssertTrue(account.isFreeWaitingForReset)
        XCTAssertFalse(account.isUsableForCodex)
        XCTAssertEqual(account.freePlanResetSeconds, 86_400)
    }

    func testSwitchIdentityPolicyPrefersStoredCapturedAccountID() {
        let account = makeAccount(
            id: "person@example.com|usage-workspace-id",
            email: "person@example.com",
            plan: "pro",
            sessionFree: 50,
            weeklyFree: 50,
            sessionResetSeconds: 0
        )

        XCTAssertEqual(
            CodexSwitchIdentityPolicy.expectedAccountID(
                for: account,
                storedAccountID: "captured-auth-account-id"
            ),
            "captured-auth-account-id"
        )
    }

    func testSwitchIdentityPolicyIgnoresTransientPersonalUsageIDWithoutStoredRecord() {
        let account = makeAccount(
            id: "person@example.com|usage-workspace-id",
            email: "person@example.com",
            plan: "pro",
            sessionFree: 50,
            weeklyFree: 50,
            sessionResetSeconds: 0
        )

        XCTAssertNil(
            CodexSwitchIdentityPolicy.expectedAccountID(for: account, storedAccountID: nil)
        )
    }

    func testSwitchIdentityPolicyUsesTransientTeamIDAsFallback() {
        let account = makeAccount(
            id: "person@example.com|usage-workspace-id",
            email: "person@example.com",
            plan: "team",
            sessionFree: 50,
            weeklyFree: 50,
            sessionResetSeconds: 0
        )

        XCTAssertEqual(
            CodexSwitchIdentityPolicy.expectedAccountID(for: account, storedAccountID: nil),
            "usage-workspace-id"
        )
    }

    @MainActor
    func testWeeklyOnlyPrimaryWindowDoesNotCreateFakeFiveHourQuota() {
        let windows = UsageService.quotaWindows(from: [
            "primary_window": [
                "limit_window_seconds": 604_800,
                "used_percent": 14,
                "reset_after_seconds": 597_667,
            ],
            "secondary_window": NSNull(),
        ])

        let account = Account(
            id: "weekly@example.com|acc",
            profileKey: "weekly@example.com",
            email: "weekly@example.com",
            workspace: "pro",
            plan: "pro",
            sessionFree: 100,
            weeklyFree: 100,
            sessionResetSeconds: 0,
            weeklyResetSeconds: 0,
            quotaWindows: windows,
            planRenewalDate: nil,
            hasError: false,
            errorMessage: nil
        )

        XCTAssertEqual(windows.map(\.label), ["1w"])
        XCTAssertNil(account.fiveHourQuotaWindow)
        XCTAssertEqual(account.weeklyQuotaWindow?.remainingPercent, 86)
        XCTAssertEqual(UsageViewModel.smartScore(account), 86)
        XCTAssertTrue(account.isUsableForCodex)
    }

    @MainActor
    func testExhaustedWeeklyOnlyWindowUsesWeeklyReset() {
        let windows = UsageService.quotaWindows(from: [
            "primary_window": [
                "limit_window_seconds": 604_800,
                "used_percent": 100,
                "reset_after_seconds": 345_600,
            ],
        ])

        let account = Account(
            id: "exhausted@example.com|acc",
            profileKey: "exhausted@example.com",
            email: "exhausted@example.com",
            workspace: "pro",
            plan: "pro",
            sessionFree: 100,
            weeklyFree: 100,
            sessionResetSeconds: 0,
            weeklyResetSeconds: 0,
            quotaWindows: windows,
            planRenewalDate: nil,
            hasError: false,
            errorMessage: nil
        )

        XCTAssertTrue(account.isWeeklyExhausted)
        XCTAssertFalse(account.isUsableForCodex)
        XCTAssertEqual(account.nextWaitingResetSeconds, 345_600)
    }

    func testQuotaWindowsUseDurationInsteadOfPrimarySecondaryPosition() {
        let windows = UsageService.quotaWindows(from: [
            "primary_window": [
                "limit_window_seconds": 604_800.0,
                "used_percent": 30.0,
                "reset_after_seconds": 500_000.0,
            ],
            "secondary_window": [
                "limit_window_seconds": 18_000.0,
                "used_percent": 20.0,
                "reset_after_seconds": 10_000.0,
            ],
        ])

        XCTAssertEqual(windows.map(\.label), ["5h", "1w"])
        XCTAssertEqual(windows.map(\.remainingPercent), [80, 70])
    }

    func testUnknownQuotaDurationUsesItsActualPeriodLabel() {
        let windows = UsageService.quotaWindows(from: [
            "primary_window": [
                "limit_window_seconds": 86_400,
                "used_percent": 25,
                "reset_after_seconds": 40_000,
            ],
        ])

        XCTAssertEqual(windows.map(\.label), ["1d"])
        XCTAssertEqual(windows.first?.kind, .custom)
    }

    func testLegacySnapshotWithoutQuotaWindowsKeepsFiveHourAndWeeklyWindows() throws {
        let account = makeAccount(
            id: "legacy@example.com|acc",
            email: "legacy@example.com",
            plan: "plus",
            sessionFree: 75,
            weeklyFree: 60,
            sessionResetSeconds: 1_000,
            weeklyResetSeconds: 500_000
        )

        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(Account.self, from: data)

        XCTAssertNil(decoded.quotaWindows)
        XCTAssertEqual(decoded.usageWindows.map(\.label), ["5h", "1w"])
        XCTAssertEqual(decoded.limitingQuotaRemaining, 60)
    }

    func testPlanDisplayNameNormalizesCommonPlans() {
        XCTAssertEqual(PlanDisplayFormatter.badgeText(for: "pro"), "Pro")
        XCTAssertEqual(PlanDisplayFormatter.badgeText(for: "plus"), "Plus")
        XCTAssertEqual(PlanDisplayFormatter.badgeText(for: "pro_lite"), "Pro Lite")
        XCTAssertEqual(PlanDisplayFormatter.badgeText(for: "pro-lite"), "Pro Lite")
        XCTAssertEqual(PlanDisplayFormatter.badgeText(for: "free"), "Free")
        XCTAssertNil(PlanDisplayFormatter.badgeText(for: "?"))
    }

    func testAutoRefreshIntervalOptionsUseExpectedDefaults() {
        let previousValue = UserDefaults.standard.object(forKey: AutoRefreshInterval.userDefaultsKey)
        defer {
            if let previousValue {
                UserDefaults.standard.set(previousValue, forKey: AutoRefreshInterval.userDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AutoRefreshInterval.userDefaultsKey)
            }
        }

        UserDefaults.standard.removeObject(forKey: AutoRefreshInterval.userDefaultsKey)

        XCTAssertEqual(AutoRefreshInterval.stored, .tenMinutes)
        XCTAssertNil(AutoRefreshInterval.off.seconds)
        XCTAssertEqual(AutoRefreshInterval.fiveMinutes.seconds, 300)
        XCTAssertEqual(AutoRefreshInterval.tenMinutes.displayName, "10 min")

        AutoRefreshInterval.thirtyMinutes.save()
        XCTAssertEqual(AutoRefreshInterval.stored, .thirtyMinutes)
    }

    func testAccountDisplayPlanNameIsIndependentOfAlias() {
        var account = makeAccount(
            id: "person@example.com|acc",
            email: "person@example.com",
            plan: "plus",
            sessionFree: 80,
            weeklyFree: 80,
            sessionResetSeconds: 0
        )
        account.alias = "Lab Member 01"

        XCTAssertEqual(account.displayName, "Lab Member 01")
        XCTAssertEqual(account.displayPlanName, "Plus")
    }

    func testFreeResetFormatterIncludesReturnContext() {
        let text = ResetFormatter.formatFreeReturn(seconds: 60)

        XCTAssertNotEqual(text, ResetFormatter.timeOnly(seconds: 60))
        XCTAssertTrue(text.contains(" "))
    }

    @MainActor
    func testAccountDisplayAliasIsPresentationOnly() {
        var account = makeAccount(id: "person@example.com|acc", email: "person@example.com", hasError: false)
        account.alias = "  Lab Member 01  "

        XCTAssertEqual(account.displayAlias, "Lab Member 01")
        XCTAssertEqual(account.displayName, "Lab Member 01")
        XCTAssertEqual(account.email, "person@example.com")
        XCTAssertEqual(account.accountID, "acc")
    }

    @MainActor
    func testAccountSearchMatchesAliasAndEmail() {
        var account = makeAccount(id: "person@example.com|acc", email: "person@example.com", hasError: false)
        account.alias = "Lab Member 01"

        XCTAssertTrue(UsageViewModel.matchesSearch(account, searchText: "member 01"))
        XCTAssertTrue(UsageViewModel.matchesSearch(account, searchText: "person@example"))
        XCTAssertFalse(UsageViewModel.matchesSearch(account, searchText: "unrelated"))
    }

    @MainActor
    func testWorkspaceDisplayAliasIsSearchableWithoutChangingOriginalWorkspace() {
        var account = makeAccount(id: "person@example.com|acc", email: "person@example.com", hasError: false)
        account.workspaceAlias = "Lab Pool A"

        XCTAssertEqual(account.workspace, "team")
        XCTAssertEqual(account.displayWorkspaceName, "Lab Pool A")
        XCTAssertTrue(account.hasDisplayWorkspaceAlias)
        XCTAssertTrue(UsageViewModel.matchesSearch(account, searchText: "pool a"))
        XCTAssertTrue(UsageViewModel.matchesSearch(account, searchText: "team"))
    }

    @MainActor
    func testWaitingForResetSortsPaidBeforeFreeThenSoonestReset() {
        let freeSoon = makeAccount(
            id: "free-soon@example.com|acc",
            email: "free-soon@example.com",
            plan: "free",
            sessionFree: 0,
            weeklyFree: 100,
            sessionResetSeconds: 60
        )
        let plusLater = makeAccount(
            id: "plus-later@example.com|acc",
            email: "plus-later@example.com",
            plan: "plus",
            sessionFree: 0,
            weeklyFree: 100,
            sessionResetSeconds: 600
        )
        let plusSoon = makeAccount(
            id: "plus-soon@example.com|acc",
            email: "plus-soon@example.com",
            plan: "plus",
            sessionFree: 0,
            weeklyFree: 100,
            sessionResetSeconds: 120
        )

        let sorted = UsageViewModel.sortedExhaustedAccounts([freeSoon, plusLater, plusSoon])

        XCTAssertEqual(sorted.map(\.email), [
            "plus-soon@example.com",
            "plus-later@example.com",
            "free-soon@example.com"
        ])
    }

    private func makeAccount(id: String, email: String, hasError: Bool) -> Account {
        Account(
            id: id,
            profileKey: id,
            email: email,
            workspace: hasError ? "?" : "team",
            plan: hasError ? "?" : "team",
            sessionFree: hasError ? 0 : 80,
            weeklyFree: hasError ? 0 : 80,
            sessionResetSeconds: 0,
            weeklyResetSeconds: 0,
            planRenewalDate: nil,
            hasError: hasError,
            errorMessage: hasError ? "Codex usage unavailable" : nil
        )
    }

    private func makeAccount(
        id: String,
        email: String,
        plan: String,
        sessionFree: Double,
        weeklyFree: Double,
        sessionResetSeconds: Double,
        weeklyResetSeconds: Double = 0
    ) -> Account {
        Account(
            id: id,
            profileKey: id,
            email: email,
            workspace: plan,
            plan: plan,
            sessionFree: sessionFree,
            weeklyFree: weeklyFree,
            sessionResetSeconds: sessionResetSeconds,
            weeklyResetSeconds: weeklyResetSeconds,
            planRenewalDate: nil,
            hasError: false,
            errorMessage: nil
        )
    }
}
