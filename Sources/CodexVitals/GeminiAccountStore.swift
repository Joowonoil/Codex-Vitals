import CryptoKit
import Foundation

struct GeminiProfile: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let email: String
    var plan: String?
    var alias: String?
    var workspace: String = "Gemini"
    var workspaceAlias: String?
    var planRenewalDate: Date?
    var isHidden = false

    init(email: String) {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        id = SHA256.hash(data: Data(self.email.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

final class GeminiAccountStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(url: URL = AppStorage.rootURL.appendingPathComponent("gemini-accounts.json")) {
        self.url = url
    }

    func load() throws -> [GeminiProfile] {
        try lock.withLock { try read() }
    }

    func update(_ change: (inout [GeminiProfile]) throws -> Void) throws {
        try lock.withLock {
            var profiles = try read()
            try change(&profiles)
            let data = try JSONEncoder().encode(profiles)
            try AppStorage.ensureDirectory(url.deletingLastPathComponent(), permissions: 0o700)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func read() throws -> [GeminiProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let profiles = try JSONDecoder().decode([GeminiProfile].self, from: Data(contentsOf: url))
        guard Set(profiles.map(\.id)).count == profiles.count,
              profiles.allSatisfy({ $0.id == GeminiProfile(email: $0.email).id }) else {
            throw GeminiUsageError.identityChanged
        }
        return profiles
    }
}

struct GeminiCredential: Sendable {
    let rawValue: String
    let email: String
    let accessToken: String
    let refreshToken: String?
    let expiry: Date?

    init(rawValue: String) throws {
        var data = Data(rawValue.utf8)
        if rawValue.hasPrefix("go-keyring-base64:") {
            guard let decoded = Data(base64Encoded: String(rawValue.dropFirst("go-keyring-base64:".count))) else {
                throw GeminiUsageError.reloginRequired
            }
            data = decoded
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["auth_method"] as? String == "consumer",
              let email = object["id_token_email"] as? String, email.contains("@"),
              let token = object["token"] as? [String: Any],
              let access = token["access_token"] as? String, !access.isEmpty else {
            throw GeminiUsageError.reloginRequired
        }
        self.rawValue = rawValue
        self.email = email.lowercased()
        accessToken = access
        refreshToken = token["refresh_token"] as? String
        expiry = (token["expiry"] as? String).flatMap(Self.date)
    }

    func replacingToken(_ response: [String: Any], now: Date) throws -> GeminiCredential {
        let wrapped = rawValue.hasPrefix("go-keyring-base64:")
        let data = wrapped
            ? Data(base64Encoded: String(rawValue.dropFirst("go-keyring-base64:".count)))!
            : Data(rawValue.utf8)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var token = object["token"] as! [String: Any]
        guard let access = response["access_token"] as? String else { throw GeminiUsageError.reloginRequired }
        token["access_token"] = access
        if let refresh = response["refresh_token"] as? String { token["refresh_token"] = refresh }
        let duration = (response["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        token["expiry"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(duration))
        object["token"] = token
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try GeminiCredential(rawValue: wrapped
            ? "go-keyring-base64:" + encoded.base64EncodedString()
            : String(decoding: encoded, as: UTF8.self))
    }

    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

protocol GeminiCredentialStoring: Sendable {
    func active() throws -> GeminiCredential?
    func writeActive(_ credential: GeminiCredential) throws
    func removeActive() throws
    func saved(profileID: String) throws -> GeminiCredential?
    func save(_ credential: GeminiCredential, profileID: String) throws
    func delete(profileID: String) throws
}

struct GeminiCredentialStore: GeminiCredentialStoring {
    private let keychain: any ClaudeKeychainStoring
    private let profileService = "app.codexvitals.menubar.Gemini"

    init(keychain: any ClaudeKeychainStoring = ClaudeKeychainStore()) { self.keychain = keychain }

    func active() throws -> GeminiCredential? {
        try keychain.read(service: "gemini", account: "antigravity").map(GeminiCredential.init)
    }

    func writeActive(_ credential: GeminiCredential) throws {
        try keychain.write(service: "gemini", account: "antigravity", value: credential.rawValue)
    }

    func removeActive() throws {
        try keychain.delete(service: "gemini", account: "antigravity")
    }

    func saved(profileID: String) throws -> GeminiCredential? {
        try keychain.read(service: profileService, account: profileID).map(GeminiCredential.init)
    }

    func save(_ credential: GeminiCredential, profileID: String) throws {
        try keychain.write(service: profileService, account: profileID, value: credential.rawValue)
    }

    func delete(profileID: String) throws {
        try keychain.delete(service: profileService, account: profileID)
    }
}
