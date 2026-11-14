import Darwin
import Foundation

enum GeminiUsageError: LocalizedError {
    case unsupportedVersion
    case unavailable
    case timedOut
    case reloginRequired
    case identityChanged
    case rateLimited(TimeInterval)
    case sessionsRunning
    case profileMissing
    case switchFailed
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return "Update Antigravity CLI to track Gemini usage."
        case .unavailable:
            return "Gemini usage is unavailable. Check your sign-in with agy."
        case .timedOut:
            return "Gemini usage check timed out."
        case .reloginRequired: return "Reconnect this Gemini account."
        case .identityChanged: return "The signed-in Gemini account changed during the operation. Please try again."
        case .rateLimited: return "Gemini usage refresh is temporarily rate limited."
        case .sessionsRunning: return "Close running agy sessions and Antigravity before switching Gemini accounts."
        case .profileMissing: return "Gemini account profile is missing."
        case .switchFailed: return "Gemini account switch failed and the previous sign-in was restored."
        case .rollbackFailed: return "Gemini sign-in could not be restored. Sign in again with agy."
        }
    }
}

struct GeminiUsageReport: Decodable {
    struct Command: Decodable {
        struct Quotas: Decodable {
            struct Group: Decodable {
                struct Bucket: Decodable {
                    let id: String
                    let window: String?
                    let remainingFraction: Double?
                    let resetTime: String?
                    let disabled: Bool?

                    enum CodingKeys: String, CodingKey {
                        case id, window, disabled
                        case bucketID = "bucketId"
                        case remainingFraction = "remaining_fraction"
                        case resetTime = "reset_time"
                        case camelRemaining = "remainingFraction"
                        case camelReset = "resetTime"
                    }

                    init(from decoder: Decoder) throws {
                        let values = try decoder.container(keyedBy: CodingKeys.self)
                        id = try values.decodeIfPresent(String.self, forKey: .id)
                            ?? values.decode(String.self, forKey: .bucketID)
                        window = try values.decodeIfPresent(String.self, forKey: .window)
                        disabled = try values.decodeIfPresent(Bool.self, forKey: .disabled)
                        remainingFraction = try values.decodeIfPresent(Double.self, forKey: .remainingFraction)
                            ?? values.decodeIfPresent(Double.self, forKey: .camelRemaining)
                        resetTime = try values.decodeIfPresent(String.self, forKey: .resetTime)
                            ?? values.decodeIfPresent(String.self, forKey: .camelReset)
                    }

                    func quota(now: Date) -> QuotaWindow? {
                        guard disabled != true, let remainingFraction,
                              remainingFraction.isFinite, (0...1).contains(remainingFraction) else {
                            return nil
                        }
                        let seconds: Double
                        switch window {
                        case "5h": seconds = QuotaWindow.fiveHourSeconds
                        case "weekly", "1w": seconds = QuotaWindow.weeklySeconds
                        default: return nil
                        }
                        let formatter = ISO8601DateFormatter()
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        let date = resetTime.flatMap { formatter.date(from: $0) } ?? {
                            formatter.formatOptions = [.withInternetDateTime]
                            return resetTime.flatMap { formatter.date(from: $0) }
                        }()
                        return QuotaWindow(
                            limitSeconds: seconds,
                            remainingPercent: remainingFraction * 100,
                            resetAfterSeconds: max(0, date?.timeIntervalSince(now) ?? 0),
                            resetTimeKnown: date != nil
                        )
                    }
                }
                let buckets: [Bucket]
                let displayName: String?
                let description: String?
            }
            let groups: [Group]
        }
        let name: String
        let data: Quotas?
    }
    let status: String
    let command: Command?

    func account(now: Date, profile: GeminiProfile? = nil) throws -> Account {
        guard status == "SUCCESS", command?.name == "usage",
              let groups = command?.data?.groups else { throw GeminiUsageError.unavailable }
        let buckets = groups.flatMap(\.buckets)
        // Stable bucket IDs keep third-party and model-specific allowances out of Gemini's main bars.
        let windows = ["gemini-5h", "gemini-weekly"].compactMap { id -> QuotaWindow? in
            guard let quota = buckets.first(where: { $0.id == id })?.quota(now: now),
                  quota.kind == (id == "gemini-5h" ? .fiveHour : .weekly) else { return nil }
            return quota
        }
        guard !windows.isEmpty else { throw GeminiUsageError.unavailable }
        let session = windows.first { $0.kind == .fiveHour }
        let weekly = windows.first { $0.kind == .weekly }
        let details = modelQuotaDetails(groups: groups, now: now)
        let argon = details.first { $0.id == "argon" }?.windows.first { $0.kind == .weekly }
        let geminiDescription = groups.first {
            $0.buckets.contains { ["gemini-5h", "gemini-weekly"].contains($0.id) }
        }?.description
        return Account(
            id: profile.map { "gemini:\($0.id)" } ?? "gemini:unidentified",
            profileKey: nil,
            email: profile?.email ?? "Antigravity CLI",
            alias: profile?.alias,
            workspace: profile?.workspace ?? "Gemini",
            workspaceAlias: profile?.workspaceAlias,
            plan: profile?.plan ?? "Gemini",
            sessionFree: session?.remainingPercent ?? 0,
            weeklyFree: weekly?.remainingPercent ?? 0,
            sessionResetSeconds: session?.resetAfterSeconds ?? 0,
            weeklyResetSeconds: weekly?.resetAfterSeconds ?? 0,
            quotaWindows: windows,
            argonQuotaWindow: argon,
            geminiQuotaDetails: details,
            geminiQuotaDescription: geminiDescription.map { String($0.prefix(1_000)) },
            planRenewalDate: profile?.planRenewalDate,
            hasError: false,
            errorMessage: nil,
            provider: .gemini,
            providerProfileID: profile?.id,
            providerIsActive: true,
            providerStatus: "ok",
            quotaReferenceDate: now
        )
    }

    private func modelQuotaDetails(groups: [Command.Quotas.Group], now: Date) -> [ModelQuotaDetail] {
        let mainIDs: Set<String> = ["gemini-5h", "gemini-weekly"]
        let mainGroups = groups.filter { $0.buckets.contains { mainIDs.contains($0.id) } }
        // Only explicit membership lists establish sharing; plan names and marketing text do not.
        let sharedMembers = mainGroups.flatMap { group -> [String] in
            let prefix = "Models within this group:"
            guard let description = group.description, description.hasPrefix(prefix) else { return [] }
            return description.dropFirst(prefix.count).split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        }

        return ["Argon", "Carbon", "Hydrogen"].compactMap { label in
            let modelID = label.lowercased()
            let modelName = "Gemini 4 \(label)"
            let namedGroups = groups.filter {
                $0.displayName?.caseInsensitiveCompare(modelName) == .orderedSame
            }
            let scoped = groups.flatMap { group in
                group.buckets.filter { bucket in
                    !mainIDs.contains(bucket.id) && !bucket.id.hasPrefix("3p-")
                        && (bucket.id.hasPrefix("gemini-\(modelID)-")
                            || group.displayName?.caseInsensitiveCompare(modelName) == .orderedSame)
                }
            }
            let activeBuckets = scoped.filter { $0.disabled != true }
            if !activeBuckets.isEmpty {
                var durations = Set<Double>()
                let windows = activeBuckets.compactMap { bucket -> QuotaWindow? in
                    guard let quota = bucket.quota(now: now),
                          !bucket.id.hasSuffix("-weekly") || quota.kind == .weekly,
                          !bucket.id.hasSuffix("-5h") || quota.kind == .fiveHour,
                          durations.insert(quota.limitSeconds).inserted else { return nil }
                    return quota
                }.sorted { $0.limitSeconds < $1.limitSeconds }
                return ModelQuotaDetail(
                    id: modelID, label: label, windows: windows,
                    explanation: namedGroups.first?.description.map { String($0.prefix(1_000)) }
                )
            }
            // Hydrogen already has the main Gemini row, so do not duplicate it.
            let explicitlyShared = sharedMembers.contains(modelName.lowercased())
                || namedGroups.contains { $0.buckets.contains { mainIDs.contains($0.id) && $0.disabled != true } }
            if label != "Hydrogen", scoped.isEmpty, explicitlyShared {
                return ModelQuotaDetail(id: modelID, label: label, sharesMainQuota: true)
            }
            return nil
        }
    }
}

struct GeminiCLIUsageClient {
    var executableURL: URL? = Self.resolveExecutable()
    var timeout: TimeInterval = 20

    static func resolveExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        if let explicit = environment["ANTIGRAVITY_CLI_PATH"] {
            let url = URL(fileURLWithPath: explicit)
            return !explicit.isEmpty && FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        let candidates = [home.appendingPathComponent(".local/bin/agy").path]
            + (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/agy" }
            + ["/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    func fetchAccount() async throws -> Account? {
        guard let executableURL else { return nil }
        let versionData = try await run(executableURL, arguments: ["--version"], timeout: 3)
        let version = String(decoding: versionData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        let components = version.split(separator: ".").compactMap { Int($0) }
        guard components.count == 3,
              version.compare("1.1.11", options: .numeric) != .orderedAscending else {
            throw GeminiUsageError.unsupportedVersion
        }
        let data = try await run(
            executableURL,
            arguments: ["--print", "/usage", "--output-format", "json", "--print-timeout", "\(Int(timeout))s"],
            timeout: timeout
        )
        return try JSONDecoder().decode(GeminiUsageReport.self, from: data).account(now: Date())
    }

    func login() async throws {
        guard let executableURL else { throw GeminiUsageError.unsupportedVersion }
        let version = String(decoding: try await run(executableURL, arguments: ["--version"], timeout: 3), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.range(of: #"^v?[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
              version.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                .compare("1.5.0", options: .numeric) != .orderedAscending else {
            throw GeminiUsageError.unsupportedVersion
        }
        _ = try await run(executableURL, arguments: ["acp", "--login"], timeout: 600, allowsBrowser: true)
    }

    private func run(
        _ executable: URL, arguments: [String], timeout: TimeInterval, allowsBrowser: Bool = false
    ) async throws -> Data {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("CodexVitals-Gemini-\(UUID())")
        try files.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defer { try? files.removeItem(at: directory) }
        // Background usage checks must never open a browser if agy needs to sign in again.
        for name in allowsBrowser ? [] : ["open", "xdg-open", "browser"] {
            let launcher = directory.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: launcher)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        for url in [outputURL, errorURL] {
            guard files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw GeminiUsageError.unavailable
            }
        }
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        if !allowsBrowser {
            environment["PATH"] = "\(directory.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
            environment["BROWSER"] = directory.appendingPathComponent("browser").path
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw GeminiUsageError.timedOut }
                for url in [outputURL, errorURL] {
                    let size = (try files.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                    guard size <= 1_048_576 else { throw GeminiUsageError.unavailable }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            if process.isRunning { process.terminate() }
            try? await Task.sleep(nanoseconds: 100_000_000)
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            throw error
        }
        guard process.terminationStatus == 0 else { throw GeminiUsageError.unavailable }
        let data = try Data(contentsOf: outputURL)
        guard data.count <= 1_048_576 else { throw GeminiUsageError.unavailable }
        return data
    }
}

struct GeminiLoadResult {
    let accounts: [Account]
    let errorMessage: String?
}
