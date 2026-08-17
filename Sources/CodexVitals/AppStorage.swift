import Foundation

enum AppStorage {
    private static let fileManager = FileManager.default
    private static let supportDirectoryName = "CodexVitals"

    static var rootURL: URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = baseURL.appendingPathComponent(supportDirectoryName, isDirectory: true)
        try? ensureDirectory(url, permissions: 0o700)
        return url
    }

    static var profilesURL: URL {
        let url = rootURL.appendingPathComponent("profiles", isDirectory: true)
        try? ensureDirectory(url, permissions: 0o700)
        return url
    }

    static var backupsURL: URL {
        let url = rootURL.appendingPathComponent("backups", isDirectory: true)
        try? ensureDirectory(url, permissions: 0o700)
        return url
    }

    static var accountsURL: URL {
        rootURL.appendingPathComponent("accounts.json")
    }

    static func ensureDirectory(_ url: URL, permissions: Int) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: permissions]
        )
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    static func writeJSON(_ object: Any, to url: URL, permissions: Int = 0o600) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try ensureDirectory(url.deletingLastPathComponent(), permissions: 0o700)
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: tempURL.path)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: tempURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: tempURL, to: url)
        }
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

struct AccountProfileCollection {
    var profiles: [String: [String: Any]]
    var orderedKeys: [String]
    var workspaceAliases: [String: String]
}

enum AccountProfileStore {
    enum Error: LocalizedError {
        case missingProfile(String)

        var errorDescription: String? {
            switch self {
            case let .missingProfile(profileKey):
                return "Account profile is missing from accounts.json: \(profileKey)"
            }
        }
    }

    static func load() -> AccountProfileCollection {
        if let local = loadLocal(), !local.profiles.isEmpty {
            return CodexCanonicalCredentialStore().hydrate(local)
        }

        return AccountProfileCollection(profiles: [:], orderedKeys: [], workspaceAliases: [:])
    }

    static func loadLocalProfiles() -> [String: [String: Any]] {
        loadLocal()?.profiles ?? [:]
    }

    static var hasProfiles: Bool {
        !loadLocalProfiles().isEmpty
    }

    static func upsert(
        profileKey: String,
        oldProfileKey: String?,
        email: String,
        accountID: String,
        accessToken: String,
        refreshToken: String,
        expiresAt: Int
    ) throws {
        try CodexAuthFileLock.withLock {
            var root = accountsRoot()
            var profiles = root["profiles"] as? [String: Any] ?? [:]
            var entry = profiles[profileKey] as? [String: Any] ?? [:]

            if let oldProfileKey,
               oldProfileKey != profileKey,
               let oldEntry = profiles[oldProfileKey] as? [String: Any] {
                entry = oldEntry.merging(entry) { current, _ in current }
                profiles.removeValue(forKey: oldProfileKey)
                replaceProfileKey(in: &root, from: oldProfileKey, to: profileKey)
            }

            entry["access"] = accessToken
            entry["refresh"] = refreshToken
            entry["expires"] = expiresAt
            entry["provider"] = "openai-codex"
            entry["type"] = "oauth"
            entry["email"] = email
            entry["accountId"] = accountID

            removeDuplicateProfiles(from: &profiles, root: &root, keeping: profileKey, email: email, accountID: accountID)
            profiles[profileKey] = entry
            root["profiles"] = profiles
            if root["version"] == nil {
                root["version"] = 1
            }
            appendToDefaultOrder(in: &root, key: profileKey)
            try AppStorage.writeJSON(root, to: AppStorage.accountsURL, permissions: 0o600)
        }
    }

    static func updateTokens(
        profileKey: String,
        email: String,
        accountID: String,
        accessToken: String,
        refreshToken: String,
        idToken: String?,
        expiresAt: Int
    ) throws {
        try CodexAuthFileLock.withLock {
            var root = accountsRoot()
            var profiles = root["profiles"] as? [String: Any] ?? [:]
            guard var entry = profiles[profileKey] as? [String: Any] else {
                throw Error.missingProfile(profileKey)
            }

            // Captured auth.json is canonical. Never advance the derived cache first.
            try updateCapturedProfiles(
                profileKey: profileKey,
                email: email,
                accountID: accountID,
                accessToken: accessToken,
                refreshToken: refreshToken,
                idToken: idToken,
                expiresAt: expiresAt
            )

            entry["access"] = accessToken
            entry["refresh"] = refreshToken
            entry["expires"] = expiresAt
            profiles[profileKey] = entry
            root["profiles"] = profiles
            try AppStorage.writeJSON(root, to: AppStorage.accountsURL, permissions: 0o600)
        }
    }

    static func updateAlias(profileKey: String, alias: String?) throws {
        try CodexAuthFileLock.withLock {
            var root = accountsRoot()
            var profiles = root["profiles"] as? [String: Any] ?? [:]
            guard var entry = profiles[profileKey] as? [String: Any] else {
                throw Error.missingProfile(profileKey)
            }

            if let alias = Account.normalizedAlias(alias) {
                entry["alias"] = alias
            } else {
                entry.removeValue(forKey: "alias")
            }

            profiles[profileKey] = entry
            root["profiles"] = profiles
            try AppStorage.writeJSON(root, to: AppStorage.accountsURL, permissions: 0o600)
        }
    }

    static func updateWorkspaceAlias(workspace: String, alias: String?) throws {
        try CodexAuthFileLock.withLock {
            let key = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }

            var root = accountsRoot()
            var aliases = root["workspaceAliases"] as? [String: String] ?? [:]
            if let alias = Account.normalizedAlias(alias) {
                aliases[key] = alias
            } else {
                aliases.removeValue(forKey: key)
            }
            root["workspaceAliases"] = aliases
            try AppStorage.writeJSON(root, to: AppStorage.accountsURL, permissions: 0o600)
        }
    }

    static func updateDefaultOrder(_ profileKeys: [String]) throws {
        try CodexAuthFileLock.withLock {
            var root = accountsRoot()
            let profiles = root["profiles"] as? [String: Any] ?? [:]
            var seen = Set<String>()
            var ordered = profileKeys.filter { key in
                guard profiles[key] != nil, !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
            for key in profiles.keys.sorted() where !seen.contains(key) {
                ordered.append(key)
            }

            var order = root["order"] as? [String: Any] ?? [:]
            order["default"] = ordered
            root["order"] = order
            try AppStorage.writeJSON(root, to: AppStorage.accountsURL, permissions: 0o600)
        }
    }

    static func remove(profileKeys: Set<String>) throws {
        guard !profileKeys.isEmpty else { return }
        try CodexAuthFileLock.withLock {
            var root = accountsRoot()
            var profiles = root["profiles"] as? [String: Any] ?? [:]
            for key in profileKeys {
                profiles.removeValue(forKey: key)
                removeProfileKey(in: &root, key: key)
            }
            root["profiles"] = profiles
            try AppStorage.writeJSON(root, to: AppStorage.accountsURL, permissions: 0o600)
        }
    }

    private static func loadLocal() -> AccountProfileCollection? {
        guard let root = AppStorage.readJSON(AppStorage.accountsURL),
              let profiles = root["profiles"] as? [String: [String: Any]] else {
            return nil
        }
        return AccountProfileCollection(
            profiles: profiles,
            orderedKeys: orderedKeys(root: root, profiles: profiles),
            workspaceAliases: normalizedWorkspaceAliases(root["workspaceAliases"] as? [String: String] ?? [:])
        )
    }

    private static func accountsRoot() -> [String: Any] {
        AppStorage.readJSON(AppStorage.accountsURL) ?? ["version": 1, "profiles": [:], "order": ["default": []]]
    }

    private static func normalizedWorkspaceAliases(_ aliases: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (workspace, alias) in aliases {
            let key = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, let alias = Account.normalizedAlias(alias) else { continue }
            normalized[key] = alias
        }
        return normalized
    }

    private static func orderedKeys(root: [String: Any], profiles: [String: [String: Any]]) -> [String] {
        let orderMap = root["order"] as? [String: [String]] ?? [:]
        var ordered: [String] = []
        var seen = Set<String>()
        for keys in orderMap.values {
            for key in keys where profiles[key] != nil && !seen.contains(key) {
                seen.insert(key)
                ordered.append(key)
            }
        }
        for key in profiles.keys.sorted() where !seen.contains(key) {
            ordered.append(key)
        }
        return ordered
    }

    private static func appendToDefaultOrder(in root: inout [String: Any], key: String) {
        var order = root["order"] as? [String: Any] ?? [:]
        var keys = order["default"] as? [String] ?? []
        if !keys.contains(key) {
            keys.append(key)
        }
        order["default"] = keys
        root["order"] = order
    }

    private static func removeDuplicateProfiles(
        from profiles: inout [String: Any],
        root: inout [String: Any],
        keeping profileKey: String,
        email: String,
        accountID: String
    ) {
        guard !accountID.isEmpty else { return }
        let duplicates = profiles.compactMap { key, value -> String? in
            guard key != profileKey,
                  let entry = value as? [String: Any],
                  (entry["accountId"] as? String) == accountID,
                  (entry["email"] as? String)?.lowercased() == email else {
                return nil
            }
            return key
        }
        for key in duplicates {
            profiles.removeValue(forKey: key)
            removeProfileKey(in: &root, key: key)
        }
    }

    private static func replaceProfileKey(in root: inout [String: Any], from oldKey: String, to newKey: String) {
        guard var order = root["order"] as? [String: Any] else { return }
        for (group, value) in order {
            guard let keys = value as? [String] else { continue }
            var seen = Set<String>()
            var updated: [String] = []
            for key in keys {
                let next = key == oldKey ? newKey : key
                guard !seen.contains(next) else { continue }
                seen.insert(next)
                updated.append(next)
            }
            order[group] = updated
        }
        root["order"] = order
    }

    private static func removeProfileKey(in root: inout [String: Any], key: String) {
        guard var order = root["order"] as? [String: Any] else { return }
        for (group, value) in order {
            guard let keys = value as? [String] else { continue }
            order[group] = keys.filter { $0 != key }
        }
        root["order"] = order
    }

    private static func updateCapturedProfiles(
        profileKey: String,
        email: String,
        accountID: String,
        accessToken: String,
        refreshToken: String,
        idToken: String?,
        expiresAt: Int
    ) throws {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: AppStorage.profilesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for entryURL in entries {
            guard entryURL.lastPathComponent != "backups",
                  (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            let metaURL = entryURL.appendingPathComponent("meta.json")
            var meta = AppStorage.readJSON(metaURL) ?? [:]
            let sourceProfileKey = meta["source_profile_key"] as? String
            let metaEmail = (meta["email"] as? String)?.lowercased()
            let metaAccountID = meta["account_id"] as? String
            let matchesSource = sourceProfileKey == profileKey
            let matchesAccount = metaEmail == email.lowercased()
                && !accountID.isEmpty
                && metaAccountID == accountID
            guard matchesSource || matchesAccount else { continue }

            let authURL = entryURL.appendingPathComponent("auth.json")
            guard var auth = AppStorage.readJSON(authURL) else { continue }
            var tokens = auth["tokens"] as? [String: Any] ?? [:]
            tokens["access_token"] = accessToken
            tokens["refresh_token"] = refreshToken
            if let idToken, !idToken.isEmpty {
                tokens["id_token"] = idToken
            }
            if !accountID.isEmpty {
                tokens["account_id"] = accountID
            }
            auth["tokens"] = tokens
            try AppStorage.writeJSON(auth, to: authURL, permissions: 0o600)

            meta["expires_at"] = expiresAt
            try AppStorage.writeJSON(meta, to: metaURL, permissions: 0o600)
        }
    }
}
