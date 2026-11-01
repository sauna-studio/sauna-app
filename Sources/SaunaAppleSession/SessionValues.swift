public import Foundation

public enum SessionContractError: Error, Sendable, Equatable {
    case invalidValue, storageUnavailable, storageLocked, storageConflict, staleOperation
}

public enum SessionEnvironment: String, Sendable, CaseIterable { case localDevelopment, production }
public enum SessionProfile: String, Sendable, CaseIterable { case customer, staff }

public struct SessionScope: Sendable, Hashable {
    public let environment: SessionEnvironment
    public let profile: SessionProfile
    public init(environment: SessionEnvironment, profile: SessionProfile) {
        self.environment = environment
        self.profile = profile
    }
    var account: String { "v1.\(environment.rawValue).\(profile.rawValue)" }
}

public struct SessionToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let bytes: Data
    public init(encoded: String) throws {
        guard encoded.utf8.count == 43,
              encoded.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let bytes = Data(base64Encoded: encoded.replacing("-", with: "+").replacing("_", with: "/") + "="),
              bytes.count == 32, Self.encode(bytes) == encoded else { throw SessionContractError.invalidValue }
        self.bytes = bytes
    }
    init(bytes: Data) { self.bytes = bytes }
    public var encoded: String { Self.encode(bytes) }
    private static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
    }
    public var description: String { "SessionToken(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

public struct CSRFToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: SessionToken
    public init(encoded: String) throws { value = try SessionToken(encoded: encoded) }
    public var encoded: String { value.encoded }
    public var description: String { "CSRFToken(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

public struct SessionWriteTicket: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let scope: SessionScope
    let generation: UUID
    let expectedRevision: Data?
    public var description: String { "SessionWriteTicket(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// Restoring bytes does not establish authentication; only the API can validate a session.
public struct UnverifiedSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let token: SessionToken
    public let expiresAt: Date
    let scope: SessionScope
    let generation: UUID
    let revision: Data
    public var description: String { "UnverifiedSession(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

public struct SessionRequestCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let token: SessionToken
    public let csrfToken: CSRFToken
    public let lease: UnverifiedSession
    public var description: String { "SessionRequestCredentials(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}
