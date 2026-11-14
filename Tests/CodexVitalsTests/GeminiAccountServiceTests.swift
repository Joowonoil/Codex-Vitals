import Foundation
import XCTest
@testable import CodexVitals

final class GeminiAccountServiceTests: XCTestCase {
    func testNativeCredentialSupportsKeyringEncodingAndStableIdentity() throws {
        let credential = try makeCredential("first@example.com")
        let encoded = "go-keyring-base64:" + Data(credential.rawValue.utf8).base64EncodedString()
        let decoded = try GeminiCredential(rawValue: encoded)
        XCTAssertEqual(decoded.email, credential.email)
        XCTAssertEqual(GeminiProfile(email: " FIRST@example.com ").id, GeminiProfile(email: credential.email).id)
        XCTAssertNotEqual(GeminiProfile(email: credential.email).id, GeminiProfile(email: "other@example.com").id)
    }

    func testImportCapturesIdentityWithoutMixingSavedAccounts() async throws {
        let fixture = try fixture()
        let first = await fixture.service.loadAccounts(previousAccounts: [], previousFetchedAt: nil)
        let firstAccount = try XCTUnwrap(first.accounts.first)
        XCTAssertEqual(firstAccount.email, "first@example.com")
        XCTAssertNotNil(firstAccount.providerProfileID)
        fixture.credentials.setActive(try makeCredential("second@example.com"))
        let second = await fixture.service.loadAccounts(previousAccounts: first.accounts, previousFetchedAt: Date())
        XCTAssertEqual(Set(second.accounts.map(\.email)), ["first@example.com", "second@example.com"])
        XCTAssertEqual(second.accounts.filter { $0.providerIsActive == true }.map(\.email), ["second@example.com"])
        XCTAssertEqual(Set(second.accounts.map(\.id)).count, 2)
    }

    func testMetadataAndOrderSurviveReload() async throws {
        let fixture = try fixture()
        _ = await fixture.service.loadAccounts(previousAccounts: [], previousFetchedAt: nil)
        fixture.credentials.setActive(try makeCredential("second@example.com"))
        _ = await fixture.service.loadAccounts(previousAccounts: [], previousFetchedAt: nil)
        let first = GeminiProfile(email: "first@example.com")
        let second = GeminiProfile(email: "second@example.com")
        let renewal = Date(timeIntervalSince1970: 1_900_000_000)
        try await fixture.service.updateAlias(profileID: first.id, alias: " Research ")
        try await fixture.service.updateWorkspaceAlias(workspace: "Gemini", alias: "Lab")
        try await fixture.service.updatePlanRenewalDate(profileID: first.id, date: renewal)
        try await fixture.service.updateOrder(profileIDs: [second.id, first.id, first.id])

        let reloaded = try GeminiAccountStore(url: fixture.url).load()
        XCTAssertEqual(reloaded.map(\.id), [second.id, first.id])
        XCTAssertEqual(reloaded[1].alias, "Research")
        XCTAssertEqual(reloaded[1].workspaceAlias, "Lab")
        XCTAssertEqual(reloaded[1].planRenewalDate, renewal)
        let text = try String(contentsOf: fixture.url, encoding: .utf8)
        XCTAssertFalse(text.contains("access_token"))
        XCTAssertFalse(text.contains("refresh_token"))
    }

    func testActiveRemovalHidesWithoutSigningOutAndExplicitAddRestores() async throws {
        let fixture = try fixture()
        let first = await fixture.service.loadAccounts(previousAccounts: [], previousFetchedAt: nil)
        let id = try XCTUnwrap(first.accounts.first?.providerProfileID)
        try await fixture.service.removeAccount(profileID: id)
        let hidden = await fixture.service.loadAccounts(previousAccounts: first.accounts, previousFetchedAt: Date())
        XCTAssertTrue(hidden.accounts.isEmpty)
        XCTAssertEqual(try fixture.credentials.active()?.email, "first@example.com")
        _ = try await fixture.service.addAccount()
        let restored = await fixture.service.loadAccounts(previousAccounts: [], previousFetchedAt: nil)
        XCTAssertEqual(restored.accounts.count, 1)
    }

    func testSwitchPreservesOutgoingAndChangesOnlyGeminiCredential() async throws {
        let fixture = try fixture()
        _ = await fixture.service.loadAccounts(previousAccounts: [], previousFetchedAt: nil)
        let target = try makeCredential("target@example.com")
        fixture.credentials.setActive(target)
        _ = await fixture.service.loadAccounts(previousAccounts: [], previousFetchedAt: nil)
        let original = try makeCredential("first@example.com")
        fixture.credentials.setActive(original)
        try await fixture.service.switchAccount(profileID: GeminiProfile(email: target.email).id)
        XCTAssertEqual(try fixture.credentials.active()?.email, target.email)
        XCTAssertEqual(try fixture.credentials.saved(profileID: GeminiProfile(email: original.email).id)?.rawValue, original.rawValue)
    }

    func testSwitchRollsBackWhenCredentialVerificationFails() async throws {
        let fixture = try fixture()
        _ = await fixture.service.loadAccounts(previousAccounts: [], previousFetchedAt: nil)
        let target = try makeCredential("target@example.com")
        fixture.credentials.setActive(target)
        _ = await fixture.service.loadAccounts(previousAccounts: [], previousFetchedAt: nil)
        fixture.credentials.setActive(try makeCredential("first@example.com"))
        fixture.credentials.failNextWrite()
        do {
            try await fixture.service.switchAccount(profileID: GeminiProfile(email: target.email).id)
            XCTFail("Expected verification failure")
        } catch GeminiUsageError.switchFailed {} catch { XCTFail("Wrong error") }
        XCTAssertEqual(try fixture.credentials.active()?.email, "first@example.com")
    }

    func testSwitchDoesNotInterruptRunningSessions() async throws {
        let fixture = try fixture(sessionsRunning: { true })
        _ = await fixture.service.loadAccounts(previousAccounts: [], previousFetchedAt: nil)
        let target = try makeCredential("target@example.com")
        fixture.credentials.setActive(target)
        _ = await fixture.service.loadAccounts(previousAccounts: [], previousFetchedAt: nil)
        fixture.credentials.setActive(try makeCredential("first@example.com"))
        do {
            try await fixture.service.switchAccount(profileID: GeminiProfile(email: target.email).id)
            XCTFail("Expected running session guard")
        } catch GeminiUsageError.sessionsRunning {} catch { XCTFail("Wrong error") }
        XCTAssertEqual(try fixture.credentials.active()?.email, "first@example.com")
    }

    func testAddDoesNotInterruptRunningSessions() async throws {
        let fixture = try fixture(sessionsRunning: { true })
        do {
            _ = try await fixture.service.addAccount()
            XCTFail("Expected running session guard")
        } catch GeminiUsageError.sessionsRunning {} catch { XCTFail("Wrong error") }
        XCTAssertEqual(try fixture.credentials.active()?.email, "first@example.com")
    }

    func testManualRefreshRetriesTransientErrorsButRespectsServerLimit() async throws {
        let remote = StubGeminiRemote()
        let fixture = try fixture(client: remote)
        let now = Date()
        let first = await fixture.service.loadAccounts(previousAccounts: [], previousFetchedAt: nil, now: now)
        await remote.setFailure(.unavailable)
        _ = await fixture.service.loadAccounts(previousAccounts: first.accounts, previousFetchedAt: now, now: now)
        await remote.setFailure(nil)
        let automatic = await fixture.service.loadAccounts(previousAccounts: first.accounts, previousFetchedAt: now, now: now)
        XCTAssertEqual(automatic.accounts.first?.providerStatus, "cached")
        let manual = await fixture.service.loadAccounts(
            previousAccounts: first.accounts, previousFetchedAt: now, forceRefresh: true, now: now
        )
        XCTAssertEqual(manual.accounts.first?.providerStatus, "ok")
        await remote.setFailure(.rateLimited(600))
        _ = await fixture.service.loadAccounts(previousAccounts: first.accounts, previousFetchedAt: now, now: now)
        await remote.setFailure(nil)
        let limited = await fixture.service.loadAccounts(
            previousAccounts: first.accounts, previousFetchedAt: now, forceRefresh: true, now: now.addingTimeInterval(100)
        )
        XCTAssertEqual(limited.accounts.first?.providerStatus, "cached")
        let recovered = await fixture.service.loadAccounts(
            previousAccounts: first.accounts, previousFetchedAt: now, now: now.addingTimeInterval(601)
        )
        XCTAssertEqual(recovered.accounts.first?.providerStatus, "ok")
    }

    func testFailedAccountDoesNotBorrowAnotherAccountsCache() async throws {
        let failing = StubGeminiRemote()
        let fixture = try fixture(client: failing)
        let first = await fixture.service.loadAccounts(previousAccounts: [], previousFetchedAt: nil)
        fixture.credentials.setActive(try makeCredential("second@example.com"))
        await failing.setFailure(.unavailable)
        let result = await fixture.service.loadAccounts(previousAccounts: first.accounts, previousFetchedAt: Date())
        let second = try XCTUnwrap(result.accounts.first { $0.email == "second@example.com" })
        XCTAssertTrue(second.hasError)
        XCTAssertTrue(second.usageWindows.isEmpty)
        XCTAssertEqual(result.accounts.first { $0.email == "first@example.com" }?.providerStatus, "cached")
    }

    func testExpiredAuthorizationShowsReconnectRatherThanCachedSuccess() async throws {
        let remote = StubGeminiRemote()
        let fixture = try fixture(client: remote)
        let first = await fixture.service.loadAccounts(previousAccounts: [], previousFetchedAt: nil)
        await remote.setFailure(.reloginRequired)
        let result = await fixture.service.loadAccounts(previousAccounts: first.accounts, previousFetchedAt: Date())
        XCTAssertEqual(result.accounts.first?.providerStatus, "reloginRequired")
        XCTAssertEqual(result.accounts.first?.hasError, true)
    }

    func testCachedResetRetainsItsOwnReferenceAcrossPartialRefreshes() async throws {
        let remote = StubGeminiRemote()
        let fixture = try fixture(client: remote)
        let first = await fixture.service.loadAccounts(previousAccounts: [], previousFetchedAt: nil)
        let original = try XCTUnwrap(first.accounts.first)
        let reference = try XCTUnwrap(original.quotaReferenceDate)
        await remote.setFailure(.unavailable)
        let result = await fixture.service.loadAccounts(
            previousAccounts: first.accounts, previousFetchedAt: reference.addingTimeInterval(200),
            now: reference.addingTimeInterval(600)
        )
        let cached = try XCTUnwrap(result.accounts.first)
        XCTAssertEqual(cached.weeklyResetSeconds, original.weeklyResetSeconds - 600, accuracy: 0.01)
        XCTAssertEqual(cached.quotaReferenceDate, reference.addingTimeInterval(600))
    }

    func testAccountChangeCannotTriggerAnotherAccountsResetNotification() async throws {
        let fixture = try fixture()
        let first = await fixture.service.loadAccounts(previousAccounts: [], previousFetchedAt: nil)
        fixture.credentials.setActive(try makeCredential("second@example.com"))
        let second = await fixture.service.loadAccounts(previousAccounts: [], previousFetchedAt: nil)
        let target = try XCTUnwrap(second.accounts.first { $0.email == "second@example.com" })
        XCTAssertTrue(UsageResetDetector.detect(
            previousAccounts: first.accounts, previousFetchedAt: Date().addingTimeInterval(-1_000_000),
            currentAccounts: [target], currentFetchedAt: Date()
        ).isEmpty)
    }

    func testGoogleTokenRefreshPreservesNativeEnvelopeAndEmail() async throws {
        let original = try makeCredential("first@example.com")
        var object = try JSONSerialization.jsonObject(with: Data(original.rawValue.utf8)) as! [String: Any]
        var token = object["token"] as! [String: Any]
        token["expiry"] = "2000-01-01T00:00:00Z"
        object["token"] = token
        let encoded = try JSONSerialization.data(withJSONObject: object)
        let expired = try GeminiCredential(rawValue: "go-keyring-base64:" + encoded.base64EncodedString())
        let client = GeminiRemoteUsageClient(transport: { request in
            let data: Data
            if request.url?.host == "oauth2.googleapis.com" {
                data = Data(#"{"access_token":"renewed-fake-access","expires_in":3600}"#.utf8)
            } else if request.url!.absoluteString.contains("loadCodeAssist") {
                data = Data(#"{"paidTier":{"id":"g1-pro-tier"}}"#.utf8)
            } else {
                data = Data(#"{"groups":[{"buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.7}]}]}"#.utf8)
            }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, clientResolver: { ("fake-client", "fake-client-secret") })
        let result = try await client.fetch(profile: GeminiProfile(email: expired.email), credential: expired)
        XCTAssertEqual(result.credential.accessToken, "renewed-fake-access")
        XCTAssertEqual(result.credential.email, expired.email)
        XCTAssertTrue(result.credential.rawValue.hasPrefix("go-keyring-base64:"))
        let expiry = try XCTUnwrap(result.credential.expiry)
        XCTAssertGreaterThan(expiry.timeIntervalSinceNow, 3500)
    }

    func testNativeQuotaUsesPlanAndDoesNotTreatUnknownResetAsNow() async throws {
        let client = GeminiRemoteUsageClient(transport: { request in
            let object: [String: Any]
            if request.url!.absoluteString.contains("loadCodeAssist") {
                object = ["paidTier": ["id": "g1-pro-tier"]]
            } else {
                object = ["groups": [["buckets": [
                    ["bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.7],
                    ["bucketId": "gemini-argon-wtu-weekly", "window": "weekly", "remainingFraction": 0.4],
                ]]]]
            }
            return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let credential = try makeCredential("first@example.com")
        let result = try await client.fetch(profile: GeminiProfile(email: credential.email), credential: credential)
        XCTAssertEqual(result.account.displayPlanName, "Pro")
        XCTAssertEqual(result.account.weeklyQuotaWindow?.hasKnownResetTime, false)
        XCTAssertEqual(result.account.argonQuotaWindow?.hasKnownResetTime, false)
        XCTAssertEqual(result.account.agingResetTimers(by: 10).weeklyQuotaWindow?.hasKnownResetTime, false)
        XCTAssertFalse(result.account.isWeeklyPriority)
    }

    func testLiveNativeAccountQueryAndInstalledClientResolver() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CODEX_VITALS_TEST_AGY"] == "1")
        XCTAssertNotNil(GeminiOAuthClientResolver.shared.resolve())
        let credential = try XCTUnwrap(GeminiCredentialStore().active())
        let result = try await GeminiRemoteUsageClient().fetch(profile: GeminiProfile(email: credential.email), credential: credential)
        XCTAssertEqual(result.account.email, credential.email)
        XCTAssertNotNil(result.account.providerProfileID)
        XCTAssertFalse(result.account.usageWindows.isEmpty)
    }

    private func fixture(
        client: any GeminiRemoteUsageProviding = StubGeminiRemote(),
        sessionsRunning: @escaping @Sendable () -> Bool = { false }
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GeminiNativeTests-\(UUID())")
        let url = directory.appendingPathComponent("accounts.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let credentials = MemoryGeminiCredentials(try makeCredential("first@example.com"))
        let service = GeminiAccountService(
            store: GeminiAccountStore(url: url), credentials: credentials, client: client,
            login: {}, sessionsRunning: sessionsRunning
        )
        return Fixture(url: url, credentials: credentials, service: service)
    }

    private func makeCredential(_ email: String) throws -> GeminiCredential {
        let object: [String: Any] = [
            "auth_method": "consumer", "id_token_email": email,
            "token": ["access_token": "fake-access", "refresh_token": "fake-refresh", "expiry": "2099-01-01T00:00:00Z"],
        ]
        return try GeminiCredential(rawValue: String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }

    private struct Fixture {
        let url: URL
        let credentials: MemoryGeminiCredentials
        let service: GeminiAccountService
    }
}

private final class MemoryGeminiCredentials: GeminiCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var current: GeminiCredential?
    private var profiles: [String: GeminiCredential] = [:]
    private var rejectWrite = false
    init(_ credential: GeminiCredential) { current = credential }
    func active() throws -> GeminiCredential? { lock.withLock { current } }
    func setActive(_ credential: GeminiCredential) { lock.withLock { current = credential } }
    func failNextWrite() { lock.withLock { rejectWrite = true } }
    func writeActive(_ credential: GeminiCredential) throws {
        lock.withLock {
            if rejectWrite { rejectWrite = false; return }
            current = credential
        }
    }
    func removeActive() throws { lock.withLock { current = nil } }
    func saved(profileID: String) throws -> GeminiCredential? { lock.withLock { profiles[profileID] } }
    func save(_ credential: GeminiCredential, profileID: String) throws { lock.withLock { profiles[profileID] = credential } }
    func delete(profileID: String) throws { lock.withLock { _ = profiles.removeValue(forKey: profileID) } }
}

private actor StubGeminiRemote: GeminiRemoteUsageProviding {
    private var failure: GeminiUsageError?
    func setFailure(_ error: GeminiUsageError?) { failure = error }
    func fetch(profile: GeminiProfile, credential: GeminiCredential) async throws -> GeminiRemoteResult {
        if let failure { throw failure }
        let raw = #"{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.8,"reset_time":"2099-01-01T00:00:00Z"}]}]}}}"#
        let account = try JSONDecoder().decode(GeminiUsageReport.self, from: Data(raw.utf8)).account(now: Date(), profile: profile)
        return GeminiRemoteResult(account: account, credential: credential)
    }
}
