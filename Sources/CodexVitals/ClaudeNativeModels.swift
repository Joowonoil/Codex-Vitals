import Foundation

enum ClaudeAccountStatus: String, Equatable {
    case ok
    case cached
    case tokenExpired = "token_expired"
    case reloginRequired = "relogin_required"
    case noCredentials = "no_credentials"
    case keychainUnavailable = "keychain_unavailable"
    case unavailable

    var errorMessage: String? {
        switch self {
        case .ok, .cached:
            return nil
        case .tokenExpired:
            return "Claude access token expired."
        case .reloginRequired:
            return "Claude re-login required."
        case .noCredentials:
            return "Claude credentials are missing."
        case .keychainUnavailable:
            return "Claude Keychain is unavailable."
        case .unavailable:
            return "Claude usage unavailable."
        }
    }
}

struct ClaudeNativeProfile: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let email: String
    let accountUUID: String?
    let organizationUUID: String?
    let organizationName: String?
    var alias: String?
    var workspaceAlias: String?
    var planRenewalDate: Date?
    var isHidden: Bool?
    var oauthAccountJSON: String
    let createdAt: Date
    var updatedAt: Date

    var displayName: String {
        Account.normalizedAlias(alias) ?? email
    }

    var workspaceName: String {
        Account.normalizedAlias(organizationName) ?? "Claude"
    }

    var displayWorkspaceName: String {
        Account.normalizedAlias(workspaceAlias) ?? workspaceName
    }

    var isVisible: Bool {
        isHidden != true
    }

    var oauthAccount: [String: Any]? {
        guard let data = oauthAccountJSON.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    var planDisplayName: String? {
        oauthAccount.flatMap(ClaudePlanFormatter.displayName)
    }

    func matches(oauthAccount: [String: Any]) -> Bool {
        let identity = ClaudeIdentity(oauthAccount: oauthAccount)
        if let accountUUID, let other = identity.accountUUID {
            return accountUUID == other
        }
        return email.caseInsensitiveCompare(identity.email) == .orderedSame
            && organizationUUID == identity.organizationUUID
    }
}

enum ClaudePlanFormatter {
    static func displayName(from metadata: [String: Any]) -> String? {
        let values = [
            string(metadata["seatTier"]),
            string(metadata["organizationType"]),
            string(metadata["userRateLimitTier"]),
            string(metadata["organizationRateLimitTier"]),
        ].compactMap { $0 }
        let normalized = values.joined(separator: " ").lowercased()

        if normalized.contains("max") {
            if normalized.contains("20x") { return "Max 20x" }
            if normalized.contains("5x") { return "Max 5x" }
            return "Max"
        }
        if normalized.contains("enterprise") { return "Enterprise" }
        if normalized.contains("team") { return "Team" }
        if normalized.contains("pro") { return "Pro" }
        if normalized.contains("free") { return "Free" }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ClaudeIdentity: Equatable, Sendable {
    let email: String
    let accountUUID: String?
    let organizationUUID: String?
    let organizationName: String?

    init(oauthAccount: [String: Any]) {
        email = Self.string(oauthAccount["emailAddress"])
            ?? Self.string(oauthAccount["email"])
            ?? ""
        accountUUID = Self.string(oauthAccount["accountUuid"])
            ?? Self.string(oauthAccount["accountUUID"])
        organizationUUID = Self.string(oauthAccount["organizationUuid"])
            ?? Self.string(oauthAccount["organizationUUID"])
        organizationName = Self.string(oauthAccount["organizationName"])
    }

    var profileID: String {
        if let accountUUID { return accountUUID }
        let org = organizationUUID ?? "personal"
        return "\(email.lowercased())|\(org)"
    }

    var isValid: Bool {
        !email.isEmpty && (accountUUID != nil || organizationUUID != nil)
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ClaudeCredentialEnvelope: Equatable, @unchecked Sendable {
    let rawValue: String
    let root: [String: Any]
    let oauth: [String: Any]

    init(rawValue: String) throws {
        guard let data = rawValue.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              Self.nonEmptyString(oauth["accessToken"]) != nil else {
            throw ClaudeNativeError.invalidCredentials
        }
        self.rawValue = rawValue
        self.root = root
        self.oauth = oauth
    }

    var accessToken: String { Self.nonEmptyString(oauth["accessToken"]) ?? "" }
    var refreshToken: String? { Self.nonEmptyString(oauth["refreshToken"]) }
    var expiresAtMilliseconds: Double? { (oauth["expiresAt"] as? NSNumber)?.doubleValue }

    var isExpiring: Bool {
        guard let expiresAtMilliseconds else { return false }
        return Date().timeIntervalSince1970 * 1000 + 5 * 60 * 1000 >= expiresAtMilliseconds
    }

    func replacingOAuth(with response: ClaudeTokenResponse) throws -> String {
        var updatedRoot = root
        var updatedOAuth = oauth
        updatedOAuth["accessToken"] = response.accessToken
        updatedOAuth["expiresAt"] = Date().timeIntervalSince1970 * 1000
            + Double(response.expiresIn) * 1000
        if let refreshToken = response.refreshToken, !refreshToken.isEmpty {
            updatedOAuth["refreshToken"] = refreshToken
        }
        if let scope = response.scope, !scope.isEmpty {
            updatedOAuth["scopes"] = scope.split(separator: " ").map(String.init)
        }
        updatedRoot["claudeAiOauth"] = updatedOAuth
        let data = try JSONSerialization.data(withJSONObject: updatedRoot, options: [.sortedKeys])
        guard let value = String(data: data, encoding: .utf8) else {
            throw ClaudeNativeError.invalidCredentials
        }
        return value
    }

    func mergingLiveSharedFields(from live: ClaudeCredentialEnvelope?) throws -> String {
        guard let live else { return rawValue }
        let sharedKeys: Set<String> = [
            "mcpOAuth", "mcpOAuthClientConfig", "mcpXaaIdp",
            "mcpXaaIdpConfig", "pluginSecrets",
        ]
        var composed = root.filter { !sharedKeys.contains($0.key) }
        for key in sharedKeys where live.root.keys.contains(key) {
            composed[key] = live.root[key]
        }
        let data = try JSONSerialization.data(withJSONObject: composed, options: [.sortedKeys])
        guard let value = String(data: data, encoding: .utf8) else {
            throw ClaudeNativeError.invalidCredentials
        }
        return value
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func == (lhs: ClaudeCredentialEnvelope, rhs: ClaudeCredentialEnvelope) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

struct ClaudeTokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let scope: String?
    let account: AccountIdentity?

    struct AccountIdentity: Decodable, Sendable {
        let uuid: String?
        let emailAddress: String?

        enum CodingKeys: String, CodingKey {
            case uuid
            case emailAddress = "email_address"
        }
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case account
    }
}

struct ClaudeUsageResponse: Decodable, Sendable {
    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOverageIncluded: Window?
    let limits: [Limit]?

    struct Window: Decodable, Sendable {
        let utilization: Double
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    struct Limit: Decodable, Sendable {
        let kind: String?
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?

        struct Scope: Decodable, Sendable {
            let model: Model?

            struct Model: Decodable, Sendable {
                let displayName: String?

                enum CodingKeys: String, CodingKey {
                    case displayName = "display_name"
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case kind
            case percent
            case resetsAt = "resets_at"
            case scope
        }
    }

    var fable: Window? {
        if let limit = limits?.first(where: { limit in
            limit.kind == "weekly_scoped"
                && limit.scope?.model?.displayName?.localizedCaseInsensitiveContains("fable") == true
                && limit.percent != nil
        }), let percent = limit.percent {
            return Window(utilization: percent, resetsAt: limit.resetsAt)
        }
        return sevenDayOverageIncluded
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOverageIncluded = "seven_day_overage_included"
        case limits
    }
}

enum ClaudeNativeError: LocalizedError, Equatable, Sendable {
    case claudeCLIUnavailable
    case keychainUnavailable(String)
    case keychainValueTooLarge
    case invalidCredentials
    case invalidAccountMetadata
    case profileMissing
    case activeAccountRemoval
    case loginFailed(Int)
    case loginCanceled
    case loginTimedOut
    case wrongAccount(expected: String, actual: String)
    case refreshRejected
    case rateLimited(retryAfter: TimeInterval?)
    case networkUnavailable
    case serviceUnavailable(Int)
    case switchVerificationFailed

    var errorDescription: String? {
        switch self {
        case .claudeCLIUnavailable:
            return "Claude Code is not installed."
        case let .keychainUnavailable(message):
            return "Claude Keychain unavailable: \(message)"
        case .keychainValueTooLarge:
            return "Claude credentials are too large for secure Keychain transfer."
        case .invalidCredentials:
            return "Claude credentials are invalid."
        case .invalidAccountMetadata:
            return "Claude account metadata is unavailable."
        case .profileMissing:
            return "Claude account profile is missing."
        case .activeAccountRemoval:
            return "Switch to another Claude account before removing the active account."
        case let .loginFailed(status):
            return "Claude login failed (\(status))."
        case .loginCanceled:
            return "Claude login canceled."
        case .loginTimedOut:
            return "Claude login timed out."
        case let .wrongAccount(expected, actual):
            return "Expected \(expected), but Claude signed in as \(actual). The signed-in account was added separately."
        case .refreshRejected:
            return "Claude refresh token was rejected; re-login required."
        case .rateLimited:
            return "Claude usage refresh is temporarily rate limited."
        case .networkUnavailable:
            return "Claude usage service is temporarily unavailable."
        case let .serviceUnavailable(status):
            return "Claude usage service returned HTTP \(status)."
        case .switchVerificationFailed:
            return "Claude account switch could not be verified and was rolled back."
        }
    }
}
