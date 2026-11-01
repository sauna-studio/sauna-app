#if os(iOS)
import Foundation
import Security

struct KeychainPersistence: SessionPersistence {
    let service: String
    init(service: String = "studio.sauna.session.v1") { self.service = service }

    private func query(scope: SessionScope, revision: Data? = nil) -> [String: Any] {
        var result: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: scope.account,
            kSecAttrSynchronizable as String: false,
        ]
        if let revision { result[kSecAttrGeneric as String] = revision }
        return result
    }
    func read(scope: SessionScope) throws -> StoredBlob? {
        var query = query(scope: scope)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef? = nil
        // SecItem.h requires a retained-result out-parameter; switching providers would change our CAS contract.
        // This initialized local stays live through the synchronous call; no pointer escapes across an await.
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let fields = result as? [String: Any],
              let payload = fields[kSecValueData as String] as? Data,
              let revision = fields[kSecAttrGeneric as String] as? Data,
              !revision.isEmpty, revision.count <= 128,
              (fields[kSecAttrAccessible as String] as? String) == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String),
              fields[kSecAttrSynchronizable as String] as? Bool != true else {
            throw SessionContractError.storageUnavailable
        }
        return StoredBlob(revision: revision, payload: payload)
    }
    func replace(scope: SessionScope, expectedRevision: Data?, with blob: StoredBlob) throws -> Bool {
        let values: [String: Any] = [
            kSecValueData as String: blob.payload,
            kSecAttrGeneric as String: blob.revision,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status: OSStatus
        if let expectedRevision {
            status = SecItemUpdate(query(scope: scope, revision: expectedRevision) as CFDictionary, values as CFDictionary)
            if status == errSecItemNotFound { return false }
        } else {
            status = SecItemAdd(query(scope: scope).merging(values) { _, new in new } as CFDictionary, nil)
            if status == errSecDuplicateItem { return false }
        }
        try check(status)
        return true
    }
    func delete(scope: SessionScope, revision: Data) throws -> Bool {
        let status = SecItemDelete(query(scope: scope, revision: revision) as CFDictionary)
        if status == errSecItemNotFound { return false }
        try check(status)
        return true
    }
    private func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecInteractionNotAllowed, errSecAuthFailed: throw SessionContractError.storageLocked
        default: throw SessionContractError.storageUnavailable
        }
    }
}

private actor VaultRegistry {
    static let shared = VaultRegistry()
    private var vaults: [SessionScope: SessionVault] = [:]
    func vault(scope: SessionScope) -> SessionVault {
        if let existing = vaults[scope] { return existing }
        let vault = SessionVault(scope: scope, persistence: KeychainPersistence())
        vaults[scope] = vault
        return vault
    }
}

extension SessionVault {
    /// App processes do not share an access group; one actor owns each scope in this process.
    public static func keychain(scope: SessionScope) async -> SessionVault {
        await VaultRegistry.shared.vault(scope: scope)
    }
}
#endif
