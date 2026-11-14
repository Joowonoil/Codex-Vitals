import Foundation

struct GeminiRemoteResult: Sendable {
    let account: Account
    let credential: GeminiCredential
}

protocol GeminiRemoteUsageProviding: Sendable {
    func fetch(profile: GeminiProfile, credential: GeminiCredential) async throws -> GeminiRemoteResult
}

struct GeminiRemoteUsageClient: GeminiRemoteUsageProviding {
    var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }
    var clientResolver: @Sendable () -> (String, String)? = { GeminiOAuthClientResolver.shared.resolve() }

    func fetch(profile: GeminiProfile, credential: GeminiCredential) async throws -> GeminiRemoteResult {
        guard credential.email == profile.email else { throw GeminiUsageError.identityChanged }
        var credential = credential
        if credential.expiry.map({ $0.timeIntervalSinceNow < 60 }) == true {
            credential = try await refresh(credential)
        }
        let tier = try await post("loadCodeAssist", credential: credential, body: [
            "metadata": ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"],
        ])
        let project = tier["cloudaicompanionProject"] as? String
        let summary = try await post(
            "retrieveUserQuotaSummary", credential: credential,
            body: project.map { ["project": $0] } ?? [:]
        )
        let wrapped: [String: Any] = ["status": "SUCCESS", "command": ["name": "usage", "data": summary]]
        let data = try JSONSerialization.data(withJSONObject: wrapped)
        let report = try JSONDecoder().decode(GeminiUsageReport.self, from: data)
        var resolvedProfile = profile
        let paid = tier["paidTier"] as? [String: Any]
        let current = tier["currentTier"] as? [String: Any]
        let tierID = (paid?["id"] ?? current?["id"]) as? String ?? ""
        if tierID.contains("ultra") { resolvedProfile.plan = "Ultra" }
        else if tierID.contains("pro") { resolvedProfile.plan = "Pro" }
        else if tierID == "free-tier" { resolvedProfile.plan = "Free" }
        else if let name = (paid?["name"] ?? current?["name"]) as? String { resolvedProfile.plan = name }
        return try GeminiRemoteResult(account: report.account(now: Date(), profile: resolvedProfile), credential: credential)
    }

    private func post(_ method: String, credential: GeminiCredential, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:\(method)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity/cli/1.5.8 darwin/\(Self.architecture)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await response(request)
    }

    private func refresh(_ credential: GeminiCredential) async throws -> GeminiCredential {
        guard let refreshToken = credential.refreshToken, let client = clientResolver() else {
            throw GeminiUsageError.reloginRequired
        }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: client.0),
            URLQueryItem(name: "client_secret", value: client.1),
            URLQueryItem(name: "refresh_token", value: refreshToken),
        ]
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let refreshed = try await response(request)
        return try credential.replacingToken(refreshed, now: Date())
    }

    private func response(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse, data.count <= 1_048_576 else {
            throw GeminiUsageError.unavailable
        }
        if http.statusCode == 401 || (http.statusCode == 400 && request.url?.host == "oauth2.googleapis.com") {
            throw GeminiUsageError.reloginRequired
        }
        if http.statusCode == 429 {
            throw GeminiUsageError.rateLimited(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 300)
        }
        guard http.statusCode == 200 else { throw GeminiUsageError.unavailable }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiUsageError.unavailable
        }
        return object
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }
}
