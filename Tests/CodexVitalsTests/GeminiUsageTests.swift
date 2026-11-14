import Foundation
import UserNotifications
import XCTest
@testable import CodexVitals

final class GeminiUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testGeminiAndArgonUseSeparateBucketsAndExcludeThirdPartyQuota() throws {
        let account = try decodedAccount()

        XCTAssertEqual(account.accountProvider, .gemini)
        XCTAssertEqual(account.usageWindows.map(\.label), ["5h", "1w"])
        XCTAssertEqual(account.usageWindows.map(\.remainingPercent), [80, 65])
        XCTAssertEqual(account.argonQuotaWindow?.remainingPercent, 42)
        XCTAssertEqual(account.supplementaryQuotas.first?.label, "Argon")
        XCTAssertNil(account.fableQuotaWindow)
        XCTAssertTrue(account.isUsableForCodex)
        XCTAssertFalse(account.canSwitchProviderAccount)
        XCTAssertEqual(account.weeklyResetSeconds, 604_800, accuracy: 1)
    }

    func testExhaustedArgonDoesNotDisableGeminiAndAgesWithSnapshot() throws {
        let account = try decodedAccount(argon: 0)
        let aged = account.agingResetTimers(by: 600)

        XCTAssertTrue(account.isUsableForCodex)
        XCTAssertFalse(account.isWeeklyExhausted)
        XCTAssertEqual(aged.argonQuotaWindow?.resetAfterSeconds, 604_200)
        let roundTrip = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(aged))
        XCTAssertEqual(roundTrip.argonQuotaWindow, aged.argonQuotaWindow)
    }

    func testWeeklyOnlyQuotaDoesNotInventFiveHourOrArgonWindows() throws {
        let account = try decodedAccount(fiveHour: nil, argon: nil)

        XCTAssertNil(account.fiveHourQuotaWindow)
        XCTAssertEqual(account.usageWindows.map(\.label), ["1w"])
        XCTAssertTrue(account.supplementaryQuotas.isEmpty)
    }

    func testMismatchedBucketCadenceCannotCreateDuplicateWindows() throws {
        let account = try decode([
            "status": "SUCCESS", "command": ["name": "usage", "data": ["groups": [
                ["buckets": [
                    ["id": "gemini-5h", "window": "weekly", "remaining_fraction": 0.5],
                    ["id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.6],
                    ["id": "gemini-argon-wtu-weekly", "window": "5h", "remaining_fraction": 0.7],
                ]],
            ]]],
        ])
        XCTAssertEqual(account.usageWindows.map(\.label), ["1w"])
        XCTAssertNil(account.argonQuotaWindow)
    }

    @MainActor
    func testGeminiDoesNotEnterCodexLoginOrSwitchFlows() throws {
        let account = try decodedAccount()
        let model = UsageViewModel(resetNotificationService: GeminiTestNotifications())
        XCTAssertFalse(model.needsRelogin(account))
        XCTAssertFalse(model.showsSwitchControls(for: account))
        XCTAssertFalse(model.canSwitchAccount(account))
        XCTAssertFalse(model.canReorderAccount(account))
        XCTAssertTrue(model.isActiveAccount(account))
    }

    func testUnknownDisabledAndFailedReportsAreNotShownAsFullQuota() throws {
        XCTAssertThrowsError(try decodedAccount(fiveHour: nil, weekly: nil))
        XCTAssertThrowsError(try decodedAccount(fiveHour: nil, weekly: 2))
        XCTAssertThrowsError(try decode([
            "status": "SUCCESS", "command": ["name": "usage", "data": ["groups": [
                ["buckets": [["id": "gemini-weekly", "window": "weekly", "remaining_fraction": 1, "disabled": true]]],
            ]]],
        ]))
        var report = try reportObject()
        report["status"] = "ERROR"
        XCTAssertThrowsError(try decode(report))
        report = try reportObject()
        var command = try XCTUnwrap(report["command"] as? [String: Any])
        command["name"] = "models"
        report["command"] = command
        XCTAssertThrowsError(try decode(report))
    }

    func testMissingCLIProducesNoAccount() async throws {
        let client = GeminiCLIUsageClient(executableURL: nil)
        let result = try await client.fetchAccount()
        XCTAssertNil(result)
    }

    func testCLIReadsReportWithoutOpeningBrowserOrUsingProjectDirectory() async throws {
        let fixture = try executable(script: """
        if [ "$1" = "--version" ]; then echo 1.5.8; exit 0; fi
        [ "$1" = "--print" ] && [ "$2" = "/usage" ] || exit 2
        [ -x "$BROWSER" ] || exit 3
        "$BROWSER" && exit 4
        case "$PWD" in *CodexVitals-Gemini-*) ;; *) exit 5 ;; esac
        /bin/cat '\(try reportFile().path)'
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let client = GeminiCLIUsageClient(executableURL: fixture)
        let loaded = try await client.fetchAccount()
        let account = try XCTUnwrap(loaded)
        XCTAssertEqual(account.weeklyFree, 65)
        XCTAssertEqual(account.argonQuotaWindow?.remainingPercent, 42)
    }

    func testCLIRejectsOldVersionBeforeSendingSlashCommand() async throws {
        let fixture = try executable(script: """
        if [ "$1" = "--version" ]; then echo 1.1.10; exit 0; fi
        exit 99
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let client = GeminiCLIUsageClient(executableURL: fixture)
        do {
            _ = try await client.fetchAccount()
            XCTFail("Expected unsupported CLI version")
        } catch GeminiUsageError.unsupportedVersion {} catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCLICommandHasABoundedTimeout() async throws {
        let fixture = try executable(script: """
        if [ "$1" = "--version" ]; then echo 1.5.8; exit 0; fi
        exec /bin/sleep 30
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let client = GeminiCLIUsageClient(executableURL: fixture, timeout: 0.2)
        let started = Date()
        do {
            _ = try await client.fetchAccount()
            XCTFail("Expected timeout")
        } catch GeminiUsageError.timedOut {} catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testArgonResetNotificationRequiresFreshUsage() throws {
        var previous = try decodedAccount(argon: 0)
        previous.argonQuotaWindow = QuotaWindow(
            limitSeconds: QuotaWindow.weeklySeconds, remainingPercent: 0, resetAfterSeconds: 100
        )
        previous.geminiQuotaDetails = nil
        var current = try decodedAccount(argon: 1)
        let fetchedAt = now.addingTimeInterval(200)
        let events = UsageResetDetector.detect(
            previousAccounts: [previous], previousFetchedAt: now,
            currentAccounts: [current], currentFetchedAt: fetchedAt
        )
        XCTAssertEqual(events.map(\.windowLabel), ["Argon"])
        current.providerStatus = "cached"
        XCTAssertTrue(UsageResetDetector.detect(
            previousAccounts: [previous], previousFetchedAt: now,
            currentAccounts: [current], currentFetchedAt: fetchedAt
        ).isEmpty)
    }

    func testLiveInstalledCLI() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CODEX_VITALS_TEST_AGY"] == "1")
        let loaded = try await GeminiCLIUsageClient().fetchAccount()
        let account = try XCTUnwrap(loaded)
        XCTAssertEqual(account.accountProvider, .gemini)
        XCTAssertFalse(account.usageWindows.isEmpty)
    }

    private func decodedAccount(
        fiveHour: Double? = 0.8, weekly: Double? = 0.65, argon: Double? = 0.42
    ) throws -> Account {
        try decode(reportObject(fiveHour: fiveHour, weekly: weekly, argon: argon))
    }

    private func decode(_ object: [String: Any]) throws -> Account {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(GeminiUsageReport.self, from: data).account(now: now)
    }

    private func reportObject(
        fiveHour: Double? = 0.8, weekly: Double? = 0.65, argon: Double? = 0.42
    ) throws -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        func bucket(_ id: String, _ window: String, _ fraction: Double?) -> [String: Any] {
            var object: [String: Any] = [
                "id": id, "window": window,
                "reset_time": formatter.string(from: now.addingTimeInterval(604_800)),
            ]
            if let fraction { object["remaining_fraction"] = fraction }
            return object
        }
        var groups: [[String: Any]] = [
            ["name": "Gemini", "buckets": [
                bucket("gemini-weekly", "weekly", weekly), bucket("gemini-5h", "5h", fiveHour),
            ]],
            ["name": "Claude/GPT", "buckets": [bucket("3p-weekly", "weekly", 0)]],
        ]
        if let argon {
            groups.append(["name": "Argon", "buckets": [bucket("gemini-argon-wtu-weekly", "weekly", argon)]])
        }
        return ["status": "SUCCESS", "command": ["name": "usage", "data": ["groups": groups]]]
    }

    private func reportFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GeminiReport-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: reportObject()).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func executable(script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GeminiTest-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("agy")
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

private final class GeminiTestNotifications: UsageResetNotifying {
    func requestAuthorization() async -> Bool { false }
    func authorizationStatus() async -> UNAuthorizationStatus { .denied }
    func deliver(events: [UsageResetEvent]) async {}
}
