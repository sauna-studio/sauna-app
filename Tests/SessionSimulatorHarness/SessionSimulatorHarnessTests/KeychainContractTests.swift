#if targetEnvironment(simulator)
import Foundation
import Security
import XCTest
@testable import SaunaAppleSession

@MainActor final class KeychainContractTests: XCTestCase {
    func testMissingOwnedNamespaceIsReportedAsNotFound() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "studio.sauna.tests.missing." + UUID().uuidString,
            kSecAttrAccount as String: "missing",
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecItemNotFound)
    }
    private let scopes = SessionEnvironment.allCases.flatMap { environment in
        SessionProfile.allCases.map { SessionScope(environment: environment, profile: $0) }
    }
    private func withStorage(_ operation: (KeychainPersistence) async throws -> Void) async throws {
        let storage = KeychainPersistence(service: "studio.sauna.tests.session." + UUID().uuidString)
        let result: Result<Void, any Error>
        do { try await operation(storage); result = .success(()) }
        catch { result = .failure(error) }
        for scope in scopes {
            if let blob = try storage.read(scope: scope) {
                _ = try storage.delete(scope: scope, revision: blob.revision)
                XCTAssertNil(try storage.read(scope: scope))
            }
        }
        try result.get()
    }
    func testRealKeychainIsDeviceOnlyAndDoesNotPersistCSRF() async throws {
        try await withStorage { storage in
            let vault = SessionVault(scope: localCustomer, persistence: storage)
            _ = try await seed(vault)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: storage.service,
                kSecAttrAccount as String: localCustomer.account,
                kSecAttrSynchronizable as String: false,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
            let attributes = try XCTUnwrap(result as? [String: Any])
            let accessibleIsDeviceOnly = (attributes[kSecAttrAccessible as String] as? String) == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            XCTAssertTrue(accessibleIsDeviceOnly)
            XCTAssertFalse(attributes[kSecAttrSynchronizable as String] as? Bool == true)
            let blob = try XCTUnwrap(storage.read(scope: localCustomer))
            XCTAssertEqual(blob.payload.count, 49)
            let csrfAbsent = blob.payload.range(of: Data(repeating: 127, count: 32)) == nil
            XCTAssertTrue(csrfAbsent)
            let restored = SessionVault(scope: localCustomer, persistence: storage)
            let lease = try await restored.restore(now: now)
            XCTAssertNotNil(lease)
            let credentials = try await restored.requestCredentials(now: now)
            XCTAssertNil(credentials)
        }
    }
    func testStaleRevisionCannotDeleteOrOverwriteANewerKeychainItem() async throws {
        try await withStorage { storage in
            let first = SessionVault(scope: localCustomer, persistence: storage)
            let old = try await seed(first)
            let second = SessionVault(scope: localCustomer, persistence: storage)
            _ = try await seed(second, byte: 2)
            XCTAssertFalse(try storage.delete(scope: localCustomer, revision: old.revision))
            let replacement = StoredBlob(revision: Data(UUID().uuidString.utf8), payload: Data(repeating: 7, count: 49))
            XCTAssertFalse(try storage.replace(scope: localCustomer, expectedRevision: old.revision, with: replacement))
            let credentials = try await second.requestCredentials(now: now)
            XCTAssertNotNil(credentials)
            let staleIgnored = try await first.invalidate(old) == false
            XCTAssertTrue(staleIgnored)
            let stillCurrent = try await second.requestCredentials(now: now) != nil
            XCTAssertTrue(stillCurrent)
        }
    }
    func testExpiryAndLogoutLeaveOtherProfilesAndEnvironmentsIntact() async throws {
        try await withStorage { storage in
            for scope in scopes { _ = try await seed(SessionVault(scope: scope, persistence: storage)) }
            let expired = SessionVault(scope: localCustomer, persistence: storage)
            let value = try await expired.restore(now: now.addingTimeInterval(3600))
            XCTAssertNil(value)
            XCTAssertNil(try storage.read(scope: localCustomer))
            for scope in scopes where scope != localCustomer { XCTAssertNotNil(try storage.read(scope: scope)) }
            let staff = SessionScope(environment: .localDevelopment, profile: .staff)
            let vault = SessionVault(scope: staff, persistence: storage)
            _ = try await vault.restore(now: now)
            try await vault.removeLocalSession()
            XCTAssertNil(try storage.read(scope: staff))
            for scope in scopes where scope.environment == .production { XCTAssertNotNil(try storage.read(scope: scope)) }
        }
    }
    func testWeakerAccessibilityIsNotSilentlyUsed() async throws {
        try await withStorage { storage in
            let vault = SessionVault(scope: localCustomer, persistence: storage)
            let lease = try await seed(vault)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: storage.service,
                kSecAttrAccount as String: localCustomer.account,
                kSecAttrSynchronizable as String: false,
                kSecAttrGeneric as String: lease.revision,
            ]
            XCTAssertEqual(SecItemUpdate(query as CFDictionary, [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary), errSecSuccess)
            XCTAssertThrowsError(try storage.read(scope: localCustomer)) { error in
                XCTAssertTrue(error as? SessionContractError == .storageUnavailable)
            }
            XCTAssertTrue(try storage.delete(scope: localCustomer, revision: lease.revision))
        }
    }
    func testPublicFactoryKeepsOneActorPerScope() async {
        let first = await SessionVault.keychain(scope: localCustomer)
        let same = await SessionVault.keychain(scope: localCustomer)
        let staff = await SessionVault.keychain(scope: SessionScope(environment: .localDevelopment, profile: .staff))
        XCTAssertTrue(first === same)
        XCTAssertFalse(first === staff)
    }
}
#endif
