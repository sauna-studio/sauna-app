import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

public enum SessionClientError: Error, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case unavailableEnvironment, staleSession, invalidResponse, unauthorized, forbidden, rateLimited
    case serviceUnavailable, network, timedOut, cancelled, storageLocked, storageUnavailable, storageConflict
    public var description: String { "SessionClientError(\(name))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    private var name: String {
        switch self {
        case .unavailableEnvironment: "unavailableEnvironment"
        case .staleSession: "staleSession"
        case .invalidResponse: "invalidResponse"
        case .unauthorized: "unauthorized"
        case .forbidden: "forbidden"
        case .rateLimited: "rateLimited"
        case .serviceUnavailable: "serviceUnavailable"
        case .network: "network"
        case .timedOut: "timedOut"
        case .cancelled: "cancelled"
        case .storageLocked: "storageLocked"
        case .storageUnavailable: "storageUnavailable"
        case .storageConflict: "storageConflict"
        }
    }
}

public struct VerifiedSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let userID: UUID
    public let expiresAt: Date
    public var description: String { "VerifiedSession(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

public struct SessionClient: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let vault: SessionVault
    private let transport: any ClientTransport
    private let clock: @Sendable () -> Date
    public var description: String { "SessionClient(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    public init(vault: SessionVault) throws {
        // Streaming installs a task delegate; buffered mode preserves the redirect contract verified here.
        try self.init(vault: vault, transport: URLSessionTransport(configuration: .init(
            session: SessionTransport.makeEphemeralSession(), httpBodyProcessingMode: .buffered)), clock: { .now })
    }

    init(vault: SessionVault, transport: any ClientTransport, clock: @escaping @Sendable () -> Date) throws {
        guard vault.scope.environment == .localDevelopment else { throw SessionClientError.unavailableEnvironment }
        self.vault = vault; self.transport = transport; self.clock = clock
    }

    public func revalidate(_ lease: UnverifiedSession) async throws -> VerifiedSession {
        do {
            try await vault.prepareRevalidation(lease, now: clock())
            let client = client(lease: lease)
            let origin: Operations.getAuthSession.Input.Headers.OriginPayload = vault.scope.profile == .customer
                ? .http_colon__sol__sol_localhost_colon_5173 : .http_colon__sol__sol_localhost_colon_5174
            let result = try await client.getAuthSession(headers: .init(Origin: origin))
            guard case .ok(let response) = result, case .json(let metadata) = response.body,
                  let userID = UUID(uuidString: metadata.userID), userID.uuidString == metadata.userID,
                  userID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
                throw SessionClientError.invalidResponse
            }
            let now = clock()
            let expiresAt = Date(timeIntervalSince1970: Double(metadata.expiresAtUnixSeconds))
            guard now.timeIntervalSince1970.isFinite, expiresAt > now,
                  expiresAt.timeIntervalSince(now) <= 86_400, expiresAt <= lease.expiresAt else {
                throw SessionClientError.invalidResponse
            }
            let csrf: CSRFToken
            do { csrf = try CSRFToken(encoded: metadata.csrfToken) }
            catch { throw SessionClientError.invalidResponse }
            try Task.checkCancellation()
            try await vault.confirmRevalidation(csrf, for: lease, expiresAt: expiresAt, clock: clock)
            return VerifiedSession(userID: userID, expiresAt: expiresAt)
        } catch {
            let failure = Self.redact(error)
            if failure == .unauthorized || failure == .staleSession {
                do { _ = try await vault.invalidate(lease) }
                catch { throw Self.redact(error) }
            }
            throw failure
        }
    }

    public func logout(_ lease: UnverifiedSession) async throws {
        let failure: SessionClientError?
        do {
            let credentials = try await vault.credentials(for: lease, now: clock())
            let client = client(lease: lease, csrf: credentials.csrfToken)
            let origin: Operations.logoutSession.Input.Headers.OriginPayload = vault.scope.profile == .customer
                ? .http_colon__sol__sol_localhost_colon_5173 : .http_colon__sol__sol_localhost_colon_5174
            let result = try await client.logoutSession(headers: .init(Origin: origin,
                X_hyphen_Sauna_hyphen_CSRF: credentials.csrfToken.encoded))
            guard case .noContent = result else { throw SessionClientError.invalidResponse }
            try Task.checkCancellation()
            failure = nil
        } catch { failure = Self.redact(error) }
        do {
            // Clearing an arbitrary current session would let an old logout erase a new login.
            let removed = try await vault.invalidate(lease)
            if let failure { throw failure }
            guard removed else { throw SessionClientError.staleSession }
        } catch { throw Self.redact(error) }
    }

    private func client(lease: UnverifiedSession, csrf: CSRFToken? = nil) -> Client {
        Client(serverURL: SessionOperationTransport.backend, transport: SessionOperationTransport(
            underlying: transport, scope: vault.scope, token: lease.token, csrf: csrf))
    }

    private static func redact(_ error: any Error) -> SessionClientError {
        if let error = error as? SessionClientError { return error }
        if let error = error as? ClientError { return redact(error.underlyingError) }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            default: return .network
            }
        }
        if let error = error as? SessionContractError {
            switch error {
            case .storageLocked: return .storageLocked
            case .storageUnavailable: return .storageUnavailable
            case .storageConflict: return .storageConflict
            case .staleOperation: return .staleSession
            case .invalidValue: return .invalidResponse
            }
        }
        if error is CancellationError || Task.isCancelled { return .cancelled }
        return .invalidResponse
    }
}

struct SessionOperationTransport: ClientTransport {
    static let backend = URL(string: "http://127.0.0.1:8080")!
    let underlying: any ClientTransport
    let scope: SessionScope
    let token: SessionToken
    let csrf: CSRFToken?

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let isSession = operationID == "getAuthSession" && request.method == .get && request.path == "/auth/session" && csrf == nil
        let isLogout = operationID == "logoutSession" && request.method == .post && request.path == "/auth/logout" && csrf != nil
        let origin = "http://localhost:\(scope.profile == .customer ? 5173 : 5174)"
        let encodedOrigin = "http%3A%2F%2Flocalhost%3A\(scope.profile == .customer ? 5173 : 5174)"
        guard scope.environment == .localDevelopment, baseURL == Self.backend, body == nil,
              isSession || isLogout, request.headerFields.filter({ $0.name == .origin }).count == 1,
              request.scheme == nil, request.authority == nil, request.headerFields[HTTPField.Name("Host")!] == nil,
              [origin, encodedOrigin].contains(request.headerFields[.origin] ?? ""),
              request.headerFields[.cookie] == nil,
              request.headerFields[HTTPField.Name("X-Sauna-CSRF")!] == csrf?.encoded else {
            throw SessionClientError.invalidResponse
        }
        var request = request
        // URI encoding changes Origin and cookie wire semantics; track sauna-api#51 before removing this normalization.
        request.headerFields[.origin] = origin
        request.headerFields[.cookie] = "__Host-sauna-\(scope.profile.rawValue)-session=\(token.encoded)"
        let (response, body) = try await underlying.send(request, body: nil, baseURL: baseURL, operationID: operationID)
        try Task.checkCancellation()
        switch response.status.code {
        case 401: throw SessionClientError.unauthorized
        case 403: throw SessionClientError.forbidden
        case 429: throw SessionClientError.rateLimited
        case 503: throw SessionClientError.serviceUnavailable
        case isSession ? 200 : 204: break
        default: throw SessionClientError.invalidResponse
        }
        let cookies = response.headerFields.filter { $0.name == .setCookie }.map(\.value)
        if isSession {
            guard cookies.isEmpty, let body else { throw SessionClientError.invalidResponse }
            let bytes = try await ArraySlice<UInt8>(collecting: body, upTo: 16_384)
            return (response, HTTPBody(bytes))
        }
        do {
            _ = try SessionCookieContract.acceptLocalResponse(scope: scope,
                url: Self.backend.appending(path: "/auth/logout"), statusCode: 204, setCookieValues: cookies)
            if let body, !(try await ArraySlice(collecting: body, upTo: 0)).isEmpty { throw SessionClientError.invalidResponse }
        } catch { throw SessionClientError.invalidResponse }
        return (response, nil)
    }
}
