import Foundation
import Synchronization
import Testing
@testable import SaunaAppleSession

final class MemoryPersistence: SessionPersistence {
    struct State: Sendable {
        var values: [SessionScope: StoredBlob] = [:]
        var readError: SessionContractError?
        var deleteError: SessionContractError?
        var replacementDuringDelete: StoredBlob?
    }
    let state = Mutex(State())
    func read(scope: SessionScope) throws -> StoredBlob? {
        try state.withLock { state in
            if let error = state.readError { throw error }
            return state.values[scope]
        }
    }
    func replace(scope: SessionScope, expectedRevision: Data?, with blob: StoredBlob) throws -> Bool {
        state.withLock { state in
            guard state.values[scope]?.revision == expectedRevision else { return false }
            state.values[scope] = blob; return true
        }
    }
    func delete(scope: SessionScope, revision: Data) throws -> Bool {
        try state.withLock { state in
            if let error = state.deleteError { throw error }
            if let replacement = state.replacementDuringDelete {
                state.values[scope] = replacement; state.replacementDuringDelete = nil
            }
            guard state.values[scope]?.revision == revision else { return false }
            state.values.removeValue(forKey: scope); return true
        }
    }
    func count() -> Int { state.withLock { $0.values.count } }
}

let localCustomer = SessionScope(environment: .localDevelopment, profile: .customer)
let now = Date(timeIntervalSince1970: 2_000_000_000)
func fixtureToken(_ byte: UInt8 = 0) -> SessionToken { SessionToken(bytes: Data(repeating: byte, count: 32)) }
func fixtureCSRF() throws -> CSRFToken { try CSRFToken(encoded: fixtureToken(127).encoded) }
func seed(_ vault: SessionVault, byte: UInt8 = 0, at date: Date = now, ttl: Double = 3600) async throws -> UnverifiedSession {
    let ticket = try await vault.beginAuthentication()
    return try await vault.save(token: fixtureToken(byte), expiresAt: date.addingTimeInterval(ttl),
                                csrfToken: fixtureCSRF(), ticket: ticket, now: date)
}

@Suite struct SessionVaultTests {
    @Test func tokensRejectMalformedAndNoncanonicalEncodings() throws {
        for text in ["", String(repeating: "A", count: 44), String(repeating: "A", count: 42), String(repeating: "A", count: 42) + "B", String(repeating: "A", count: 42) + "="] {
            #expect(throws: SessionContractError.invalidValue) { try SessionToken(encoded: text) }
        }
        let value = try SessionToken(encoded: String(repeating: "A", count: 43))
        let roundtrip = value.encoded == String(repeating: "A", count: 43)
        #expect(roundtrip)
    }
    @Test func secretDiagnosticsAndReflectionAreRedacted() throws {
        let token = fixtureToken(17)
        let secret = try fixtureCSRF()
        let diagnosticsSafe = !String(reflecting: token).contains(token.encoded)
            && !String(reflecting: secret).contains(secret.encoded)
        #expect(diagnosticsSafe)
        #expect(Mirror(reflecting: token).children.isEmpty)
        #expect(Mirror(reflecting: secret).children.isEmpty)
    }
    @Test func persistenceContainsOnlyTokenAndBoundedTimeMetadata() async throws {
        let storage = MemoryPersistence()
        let vault = SessionVault(scope: localCustomer, persistence: storage)
        _ = try await seed(vault)
        let blob = try #require(try storage.read(scope: localCustomer))
        #expect(blob.payload.count == 49)
        let csrfNotPersisted = blob.payload.range(of: Data(repeating: 127, count: 32)) == nil
        #expect(csrfNotPersisted)
        #expect(try await vault.requestCredentials(now: now) != nil)
    }
    @Test func restoreHasNoCSRFUntilTheAPIResponseIsConfirmed() async throws {
        let storage = MemoryPersistence()
        let first = SessionVault(scope: localCustomer, persistence: storage)
        _ = try await seed(first)
        let relaunched = SessionVault(scope: localCustomer, persistence: storage)
        let lease = try #require(try await relaunched.restore(now: now))
        #expect(try await relaunched.requestCredentials(now: now) == nil)
        try await relaunched.confirmCSRF(fixtureCSRF(), for: lease, now: now)
        #expect(try await relaunched.requestCredentials(now: now) != nil)
    }
    @Test func expiryDeletesOnlyItsOwnProfileAndEnvironment() async throws {
        let storage = MemoryPersistence()
        let scopes = SessionEnvironment.allCases.flatMap { environment in SessionProfile.allCases.map { SessionScope(environment: environment, profile: $0) } }
        for scope in scopes { _ = try await seed(SessionVault(scope: scope, persistence: storage)) }
        let expired = SessionVault(scope: localCustomer, persistence: storage)
        #expect(try await expired.restore(now: now.addingTimeInterval(3600)) == nil)
        #expect(storage.count() == 3)
        for scope in scopes where scope != localCustomer { #expect(try storage.read(scope: scope) != nil) }
    }
    @Test func invalidAndNonfiniteTimesCannotBeSaved() async throws {
        let vault = SessionVault(scope: localCustomer, persistence: MemoryPersistence())
        for interval in [0, -1, 86_401, Double.infinity, Double.nan] {
            let ticket = try await vault.beginAuthentication()
            await #expect(throws: SessionContractError.invalidValue) {
                try await vault.save(token: fixtureToken(), expiresAt: now.addingTimeInterval(interval),
                                     csrfToken: fixtureCSRF(), ticket: ticket, now: now)
            }
        }
    }
    @Test func corruptedUnsupportedAndOversizedRecordsAreRemoved() async throws {
        for bytes in [Data([1]), Data(repeating: 0, count: 49), Data(repeating: 1, count: 2048)] {
            let storage = MemoryPersistence()
            storage.state.withLock { $0.values[localCustomer] = StoredBlob(revision: Data([1]), payload: bytes) }
            let vault = SessionVault(scope: localCustomer, persistence: storage)
            #expect(try await vault.restore(now: now) == nil)
            #expect(storage.count() == 0)
        }
    }
    @Test func movingClockBackwardsDoesNotExtendAPersistedSession() async throws {
        let storage = MemoryPersistence()
        _ = try await seed(SessionVault(scope: localCustomer, persistence: storage))
        let restarted = SessionVault(scope: localCustomer, persistence: storage)
        #expect(try await restarted.restore(now: now.addingTimeInterval(-1)) == nil)
        #expect(storage.count() == 0)
    }
    @Test func logoutPreventsAnOlderAuthenticationFromSaving() async throws {
        let storage = MemoryPersistence()
        let vault = SessionVault(scope: localCustomer, persistence: storage)
        let ticket = try await vault.beginAuthentication()
        try await vault.removeLocalSession()
        await #expect(throws: SessionContractError.staleOperation) {
            try await vault.save(token: fixtureToken(), expiresAt: now.addingTimeInterval(60),
                                 csrfToken: fixtureCSRF(), ticket: ticket, now: now)
        }
        #expect(storage.count() == 0)
    }
    @Test func anOlder401CannotDeleteANewerLogin() async throws {
        let storage = MemoryPersistence()
        let vault = SessionVault(scope: localCustomer, persistence: storage)
        let old = try await seed(vault)
        _ = try await seed(vault, byte: 1)
        #expect(try await vault.invalidate(old) == false)
        #expect(try await vault.requestCredentials(now: now) != nil)
        #expect(storage.count() == 1)
    }
    @Test func compareAndSwapDoesNotOverwriteAConcurrentWriter() async throws {
        let storage = MemoryPersistence()
        let first = SessionVault(scope: localCustomer, persistence: storage)
        let second = SessionVault(scope: localCustomer, persistence: storage)
        let firstTicket = try await first.beginAuthentication()
        _ = try await seed(second, byte: 2)
        await #expect(throws: SessionContractError.storageConflict) {
            try await first.save(token: fixtureToken(), expiresAt: now.addingTimeInterval(60),
                                 csrfToken: fixtureCSRF(), ticket: firstTicket, now: now)
        }
        #expect(try await second.requestCredentials(now: now) != nil)
    }
    @Test func staleCleanupCannotDeleteAnotherInstancesNewRecord() async throws {
        let storage = MemoryPersistence()
        let first = SessionVault(scope: localCustomer, persistence: storage)
        let old = try await seed(first)
        let second = SessionVault(scope: localCustomer, persistence: storage)
        _ = try await seed(second, byte: 2)
        #expect(try await first.invalidate(old) == false)
        #expect(try await second.requestCredentials(now: now) != nil)
    }
    @Test func lockedStorageIsNotClassifiedAsMissingOrExpired() async throws {
        let storage = MemoryPersistence()
        let vault = SessionVault(scope: localCustomer, persistence: storage)
        _ = try await seed(vault)
        storage.state.withLock { $0.readError = .storageLocked }
        await #expect(throws: SessionContractError.storageLocked) { try await vault.requestCredentials(now: now) }
        storage.state.withLock { $0.readError = nil }
        #expect(try await vault.requestCredentials(now: now) != nil)
        #expect(storage.count() == 1)
    }
    @Test func deletionFailureDoesNotResurrectTheTokenInTheSameProcess() async throws {
        let storage = MemoryPersistence()
        let vault = SessionVault(scope: localCustomer, persistence: storage)
        _ = try await seed(vault)
        storage.state.withLock { $0.deleteError = .storageUnavailable }
        await #expect(throws: SessionContractError.storageUnavailable) { try await vault.removeLocalSession() }
        #expect(try await vault.requestCredentials(now: now) == nil)
        #expect(try await vault.restore(now: now) == nil)
        #expect(storage.count() == 1)
    }
    @Test func logoutReadFailureStillSuppressesRestoration() async throws {
        let storage = MemoryPersistence()
        let vault = SessionVault(scope: localCustomer, persistence: storage)
        _ = try await seed(vault)
        storage.state.withLock { $0.readError = .storageLocked }
        await #expect(throws: SessionContractError.storageLocked) { try await vault.removeLocalSession() }
        storage.state.withLock { $0.readError = nil }
        #expect(try await vault.restore(now: now) == nil)
        #expect(try await vault.requestCredentials(now: now) == nil)
    }
    @Test func explicitLogoutReportsAConcurrentReplacementWithoutDeletingIt() async throws {
        let storage = MemoryPersistence()
        let vault = SessionVault(scope: localCustomer, persistence: storage)
        _ = try await seed(vault)
        let replacement = StoredBlob(revision: Data([9]), payload: Data([1]))
        storage.state.withLock { $0.replacementDuringDelete = replacement }
        await #expect(throws: SessionContractError.storageConflict) { try await vault.removeLocalSession() }
        let newerPreserved = try storage.read(scope: localCustomer)?.revision == replacement.revision
        #expect(newerPreserved)
        #expect(try await vault.restore(now: now) == nil)
    }
}
