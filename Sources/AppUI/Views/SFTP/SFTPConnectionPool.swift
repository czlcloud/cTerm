import Foundation

// MARK: - SFTP Connection Pool

/// A per-host connection pool for CitadelSFTP clients.
/// Reuses idle connections instead of creating new SSH sessions for every operation.
@MainActor
final class SFTPConnectionPool {
    static let shared = SFTPConnectionPool()

    private struct PoolKey: Hashable {
        let host: String
        let port: Int
        let username: String
    }

    private struct PooledConnection {
        let client: CitadelSFTP
        let key: PoolKey
        var lastUsed: Date
        var inUse: Bool = false
    }

    private var connections: [PoolKey: [PooledConnection]] = [:]
    private let idleTimeout: TimeInterval = 120
    private var cleanupTask: Task<Void, Never>?

    private func log(_ msg: String) { SFTPLogger.log("pool", msg) }

    private init() {
        log("pool init")
        startCleanupTimer()
    }

    deinit { cleanupTask?.cancel() }

    // MARK: - Borrow

    func borrow(host: String, port: Int, username: String, password: String) async throws -> CitadelSFTP {
        let key = PoolKey(host: host, port: port, username: username)
        let poolSize = connections[key]?.count ?? 0
        let idleCount = connections[key]?.filter { !$0.inUse }.count ?? 0

        // Try to find an idle connection
        if var pool = connections[key] {
            if let idx = pool.firstIndex(where: { !$0.inUse }) {
                let conn = pool[idx].client
                let idleSec = Date().timeIntervalSince(pool[idx].lastUsed)
                log("borrow \(host):\(port) — found idle conn (idle \(String(format: "%.0f", idleSec))s), reusing (pool: \(pool.count) total, \(pool.filter{!$0.inUse}.count - 1) idle)")
                pool[idx].inUse = true
                pool[idx].lastUsed = Date()
                connections[key] = pool
                return conn
            }
        }

        // No idle connection — create a new one
        log("borrow \(host):\(port) — no idle (pool: \(poolSize) total, \(idleCount) idle), creating new...")
        let client = CitadelSFTP()
        try await client.connect(host: host, port: port, username: username, password: password)
        log("borrow \(host):\(port) — new conn established")
        let pooled = PooledConnection(client: client, key: key, lastUsed: Date(), inUse: true)
        var existing = connections[key] ?? []
        existing.append(pooled)
        connections[key] = existing
        return client
    }

    // MARK: - Return

    func returnClient(_ client: CitadelSFTP) {
        for (key, var pool) in connections {
            if let idx = pool.firstIndex(where: { $0.client === client }) {
                pool[idx].inUse = false
                pool[idx].lastUsed = Date()
                connections[key] = pool
                log("return \(key.host):\(key.port) — returned to pool (pool: \(pool.count) total, \(pool.filter{!$0.inUse}.count) idle)")
                let idle = pool.filter { !$0.inUse }
                if idle.count > 1 {
                    removeOldestIdle(for: key)
                }
                return
            }
        }
        log("return — orphan client, disconnecting")
        Task.detached { await client.disconnect() }
    }

    // MARK: - Evict

    func evict(host: String, port: Int, username: String) async {
        let key = PoolKey(host: host, port: port, username: username)
        guard let pool = connections.removeValue(forKey: key) else { return }
        log("evict \(host):\(port) — closing \(pool.count) conn(s)")
        for conn in pool {
            await conn.client.disconnect()
        }
    }

    func evictAll() async {
        let all = connections
        connections.removeAll()
        log("evictAll — closing all pools (\(all.count) host(s))")
        for (_, pool) in all {
            for conn in pool {
                await conn.client.disconnect()
            }
        }
    }

    // MARK: - Private

    private func removeOldestIdle(for key: PoolKey) {
        guard var pool = connections[key] else { return }
        let idleIndices = pool.indices.filter { !pool[$0].inUse }
        guard idleIndices.count > 1,
              let oldest = idleIndices.min(by: { pool[$0].lastUsed < pool[$1].lastUsed }) else { return }
        log("trim \(key.host):\(key.port) — removing oldest idle (idle \(String(format: "%.0f", Date().timeIntervalSince(pool[oldest].lastUsed)))s)")
        let client = pool[oldest].client
        pool.remove(at: oldest)
        connections[key] = pool.isEmpty ? nil : pool
        Task.detached { await client.disconnect() }
    }

    private func startCleanupTimer() {
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.cleanupIdleConnections()
            }
        }
    }

    private func cleanupIdleConnections() async {
        let now = Date()
        for (key, var pool) in connections {
            let before = pool.count
            pool.removeAll { conn in
                !conn.inUse && now.timeIntervalSince(conn.lastUsed) > idleTimeout
            }
            if pool.count < before {
                log("cleanup \(key.host):\(key.port) — evicted \(before - pool.count) idle conn(s) (\(pool.count) remaining)")
                connections[key] = pool.isEmpty ? nil : pool
            }
        }
    }
}
