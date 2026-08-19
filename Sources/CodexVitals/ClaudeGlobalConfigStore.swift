import Foundation

struct ClaudeGlobalConfigSnapshot: @unchecked Sendable {
    let rawData: Data
    let object: [String: Any]

    var oauthAccount: [String: Any]? {
        object["oauthAccount"] as? [String: Any]
    }
}

protocol ClaudeGlobalConfigStoring: Sendable {
    func read() throws -> ClaudeGlobalConfigSnapshot
    func writeOAuthAccount(_ oauthAccount: [String: Any]) throws
    func restore(_ snapshot: ClaudeGlobalConfigSnapshot) throws
    func writeCredentialShadowIfPresent(_ credentials: String) throws
}

final class ClaudeGlobalConfigStore: ClaudeGlobalConfigStoring, @unchecked Sendable {
    private let fileManager: FileManager
    private let configURL: URL
    private let credentialShadowURL: URL
    private let maximumConfigBytes = 16 * 1024 * 1024

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        configURL = homeURL.appendingPathComponent(".claude.json")
        credentialShadowURL = homeURL.appendingPathComponent(".claude/.credentials.json")
    }

    func read() throws -> ClaudeGlobalConfigSnapshot {
        let data = try Data(contentsOf: configURL)
        guard data.count <= maximumConfigBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeNativeError.invalidAccountMetadata
        }
        return ClaudeGlobalConfigSnapshot(rawData: data, object: object)
    }

    func writeOAuthAccount(_ oauthAccount: [String: Any]) throws {
        var object = try read().object
        object["oauthAccount"] = oauthAccount
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try write(data, to: configURL)
    }

    func restore(_ snapshot: ClaudeGlobalConfigSnapshot) throws {
        try write(snapshot.rawData, to: configURL)
    }

    func writeCredentialShadowIfPresent(_ credentials: String) throws {
        guard fileManager.fileExists(atPath: credentialShadowURL.path) else { return }
        guard let data = credentials.data(using: .utf8) else {
            throw ClaudeNativeError.invalidCredentials
        }
        try write(data, to: credentialShadowURL)
    }

    private func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try AppStorage.ensureDirectory(parent, permissions: 0o700)
        }
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
