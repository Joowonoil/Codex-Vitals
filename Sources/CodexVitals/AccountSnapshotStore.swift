import Foundation

/// Stores the latest `/usage` result so the popover does not open empty after relaunch.
enum AccountSnapshotStore {

    private struct Payload: Codable {
        var lastRefreshEpoch: TimeInterval?
        var accounts: [Account]
    }

    private static var url: URL {
        AppStorage.rootURL.appendingPathComponent("accounts-snapshot.json")
    }

    static func load(now: Date = Date()) -> (accounts: [Account], lastRefresh: Date?)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        guard let p = try? dec.decode(Payload.self, from: data), !p.accounts.isEmpty else { return nil }
        let date = p.lastRefreshEpoch.map { Date(timeIntervalSince1970: $0) }
        return rebase(accounts: p.accounts, lastRefresh: date, now: now)
    }

    static func rebase(
        accounts: [Account],
        lastRefresh: Date?,
        now: Date
    ) -> (accounts: [Account], lastRefresh: Date?) {
        guard let lastRefresh else { return (accounts, nil) }
        let elapsed = max(0, now.timeIntervalSince(lastRefresh))
        return (accounts.map { $0.agingResetTimers(by: elapsed) }, now)
    }

    static func save(accounts: [Account], lastRefresh: Date?) {
        let p = Payload(
            lastRefreshEpoch: lastRefresh.map { $0.timeIntervalSince1970 },
            accounts: accounts
        )
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
