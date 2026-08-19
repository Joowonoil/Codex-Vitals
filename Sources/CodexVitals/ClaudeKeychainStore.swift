import Darwin
import Foundation

protocol ClaudeKeychainStoring: Sendable {
    var activeAccountName: String { get }
    func read(service: String, account: String) throws -> String?
    func write(service: String, account: String, value: String) throws
    func delete(service: String, account: String) throws
}

final class ClaudeKeychainStore: ClaudeKeychainStoring, @unchecked Sendable {
    static let activeService = "Claude Code-credentials"
    static let profileService = "com.ramterstudio.CodexVitals.Claude"
    static let safetyService = "com.ramterstudio.CodexVitals.Claude.Safety"
    static let safetyAccount = "last-live-credential"

    private let securityURL = URL(fileURLWithPath: "/usr/bin/security")
    private let maximumOutputBytes = 64 * 1024
    private let maximumInteractiveCommandBytes = 4_000

    var activeAccountName: String {
        let environmentUser = ProcessInfo.processInfo.environment["USER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return environmentUser?.isEmpty == false ? environmentUser! : NSUserName()
    }

    func read(service: String, account: String) throws -> String? {
        let result = try run(arguments: [
            "find-generic-password", "-a", account, "-w", "-s", service,
        ])
        if result.status == 0 {
            guard result.stdout.count <= maximumOutputBytes,
                  let value = String(data: result.stdout, encoding: .utf8) else {
                throw ClaudeNativeError.keychainUnavailable("invalid response")
            }
            return value.hasSuffix("\n") ? String(value.dropLast()) : value
        }
        if result.status == 44 { return nil }
        throw ClaudeNativeError.keychainUnavailable("read failed (\(result.status))")
    }

    func write(service: String, account: String, value: String) throws {
        let hex = value.data(using: .utf8)?.map { String(format: "%02x", $0) }.joined() ?? ""
        let command = "add-generic-password -U -a \(quoted(account)) -s \(quoted(service)) -X \(hex)\n"
        guard command.utf8.count <= maximumInteractiveCommandBytes else {
            throw ClaudeNativeError.keychainValueTooLarge
        }
        let result = try run(arguments: ["-i"], standardInput: Data(command.utf8))
        guard result.status == 0 else {
            throw ClaudeNativeError.keychainUnavailable("write failed (\(result.status))")
        }
    }

    func delete(service: String, account: String) throws {
        let result = try run(arguments: [
            "delete-generic-password", "-a", account, "-s", service,
        ])
        guard result.status == 0 || result.status == 44 else {
            throw ClaudeNativeError.keychainUnavailable("delete failed (\(result.status))")
        }
    }

    private func quoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func run(arguments: [String], standardInput: Data? = nil) throws -> ProcessResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = securityURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        if let standardInput {
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(standardInput)
            try input.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        guard stdout.count <= maximumOutputBytes, stderr.count <= maximumOutputBytes else {
            throw ClaudeNativeError.keychainUnavailable("response too large")
        }
        return ProcessResult(status: process.terminationStatus, stdout: stdout)
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: Data
    }
}
