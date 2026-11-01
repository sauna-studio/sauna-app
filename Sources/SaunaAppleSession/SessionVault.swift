import Foundation

struct StoredBlob: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let revision: Data
    let payload: Data
    var description: String { "StoredBlob(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}
protocol SessionPersistence: Sendable {
    func read(scope: SessionScope) throws -> StoredBlob?
    func replace(scope: SessionScope, expectedRevision: Data?, with blob: StoredBlob) throws -> Bool
    func delete(scope: SessionScope, revision: Data) throws -> Bool
}

private struct PersistedSession {
    let token: SessionToken
    let storedAt: Date
    let expiresAt: Date
    func valid(at now: Date) -> Bool {
        let values = [storedAt.timeIntervalSince1970, expiresAt.timeIntervalSince1970, now.timeIntervalSince1970]
        return values.allSatisfy(\.isFinite) && now >= storedAt && now < expiresAt
            && expiresAt.timeIntervalSince(storedAt) > 0 && expiresAt.timeIntervalSince(storedAt) <= 86_400
    }
    func encode() -> Data {
        var data = Data([1])
        for value in [storedAt.timeIntervalSince1970, expiresAt.timeIntervalSince1970] {
            var bits = value.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        data.append(token.bytes)
        return data
    }
    init(token: SessionToken, storedAt: Date, expiresAt: Date) {
        self.token = token; self.storedAt = storedAt; self.expiresAt = expiresAt
    }
    init?(data: Data) {
        guard data.count == 49, data.first == 1 else { return nil }
        let bytes = Array(data)
        func double(at offset: Int) -> Double {
            let bits = bytes[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            return Double(bitPattern: bits)
        }
        storedAt = Date(timeIntervalSince1970: double(at: 1))
        expiresAt = Date(timeIntervalSince1970: double(at: 9))
        token = SessionToken(bytes: Data(bytes[17..<49]))
    }
}

public actor SessionVault: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public nonisolated var description: String { "SessionVault(<redacted>)" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    public nonisolated let scope: SessionScope
    private let persistence: any SessionPersistence
    private var generation = UUID()
    private var current: (blob: StoredBlob, session: PersistedSession)?
    private var csrf: CSRFToken?
    private var csrfExpiresAt: Date?
    private var blockedRevision: Data?
    private var restoreSuppressed = false

    init(scope: SessionScope, persistence: any SessionPersistence) {
        self.scope = scope; self.persistence = persistence
    }

    public func beginAuthentication() throws -> SessionWriteTicket {
        generation = UUID(); current = nil; csrf = nil; csrfExpiresAt = nil
        let revision = try persistence.read(scope: scope)?.revision
        return SessionWriteTicket(scope: scope, generation: generation, expectedRevision: revision)
    }

    public func save(token: SessionToken, expiresAt: Date, csrfToken: CSRFToken,
                     ticket: SessionWriteTicket, now: Date = .now) throws -> UnverifiedSession {
        guard ticket.scope == scope, ticket.generation == generation else { throw SessionContractError.staleOperation }
        let session = PersistedSession(token: token, storedAt: now, expiresAt: expiresAt)
        guard session.valid(at: now) else { throw SessionContractError.invalidValue }
        let blob = StoredBlob(revision: Data(UUID().uuidString.utf8), payload: session.encode())
        guard try persistence.replace(scope: scope, expectedRevision: ticket.expectedRevision, with: blob) else {
            throw SessionContractError.storageConflict
        }
        current = (blob, session); csrf = csrfToken; csrfExpiresAt = expiresAt; blockedRevision = nil; restoreSuppressed = false
        return lease(blob: blob, session: session)
    }

    public func restore(now: Date = .now) throws -> UnverifiedSession? {
        generation = UUID(); current = nil; csrf = nil; csrfExpiresAt = nil
        guard !restoreSuppressed else { return nil }
        guard let blob = try persistence.read(scope: scope) else { return nil }
        guard blockedRevision != blob.revision,
              let session = PersistedSession(data: blob.payload), session.valid(at: now) else {
            blockedRevision = blob.revision; restoreSuppressed = true
            _ = try persistence.delete(scope: scope, revision: blob.revision)
            return nil
        }
        current = (blob, session)
        return lease(blob: blob, session: session)
    }

    func prepareRevalidation(_ lease: UnverifiedSession, now: Date) throws {
        try Task.checkCancellation()
        try validate(lease, now: now)
        csrf = nil; csrfExpiresAt = nil
    }

    func credentials(for lease: UnverifiedSession, now: Date) throws -> SessionRequestCredentials {
        try Task.checkCancellation()
        try validate(lease, now: now)
        guard let csrf, let csrfExpiresAt, now < csrfExpiresAt else { throw SessionContractError.staleOperation }
        return SessionRequestCredentials(token: lease.token, csrfToken: csrf, lease: lease)
    }

    public func confirmCSRF(_ csrfToken: CSRFToken, for lease: UnverifiedSession, now: Date = .now) throws {
        try Task.checkCancellation()
        try validate(lease, now: now)
        csrf = csrfToken; csrfExpiresAt = lease.expiresAt
    }

    func confirmRevalidation(_ csrfToken: CSRFToken, for lease: UnverifiedSession, expiresAt: Date,
                             clock: @Sendable () -> Date) throws {
        try Task.checkCancellation()
        let now = clock()
        try validate(lease, now: now)
        guard expiresAt > now, expiresAt <= lease.expiresAt else { throw SessionContractError.staleOperation }
        csrf = csrfToken; csrfExpiresAt = expiresAt
    }

    public func requestCredentials(now: Date = .now) throws -> SessionRequestCredentials? {
        guard let current else { return nil }
        let lease = lease(blob: current.blob, session: current.session)
        do { try validate(lease, now: now) }
        catch SessionContractError.staleOperation { try invalidate(lease); return nil }
        guard let csrf, let csrfExpiresAt, now < csrfExpiresAt else { return nil }
        return SessionRequestCredentials(token: lease.token, csrfToken: csrf, lease: lease)
    }

    /// A delayed response for an older request must not clear a newer login.
    @discardableResult public func invalidate(_ lease: UnverifiedSession) throws -> Bool {
        guard lease.scope == scope, lease.generation == generation,
              current?.blob.revision == lease.revision else { return false }
        generation = UUID(); current = nil; csrf = nil; csrfExpiresAt = nil; blockedRevision = lease.revision; restoreSuppressed = true
        return try persistence.delete(scope: scope, revision: lease.revision)
    }

    /// This clears only local storage; server-side logout is a separate API operation.
    public func removeLocalSession() throws {
        generation = UUID(); current = nil; csrf = nil; csrfExpiresAt = nil; restoreSuppressed = true
        guard let blob = try persistence.read(scope: scope) else { return }
        blockedRevision = blob.revision
        let removed = try persistence.delete(scope: scope, revision: blob.revision)
        if !removed, try persistence.read(scope: scope) != nil { throw SessionContractError.storageConflict }
    }

    private func lease(blob: StoredBlob, session: PersistedSession) -> UnverifiedSession {
        UnverifiedSession(token: session.token, expiresAt: session.expiresAt, scope: scope,
                          generation: generation, revision: blob.revision)
    }
    private func validate(_ lease: UnverifiedSession, now: Date) throws {
        guard lease.scope == scope, lease.generation == generation,
              let current, current.blob.revision == lease.revision,
              current.session.valid(at: now),
              try persistence.read(scope: scope)?.revision == lease.revision else {
            throw SessionContractError.staleOperation
        }
    }
}
