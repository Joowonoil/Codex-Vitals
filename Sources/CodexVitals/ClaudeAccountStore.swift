import Foundation

struct ClaudeProfileDocument: Codable, Sendable {
    var version: Int = 1
    var profiles: [ClaudeNativeProfile] = []
    var order: [String] = []
}

final class ClaudeAccountStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let storeURL: URL
    private let lock = NSLock()

    init(
        storeURL: URL = AppStorage.rootURL.appendingPathComponent("claude-accounts.json"),
        fileManager: FileManager = .default
    ) {
        self.storeURL = storeURL
        self.fileManager = fileManager
    }

    func load() throws -> [ClaudeNativeProfile] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    func profile(id: String) throws -> ClaudeNativeProfile? {
        try load().first { $0.id == id }
    }

    @discardableResult
    func upsert(
        identity: ClaudeIdentity,
        oauthAccount: [String: Any],
        alias: String? = nil,
        now: Date = Date()
    ) throws -> ClaudeNativeProfile {
        guard identity.isValid else { throw ClaudeNativeError.invalidAccountMetadata }
        let oauthData = try JSONSerialization.data(withJSONObject: oauthAccount, options: [.sortedKeys])
        guard let oauthJSON = String(data: oauthData, encoding: .utf8) else {
            throw ClaudeNativeError.invalidAccountMetadata
        }

        lock.lock()
        defer { lock.unlock() }
        var document = try documentUnlocked()
        let existingIndex = document.profiles.firstIndex { profile in
            profile.id == identity.profileID || profile.matches(oauthAccount: oauthAccount)
        }
        let existing = existingIndex.map { document.profiles[$0] }
        let profile = ClaudeNativeProfile(
            id: existing?.id ?? identity.profileID,
            email: identity.email,
            accountUUID: identity.accountUUID,
            organizationUUID: identity.organizationUUID,
            organizationName: identity.organizationName,
            alias: Account.normalizedAlias(alias) ?? existing?.alias,
            workspaceAlias: existing?.workspaceAlias,
            planRenewalDate: existing?.planRenewalDate,
            isHidden: existing?.isHidden,
            oauthAccountJSON: oauthJSON,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        if let existingIndex {
            document.profiles[existingIndex] = profile
        } else {
            document.profiles.append(profile)
            document.order.append(profile.id)
        }
        try write(document)
        return profile
    }

    func updateAlias(profileID: String, alias: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        var document = try documentUnlocked()
        guard let index = document.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ClaudeNativeError.profileMissing
        }
        document.profiles[index].alias = Account.normalizedAlias(alias)
        document.profiles[index].updatedAt = Date()
        try write(document)
    }

    func updateWorkspaceAlias(workspace: String, alias: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        var document = try documentUnlocked()
        let normalizedAlias = Account.normalizedAlias(alias)
        var changed = false
        for index in document.profiles.indices where document.profiles[index].workspaceName == workspace {
            document.profiles[index].workspaceAlias = normalizedAlias
            document.profiles[index].updatedAt = Date()
            changed = true
        }
        guard changed else { throw ClaudeNativeError.profileMissing }
        try write(document)
    }

    func updatePlanRenewalDate(profileID: String, date: Date?) throws {
        lock.lock()
        defer { lock.unlock() }
        var document = try documentUnlocked()
        guard let index = document.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ClaudeNativeError.profileMissing
        }
        document.profiles[index].planRenewalDate = date
        document.profiles[index].updatedAt = Date()
        try write(document)
    }

    func setHidden(profileID: String, hidden: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        var document = try documentUnlocked()
        guard let index = document.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ClaudeNativeError.profileMissing
        }
        document.profiles[index].isHidden = hidden ? true : nil
        document.profiles[index].updatedAt = Date()
        if !hidden, !document.order.contains(profileID) {
            document.order.append(profileID)
        }
        try write(document)
    }

    func updateOrder(_ orderedProfileIDs: [String]) throws {
        lock.lock()
        defer { lock.unlock() }
        var document = try documentUnlocked()
        let knownIDs = Set(document.profiles.map(\.id))
        let requested = orderedProfileIDs.filter { knownIDs.contains($0) }
        let remaining = document.order.filter { !requested.contains($0) && knownIDs.contains($0) }
        document.order = requested + remaining
        try write(document)
    }

    func remove(profileID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var document = try documentUnlocked()
        guard document.profiles.contains(where: { $0.id == profileID }) else {
            throw ClaudeNativeError.profileMissing
        }
        document.profiles.removeAll { $0.id == profileID }
        document.order.removeAll { $0 == profileID }
        try write(document)
    }

    private func loadUnlocked() throws -> [ClaudeNativeProfile] {
        let document = try documentUnlocked()
        let order = Dictionary(uniqueKeysWithValues: document.order.enumerated().map { ($1, $0) })
        return document.profiles.sorted { lhs, rhs in
            let left = order[lhs.id] ?? Int.max
            let right = order[rhs.id] ?? Int.max
            if left != right { return left < right }
            return lhs.email.localizedCaseInsensitiveCompare(rhs.email) == .orderedAscending
        }
    }

    private func documentUnlocked() throws -> ClaudeProfileDocument {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            return ClaudeProfileDocument()
        }
        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ClaudeProfileDocument.self, from: data)
        guard document.version == 1 else {
            throw ClaudeNativeError.invalidAccountMetadata
        }
        return document
    }

    private func write(_ document: ClaudeProfileDocument) throws {
        let data = try JSONEncoder.codexVitals.encode(document)
        try AppStorage.ensureDirectory(storeURL.deletingLastPathComponent(), permissions: 0o700)
        let temporaryURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent(".\(storeURL.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        if fileManager.fileExists(atPath: storeURL.path) {
            _ = try fileManager.replaceItemAt(storeURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: storeURL)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }
}

private extension JSONEncoder {
    static var codexVitals: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
