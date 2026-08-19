import Foundation
import XCTest
@testable import CodexVitals

final class ClaudeNativeServiceTests: XCTestCase {
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
        let reloaded = try ClaudeAccountStore(storeURL: url).load()

        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.id, profile.id)
        XCTAssertEqual(reloaded.first?.alias, "Primary")
        XCTAssertEqual(reloaded.first?.email, "researcher@example.com")
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
        _ = try accountStore.upsert(
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
            targetProfileID: target.id,
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
    let targetProfileID: String
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

private enum TestFailure: Error {
    case expected
}
