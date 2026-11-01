import Foundation

public enum SessionCookieUpdate: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case issued(token: SessionToken, expiresAt: Date)
    case cleared
    public var description: String { "SessionCookieUpdate(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

public enum SessionCookieContract {
    /// Header folding loses cookie boundaries; callers must preserve individual Set-Cookie field values.
    public static func acceptLocalResponse(scope: SessionScope, url: URL, statusCode: Int,
                                           setCookieValues: [String], metadataExpiresAt: Date? = nil,
                                           now: Date = .now) throws -> SessionCookieUpdate {
        guard scope.environment == .localDevelopment,
              url.scheme == "http", url.host == "127.0.0.1", url.port == 8080,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              setCookieValues.count == 1, let header = setCookieValues.first,
              header.utf8.count <= 512, header.utf8.allSatisfy({ (32...126).contains($0) }),
              !header.contains(",") else { throw SessionContractError.invalidValue }
        let parts = header.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 6, let first = parts.first else { throw SessionContractError.invalidValue }
        let pair = first.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2, pair[0] == "__Host-sauna-\(scope.profile.rawValue)-session" else { throw SessionContractError.invalidValue }
        var attributes: [String: String] = [:]
        for part in parts.dropFirst() {
            let fields = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(fields[0]).lowercased()
            guard attributes[key] == nil else { throw SessionContractError.invalidValue }
            attributes[key] = fields.count == 2 ? String(fields[1]) : ""
        }
        guard Set(attributes.keys) == ["path", "max-age", "secure", "httponly", "samesite"],
              attributes["path"] == "/", attributes["secure"] == "", attributes["httponly"] == "",
              attributes["samesite"]?.lowercased() == "strict",
              let ageText = attributes["max-age"], let age = Int(ageText), String(age) == ageText else {
            throw SessionContractError.invalidValue
        }
        if statusCode == 200, url.path == "/auth/passkeys/authentication/finish" {
            guard (1...86_400).contains(age), let expiry = metadataExpiresAt,
                  now.timeIntervalSince1970.isFinite, expiry.timeIntervalSince1970.isFinite,
                  expiry > now else { throw SessionContractError.invalidValue }
            let token = try SessionToken(encoded: String(pair[1]))
            return .issued(token: token, expiresAt: min(expiry, now.addingTimeInterval(Double(age))))
        }
        let clears: Set<String> = ["/auth/logout", "/auth/sessions/revoke-all", "/auth/passkeys/addition/finish", "/auth/passkeys/revocation/finish"]
        guard statusCode == 204, clears.contains(url.path), age == 0, pair[1].isEmpty else {
            throw SessionContractError.invalidValue
        }
        return .cleared
    }
}
