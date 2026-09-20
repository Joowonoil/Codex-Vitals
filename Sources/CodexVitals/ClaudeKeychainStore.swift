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

    private let securityURL: URL
    private let commandTimeout: TimeInterval
    private let maximumOutputBytes = 64 * 1024
    private let maximumInteractiveCommandBytes = 4_000

    init(
        securityURL: URL = URL(fileURLWithPath: "/usr/bin/security"),
        commandTimeout: TimeInterval = 5
    ) {
        self.securityURL = securityURL
        self.commandTimeout = commandTimeout
    }

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
        let stdout = BoundedProcessOutput(maximumBytes: maximumOutputBytes)
        let stderr = BoundedProcessOutput(maximumBytes: maximumOutputBytes)
        let readers = DispatchGroup()
        let terminated = DispatchSemaphore(value: 0)
        let input = standardInput.map { _ in Pipe() }
        process.executableURL = securityURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input
        process.terminationHandler = { _ in terminated.signal() }

        try process.run()
        drain(output.fileHandleForReading, into: stdout, group: readers)
        drain(errors.fileHandleForReading, into: stderr, group: readers)

        if let standardInput, let input {
            input.fileHandleForWriting.write(standardInput)
            try input.fileHandleForWriting.close()
        }

        if terminated.wait(timeout: .now() + commandTimeout) == .timedOut {
            process.terminate()
            if terminated.wait(timeout: .now() + 1) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1)
            }
            readers.wait()
            throw ClaudeNativeError.keychainUnavailable("command timed out")
        }

        readers.wait()
        let stdoutResult = stdout.result
        let stderrResult = stderr.result
        guard !stdoutResult.exceededLimit, !stderrResult.exceededLimit else {
            throw ClaudeNativeError.keychainUnavailable("response too large")
        }
        return ProcessResult(status: process.terminationStatus, stdout: stdoutResult.data)
    }

    private func drain(
        _ handle: FileHandle,
        into output: BoundedProcessOutput,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                let chunk: Data
                do {
                    guard let value = try handle.read(upToCount: 4_096) else { return }
                    chunk = value
                } catch {
                    return
                }
                guard !chunk.isEmpty else {
                    return
                }
                output.append(chunk)
            }
        }
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: Data
    }

    private final class BoundedProcessOutput: @unchecked Sendable {
        private let maximumBytes: Int
        private let lock = NSLock()
        private var data = Data()
        private var exceededLimit = false

        init(maximumBytes: Int) {
            self.maximumBytes = maximumBytes
        }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            let remaining = max(0, maximumBytes + 1 - data.count)
            if remaining > 0 {
                data.append(chunk.prefix(remaining))
            }
            if data.count > maximumBytes || chunk.count > remaining {
                exceededLimit = true
            }
        }

        var result: (data: Data, exceededLimit: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (data, exceededLimit)
        }
    }
}
