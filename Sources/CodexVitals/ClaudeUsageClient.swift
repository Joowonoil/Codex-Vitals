import Foundation

struct ClaudeUsageResult: Sendable {
    let credential: String
    let response: ClaudeUsageResponse
}

protocol ClaudeUsageProviding: Sendable {
    func fetchUsage(
        credential: String,
        expectedAccountUUID: String?,
        refreshIfNeeded: Bool
    ) async throws -> ClaudeUsageResult
}

final class ClaudeUsageClient: ClaudeUsageProviding, @unchecked Sendable {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchUsage(
        credential rawCredential: String,
        expectedAccountUUID: String?,
        refreshIfNeeded: Bool
    ) async throws -> ClaudeUsageResult {
        var credential = try ClaudeCredentialEnvelope(rawValue: rawCredential)
        if refreshIfNeeded && credential.isExpiring {
            credential = try await refresh(credential, expectedAccountUUID: expectedAccountUUID)
        }

        var request = URLRequest(url: Self.usageURL, timeoutInterval: 15)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeNativeError.networkUnavailable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            let decoded = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
            return ClaudeUsageResult(credential: credential.rawValue, response: decoded)
        case 401, 403:
            throw ClaudeNativeError.refreshRejected
        case 429:
            throw ClaudeNativeError.rateLimited(
                retryAfter: Self.retryAfterSeconds(from: response as? HTTPURLResponse)
            )
        default:
            throw ClaudeNativeError.serviceUnavailable(status)
        }
    }

    static func retryAfterSeconds(from response: HTTPURLResponse?) -> TimeInterval? {
        guard let rawValue = response?.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        guard let seconds = TimeInterval(rawValue) else { return nil }
        return max(0, seconds)
    }

    private func refresh(
        _ credential: ClaudeCredentialEnvelope,
        expectedAccountUUID: String?
    ) async throws -> ClaudeCredentialEnvelope {
        guard let refreshToken = credential.refreshToken else {
            throw ClaudeNativeError.refreshRejected
        }
        var request = URLRequest(url: Self.tokenURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeNativeError.networkUnavailable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 429 {
                throw ClaudeNativeError.rateLimited(
                    retryAfter: Self.retryAfterSeconds(from: response as? HTTPURLResponse)
                )
            }
            if status == 400 || status == 401 || status == 403 {
                throw ClaudeNativeError.refreshRejected
            }
            throw ClaudeNativeError.serviceUnavailable(status)
        }

        let token = try JSONDecoder().decode(ClaudeTokenResponse.self, from: data)
        if let expectedAccountUUID,
           let actual = token.account?.uuid,
           actual != expectedAccountUUID {
            throw ClaudeNativeError.wrongAccount(expected: expectedAccountUUID, actual: actual)
        }
        let updated = try credential.replacingOAuth(with: token)
        return try ClaudeCredentialEnvelope(rawValue: updated)
    }
}
