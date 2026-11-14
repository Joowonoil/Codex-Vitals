import AppKit
import Foundation

actor GeminiAccountService {
    private let store: GeminiAccountStore
    private let credentials: any GeminiCredentialStoring
    private let client: any GeminiRemoteUsageProviding
    private let login: @Sendable () async throws -> Void
    private let sessionsRunning: @Sendable () -> Bool
    private struct RetryDelay {
        let until: Date
        let isServerLimit: Bool
    }

    private var backoff: [String: RetryDelay] = [:]
    private var credentialGeneration = 0

    init(
        store: GeminiAccountStore = GeminiAccountStore(),
        credentials: any GeminiCredentialStoring = GeminiCredentialStore(),
        client: any GeminiRemoteUsageProviding = GeminiRemoteUsageClient(),
        login: @escaping @Sendable () async throws -> Void = { try await GeminiCLIUsageClient().login() },
        sessionsRunning: @escaping @Sendable () -> Bool = { GeminiAccountService.hasRunningSessions() }
    ) {
        self.store = store
        self.credentials = credentials
        self.client = client
        self.login = login
        self.sessionsRunning = sessionsRunning
    }

    func loadAccounts(
        previousAccounts: [Account], previousFetchedAt: Date?,
        forceRefresh: Bool = false, now: Date = Date()
    ) async -> GeminiLoadResult {
        let generation = credentialGeneration
        var active: GeminiCredential?
        do {
            active = try credentials.active()
            if let active { _ = try capture(active, unhide: false) }
        } catch {}
        let profiles: [GeminiProfile]
        do { profiles = try store.load().filter { !$0.isHidden } }
        catch { return GeminiLoadResult(accounts: [], errorMessage: "Could not read saved Gemini accounts.") }
        var accounts: [Account] = []
        for start in stride(from: 0, to: profiles.count, by: 4) {
            await withTaskGroup(of: Account.self) { group in
                for profile in profiles[start..<min(start + 4, profiles.count)] {
                    let credential = active
                    group.addTask { [self] in
                        await loadAccount(
                            profile, active: credential, previousAccounts: previousAccounts,
                            previousFetchedAt: previousFetchedAt, now: now, generation: generation,
                            forceRefresh: forceRefresh
                        )
                    }
                }
                for await account in group { accounts.append(account) }
            }
        }
        // Re-read edits made while network requests were in flight, including ordering and hidden rows.
        let latest = (try? store.load()) ?? profiles
        let ordered = latest.filter { !$0.isHidden }.compactMap { profile -> Account? in
            guard var account = accounts.first(where: { $0.providerProfileID == profile.id }) else { return nil }
            account.alias = profile.alias
            account.workspaceAlias = profile.workspaceAlias
            account.planRenewalDate = profile.planRenewalDate
            return account
        }
        return GeminiLoadResult(accounts: ordered, errorMessage: nil)
    }

    private func loadAccount(
        _ profile: GeminiProfile, active: GeminiCredential?, previousAccounts: [Account],
        previousFetchedAt: Date?, now: Date, generation: Int, forceRefresh: Bool
    ) async -> Account {
        let isActive = active?.email == profile.email
        let previous = previousAccounts.first { $0.isGeminiAccount && $0.providerProfileID == profile.id }
        if let retry = backoff[profile.id], now < retry.until, !forceRefresh || retry.isServerLimit {
            return cached(profile, previous: previous, fetchedAt: previousFetchedAt, now: now, active: isActive)
        }
        do {
            guard let credential = isActive ? active : try credentials.saved(profileID: profile.id),
                  credential.email == profile.email else { throw GeminiUsageError.reloginRequired }
            let result = try await client.fetch(profile: profile, credential: credential)
            guard generation == credentialGeneration else {
                return cached(profile, previous: previous, fetchedAt: previousFetchedAt, now: Date(), active: false)
            }
            // Never overwrite a newer credential written by agy while the request was in flight.
            if result.credential.rawValue != credential.rawValue {
                if isActive, try credentials.active()?.rawValue == credential.rawValue {
                    try credentials.writeActive(result.credential)
                }
                try credentials.save(result.credential, profileID: profile.id)
            }
            backoff[profile.id] = nil
            var account = result.account
            account.providerIsActive = try credentials.active()?.email == profile.email
            let plan = account.plan == "Gemini" ? profile.plan : account.plan
            if profile.plan != plan { try updateProfile(profile.id) { $0.plan = plan } }
            return account
        } catch {
            let status: String
            if case GeminiUsageError.reloginRequired = error {
                status = "reloginRequired"
            } else {
                status = previous == nil ? "unavailable" : "cached"
                let delay: TimeInterval
                let isServerLimit: Bool
                if case let GeminiUsageError.rateLimited(retryAfter) = error {
                    delay = max(300, retryAfter)
                    isServerLimit = true
                } else {
                    delay = 300
                    isServerLimit = false
                }
                backoff[profile.id] = RetryDelay(until: now.addingTimeInterval(delay), isServerLimit: isServerLimit)
            }
            var account = cached(profile, previous: previous, fetchedAt: previousFetchedAt, now: now, active: isActive)
            account.providerStatus = status
            if status == "reloginRequired" || previous == nil {
                account = empty(profile, active: isActive, status: status)
            }
            return account
        }
    }

    @discardableResult
    func addAccount(expectedProfileID: String? = nil) async throws -> GeminiProfile {
        guard !sessionsRunning() else { throw GeminiUsageError.sessionsRunning }
        if let active = try? credentials.active() { _ = try capture(active, unhide: false) }
        try await login()
        try Task.checkCancellation()
        guard let active = try credentials.active() else { throw GeminiUsageError.reloginRequired }
        let profile = try capture(active, unhide: true)
        credentialGeneration += 1
        backoff[profile.id] = nil
        if let expectedProfileID, expectedProfileID != profile.id { throw GeminiUsageError.identityChanged }
        return profile
    }

    func switchAccount(profileID: String) throws {
        guard let target = try store.load().first(where: { $0.id == profileID }),
              let targetCredential = try credentials.saved(profileID: profileID),
              targetCredential.email == target.email else { throw GeminiUsageError.profileMissing }
        let original = try credentials.active()
        if original?.email == target.email { return }
        guard !sessionsRunning() else { throw GeminiUsageError.sessionsRunning }
        if let original { _ = try capture(original, unhide: false) }
        credentialGeneration += 1
        do {
            try credentials.writeActive(targetCredential)
            guard try credentials.active()?.rawValue == targetCredential.rawValue else {
                throw GeminiUsageError.identityChanged
            }
            backoff[profileID] = nil
        } catch {
            do {
                if let original {
                    try credentials.writeActive(original)
                    guard try credentials.active()?.rawValue == original.rawValue else {
                        throw GeminiUsageError.rollbackFailed
                    }
                } else {
                    try credentials.removeActive()
                    guard try credentials.active() == nil else { throw GeminiUsageError.rollbackFailed }
                }
            } catch { throw GeminiUsageError.rollbackFailed }
            throw GeminiUsageError.switchFailed
        }
    }

    func updateAlias(profileID: String, alias: String?) throws {
        try updateProfile(profileID) { $0.alias = Account.normalizedAlias(alias) }
    }

    func updateWorkspaceAlias(workspace: String, alias: String?) throws {
        try store.update { profiles in
            for index in profiles.indices where profiles[index].workspace == workspace {
                profiles[index].workspaceAlias = Account.normalizedAlias(alias)
            }
        }
    }

    func updatePlanRenewalDate(profileID: String, date: Date?) throws {
        try updateProfile(profileID) { $0.planRenewalDate = date }
    }

    func updateOrder(profileIDs: [String]) throws {
        try store.update { profiles in
            var positions: [String: Int] = [:]
            for (index, id) in profileIDs.enumerated() where positions[id] == nil { positions[id] = index }
            profiles = profiles.enumerated().sorted {
                (positions[$0.element.id] ?? profileIDs.count + $0.offset)
                    < (positions[$1.element.id] ?? profileIDs.count + $1.offset)
            }.map(\.element)
        }
    }

    func removeAccount(profileID: String) throws {
        guard let profile = try store.load().first(where: { $0.id == profileID }) else {
            throw GeminiUsageError.profileMissing
        }
        if try credentials.active()?.email == profile.email {
            try updateProfile(profileID) { $0.isHidden = true }
        } else {
            let original = try credentials.saved(profileID: profileID)
            do {
                try credentials.delete(profileID: profileID)
                try store.update { $0.removeAll { $0.id == profileID } }
            } catch {
                if let original { try? credentials.save(original, profileID: profileID) }
                throw error
            }
        }
        backoff[profileID] = nil
    }

    @discardableResult
    private func capture(_ credential: GeminiCredential, unhide: Bool) throws -> GeminiProfile {
        let identity = GeminiProfile(email: credential.email)
        if try credentials.saved(profileID: identity.id)?.rawValue != credential.rawValue {
            try credentials.save(credential, profileID: identity.id)
        }
        var result = identity
        try store.update { profiles in
            if let index = profiles.firstIndex(where: { $0.id == identity.id }) {
                if unhide { profiles[index].isHidden = false }
                result = profiles[index]
            } else {
                profiles.append(identity)
            }
        }
        return result
    }

    private func updateProfile(_ id: String, _ update: (inout GeminiProfile) -> Void) throws {
        try store.update { profiles in
            guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw GeminiUsageError.profileMissing }
            update(&profiles[index])
        }
    }

    private func cached(
        _ profile: GeminiProfile, previous: Account?, fetchedAt: Date?, now: Date, active: Bool
    ) -> Account {
        guard let previous else { return empty(profile, active: active, status: "unavailable") }
        var account = previous.rebased(to: now, fallbackReference: fetchedAt)
        account.providerIsActive = active
        account.providerStatus = "cached"
        account.alias = profile.alias
        account.workspaceAlias = profile.workspaceAlias
        account.planRenewalDate = profile.planRenewalDate
        return account
    }

    private func empty(_ profile: GeminiProfile, active: Bool, status: String) -> Account {
        Account(
            id: "gemini:\(profile.id)", profileKey: nil, email: profile.email, alias: profile.alias,
            workspace: profile.workspace, workspaceAlias: profile.workspaceAlias, plan: profile.plan ?? "Gemini",
            sessionFree: 0, weeklyFree: 0, sessionResetSeconds: 0, weeklyResetSeconds: 0,
            quotaWindows: [], planRenewalDate: profile.planRenewalDate, hasError: true,
            errorMessage: status == "reloginRequired" ? GeminiUsageError.reloginRequired.localizedDescription : GeminiUsageError.unavailable.localizedDescription,
            provider: .gemini, providerProfileID: profile.id, providerIsActive: active, providerStatus: status
        )
    }

    private static func hasRunningSessions() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "agy"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return true }
        return process.terminationStatus == 0 || NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier?.lowercased().contains("antigravity") == true
        }
    }
}
