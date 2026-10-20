import Foundation

/// Config + leases for agent-only hidden columns (indices 100+ by default).
@MainActor
final class AgentColumnLeases {
    static let shared = AgentColumnLeases()

    /// Default first agent column index (human deck stays 0…n-1).
    static let defaultBaseIndex = 100
    static let defaultColumnCount = 2
    static let defaultNavMinIntervalSeconds: TimeInterval = 5.0
    static let defaultLeaseTTLSeconds: TimeInterval = 120.0
    static let maxLeaseTTLSeconds: TimeInterval = 600.0

    struct LeaseSnapshot: Sendable {
        let column: Int
        let agentId: String
        let expiresAt: Date
        let remainingSeconds: Int
    }

    struct AcquireResult: Sendable {
        let column: Int
        let agentId: String
        let expiresAt: Date
        let ttlSeconds: Int
        let renewed: Bool
    }

    private struct Lease {
        var agentId: String
        var expiresAt: Date
    }

    private(set) var baseIndex: Int
    private(set) var columnCount: Int
    private(set) var navMinInterval: TimeInterval
    private(set) var allowUserNav: Bool

    private var leases: [Int: Lease] = [:]
    private var lastNavigateAt: [Int: Date] = [:]

    private init() {
        baseIndex = Self.envInt("XDECK_AGENT_COLUMN_BASE", default: Self.defaultBaseIndex, min: 10, max: 10_000)
        columnCount = Self.envInt("XDECK_AGENT_COLUMNS", default: Self.defaultColumnCount, min: 0, max: 8)
        let intervalMs = Self.envInt(
            "XDECK_AGENT_NAV_MIN_INTERVAL_MS",
            default: Int(Self.defaultNavMinIntervalSeconds * 1000),
            min: 0,
            max: 60_000
        )
        navMinInterval = TimeInterval(intervalMs) / 1000.0
        allowUserNav = Self.envFlag("XDECK_AGENT_ALLOW_USER_NAV")
    }

    var agentIndices: [Int] {
        guard columnCount > 0 else { return [] }
        return Array(baseIndex..<(baseIndex + columnCount))
    }

    func isAgentColumn(_ index: Int) -> Bool {
        agentIndices.contains(index)
    }

    func isUserColumn(_ index: Int) -> Bool {
        !isAgentColumn(index)
    }

    /// Reclaim expired leases, then grant a free agent column (or renew same agentId).
    func acquire(agentId: String, ttlSeconds: TimeInterval?) throws -> AcquireResult {
        let trimmed = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentBridgeError.badRequest("Missing agentId")
        }
        guard columnCount > 0 else {
            throw AgentBridgeError.conflict("No agent columns configured (XDECK_AGENT_COLUMNS=0)")
        }

        reclaimExpired()

        let ttl = Self.clampTTL(ttlSeconds)
        let expires = Date().addingTimeInterval(ttl)

        // Same agent already holds a column → renew in place.
        if let existing = leases.first(where: { $0.value.agentId == trimmed }) {
            leases[existing.key] = Lease(agentId: trimmed, expiresAt: expires)
            return AcquireResult(
                column: existing.key,
                agentId: trimmed,
                expiresAt: expires,
                ttlSeconds: Int(ttl),
                renewed: true
            )
        }

        guard let free = agentIndices.first(where: { leases[$0] == nil }) else {
            throw AgentBridgeError.conflict(
                "No free agent columns (all \(columnCount) leased). Release or wait for TTL expiry."
            )
        }
        leases[free] = Lease(agentId: trimmed, expiresAt: expires)
        return AcquireResult(
            column: free,
            agentId: trimmed,
            expiresAt: expires,
            ttlSeconds: Int(ttl),
            renewed: false
        )
    }

    @discardableResult
    func release(agentId: String?, column: Int?) throws -> [Int] {
        reclaimExpired()
        var released: [Int] = []

        if let column {
            guard isAgentColumn(column) else {
                throw AgentBridgeError.badRequest("Column \(column) is not an agent column")
            }
            if let lease = leases[column] {
                if let agentId {
                    let trimmed = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard lease.agentId == trimmed else {
                        throw AgentBridgeError.forbidden(
                            "Column \(column) is leased by a different agentId"
                        )
                    }
                }
                leases.removeValue(forKey: column)
                released.append(column)
            }
            return released
        }

        guard let agentId else {
            throw AgentBridgeError.badRequest("Provide agentId and/or column to release")
        }
        let trimmed = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        for (index, lease) in leases where lease.agentId == trimmed {
            leases.removeValue(forKey: index)
            released.append(index)
        }
        return released.sorted()
    }

    func lease(for column: Int) -> LeaseSnapshot? {
        reclaimExpired()
        guard let lease = leases[column] else { return nil }
        let remaining = max(0, Int(lease.expiresAt.timeIntervalSinceNow.rounded(.down)))
        return LeaseSnapshot(
            column: column,
            agentId: lease.agentId,
            expiresAt: lease.expiresAt,
            remainingSeconds: remaining
        )
    }

    /// Gate navigate/scroll on agent columns: matching live lease required.
    func requireAgentLease(column: Int, agentId: String?) throws {
        guard isAgentColumn(column) else { return }
        reclaimExpired()
        guard let lease = leases[column] else {
            throw AgentBridgeError.forbidden(
                "Agent column \(column) requires an active lease — call acquire_column first"
            )
        }
        let trimmed = (agentId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentBridgeError.forbidden(
                "Agent column \(column) requires agentId matching the lease holder (\(lease.agentId))"
            )
        }
        guard lease.agentId == trimmed else {
            throw AgentBridgeError.forbidden(
                "Agent column \(column) is leased by '\(lease.agentId)', not '\(trimmed)'"
            )
        }
    }

    /// Gate navigate/scroll on human deck columns unless opt-in.
    func requireUserNavAllowed(column: Int) throws {
        guard isUserColumn(column) else { return }
        guard allowUserNav else {
            throw AgentBridgeError.forbidden(
                "Navigating/scrolling user columns (\(column)) is refused by default to protect the human deck. Use an agent column (acquire_column) or set XDECK_AGENT_ALLOW_USER_NAV=1 on the XDeck process."
            )
        }
    }

    /// Min interval between navigations on a given agent column.
    func requireNavPacing(column: Int) throws {
        guard isAgentColumn(column), navMinInterval > 0 else { return }
        if let last = lastNavigateAt[column] {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < navMinInterval {
                let waitMs = Int(((navMinInterval - elapsed) * 1000).rounded(.up))
                throw AgentBridgeError.tooManyRequests(
                    "Agent column \(column) navigation pacing: wait \(waitMs)ms (min interval \(Int(navMinInterval * 1000))ms)"
                )
            }
        }
    }

    func markNavigated(column: Int) {
        guard isAgentColumn(column) else { return }
        lastNavigateAt[column] = Date()
    }

    func reclaimExpired() {
        let now = Date()
        for (index, lease) in leases where lease.expiresAt <= now {
            leases.removeValue(forKey: index)
        }
    }

    private static func clampTTL(_ raw: TimeInterval?) -> TimeInterval {
        let value = raw ?? defaultLeaseTTLSeconds
        if value < 1 { return 1 }
        if value > maxLeaseTTLSeconds { return maxLeaseTTLSeconds }
        return value
    }

    private static func envInt(_ name: String, default def: Int, min: Int, max: Int) -> Int {
        guard let raw = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let n = Int(raw) else { return def }
        return Swift.min(max, Swift.max(min, n))
    }

    private static func envFlag(_ name: String) -> Bool {
        let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "1" || value == "true" || value == "yes"
    }
}
