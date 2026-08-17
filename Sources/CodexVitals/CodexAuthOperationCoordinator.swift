import Foundation

/// Serializes auth mutations for one captured profile without blocking unrelated accounts.
actor CodexProfileOperationGate {
    static let shared = CodexProfileOperationGate()

    private var heldProfileKeys = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    nonisolated func withExclusiveAccess<T>(
        for profileKey: String,
        operation: () async throws -> T
    ) async throws -> T {
        await acquire(profileKey)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await release(profileKey)
            return result
        } catch {
            await release(profileKey)
            throw error
        }
    }

    private func acquire(_ profileKey: String) async {
        guard heldProfileKeys.contains(profileKey) else {
            heldProfileKeys.insert(profileKey)
            return
        }

        await withCheckedContinuation { continuation in
            waiters[profileKey, default: []].append(continuation)
        }
    }

    private func release(_ profileKey: String) {
        guard var queued = waiters[profileKey], !queued.isEmpty else {
            waiters[profileKey] = nil
            heldProfileKeys.remove(profileKey)
            return
        }

        let next = queued.removeFirst()
        waiters[profileKey] = queued.isEmpty ? nil : queued
        next.resume()
    }
}

/// Limits the first recovery wave so multiple expired accounts do not burst the OAuth endpoint.
actor CodexRefreshPermitPool {
    static let shared = CodexRefreshPermitPool(limit: 2)

    let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
        available = max(1, limit)
    }

    nonisolated func withPermit<T>(operation: () async throws -> T) async throws -> T {
        await acquire()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async {
        guard available == 0 else {
            available -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            available = min(limit, available + 1)
            return
        }

        let next = waiters.removeFirst()
        next.resume()
    }
}
