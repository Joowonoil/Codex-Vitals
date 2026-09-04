import Foundation
import XCTest
@testable import CodexVitals

final class ClaudeNativeServiceTests: XCTestCase {
    func testClaudePlanFormatterUsesOrganizationTierMetadata() {
        XCTAssertEqual(
            ClaudePlanFormatter.displayName(from: [
                "organizationType": "claude_max",
                "organizationRateLimitTier": "default_claude_max_5x",
            ]),
            "Max 5x"
        )
        XCTAssertEqual(
            ClaudePlanFormatter.displayName(from: [
                "organizationType": "claude_max",
                "organizationRateLimitTier": "default_claude_max_20x",
            ]),
            "Max 20x"
        )
        XCTAssertEqual(
            ClaudePlanFormatter.displayName(from: ["seatTier": "pro"]),
            "Pro"
        )
        XCTAssertNil(ClaudePlanFormatter.displayName(from: ["billingType": "stripe_subscription"]))
    }

    func testUsageResponseParsesFableFromScopedWeeklyLimits() throws {
        let data = Data(#"""
        {
          "five_hour": { "utilization": 100, "resets_at": "2026-08-22T13:00:00Z" },
          "seven_day": { "utilization": 21, "resets_at": "2026-08-29T00:00:00Z" },
          "limits": [
            {
              "kind": "weekly_scoped",
              "percent": 12,
              "resets_at": "2026-08-29T00:00:00Z",
              "scope": { "model": { "display_name": "Opus" } }
            },
            {
              "kind": "weekly_scoped",
              "percent": 40,
              "resets_at": "2026-08-29T00:00:00Z",
              "scope": { "model": { "display_name": "Fable 5" } }
            }
          ]
        }
        """#.utf8)

        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let fable = try XCTUnwrap(response.fable)

        XCTAssertEqual(fable.utilization, 40)
        XCTAssertEqual(fable.resetsAt, "2026-08-29T00:00:00Z")
    }

    func testUsageResponseFallsBackToLegacyFableWindow() throws {
        let data = Data(#"""
        {
          "five_hour": null,
          "seven_day": null,
          "seven_day_overage_included": {
            "utilization": 35,
            "resets_at": "2026-08-29T00:00:00Z"
          }
        }
        """#.utf8)

        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)

        XCTAssertEqual(response.fable?.utilization, 35)
    }

    func testCredentialCompositionUsesLiveSharedFieldsOnly() throws {
        let target = try ClaudeCredentialEnvelope(rawValue: credential(
            access: "target-access",
            extra: [
                "pluginSecrets": ["origin": "target"],
                "trustedDeviceToken": "target-device",
            ]
        ))
        let live = try ClaudeCredentialEnvelope(rawValue: credential(
            access: "live-access",
            extra: [
                "pluginSecrets": ["origin": "live"],
                "mcpOAuth": ["token": "live-mcp"],
                "trustedDeviceToken": "live-device",
            ]
        ))

        let composed = try ClaudeCredentialEnvelope(
            rawValue: target.mergingLiveSharedFields(from: live)
        )

        XCTAssertEqual(composed.accessToken, "target-access")
        XCTAssertEqual(
            (composed.root["pluginSecrets"] as? [String: String])?["origin"],
            "live"
        )
        XCTAssertEqual((composed.root["mcpOAuth"] as? [String: String])?["token"], "live-mcp")
        XCTAssertEqual(composed.root["trustedDeviceToken"] as? String, "target-device")
    }

    func testProfileStoreRoundTripsISO8601DatesAndAlias() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("claude-accounts.json")
        let store = ClaudeAccountStore(storeURL: url)
        let oauth = oauthAccount(email: "researcher@example.com", uuid: "account-1")

        let profile = try store.upsert(
            identity: ClaudeIdentity(oauthAccount: oauth),
            oauthAccount: oauth,
            alias: "Primary"
        )
        let renewalDate = Date(timeIntervalSince1970: 1_800_000_000)
        try store.updateWorkspaceAlias(workspace: "Research Lab", alias: "Lab")
        try store.updatePlanRenewalDate(profileID: profile.id, date: renewalDate)
        try store.setHidden(profileID: profile.id, hidden: true)
        let reloaded = try ClaudeAccountStore(storeURL: url).load()

        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.id, profile.id)
        XCTAssertEqual(reloaded.first?.alias, "Primary")
        XCTAssertEqual(reloaded.first?.email, "researcher@example.com")
        XCTAssertEqual(reloaded.first?.workspaceAlias, "Lab")
        XCTAssertEqual(reloaded.first?.planRenewalDate, renewalDate)
        XCTAssertFalse(try XCTUnwrap(reloaded.first).isVisible)
    }

    func testProfileStorePersistsClaudeAccountOrder() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("claude-accounts.json")
        let store = ClaudeAccountStore(storeURL: url)
        let first = try store.upsert(
            identity: ClaudeIdentity(oauthAccount: oauthAccount(email: "first@example.com", uuid: "first")),
            oauthAccount: oauthAccount(email: "first@example.com", uuid: "first")
        )
        let second = try store.upsert(
            identity: ClaudeIdentity(oauthAccount: oauthAccount(email: "second@example.com", uuid: "second")),
            oauthAccount: oauthAccount(email: "second@example.com", uuid: "second")
        )

        try store.updateOrder([second.id, first.id])

        XCTAssertEqual(try ClaudeAccountStore(storeURL: url).load().map(\.id), [second.id, first.id])
    }

    func testGlobalConfigUpdatePreservesSiblingSettingsAndHomePermissions() throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path)
        let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let configURL = home.appendingPathComponent(".claude.json")
        let shadowURL = claudeDirectory.appendingPathComponent(".credentials.json")
        try jsonData([
            "oauthAccount": oauthAccount(email: "old@example.com", uuid: "old"),
            "projects": ["/tmp/project": ["trusted": true]],
        ]).write(to: configURL)
        try Data("old".utf8).write(to: shadowURL)

        let store = ClaudeGlobalConfigStore(homeURL: home)
        try store.writeOAuthAccount(oauthAccount(email: "new@example.com", uuid: "new"))
        try store.writeCredentialShadowIfPresent("new-credential")

        let snapshot = try store.read()
        XCTAssertEqual(
            ((snapshot.object["projects"] as? [String: Any])?["/tmp/project"] as? [String: Bool])?["trusted"],
            true
        )
        XCTAssertEqual(
            (snapshot.oauthAccount?["emailAddress"] as? String),
            "new@example.com"
        )
        XCTAssertEqual(try String(contentsOf: shadowURL, encoding: .utf8), "new-credential")
        let permissions = try FileManager.default.attributesOfItem(atPath: home.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o755)
    }

    func testLoadSuppressesInvalidCredentialsWhenNoClaudeProfilesAreConfigured() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = FakeClaudeKeychain()
        try keychain.write(
            service: ClaudeKeychainStore.activeService,
            account: keychain.activeAccountName,
            value: "{}"
        )
        let service = ClaudeAccountService(
            keychain: keychain,
            accountStore: ClaudeAccountStore(storeURL: root.appendingPathComponent("accounts.json")),
            configStore: FakeClaudeConfig(object: [
                "oauthAccount": oauthAccount(email: "unused@example.com", uuid: "unused-account"),
            ]),
            usageClient: UnusedClaudeUsageProvider()
        )

        let result = await service.loadAccounts()

        XCTAssertTrue(result.accounts.isEmpty)
        XCTAssertNil(result.errorMessage)
    }

    func testLoadReportsInvalidCredentialsWhenClaudeProfileExists() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oauth = oauthAccount(email: "configured@example.com", uuid: "configured-account")
        let accountStore = ClaudeAccountStore(storeURL: root.appendingPathComponent("accounts.json"))
        _ = try accountStore.upsert(
            identity: ClaudeIdentity(oauthAccount: oauth),
            oauthAccount: oauth
        )
        let keychain = FakeClaudeKeychain()
        try keychain.write(
            service: ClaudeKeychainStore.activeService,
            account: keychain.activeAccountName,
            value: "{}"
        )
        let service = ClaudeAccountService(
            keychain: keychain,
            accountStore: accountStore,
            configStore: FakeClaudeConfig(object: ["oauthAccount": oauth]),
            usageClient: UnusedClaudeUsageProvider()
        )

        let result = await service.loadAccounts()

        XCTAssertEqual(result.accounts.count, 1)
        XCTAssertEqual(result.errorMessage, "Claude credentials are invalid.")
    }

    func testRetryAfterParserReadsDelaySeconds() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "768"]
        ))

        XCTAssertEqual(ClaudeUsageClient.retryAfterSeconds(from: response), 768)
    }

    func testClaudeUsageUsesFifteenMinuteMinimumAndHonorsLongerRetryAfter() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oauth = oauthAccount(email: "configured@example.com", uuid: "configured-account")
        let accountStore = ClaudeAccountStore(storeURL: root.appendingPathComponent("accounts.json"))
        let profile = try accountStore.upsert(
            identity: ClaudeIdentity(oauthAccount: oauth),
            oauthAccount: oauth
        )
        let rawCredential = credential(access: "active-access")
        let keychain = FakeClaudeKeychain()
        try keychain.write(
            service: ClaudeKeychainStore.activeService,
            account: keychain.activeAccountName,
            value: rawCredential
        )
        let successfulUsage = try usageResult(credential: rawCredential, now: now)
        let usageProvider = SequenceClaudeUsageProvider(results: [
            .success(successfulUsage),
            .failure(.rateLimited(retryAfter: TimeInterval(30 * 60))),
            .success(successfulUsage),
        ])
        let service = ClaudeAccountService(
            keychain: keychain,
            accountStore: accountStore,
            configStore: FakeClaudeConfig(object: ["oauthAccount": oauth]),
            usageClient: usageProvider
        )

        let first = await service.loadAccounts(now: now)
        let firstCallCount = await usageProvider.numberOfCalls()
        XCTAssertEqual(firstCallCount, 1)
        XCTAssertEqual(first.accounts.first?.providerStatus, ClaudeAccountStatus.ok.rawValue)

        let fiveMinutesLater = now.addingTimeInterval(5 * 60)
        let withinMinimum = await service.loadAccounts(
            previousAccounts: first.accounts,
            previousFetchedAt: now,
            now: fiveMinutesLater
        )
        let minimumIntervalCallCount = await usageProvider.numberOfCalls()
        XCTAssertEqual(minimumIntervalCallCount, 1)
        XCTAssertEqual(withinMinimum.accounts.first?.providerStatus, ClaudeAccountStatus.cached.rawValue)
        let cachedAccount = try XCTUnwrap(withinMinimum.accounts.first)
        XCTAssertTrue(cachedAccount.canSwitchProviderAccount)
        let cachedReset = try XCTUnwrap(
            cachedAccount.fiveHourQuotaWindow?.resetAfterSeconds
        )
        XCTAssertEqual(
            cachedReset,
            TimeInterval(55 * 60),
            accuracy: 1
        )

        let afterMinimum = now.addingTimeInterval(15 * 60 + 1)
        let rateLimited = await service.loadAccounts(
            previousAccounts: withinMinimum.accounts,
            previousFetchedAt: fiveMinutesLater,
            now: afterMinimum
        )
        let rateLimitedCallCount = await usageProvider.numberOfCalls()
        XCTAssertEqual(rateLimitedCallCount, 2)
        XCTAssertEqual(rateLimited.accounts.first?.providerStatus, ClaudeAccountStatus.cached.rawValue)
        let rateLimitedAccount = try XCTUnwrap(rateLimited.accounts.first)
        XCTAssertFalse(rateLimitedAccount.hasError)

        _ = await service.loadAccounts(
            previousAccounts: rateLimited.accounts,
            previousFetchedAt: afterMinimum,
            now: now.addingTimeInterval(30 * 60)
        )
        let retryWaitCallCount = await usageProvider.numberOfCalls()
        XCTAssertEqual(retryWaitCallCount, 2)

        let afterRetry = now.addingTimeInterval(45 * 60 + 2)
        let refreshed = await service.loadAccounts(
            previousAccounts: rateLimited.accounts,
            previousFetchedAt: afterMinimum,
            now: afterRetry
        )
        let refreshedCallCount = await usageProvider.numberOfCalls()
        XCTAssertEqual(refreshedCallCount, 3)
        XCTAssertEqual(refreshed.accounts.first?.providerProfileID, profile.id)
        XCTAssertEqual(refreshed.accounts.first?.providerStatus, ClaudeAccountStatus.ok.rawValue)
    }

    func testRateLimitAfterRelaunchFallsBackToSavedClaudeSnapshot() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oauth = oauthAccount(email: "configured@example.com", uuid: "configured-account")
        let accountStore = ClaudeAccountStore(storeURL: root.appendingPathComponent("accounts.json"))
        _ = try accountStore.upsert(
            identity: ClaudeIdentity(oauthAccount: oauth),
            oauthAccount: oauth
        )
        let rawCredential = credential(access: "active-access")
        let keychain = FakeClaudeKeychain()
        try keychain.write(
            service: ClaudeKeychainStore.activeService,
            account: keychain.activeAccountName,
            value: rawCredential
        )
        let initialProvider = SequenceClaudeUsageProvider(results: [
            .success(try usageResult(credential: rawCredential, now: now)),
        ])
        let initialService = ClaudeAccountService(
            keychain: keychain,
            accountStore: accountStore,
            configStore: FakeClaudeConfig(object: ["oauthAccount": oauth]),
            usageClient: initialProvider
        )
        let saved = await initialService.loadAccounts(now: now)
        let rateLimitedProvider = SequenceClaudeUsageProvider(results: [
            .failure(.rateLimited(retryAfter: TimeInterval(15 * 60))),
        ])
        let relaunchedService = ClaudeAccountService(
            keychain: keychain,
            accountStore: accountStore,
            configStore: FakeClaudeConfig(object: ["oauthAccount": oauth]),
            usageClient: rateLimitedProvider
        )

        let result = await relaunchedService.loadAccounts(
            previousAccounts: saved.accounts,
            previousFetchedAt: now,
            now: now.addingTimeInterval(60)
        )

        let callCount = await rateLimitedProvider.numberOfCalls()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(result.accounts.first?.providerStatus, ClaudeAccountStatus.cached.rawValue)
        let cachedAccount = try XCTUnwrap(result.accounts.first)
        XCTAssertFalse(cachedAccount.hasError)
        XCTAssertFalse(cachedAccount.usageWindows.isEmpty)
    }

    func testNativeSwitchPreservesLiveSharedFieldsAndOnlyReplacesOAuthAccount() async throws {
        let fixture = try makeSwitchFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try await fixture.service.switchAccount(profileID: fixture.targetProfileID)

        let activeRaw = try XCTUnwrap(fixture.keychain.value(
            service: ClaudeKeychainStore.activeService,
            account: "tester"
        ))
        let active = try ClaudeCredentialEnvelope(rawValue: activeRaw)
        XCTAssertEqual(active.accessToken, "target-access")
        XCTAssertEqual((active.root["pluginSecrets"] as? [String: String])?["source"], "live")
        let config = try fixture.config.read()
        XCTAssertEqual(config.oauthAccount?["emailAddress"] as? String, "target@example.com")
        XCTAssertEqual(config.object["theme"] as? String, "dark")
    }

    func testNativeSwitchRollsBackCredentialAndConfigWhenConfigWriteFails() async throws {
        let fixture = try makeSwitchFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.config.failNextOAuthWrite = true

        do {
            try await fixture.service.switchAccount(profileID: fixture.targetProfileID)
            XCTFail("Expected switch failure")
        } catch {}

        let activeRaw = try XCTUnwrap(fixture.keychain.value(
            service: ClaudeKeychainStore.activeService,
            account: "tester"
        ))
        XCTAssertEqual(try ClaudeCredentialEnvelope(rawValue: activeRaw).accessToken, "live-access")
        let config = try fixture.config.read()
        XCTAssertEqual(config.oauthAccount?["emailAddress"] as? String, "live@example.com")
        let shadow = try XCTUnwrap(fixture.config.shadowCredential)
        XCTAssertEqual(try ClaudeCredentialEnvelope(rawValue: shadow).accessToken, "live-access")
    }

    func testRemovingActiveClaudeProfileHidesItWithoutLoggingClaudeOut() async throws {
        let fixture = try makeSwitchFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try await fixture.service.removeAccount(profileID: fixture.liveProfileID)

        XCTAssertFalse(try XCTUnwrap(fixture.accountStore.profile(id: fixture.liveProfileID)).isVisible)
        XCTAssertNotNil(fixture.keychain.value(
            service: ClaudeKeychainStore.activeService,
            account: "tester"
        ))
        let result = await fixture.service.loadAccounts()
        XCTAssertFalse(result.accounts.contains { $0.providerProfileID == fixture.liveProfileID })
    }

    func testLoadRecoversInterruptedSwitchFromKeychainSafetyCredential() async throws {
        let fixture = try makeSwitchFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let liveCredential = credential(
            access: "live-access",
            extra: ["pluginSecrets": ["source": "live"]]
        )
        let interruptedTarget = credential(access: "target-access")
        try fixture.keychain.write(
            service: ClaudeKeychainStore.profileService,
            account: "live-account",
            value: liveCredential
        )
        try fixture.keychain.write(
            service: ClaudeKeychainStore.safetyService,
            account: ClaudeKeychainStore.safetyAccount,
            value: liveCredential
        )
        try fixture.keychain.write(
            service: ClaudeKeychainStore.activeService,
            account: "tester",
            value: interruptedTarget
        )

        _ = await fixture.service.loadAccounts()

        let restored = try XCTUnwrap(fixture.keychain.value(
            service: ClaudeKeychainStore.activeService,
            account: "tester"
        ))
        XCTAssertEqual(try ClaudeCredentialEnvelope(rawValue: restored).accessToken, "live-access")
        XCTAssertNil(fixture.keychain.value(
            service: ClaudeKeychainStore.safetyService,
            account: ClaudeKeychainStore.safetyAccount
        ))
    }

    private func makeSwitchFixture() throws -> SwitchFixture {
        let root = temporaryDirectory()
        let accountStore = ClaudeAccountStore(storeURL: root.appendingPathComponent("accounts.json"))
        let liveOAuth = oauthAccount(email: "live@example.com", uuid: "live-account")
        let targetOAuth = oauthAccount(email: "target@example.com", uuid: "target-account")
        let live = try accountStore.upsert(
            identity: ClaudeIdentity(oauthAccount: liveOAuth),
            oauthAccount: liveOAuth
        )
        let target = try accountStore.upsert(
            identity: ClaudeIdentity(oauthAccount: targetOAuth),
            oauthAccount: targetOAuth
        )

        let keychain = FakeClaudeKeychain()
        let liveCredential = credential(
            access: "live-access",
            extra: ["pluginSecrets": ["source": "live"]]
        )
        let targetCredential = credential(
            access: "target-access",
            extra: ["pluginSecrets": ["source": "target"]]
        )
        try keychain.write(
            service: ClaudeKeychainStore.activeService,
            account: "tester",
            value: liveCredential
        )
        try keychain.write(
            service: ClaudeKeychainStore.profileService,
            account: target.id,
            value: targetCredential
        )
        let config = FakeClaudeConfig(object: [
            "oauthAccount": liveOAuth,
            "theme": "dark",
        ])
        config.shadowCredential = "live-credential-placeholder"
        let service = ClaudeAccountService(
            keychain: keychain,
            accountStore: accountStore,
            configStore: config,
            usageClient: UnusedClaudeUsageProvider()
        )
        return SwitchFixture(
            root: root,
            liveProfileID: live.id,
            targetProfileID: target.id,
            accountStore: accountStore,
            keychain: keychain,
            config: config,
            service: service
        )
    }

    private func oauthAccount(email: String, uuid: String) -> [String: Any] {
        [
            "emailAddress": email,
            "accountUuid": uuid,
            "organizationUuid": "org-1",
            "organizationName": "Research Lab",
        ]
    }

    private func credential(access: String, extra: [String: Any] = [:]) -> String {
        var root = extra
        root["claudeAiOauth"] = [
            "accessToken": access,
            "refreshToken": "refresh-\(access)",
            "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,
        ]
        return String(data: try! jsonData(root), encoding: .utf8)!
    }

    private func usageResult(credential: String, now: Date) throws -> ClaudeUsageResult {
        let formatter = ISO8601DateFormatter()
        let fiveHourReset = formatter.string(from: now.addingTimeInterval(60 * 60))
        let weeklyReset = formatter.string(from: now.addingTimeInterval(7 * 24 * 60 * 60))
        let data = Data(#"""
        {
          "five_hour": { "utilization": 25, "resets_at": "\#(fiveHourReset)" },
          "seven_day": { "utilization": 40, "resets_at": "\#(weeklyReset)" }
        }
        """#.utf8)
        return ClaudeUsageResult(
            credential: credential,
            response: try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        )
    }

    private func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexVitals-ClaudeTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct SwitchFixture {
    let root: URL
    let liveProfileID: String
    let targetProfileID: String
    let accountStore: ClaudeAccountStore
    let keychain: FakeClaudeKeychain
    let config: FakeClaudeConfig
    let service: ClaudeAccountService
}

private final class FakeClaudeKeychain: ClaudeKeychainStoring, @unchecked Sendable {
    let activeAccountName = "tester"
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func read(service: String, account: String) throws -> String? {
        lock.withLock { values[key(service, account)] }
    }

    func write(service: String, account: String, value: String) throws {
        lock.withLock { values[key(service, account)] = value }
    }

    func delete(service: String, account: String) throws {
        lock.withLock { _ = values.removeValue(forKey: key(service, account)) }
    }

    func value(service: String, account: String) -> String? {
        lock.withLock { values[key(service, account)] }
    }

    private func key(_ service: String, _ account: String) -> String {
        "\(service)|\(account)"
    }
}

private final class FakeClaudeConfig: ClaudeGlobalConfigStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var object: [String: Any]
    var failNextOAuthWrite = false
    var shadowCredential: String?

    init(object: [String: Any]) {
        self.object = object
    }

    func read() throws -> ClaudeGlobalConfigSnapshot {
        try lock.withLock {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return ClaudeGlobalConfigSnapshot(rawData: data, object: object)
        }
    }

    func writeOAuthAccount(_ oauthAccount: [String: Any]) throws {
        try lock.withLock {
            if failNextOAuthWrite {
                failNextOAuthWrite = false
                throw TestFailure.expected
            }
            object["oauthAccount"] = oauthAccount
        }
    }

    func restore(_ snapshot: ClaudeGlobalConfigSnapshot) throws {
        lock.withLock { object = snapshot.object }
    }

    func writeCredentialShadowIfPresent(_ credentials: String) throws {
        lock.withLock { shadowCredential = credentials }
    }
}

private struct UnusedClaudeUsageProvider: ClaudeUsageProviding {
    func fetchUsage(
        credential: String,
        expectedAccountUUID: String?,
        refreshIfNeeded: Bool
    ) async throws -> ClaudeUsageResult {
        throw TestFailure.expected
    }
}

private actor SequenceClaudeUsageProvider: ClaudeUsageProviding {
    private var results: [Result<ClaudeUsageResult, ClaudeNativeError>]
    private var callCount = 0

    init(results: [Result<ClaudeUsageResult, ClaudeNativeError>]) {
        self.results = results
    }

    func fetchUsage(
        credential: String,
        expectedAccountUUID: String?,
        refreshIfNeeded: Bool
    ) async throws -> ClaudeUsageResult {
        callCount += 1
        guard !results.isEmpty else { throw TestFailure.expected }
        return try results.removeFirst().get()
    }

    func numberOfCalls() -> Int {
        callCount
    }
}

private enum TestFailure: Error {
    case expected
}
