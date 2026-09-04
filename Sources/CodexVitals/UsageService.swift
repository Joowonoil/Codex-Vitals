import Foundation

struct BankedResetAvailability: Equatable, Sendable {
    let count: Int
    /// Known expiration instants for available credits. `nil` means only the count was returned.
    let expirations: [Date]?
}

/// Fetches best-effort Codex usage data from chatgpt.com.
final class UsageService: @unchecked Sendable {

    private let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                   + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    private let refreshedAccessTokenKey = "__codex_switchboard_access_token"
    private let metadataCache = AccountMetadataCache()
    private let tokenRefreshService: CodexTokenRefreshService
    private static let maxConcurrentRequests = 4
    private static let metadataCacheTTL: TimeInterval = 6 * 60 * 60
    private static let refreshFailedError = CodexTokenRefreshService.reloginRequiredMessage
    private static let resetCreditRetryDelays: [UInt64] = [750_000_000, 1_500_000_000]

    private struct AccountMetadata: Sendable {
        let workspaceName: String?
        let planRenewalDate: Date?
    }

    private actor AccountMetadataCache {
        private struct Entry {
            let value: [String: AccountMetadata]
            let fetchedAt: Date
        }

        private var entries: [String: Entry] = [:]

        func value(for token: String, now: Date, ttl: TimeInterval) -> [String: AccountMetadata]? {
            guard let entry = entries[token],
                  now.timeIntervalSince(entry.fetchedAt) < ttl else {
                entries[token] = nil
                return nil
            }
            return entry.value
        }

        func store(_ value: [String: AccountMetadata], for token: String, fetchedAt: Date) {
            entries[token] = Entry(value: value, fetchedAt: fetchedAt)
        }
    }

    init(tokenRefreshService: CodexTokenRefreshService = CodexTokenRefreshService()) {
        self.tokenRefreshService = tokenRefreshService
    }

    // MARK: - Public

    func loadAll(forceMetadataRefresh: Bool = false) async -> [Account] {
        let collection = AccountProfileStore.load()
        let profiles = collection.profiles
        let validKeys = collection.orderedKeys.filter { profiles[$0] != nil }
        let workspaceAliases = collection.workspaceAliases

        let usages = await fetchUsages(validKeys: validKeys, profiles: profiles)

        var teamNames = TeamNameCacheStore.load()
        let workspaceNamedAccountIDs = workspaceNamedAccountIDs(
            validKeys: validKeys,
            profiles: profiles,
            usages: usages
        )
        let metadataTokens = accountMetadataTokens(
            validKeys: validKeys,
            profiles: profiles,
            usages: usages
        )
        let tokenAccountMetadata = await fetchAccountMetadata(
            for: metadataTokens,
            forceRefresh: forceMetadataRefresh
        )
        // The reset-credit endpoint applies a tighter burst limit than usage and metadata.
        // Fetch these serially after metadata so every account has a fair chance to populate.
        let resetCreditAvailability = await fetchResetCreditAvailability(
            validKeys: validKeys,
            profiles: profiles,
            usages: usages
        )
        let accountMetadataByID = mergedAccountMetadata(from: tokenAccountMetadata)

        if !tokenAccountMetadata.isEmpty {
            var resolvedNames: [String: String] = [:]
            for tokenMap in tokenAccountMetadata.values {
                for (aid, metadata) in tokenMap
                where workspaceNamedAccountIDs.contains(aid)
                    && !aid.isEmpty
                    && metadata.workspaceName?.isEmpty == false
                    && metadata.workspaceName?.isGenericWorkspaceName == false {
                    guard let name = metadata.workspaceName else { continue }
                    if teamNames[aid] == nil || teamNames[aid]?.isGenericWorkspaceName == true {
                        teamNames[aid] = name
                    }
                    resolvedNames[aid] = name
                }
            }
            TeamNameCacheStore.save(resolvedNames)
        }

        // Build Account list
        var accounts: [Account] = []
        var seenEmails = Set<String>()

        for key in validKeys {
            guard let p = profiles[key] else { continue }
            let usage = usages[key] ?? [:]

            let email = (p["email"]     as? String)
                     ?? (usage["email"] as? String)
                     ?? (p["accountId"] as? String)
                     ?? key.components(separatedBy: ":").last ?? key
            let alias = Account.normalizedAlias(p["alias"] as? String)

            let aid = Self.resolvedAccountID(usage: usage, profile: p)
            let dedup = Self.dedupID(email: email, accountID: aid, profileKey: key)
            guard !seenEmails.contains(dedup) else { continue }
            seenEmails.insert(dedup)

            let usageError = usageErrorMessage(from: usage)
            let rl  = usage["rate_limit"]       as? [String: Any]
            let quotaWindows = Self.quotaWindows(from: rl)
            let hasUsage = usageError == nil && !quotaWindows.isEmpty
            let fiveHourWindow = quotaWindows.first { $0.kind == .fiveHour }
            let weeklyWindow = quotaWindows.first { $0.kind == .weekly }

            let planType = resolvedPlanType(profile: p, usage: usage)
            let usesWorkspaceName = workspaceNamedAccountIDs.contains(aid)
            var ws = usesWorkspaceName ? teamNames[aid] : nil
            var planRenewalDate: Date?

            // Retry with the current account token when the real workspace name is unavailable.
            if let tok = accessToken(for: key, profile: p, usages: usages),
               !tok.isEmpty {
                let metadata = tokenAccountMetadata[tok]?[aid] ?? accountMetadataByID[aid]
                if let metadata {
                    planRenewalDate = metadata.planRenewalDate

                    if usesWorkspaceName,
                       (ws == nil || ws?.isEmpty == true || ws?.isGenericWorkspaceName == true),
                       let resolved = metadata.workspaceName,
                       !resolved.isEmpty {
                        ws = resolved
                        teamNames[aid] = resolved
                    } else if usesWorkspaceName,
                              (ws == nil || ws?.isEmpty == true || ws?.isGenericWorkspaceName == true) {
                        // Last fallback: use any non-generic workspace name returned by this token.
                        if let tokenMap = tokenAccountMetadata[tok],
                           let anyRealName = tokenMap.values.compactMap(\.workspaceName).first(where: { !$0.isEmpty && !$0.isGenericWorkspaceName }) {
                            ws = anyRealName
                        }
                    }
                }
            }

            let workspaceName = ws
                ?? planType
                ?? "?"
            let workspaceAlias = Account.normalizedAlias(workspaceAliases[workspaceName])

            accounts.append(Account(
                id: dedup,
                profileKey: key,
                email: email,
                alias: alias,
                workspace: workspaceName,
                workspaceAlias: workspaceAlias,
                plan: planType ?? "?",
                sessionFree: fiveHourWindow?.remainingPercent ?? 100,
                weeklyFree: weeklyWindow?.remainingPercent ?? 100,
                sessionResetSeconds: fiveHourWindow?.resetAfterSeconds ?? 0,
                weeklyResetSeconds: weeklyWindow?.resetAfterSeconds ?? 0,
                quotaWindows: hasUsage ? quotaWindows : [],
                availableResetCount: resetCreditAvailability[key]?.count,
                bankedResetExpirations: resetCreditAvailability[key]?.expirations,
                planRenewalDate: planRenewalDate,
                hasError: !hasUsage,
                errorMessage: usageError ?? (!hasUsage ? "Codex usage unavailable" : nil)
            ))
        }
        applyWorkspacePlanDates(to: &accounts)
        return accounts
    }

    // MARK: - Private Helpers

    static func dedupID(email: String, accountID: String, profileKey: String) -> String {
        "\(email.lowercased())|\(accountID.isEmpty ? profileKey : accountID)"
    }

    static func resolvedAccountID(
        usage: [String: Any],
        profile: [String: Any]
    ) -> String {
        for candidate in [usage["account_id"] as? String, profile["accountId"] as? String] {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            return value
        }
        return ""
    }

    static func quotaWindows(from rateLimit: [String: Any]?) -> [QuotaWindow] {
        guard let rateLimit else { return [] }

        return ["primary_window", "secondary_window"]
            .compactMap { key -> QuotaWindow? in
                guard let window = rateLimit[key] as? [String: Any],
                      let limitSeconds = numericValue(window["limit_window_seconds"]),
                      limitSeconds > 0,
                      let usedPercent = numericValue(window["used_percent"]) else {
                    return nil
                }

                return QuotaWindow(
                    limitSeconds: limitSeconds,
                    remainingPercent: 100 - usedPercent,
                    resetAfterSeconds: numericValue(window["reset_after_seconds"]) ?? 0
                )
            }
            .sorted { $0.limitSeconds < $1.limitSeconds }
    }

    static func availableResetCount(from response: [String: Any]) -> Int? {
        bankedResetAvailability(from: response)?.count
    }

    static func bankedResetAvailability(from response: [String: Any]) -> BankedResetAvailability? {
        guard response["error"] == nil else { return nil }
        let resetCredits = (response["rate_limit_reset_credits"] as? [String: Any]) ?? response
        guard let value = numericValue(
            resetCredits["available_count"]
        ),
              value >= 0 else {
            return nil
        }
        let count = Int(value)
        guard count > 0 else {
            return BankedResetAvailability(count: 0, expirations: [])
        }

        // The regular usage response includes only the count. The dedicated read-only
        // endpoint additionally includes one entry per credit and its expiration.
        guard let credits = resetCredits["credits"] as? [[String: Any]] else {
            return BankedResetAvailability(count: count, expirations: nil)
        }

        let expirations = credits
            .filter { credit in
                guard let status = credit["status"] as? String else { return false }
                return status.caseInsensitiveCompare("available") == .orderedSame
            }
            .compactMap { apiDateValue($0["expires_at"]) }
            .sorted()

        return BankedResetAvailability(count: count, expirations: expirations)
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private func fetchUsage(token: String) async -> [String: Any] {
        await apiGet("/backend-api/codex/usage", token: token)
    }

    private func fetchUsage(profileKey: String, profile: [String: Any]) async -> [String: Any] {
        let initial = await tokenRefreshService.credentialForUsage(
            profileKey: profileKey,
            profile: profile
        )
        guard case let .ready(credential) = initial else {
            if case let .unavailable(message) = initial {
                return ["error": message]
            }
            return ["error": "missing access token"]
        }

        var accessToken = credential.accessToken
        var response = await fetchUsage(token: accessToken)

        if !credential.didRefresh,
           Self.authErrorCode(from: response) == "token_expired" {
            let recovery = await tokenRefreshService.credentialForUsage(
                profileKey: profileKey,
                profile: profile,
                forceRefresh: true
            )
            switch recovery {
            case let .ready(refreshed) where refreshed.accessToken != accessToken:
                accessToken = refreshed.accessToken
                response = await fetchUsage(token: accessToken)
            case let .unavailable(message):
                return ["error": message]
            default:
                break
            }
        }

        return usage(response, accessToken: accessToken)
    }

    private func fetchUsages(
        validKeys: [String],
        profiles: [String: [String: Any]]
    ) async -> [String: [String: Any]] {
        let jobs: [(String, [String: Any])] = validKeys.compactMap { key in
            guard let profile = profiles[key] else { return nil }
            return (key, profile)
        }

        guard !jobs.isEmpty else { return [:] }

        return await withTaskGroup(of: (String, [String: Any]).self) { group in
            var iterator = jobs.makeIterator()
            var activeCount = 0
            var result: [String: [String: Any]] = [:]

            func scheduleNext() {
                guard let job = iterator.next() else { return }
                activeCount += 1
                group.addTask { [self] in
                    (job.0, await fetchUsage(profileKey: job.0, profile: job.1))
                }
            }

            for _ in 0..<min(Self.maxConcurrentRequests, jobs.count) {
                scheduleNext()
            }

            while activeCount > 0, let (key, usage) = await group.next() {
                activeCount -= 1
                result[key] = usage
                scheduleNext()
            }

            return result
        }
    }

    private func fetchResetCreditAvailability(
        validKeys: [String],
        profiles: [String: [String: Any]],
        usages: [String: [String: Any]]
    ) async -> [String: BankedResetAvailability] {
        var result: [String: BankedResetAvailability] = [:]
        var jobs: [(profileKey: String, token: String, accountID: String)] = []

        for key in validKeys {
            if let availability = Self.bankedResetAvailability(from: usages[key] ?? [:]) {
                result[key] = availability
                // Zero has no expiration details to retrieve. A positive count still
                // needs the dedicated endpoint so the UI can list every expiration.
                if availability.count == 0 {
                    continue
                }
            }
            guard let profile = profiles[key],
                  let token = accessToken(for: key, profile: profile, usages: usages),
                  !token.isEmpty else {
                continue
            }
            let accountID = Self.resolvedAccountID(
                usage: usages[key] ?? [:],
                profile: profile
            )
            guard !accountID.isEmpty else { continue }
            jobs.append((key, token, accountID))
        }

        guard !jobs.isEmpty else { return result }

        for job in jobs {
            guard !Task.isCancelled else { break }
            if let availability = await fetchResetCreditAvailability(
                token: job.token,
                accountID: job.accountID
            ) {
                result[job.profileKey] = availability
            }
        }
        return result
    }

    private func fetchResetCreditAvailability(
        token: String,
        accountID: String
    ) async -> BankedResetAvailability? {
        for attempt in 0...Self.resetCreditRetryDelays.count {
            if attempt > 0 {
                do {
                    try await Task.sleep(
                        nanoseconds: Self.resetCreditRetryDelays[attempt - 1]
                    )
                } catch {
                    return nil
                }
            }

            let response = await apiGet(
                "/backend-api/wham/rate-limit-reset-credits",
                token: token,
                accountID: accountID
            )
            if let availability = Self.bankedResetAvailability(from: response) {
                return availability
            }

            let statusCode = response["http_status"] as? Int
            let isTransient = statusCode == nil
                || statusCode == 408
                || statusCode == 429
                || (statusCode.map { 500...599 ~= $0 } ?? false)
            guard isTransient else { return nil }
        }
        return nil
    }

    private func fetchAccountMetadata(token: String) async -> [String: AccountMetadata] {
        let data = await apiGet("/backend-api/accounts/check/v4-2023-04-27", token: token, timeout: 4)
        var result: [String: AccountMetadata] = [:]
        if let accts = data["accounts"] as? [String: [String: Any]] {
            for (aid, info) in accts {
                let account = info["account"] as? [String: Any]
                let entitlement = info["entitlement"] as? [String: Any]
                result[aid] = AccountMetadata(
                    workspaceName: account?["name"] as? String,
                    planRenewalDate: planRenewalDate(from: entitlement)
                )
            }
        }
        return result
    }

    private func fetchAccountMetadata(
        for tokens: Set<String>,
        forceRefresh: Bool
    ) async -> [String: [String: AccountMetadata]] {
        guard !tokens.isEmpty else { return [:] }

        var cachedResults: [String: [String: AccountMetadata]] = [:]
        var tokensToFetch: [String] = []
        let now = Date()

        for token in tokens {
            if !forceRefresh,
               let cached = await metadataCache.value(
                for: token,
                now: now,
                ttl: Self.metadataCacheTTL
               ) {
                cachedResults[token] = cached
            } else {
                tokensToFetch.append(token)
            }
        }

        guard !tokensToFetch.isEmpty else { return cachedResults }

        let fetchedResults = await fetchUncachedAccountMetadata(for: tokensToFetch)
        for (token, metadata) in fetchedResults where !metadata.isEmpty {
            await metadataCache.store(metadata, for: token, fetchedAt: Date())
        }

        return cachedResults.merging(fetchedResults) { _, fresh in fresh }
    }

    private func fetchUncachedAccountMetadata(
        for tokens: [String]
    ) async -> [String: [String: AccountMetadata]] {
        await withTaskGroup(of: (String, [String: AccountMetadata]).self) { group in
            var iterator = tokens.makeIterator()
            var activeCount = 0
            var result: [String: [String: AccountMetadata]] = [:]

            func scheduleNext() {
                guard let token = iterator.next() else { return }
                activeCount += 1
                group.addTask { [self] in
                    (token, await fetchAccountMetadata(token: token))
                }
            }

            for _ in 0..<min(Self.maxConcurrentRequests, tokens.count) {
                scheduleNext()
            }

            while activeCount > 0, let (token, names) = await group.next() {
                activeCount -= 1
                result[token] = names
                scheduleNext()
            }

            return result
        }
    }

    private func mergedAccountMetadata(
        from tokenAccountMetadata: [String: [String: AccountMetadata]]
    ) -> [String: AccountMetadata] {
        var result: [String: AccountMetadata] = [:]

        for metadataMap in tokenAccountMetadata.values {
            for (accountID, metadata) in metadataMap {
                guard !accountID.isEmpty else { continue }

                if let existing = result[accountID] {
                    result[accountID] = AccountMetadata(
                        workspaceName: existing.workspaceName ?? metadata.workspaceName,
                        planRenewalDate: existing.planRenewalDate ?? metadata.planRenewalDate
                    )
                } else {
                    result[accountID] = metadata
                }
            }
        }

        return result
    }

    private func applyWorkspacePlanDates(to accounts: inout [Account]) {
        var datesByWorkspace: [String: Date] = [:]

        for account in accounts {
            guard let date = account.planRenewalDate,
                  !account.workspace.isGenericWorkspaceName else { continue }
            datesByWorkspace[account.workspace] = date
        }

        guard !datesByWorkspace.isEmpty else { return }

        for index in accounts.indices where accounts[index].planRenewalDate == nil {
            let workspace = accounts[index].workspace
            guard !workspace.isGenericWorkspaceName,
                  let date = datesByWorkspace[workspace] else { continue }
            accounts[index].planRenewalDate = date
        }
    }

    private func apiGet(
        _ endpoint: String,
        token: String,
        accountID: String? = nil,
        timeout: TimeInterval = 10
    ) async -> [String: Any] {
        guard let url = URL(string: "https://chatgpt.com\(endpoint)") else {
            return ["error": "bad URL"]
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)",   forHTTPHeaderField: "Authorization")
        req.setValue(ua,                  forHTTPHeaderField: "User-Agent")
        req.setValue("application/json",  forHTTPHeaderField: "Accept")
        req.setValue("https://chatgpt.com",  forHTTPHeaderField: "Origin")
        req.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        req.setValue("en-US,en;q=0.9",   forHTTPHeaderField: "Accept-Language")
        if let accountID, !accountID.isEmpty {
            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                obj["http_status"] = statusCode
                if !(200...299).contains(statusCode), obj["error"] == nil {
                    obj["error"] = readableAPIError(from: obj) ?? "HTTP \(statusCode)"
                }
                return obj
            }
            return [
                "error": statusCode == 0 ? "parse error" : "HTTP \(statusCode)",
                "http_status": statusCode,
            ]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    private func usage(_ usage: [String: Any], accessToken: String) -> [String: Any] {
        var usage = usage
        usage[refreshedAccessTokenKey] = accessToken
        return usage
    }

    private func usageErrorMessage(from data: [String: Any]) -> String? {
        if let error = data["error"] as? String, error == Self.refreshFailedError {
            return error
        }

        if let code = Self.authErrorCode(from: data) {
            switch code {
            case "deactivated_workspace":
                return "Workspace deactivated"
            case "token_expired":
                return "Token expired"
            case "token_invalidated":
                return "Token invalidated"
            case "token_revoked":
                return "Token revoked"
            default:
                return code.replacingOccurrences(of: "_", with: " ")
            }
        }

        if let status = data["http_status"] as? Int, status == 401 {
            return "Expired or revoked"
        }

        if let error = data["error"] as? String, !error.isEmpty {
            return error.replacingOccurrences(of: "_", with: " ")
        }

        if let message = data["message"] as? String, !message.isEmpty {
            return message
        }

        if let status = data["http_status"] as? Int, !(200...299).contains(status) {
            return "HTTP \(status)"
        }

        return nil
    }

    static func isExpiredOrRevokedAuthError(_ message: String?) -> Bool {
        isRecoverableAuthError(message) || requiresRelogin(message)
    }

    static func isRecoverableAuthError(_ message: String?) -> Bool {
        normalizedAuthMessage(message) == "token expired"
    }

    static func requiresRelogin(_ message: String?) -> Bool {
        let normalized = normalizedAuthMessage(message)
        return normalized == "expired or revoked"
            || normalized == "token invalidated"
            || normalized == "token revoked"
            || normalized == normalizedAuthMessage(refreshFailedError)
            || normalized == "http 401"
            || normalized == "http 403"
            || normalized == "re login required"
    }

    static func authErrorCode(from data: [String: Any]) -> String? {
        let candidates: [String?] = [
            (data["detail"] as? [String: Any])?["code"] as? String,
            (data["error"] as? [String: Any])?["code"] as? String,
            data["code"] as? String,
        ]
        guard let raw = candidates.compactMap({ $0 }).first else {
            if let error = data["error"] as? String {
                let normalized = normalizedAuthMessage(error)
                if normalized == "token expired" { return "token_expired" }
                if normalized == "token invalidated" { return "token_invalidated" }
                if normalized == "token revoked" { return "token_revoked" }
            }
            return nil
        }

        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func normalizedAuthMessage(_ message: String?) -> String {
        (message ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func readableAPIError(from data: [String: Any]) -> String? {
        if let detail = data["detail"] as? [String: Any],
           let code = detail["code"] as? String,
           !code.isEmpty {
            return code
        }
        if let detail = data["detail"] as? String, !detail.isEmpty {
            return detail
        }
        if let error = data["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let code = error["code"] as? String, !code.isEmpty {
                return code
            }
        }
        if let message = data["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    private func accountMetadataTokens(
        validKeys: [String],
        profiles: [String: [String: Any]],
        usages: [String: [String: Any]]
    ) -> Set<String> {
        var tokens = Set<String>()

        for key in validKeys {
            guard let profile = profiles[key],
                  let usage = usages[key] else { continue }

            if usage["error"] == nil,
               let token = accessToken(for: key, profile: profile, usages: usages),
               !token.isEmpty {
                tokens.insert(token)
            }
        }

        return tokens
    }

    private func workspaceNamedAccountIDs(
        validKeys: [String],
        profiles: [String: [String: Any]],
        usages: [String: [String: Any]]
    ) -> Set<String> {
        var accountIDs = Set<String>()

        for key in validKeys {
            guard let profile = profiles[key],
                  let usage = usages[key] else { continue }

            let accountID = Self.resolvedAccountID(usage: usage, profile: profile)
            guard !accountID.isEmpty else { continue }

            let planType = resolvedPlanType(profile: profile, usage: usage)
            if shouldUseWorkspaceName(planType: planType, accountID: accountID) {
                accountIDs.insert(accountID)
            }
        }

        return accountIDs
    }

    private func resolvedPlanType(
        profile: [String: Any],
        usage: [String: Any]
    ) -> String? {
        let planType = (usage["plan_type"] as? String) ?? (profile["plan"] as? String)
        let trimmed = planType?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == true ? nil : trimmed
    }

    private func accessToken(
        for key: String,
        profile: [String: Any],
        usages: [String: [String: Any]]
    ) -> String? {
        (usages[key]?[refreshedAccessTokenKey] as? String) ?? (profile["access"] as? String)
    }

    private func shouldUseWorkspaceName(planType: String?, accountID: String) -> Bool {
        if accountID.isLikelyPersonalAccountID {
            return false
        }

        guard let planType else {
            return true
        }

        if planType.isUnknownPlanType {
            return true
        }

        return !planType.isPersonalPlanType
    }

    private func planRenewalDate(from entitlement: [String: Any]?) -> Date? {
        guard let entitlement else { return nil }
        return dateValue(entitlement["renews_at"])
            ?? dateValue(entitlement["expires_at"])
            ?? dateValue((entitlement["discount"] as? [String: Any])?["discount_expires_at"])
    }

    private func dateValue(_ value: Any?) -> Date? {
        Self.apiDateValue(value)
    }

    private static func apiDateValue(_ value: Any?) -> Date? {
        if let string = value as? String {
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: string) {
                return date
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        }

        if let number = value as? Double {
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
        }

        if let number = value as? Int {
            let double = Double(number)
            return Date(timeIntervalSince1970: double > 10_000_000_000 ? double / 1000 : double)
        }

        return nil
    }
}
