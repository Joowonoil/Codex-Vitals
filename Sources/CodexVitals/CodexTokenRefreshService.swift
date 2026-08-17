import CryptoKit
import Foundation

enum CodexOAuthConfiguration {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
}

struct CodexUsageCredential {
    let accessToken: String
    let didRefresh: Bool
}

enum CodexUsageCredentialResult {
    case ready(CodexUsageCredential)
    case unavailable(String)
}

struct CodexTokenRefreshHTTPResponse {
    let statusCode: Int
    let data: Data
    let retryAfter: TimeInterval?
}

protocol CodexTokenRefreshTransport {
    func refresh(refreshToken: String) async throws -> CodexTokenRefreshHTTPResponse
}

final class URLSessionCodexTokenRefreshTransport: CodexTokenRefreshTransport, @unchecked Sendable {
    private let session: URLSession
    private let tokenURL: URL
    private let clientID: String

    init(
        session: URLSession = .shared,
        tokenURL: URL = CodexOAuthConfiguration.tokenURL,
        clientID: String = CodexOAuthConfiguration.clientID
    ) {
        self.session = session
        self.tokenURL = tokenURL
        self.clientID = clientID
    }

    func refresh(refreshToken: String) async throws -> CodexTokenRefreshHTTPResponse {
        var request = URLRequest(url: tokenURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])

        let (data, response) = try await session.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        return CodexTokenRefreshHTTPResponse(
            statusCode: httpResponse?.statusCode ?? 0,
            data: data,
            retryAfter: Self.retryAfter(from: httpResponse)
        )
    }

    private static func retryAfter(from response: HTTPURLResponse?) -> TimeInterval? {
        guard let raw = response?.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        if let seconds = TimeInterval(raw), seconds >= 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}

fileprivate struct CodexCanonicalCredential {
    let profileKey: String
    let profile: [String: Any]
    let record: CapturedProfileRecord
    let auth: StoredCodexAuth
    let revision: String
}

fileprivate struct CodexRefreshFailureState {
    enum Kind: String {
        case transient
        case permanent
    }

    let authRevision: String
    let kind: Kind
    let failureCount: Int
    let errorCode: String
    let nextRetryAt: Date?
}

fileprivate enum CodexCanonicalCredentialStoreError: Error {
    case profileChanged
    case becameActive
}

final class CodexCanonicalCredentialStore: @unchecked Sendable {
    private let profileStoreURL: URL
    private let accountsURL: URL
    private let liveAuthURL: URL

    init(
        profileStoreURL: URL = AppStorage.profilesURL,
        accountsURL: URL = AppStorage.accountsURL,
        liveAuthURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    ) {
        self.profileStoreURL = profileStoreURL
        self.accountsURL = accountsURL
        self.liveAuthURL = liveAuthURL
    }

    func hydrate(_ collection: AccountProfileCollection) -> AccountProfileCollection {
        let records = CapturedProfileDedupeService.records(profileStoreURL: profileStoreURL)
        var profiles = collection.profiles

        for profileKey in collection.orderedKeys {
            guard var profile = profiles[profileKey],
                  let credential = credential(
                    profileKey: profileKey,
                    profile: profile,
                    records: records
                  ) else {
                continue
            }

            profile["access"] = credential.auth.accessToken
            profile["refresh"] = credential.auth.refreshToken
            profile["expires"] = credential.auth.accessExpiresAt
            if !credential.auth.email.isEmpty {
                profile["email"] = credential.auth.email
            }
            if !credential.auth.accountID.isEmpty {
                profile["accountId"] = credential.auth.accountID
            }
            profiles[profileKey] = profile
        }

        return AccountProfileCollection(
            profiles: profiles,
            orderedKeys: collection.orderedKeys,
            workspaceAliases: collection.workspaceAliases
        )
    }

    fileprivate func credential(
        profileKey: String,
        profile: [String: Any]
    ) -> CodexCanonicalCredential? {
        credential(
            profileKey: profileKey,
            profile: profile,
            records: CapturedProfileDedupeService.records(profileStoreURL: profileStoreURL)
        )
    }

    fileprivate func activeAuth(for credential: CodexCanonicalCredential) -> StoredCodexAuth? {
        guard let liveAuth = StoredCodexAuth.load(from: liveAuthURL),
              credential.auth.matchesIdentity(of: liveAuth) else {
            return nil
        }
        return liveAuth
    }

    fileprivate func failureState(for credential: CodexCanonicalCredential) -> CodexRefreshFailureState? {
        guard let meta = AppStorage.readJSON(credential.record.metaURL),
              let refresh = meta["token_refresh"] as? [String: Any],
              let revision = refresh["auth_revision"] as? String,
              revision == credential.revision,
              let rawKind = refresh["status"] as? String,
              let kind = CodexRefreshFailureState.Kind(rawValue: rawKind) else {
            return nil
        }

        return CodexRefreshFailureState(
            authRevision: revision,
            kind: kind,
            failureCount: refresh["failure_count"] as? Int ?? 0,
            errorCode: refresh["error_code"] as? String ?? "unknown",
            nextRetryAt: Self.parseISO8601(refresh["next_retry_at"] as? String)
        )
    }

    fileprivate func recordFailure(
        for credential: CodexCanonicalCredential,
        kind: CodexRefreshFailureState.Kind,
        failureCount: Int,
        errorCode: String,
        nextRetryAt: Date?
    ) {
        try? CodexAuthFileLock.withLock {
            guard let current = self.credential(
                profileKey: credential.profileKey,
                profile: credential.profile
            ), current.revision == credential.revision else {
                return
            }

            var meta = AppStorage.readJSON(current.record.metaURL) ?? [:]
            var refresh: [String: Any] = [
                "auth_revision": current.revision,
                "status": kind.rawValue,
                "failure_count": max(1, failureCount),
                "error_code": errorCode,
            ]
            if let nextRetryAt {
                refresh["next_retry_at"] = ISO8601DateFormatter.codexVitals.string(from: nextRetryAt)
            }
            meta["token_refresh"] = refresh
            try AppStorage.writeJSON(meta, to: current.record.metaURL, permissions: 0o600)
        }
    }

    fileprivate func persist(
        root: [String: Any],
        expected credential: CodexCanonicalCredential
    ) throws -> CodexCanonicalCredential {
        try CodexAuthFileLock.withLock {
            guard let current = self.credential(
                profileKey: credential.profileKey,
                profile: credential.profile
            ), current.record.profileURL.standardizedFileURL == credential.record.profileURL.standardizedFileURL,
               current.revision == credential.revision else {
                throw CodexCanonicalCredentialStoreError.profileChanged
            }

            if activeAuth(for: current) != nil {
                throw CodexCanonicalCredentialStoreError.becameActive
            }

            // The captured auth is the credential source of truth. Derived files are repaired after it.
            try AppStorage.writeJSON(root, to: current.record.authURL, permissions: 0o600)
            guard let updated = self.credential(
                profileKey: current.profileKey,
                profile: current.profile
            ) else {
                throw CodexCanonicalCredentialStoreError.profileChanged
            }

            repairDerivedFilesBestEffort(using: updated)
            return updated
        }
    }

    private func credential(
        profileKey: String,
        profile: [String: Any],
        records: [CapturedProfileRecord]
    ) -> CodexCanonicalCredential? {
        guard let record = canonicalRecord(
            profileKey: profileKey,
            profile: profile,
            records: records
        ), let data = try? Data(contentsOf: record.authURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let auth = StoredCodexAuth.parse(root: root) else {
            return nil
        }

        return CodexCanonicalCredential(
            profileKey: profileKey,
            profile: profile,
            record: record,
            auth: auth,
            revision: Self.sha256(data)
        )
    }

    private func canonicalRecord(
        profileKey: String,
        profile: [String: Any],
        records: [CapturedProfileRecord]
    ) -> CapturedProfileRecord? {
        let sourceMatches = records.filter { $0.sourceProfileKey == profileKey }
        if let newest = sourceMatches.max(by: { $0.freshnessDate < $1.freshnessDate }) {
            return newest
        }

        let email = (profile["email"] as? String)?.lowercased() ?? ""
        let accountID = profile["accountId"] as? String ?? ""
        let identityMatches = records.filter { record in
            record.email == email
                && !accountID.isEmpty
                && record.accountID == accountID
        }
        return identityMatches.max(by: { $0.freshnessDate < $1.freshnessDate })
    }

    private func repairDerivedFilesBestEffort(using credential: CodexCanonicalCredential) {
        var meta = AppStorage.readJSON(credential.record.metaURL) ?? [:]
        meta["email"] = credential.auth.email
        if !credential.auth.accountID.isEmpty {
            meta["account_id"] = credential.auth.accountID
        }
        meta["expires_at"] = credential.auth.accessExpiresAt
        meta.removeValue(forKey: "token_refresh")
        try? AppStorage.writeJSON(meta, to: credential.record.metaURL, permissions: 0o600)

        guard var root = AppStorage.readJSON(accountsURL),
              var profiles = root["profiles"] as? [String: Any],
              var entry = profiles[credential.profileKey] as? [String: Any] else {
            return
        }
        entry["access"] = credential.auth.accessToken
        entry["refresh"] = credential.auth.refreshToken
        entry["expires"] = credential.auth.accessExpiresAt
        profiles[credential.profileKey] = entry
        root["profiles"] = profiles
        try? AppStorage.writeJSON(root, to: accountsURL, permissions: 0o600)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}

final class CodexTokenRefreshService: @unchecked Sendable {
    static let proactiveWindow: TimeInterval = 5 * 60
    static let fallbackRefreshAge: TimeInterval = 8 * 24 * 60 * 60
    static let temporaryFailureMessage = "Token refresh temporarily unavailable"
    static let reloginRequiredMessage = "Refresh failed - re-login required"

    private static let backoffSchedule: [TimeInterval] = [60, 5 * 60, 15 * 60, 60 * 60]
    private static let permanentEndpointCodes: Set<String> = [
        "invalid_grant",
        "refresh_token_expired",
        "refresh_token_invalidated",
        "refresh_token_reused",
    ]

    private let transport: CodexTokenRefreshTransport
    private let credentialStore: CodexCanonicalCredentialStore
    private let profileGate: CodexProfileOperationGate
    private let permitPool: CodexRefreshPermitPool
    private let now: () -> Date

    init(
        transport: CodexTokenRefreshTransport = URLSessionCodexTokenRefreshTransport(),
        credentialStore: CodexCanonicalCredentialStore = CodexCanonicalCredentialStore(),
        profileGate: CodexProfileOperationGate = .shared,
        permitPool: CodexRefreshPermitPool = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.credentialStore = credentialStore
        self.profileGate = profileGate
        self.permitPool = permitPool
        self.now = now
    }

    func credentialForUsage(
        profileKey: String,
        profile: [String: Any],
        forceRefresh: Bool = false
    ) async -> CodexUsageCredentialResult {
        guard let initial = credentialStore.credential(profileKey: profileKey, profile: profile) else {
            return .unavailable(Self.reloginRequiredMessage)
        }

        if let liveAuth = credentialStore.activeAuth(for: initial) {
            return .ready(CodexUsageCredential(accessToken: liveAuth.accessToken, didRefresh: false))
        }

        if let blocked = blockedResult(
            for: initial,
            at: now(),
            allowExistingAccessToken: !forceRefresh
        ) {
            return blocked
        }

        guard forceRefresh || Self.shouldRefresh(initial.auth, at: now()) else {
            return .ready(CodexUsageCredential(accessToken: initial.auth.accessToken, didRefresh: false))
        }

        do {
            return try await permitPool.withPermit {
                try await self.profileGate.withExclusiveAccess(for: profileKey) {
                    try await self.refreshWithinGate(
                        profileKey: profileKey,
                        profile: profile,
                        forceRefresh: forceRefresh
                    )
                }
            }
        } catch is CancellationError {
            return .unavailable(Self.temporaryFailureMessage)
        } catch {
            return .unavailable(Self.temporaryFailureMessage)
        }
    }

    static func shouldRefresh(_ auth: StoredCodexAuth, at now: Date) -> Bool {
        if auth.accessExpiresAt > 0 {
            let expiresAt = Date(timeIntervalSince1970: TimeInterval(auth.accessExpiresAt) / 1000)
            return expiresAt <= now.addingTimeInterval(proactiveWindow)
        }

        guard let lastRefresh = auth.lastRefreshDate else { return false }
        return lastRefresh <= now.addingTimeInterval(-fallbackRefreshAge)
    }

    private func refreshWithinGate(
        profileKey: String,
        profile: [String: Any],
        forceRefresh: Bool
    ) async throws -> CodexUsageCredentialResult {
        guard let current = credentialStore.credential(profileKey: profileKey, profile: profile) else {
            return .unavailable(Self.reloginRequiredMessage)
        }

        if let liveAuth = credentialStore.activeAuth(for: current) {
            return .ready(CodexUsageCredential(accessToken: liveAuth.accessToken, didRefresh: false))
        }

        let currentDate = now()
        if let blocked = blockedResult(
            for: current,
            at: currentDate,
            allowExistingAccessToken: !forceRefresh
        ) {
            return blocked
        }
        guard forceRefresh || Self.shouldRefresh(current.auth, at: currentDate) else {
            return .ready(CodexUsageCredential(accessToken: current.auth.accessToken, didRefresh: false))
        }

        let response: CodexTokenRefreshHTTPResponse
        do {
            response = try await transport.refresh(refreshToken: current.auth.refreshToken)
        } catch {
            return recordTransientFailure(
                for: current,
                code: "transport_error",
                retryAfter: nil,
                allowExistingAccessToken: !forceRefresh
            )
        }

        guard (200...299).contains(response.statusCode) else {
            let code = Self.endpointErrorCode(from: response.data, statusCode: response.statusCode)
            if Self.isPermanentFailure(code: code, statusCode: response.statusCode) {
                credentialStore.recordFailure(
                    for: current,
                    kind: .permanent,
                    failureCount: 1,
                    errorCode: code,
                    nextRetryAt: nil
                )
                return .unavailable(Self.reloginRequiredMessage)
            }
            return recordTransientFailure(
                for: current,
                code: code,
                retryAfter: response.retryAfter,
                allowExistingAccessToken: !forceRefresh
            )
        }

        guard let tokenResponse = try? JSONDecoder().decode(RefreshTokenResponse.self, from: response.data),
              let accessToken = tokenResponse.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            return recordPermanentFailure(for: current, code: "invalid_refresh_response")
        }

        let refreshedAt = now()
        var root = current.auth.root
        var tokens = root["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = accessToken
        if let refreshToken = tokenResponse.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !refreshToken.isEmpty {
            tokens["refresh_token"] = refreshToken
        }
        if let idToken = tokenResponse.idToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !idToken.isEmpty {
            tokens["id_token"] = idToken
        }
        root["tokens"] = tokens
        root["last_refresh"] = ISO8601DateFormatter.codexVitals.string(from: refreshedAt)

        guard let refreshedAuth = StoredCodexAuth.parse(root: root),
              current.auth.matchesIdentity(of: refreshedAuth),
              refreshedAuth.accessExpiresAt > Int(refreshedAt.addingTimeInterval(60).timeIntervalSince1970 * 1000) else {
            return recordPermanentFailure(for: current, code: "refresh_identity_mismatch")
        }

        do {
            let persisted = try credentialStore.persist(root: root, expected: current)
            return .ready(CodexUsageCredential(accessToken: persisted.auth.accessToken, didRefresh: true))
        } catch CodexCanonicalCredentialStoreError.becameActive {
            guard let latest = credentialStore.credential(profileKey: profileKey, profile: profile),
                  let liveAuth = credentialStore.activeAuth(for: latest) else {
                return .unavailable(Self.temporaryFailureMessage)
            }
            return .ready(CodexUsageCredential(accessToken: liveAuth.accessToken, didRefresh: true))
        } catch CodexCanonicalCredentialStoreError.profileChanged {
            guard let latest = credentialStore.credential(profileKey: profileKey, profile: profile) else {
                return .unavailable(Self.reloginRequiredMessage)
            }
            if latest.revision != current.revision {
                return .ready(CodexUsageCredential(accessToken: latest.auth.accessToken, didRefresh: true))
            }
            return recordPermanentFailure(for: current, code: "local_persistence_failed")
        } catch {
            return recordPermanentFailure(for: current, code: "local_persistence_failed")
        }
    }

    private func blockedResult(
        for credential: CodexCanonicalCredential,
        at date: Date,
        allowExistingAccessToken: Bool
    ) -> CodexUsageCredentialResult? {
        guard let state = credentialStore.failureState(for: credential) else { return nil }
        switch state.kind {
        case .permanent:
            return .unavailable(Self.reloginRequiredMessage)
        case .transient:
            guard let nextRetryAt = state.nextRetryAt, nextRetryAt > date else { return nil }
            if allowExistingAccessToken,
               Self.isAccessTokenUsable(credential.auth, at: date) {
                return .ready(CodexUsageCredential(accessToken: credential.auth.accessToken, didRefresh: false))
            }
            return .unavailable(Self.temporaryFailureMessage)
        }
    }

    private func recordTransientFailure(
        for credential: CodexCanonicalCredential,
        code: String,
        retryAfter: TimeInterval?,
        allowExistingAccessToken: Bool
    ) -> CodexUsageCredentialResult {
        let previousCount = credentialStore.failureState(for: credential)?.failureCount ?? 0
        let failureCount = previousCount + 1
        let scheduleIndex = min(failureCount - 1, Self.backoffSchedule.count - 1)
        let delay = max(Self.backoffSchedule[scheduleIndex], retryAfter ?? 0)
        let currentDate = now()
        credentialStore.recordFailure(
            for: credential,
            kind: .transient,
            failureCount: failureCount,
            errorCode: code,
            nextRetryAt: currentDate.addingTimeInterval(delay)
        )

        if allowExistingAccessToken,
           Self.isAccessTokenUsable(credential.auth, at: currentDate) {
            return .ready(CodexUsageCredential(accessToken: credential.auth.accessToken, didRefresh: false))
        }
        return .unavailable(Self.temporaryFailureMessage)
    }

    private func recordPermanentFailure(
        for credential: CodexCanonicalCredential,
        code: String
    ) -> CodexUsageCredentialResult {
        credentialStore.recordFailure(
            for: credential,
            kind: .permanent,
            failureCount: 1,
            errorCode: code,
            nextRetryAt: nil
        )
        return .unavailable(Self.reloginRequiredMessage)
    }

    private static func isAccessTokenUsable(_ auth: StoredCodexAuth, at date: Date) -> Bool {
        guard auth.accessExpiresAt > 0 else { return false }
        return auth.accessExpiresAt > Int(date.timeIntervalSince1970 * 1000)
    }

    private static func isPermanentFailure(code: String, statusCode: Int) -> Bool {
        permanentEndpointCodes.contains(code)
            || ((400...499).contains(statusCode) && statusCode != 429)
    }

    private static func endpointErrorCode(from data: Data, statusCode: Int) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "http_\(statusCode)"
        }

        let candidates: [String?] = [
            root["code"] as? String,
            (root["error"] as? [String: Any])?["code"] as? String,
            root["error"] as? String,
            (root["detail"] as? [String: Any])?["code"] as? String,
        ]
        let raw = candidates.compactMap { $0 }.first ?? "http_\(statusCode)"
        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}

private struct RefreshTokenResponse: Decodable {
    let idToken: String?
    let accessToken: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}
