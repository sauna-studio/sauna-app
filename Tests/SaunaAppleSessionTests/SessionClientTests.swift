import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import Synchronization
import Testing
@testable import SaunaAppleSession

private let clientNow = Date(timeIntervalSince1970: 2_000_000_000)
private let clientScope = SessionScope(environment: .localDevelopment, profile: .customer)
private let clientUser = UUID(uuidString: "019A3DDD-4056-7000-8000-000000000001")!
private func clientToken(_ byte: UInt8) throws -> SessionToken {
    try SessionToken(encoded: Data(repeating: byte, count: 32).base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: ""))
}
private func metadata(userID: String = clientUser.uuidString, expiry: Int64 = 2_000_000_500, csrf: String? = nil) throws -> String {
    let csrf = try csrf ?? clientToken(3).encoded
    let data = try JSONSerialization.data(withJSONObject: ["userID": userID, "expiresAtUnixSeconds": expiry, "csrfToken": csrf])
    return String(decoding: data, as: UTF8.self)
}
private func clientSeed(_ vault: SessionVault, byte: UInt8 = 1) async throws -> UnverifiedSession {
    let ticket = try await vault.beginAuthentication()
    return try await vault.save(token: clientToken(byte), expiresAt: clientNow.addingTimeInterval(600),
        csrfToken: CSRFToken(encoded: clientToken(3).encoded), ticket: ticket, now: clientNow)
}
private struct ReplyTransport: ClientTransport {
    let reply: @Sendable (HTTPRequest, String) async throws -> (HTTPResponse, HTTPBody?)
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        try await reply(request, operationID)
    }
}
private func jsonReply(_ body: String, status: Int = 200, headers: HTTPFields = [:]) -> (HTTPResponse, HTTPBody?) {
    var headers = headers; headers[.contentType] = "application/json"
    return (HTTPResponse(status: .init(code: status), headerFields: headers), HTTPBody(body.utf8))
}
private func clearingReply(profile: SessionProfile = .customer) -> (HTTPResponse, HTTPBody?) {
    (HTTPResponse(status: .noContent, headerFields: [.setCookie: "__Host-sauna-\(profile.rawValue)-session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict"]), nil)
}
private actor ResponseGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var reached = false
    private var released = false
    func suspend() async {
        reached = true
        if released { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func waitForRequest() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !reached && ContinuousClock.now < deadline { await Task.yield() }
        return reached
    }
    func release() { released = true; waiting?.resume(); waiting = nil }
}
private final class ClockProgress: Sendable { let calls = Mutex(0) }
private final class RequestObservation: Sendable { let value = Mutex(false) }

@Suite struct SessionClientTests {
    @Test func revalidationUsesProfileOriginAndOnlyThenMakesCSRFUsable() async throws {
        for profile in SessionProfile.allCases {
            let scope = SessionScope(environment: .localDevelopment, profile: profile)
            let storage = MemoryPersistence(); let vault = SessionVault(scope: scope, persistence: storage)
            _ = try await clientSeed(vault)
            let lease = try #require(await vault.restore(now: clientNow))
            #expect(try await vault.requestCredentials(now: clientNow) == nil)
            let observation = RequestObservation()
            let body = try metadata()
            let transport = ReplyTransport { request, operation in
                let expectedCookie = try "__Host-sauna-\(profile.rawValue)-session=\(clientToken(1).encoded)"
                observation.value.withLock { $0 = operation == "getAuthSession" && request.method == .get
                    && request.path == "/auth/session" && request.headerFields[.origin] == "http://localhost:\(profile == .customer ? 5173 : 5174)"
                    && request.headerFields[.cookie] == expectedCookie && request.headerFields[HTTPField.Name("X-Sauna-CSRF")!] == nil }
                return jsonReply(body)
            }
            let client = try SessionClient(vault: vault, transport: transport, clock: { clientNow })
            let verified = try await client.revalidate(lease)
            #expect(verified.userID == clientUser)
            #expect(verified.expiresAt == clientNow.addingTimeInterval(500))
            #expect(observation.value.withLock { $0 })
            #expect(try await vault.requestCredentials(now: clientNow) != nil)
        }
    }
    @Test func serverMetadataCapsCSRFValidityAndIsCheckedAgainAtConfirmation() async throws {
        let vault = SessionVault(scope: clientScope, persistence: MemoryPersistence())
        let lease = try await clientSeed(vault); let body = try metadata()
        let transport = ReplyTransport { _, _ in jsonReply(body) }
        let client = try SessionClient(vault: vault, transport: transport, clock: { clientNow })
        _ = try await client.revalidate(lease)
        #expect(try await vault.requestCredentials(now: clientNow.addingTimeInterval(499)) != nil)
        #expect(try await vault.requestCredentials(now: clientNow.addingTimeInterval(500)) == nil)
        let progress = ClockProgress()
        let later = try SessionClient(vault: vault, transport: transport, clock: {
            progress.calls.withLock { count in count += 1; return clientNow.addingTimeInterval(count >= 3 ? 501 : 0) }
        })
        await #expect(throws: SessionClientError.staleSession) { try await later.revalidate(lease) }
        #expect(try await vault.requestCredentials(now: clientNow) == nil)
    }
    @Test func productionAndForeignScopeAreRejectedBeforeTransport() async throws {
        let production = SessionVault(scope: .init(environment: .production, profile: .customer), persistence: MemoryPersistence())
        #expect(throws: SessionClientError.unavailableEnvironment) { try SessionClient(vault: production) }
        let vault = SessionVault(scope: clientScope, persistence: MemoryPersistence())
        let foreign = SessionVault(scope: .init(environment: .localDevelopment, profile: .staff), persistence: MemoryPersistence())
        let lease = try await clientSeed(foreign)
        let called = RequestObservation()
        let client = try SessionClient(vault: vault, transport: ReplyTransport { _, _ in
            called.value.withLock { $0 = true }; return jsonReply("{}")
        }, clock: { clientNow })
        await #expect(throws: SessionClientError.staleSession) { try await client.revalidate(lease) }
        #expect(!called.value.withLock { $0 })
    }
    @Test func expiredLeaseIsRemovedBeforeAnyTransportRequest() async throws {
        let storage = MemoryPersistence(); let vault = SessionVault(scope: clientScope, persistence: storage)
        let lease = try await clientSeed(vault); let called = RequestObservation()
        let client = try SessionClient(vault: vault, transport: ReplyTransport { _, _ in
            called.value.withLock { $0 = true }; return jsonReply("{}")
        }, clock: { clientNow.addingTimeInterval(600) })
        await #expect(throws: SessionClientError.staleSession) { try await client.revalidate(lease) }
        #expect(storage.count() == 0)
        #expect(!called.value.withLock { $0 })
    }
    @Test func invalidMetadataNeverConfirmsCSRF() async throws {
        let bodies = try [metadata(userID: "invalid"), metadata(userID: clientUser.uuidString.lowercased()),
            metadata(userID: "00000000-0000-0000-0000-000000000000"), metadata(expiry: 2_000_000_000),
            metadata(expiry: 2_000_000_601), metadata(expiry: Int64.max), metadata(csrf: "bad"),
            "{\"userID\":\"unexpected\"}", "{invalid", String(repeating: "x", count: 16_385)]
        for body in bodies {
            let vault = SessionVault(scope: clientScope, persistence: MemoryPersistence())
            let lease = try await clientSeed(vault)
            let client = try SessionClient(vault: vault, transport: ReplyTransport { _, _ in jsonReply(body) }, clock: { clientNow })
            await #expect(throws: SessionClientError.invalidResponse) { try await client.revalidate(lease) }
            #expect(try await vault.requestCredentials(now: clientNow) == nil)
        }
    }
    @Test func GETRejectsAnySetCookieInsteadOfRenewingTheSession() async throws {
        let vault = SessionVault(scope: clientScope, persistence: MemoryPersistence())
        let lease = try await clientSeed(vault); let body = try metadata()
        let client = try SessionClient(vault: vault, transport: ReplyTransport { _, _ in
            jsonReply(body, headers: [.setCookie: "anything=value"])
        }, clock: { clientNow })
        await #expect(throws: SessionClientError.invalidResponse) { try await client.revalidate(lease) }
        #expect(try await vault.requestCredentials(now: clientNow) == nil)
    }
    @Test func errorStatusesAreFixedAnd401InvalidatesEvenMalformedErrorBodies() async throws {
        let cases: [(Int, SessionClientError)] = [(401, .unauthorized), (403, .forbidden), (429, .rateLimited), (503, .serviceUnavailable), (302, .invalidResponse)]
        for (status, expected) in cases {
            let storage = MemoryPersistence(); let vault = SessionVault(scope: clientScope, persistence: storage)
            let lease = try await clientSeed(vault)
            let client = try SessionClient(vault: vault, transport: ReplyTransport { _, _ in
                jsonReply("not JSON or a problem body", status: status)
            }, clock: { clientNow })
            await #expect(throws: expected) { try await client.revalidate(lease) }
            #expect(storage.count() == (status == 401 ? 0 : 1))
            #expect(try await vault.requestCredentials(now: clientNow) == nil)
        }
    }
    @Test func networkTimeoutAndCancellationNeverReturnRawErrorsOrAuthenticate() async throws {
        for (code, expected) in [(URLError.Code.notConnectedToInternet, SessionClientError.network), (.timedOut, .timedOut), (.cancelled, .cancelled)] {
            let vault = SessionVault(scope: clientScope, persistence: MemoryPersistence())
            let lease = try await clientSeed(vault)
            let client = try SessionClient(vault: vault, transport: ReplyTransport { _, _ in
                throw URLError(code, userInfo: [NSLocalizedDescriptionKey: "SYNTHETIC_SECRET_MUST_NOT_ESCAPE"])
            }, clock: { clientNow })
            await #expect(throws: expected) { try await client.revalidate(lease) }
            #expect(try await vault.requestCredentials(now: clientNow) == nil)
            #expect(!String(reflecting: expected).contains("SYNTHETIC_SECRET"))
        }
    }
    @Test func delayed200And401CannotAffectANewerLogin() async throws {
        for status in [200, 401] {
            let vault = SessionVault(scope: clientScope, persistence: MemoryPersistence())
            let old = try await clientSeed(vault); let gate = ResponseGate(); let body = try metadata()
            let client = try SessionClient(vault: vault, transport: ReplyTransport { _, _ in
                await gate.suspend(); return jsonReply(body, status: status)
            }, clock: { clientNow })
            let task = Task { try await client.revalidate(old) }
            try #require(await gate.waitForRequest())
            let newer = try await clientSeed(vault, byte: 2)
            await gate.release()
            await #expect(throws: status == 200 ? SessionClientError.staleSession : .unauthorized) { try await task.value }
            let credentials = try #require(await vault.requestCredentials(now: clientNow))
            let newerSurvives = credentials.token.encoded == newer.token.encoded
            #expect(newerSurvives)
        }
    }
    @Test func cancellationWhileResponseIsPendingNeverConfirmsCSRF() async throws {
        let vault = SessionVault(scope: clientScope, persistence: MemoryPersistence())
        let lease = try await clientSeed(vault); let gate = ResponseGate(); let body = try metadata()
        let client = try SessionClient(vault: vault, transport: ReplyTransport { _, _ in
            await gate.suspend(); return jsonReply(body)
        }, clock: { clientNow })
        let task = Task { try await client.revalidate(lease) }
        try #require(await gate.waitForRequest()); task.cancel(); await gate.release()
        await #expect(throws: SessionClientError.cancelled) { try await task.value }
        #expect(try await vault.requestCredentials(now: clientNow) == nil)
    }
    @Test func logoutUsesSameLeaseCredentialsAndClearsLocalSessionOnly() async throws {
        for profile in SessionProfile.allCases {
            let scope = SessionScope(environment: .localDevelopment, profile: profile)
            let storage = MemoryPersistence(); let vault = SessionVault(scope: scope, persistence: storage)
            let lease = try await clientSeed(vault); let observed = RequestObservation()
            let client = try SessionClient(vault: vault, transport: ReplyTransport { request, operation in
                let expectedCookie = try "__Host-sauna-\(profile.rawValue)-session=\(clientToken(1).encoded)"
                let expectedCSRF = try clientToken(3).encoded
                observed.value.withLock { $0 = operation == "logoutSession" && request.method == .post
                    && request.path == "/auth/logout" && request.headerFields[.cookie] == expectedCookie
                    && request.headerFields[HTTPField.Name("X-Sauna-CSRF")!] == expectedCSRF }
                return clearingReply(profile: profile)
            }, clock: { clientNow })
            try await client.logout(lease)
            #expect(observed.value.withLock { $0 })
            #expect(storage.count() == 0)
            #expect(try await vault.restore(now: clientNow) == nil)
        }
    }
    @Test func failedOrCancelledLogoutClearsLocalButReportsRemoteFailure() async throws {
        let cases: [(Int, SessionClientError)] = [(401, .unauthorized), (403, .forbidden), (429, .rateLimited), (503, .serviceUnavailable), (302, .invalidResponse)]
        for (status, error) in cases {
            let vault = SessionVault(scope: clientScope, persistence: MemoryPersistence()); let lease = try await clientSeed(vault)
            let client = try SessionClient(vault: vault, transport: ReplyTransport { _, _ in jsonReply("", status: status) }, clock: { clientNow })
            await #expect(throws: error) { try await client.logout(lease) }
            #expect(try await vault.restore(now: clientNow) == nil)
        }
        for code in [URLError.Code.cancelled, .timedOut, .notConnectedToInternet] {
            let vault = SessionVault(scope: clientScope, persistence: MemoryPersistence()); let lease = try await clientSeed(vault)
            let client = try SessionClient(vault: vault, transport: ReplyTransport { _, _ in throw URLError(code) }, clock: { clientNow })
            await #expect(throws: SessionClientError.self) { try await client.logout(lease) }
            #expect(try await vault.restore(now: clientNow) == nil)
        }
    }
    @Test func logoutDeletionFailureIsExplicitAndCannotRestoreOldToken() async throws {
        let storage = MemoryPersistence(); let vault = SessionVault(scope: clientScope, persistence: storage); let lease = try await clientSeed(vault)
        storage.state.withLock { $0.deleteError = .storageUnavailable }
        let client = try SessionClient(vault: vault, transport: ReplyTransport { _, _ in clearingReply() }, clock: { clientNow })
        await #expect(throws: SessionClientError.storageUnavailable) { try await client.logout(lease) }
        #expect(try await vault.restore(now: clientNow) == nil)
        #expect(storage.count() == 1)
    }
    @Test func oldLogoutCannotClearANewerLoginAfterAnyResponse() async throws {
        for status in [204, 401, 503] {
            let vault = SessionVault(scope: clientScope, persistence: MemoryPersistence()); let old = try await clientSeed(vault)
            let gate = ResponseGate()
            let client = try SessionClient(vault: vault, transport: ReplyTransport { _, _ in
                await gate.suspend(); return status == 204 ? clearingReply() : jsonReply("", status: status)
            }, clock: { clientNow })
            let task = Task { try await client.logout(old) }; try #require(await gate.waitForRequest())
            let newer = try await clientSeed(vault, byte: 2); await gate.release()
            await #expect(throws: SessionClientError.self) { try await task.value }
            let credentials = try #require(await vault.requestCredentials(now: clientNow))
            let newerSurvives = credentials.token.encoded == newer.token.encoded
            #expect(newerSurvives)
        }
    }
    @Test func missingDuplicateFoldedAndWrongProfileLogoutCookiesAreRejected() async throws {
        for cookies: [String] in [[], ["__Host-sauna-staff-session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict"],
            ["__Host-sauna-customer-session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict", "extra=value"],
            ["__Host-sauna-customer-session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict, extra=value"]] {
            let vault = SessionVault(scope: clientScope, persistence: MemoryPersistence()); let lease = try await clientSeed(vault)
            let client = try SessionClient(vault: vault, transport: ReplyTransport { _, _ in
                let fields = HTTPFields(cookies.map { HTTPField(name: .setCookie, value: $0) })
                return (HTTPResponse(status: .noContent, headerFields: fields), nil)
            }, clock: { clientNow })
            await #expect(throws: SessionClientError.invalidResponse) { try await client.logout(lease) }
            #expect(try await vault.restore(now: clientNow) == nil)
        }
    }
    @Test func operationGuardRejectsChangedDestinationsMethodsPathsAndProfiles() async throws {
        let observed = RequestObservation()
        let transport = SessionOperationTransport(underlying: ReplyTransport { _, _ in
            observed.value.withLock { $0 = true }; return jsonReply("{}")
        }, scope: clientScope, token: try clientToken(1), csrf: nil)
        let requests: [(HTTPRequest, URL, String)] = [
            (HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/auth/session", headerFields: [.origin: "http://localhost:5173"]), URL(string: "http://example.com")!, "getAuthSession"),
            (HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/auth/session?x=1", headerFields: [.origin: "http://localhost:5173"]), SessionOperationTransport.backend, "getAuthSession"),
            (HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/auth/session", headerFields: [.origin: "http://localhost:5173"]), SessionOperationTransport.backend, "getAuthSession"),
            (HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/auth/session", headerFields: [.origin: "http://localhost:5174"]), SessionOperationTransport.backend, "getAuthSession"),
            (HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/health", headerFields: [.origin: "http://localhost:5173"]), SessionOperationTransport.backend, "getHealth")]
        let extraHeaders: [HTTPFields] = [
            [.origin: "http%3A%2F%2Flocalhost%3A5174"],
            [.origin: "http%253A%252F%252Flocalhost%253A5173"],
            HTTPFields([HTTPField(name: .origin, value: "http://localhost:5173"), HTTPField(name: .origin, value: "http://localhost:5173")]),
            [.origin: "http://localhost:5173", HTTPField.Name("Host")!: "external.example"]]
        for fields in extraHeaders {
            let request = HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/auth/session", headerFields: fields)
            await #expect(throws: SessionClientError.invalidResponse) { try await transport.send(request, body: nil, baseURL: SessionOperationTransport.backend, operationID: "getAuthSession") }
        }
        for (request, base, operation) in requests {
            await #expect(throws: SessionClientError.invalidResponse) { try await transport.send(request, body: nil, baseURL: base, operationID: operation) }
        }
        #expect(!observed.value.withLock { $0 })
    }
}

private struct OwnedLoopbackRoute: ClientTransport {
    let underlying: URLSessionTransport
    let url: URL
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        try await underlying.send(request, body: body, baseURL: url, operationID: operationID)
    }
}
@Suite(.serialized) struct SessionClientWireTests {
    @Test func generatedOperationsSendLiteralProfileOriginsOverRealHTTP() async throws {
        for profile in SessionProfile.allCases {
            let observation = RequestObservation(); let body = try metadata()
            let cookie = try "__Host-sauna-\(profile.rawValue)-session=\(clientToken(1).encoded)"
            let csrf = try clientToken(3).encoded
            let fixture = try LoopbackFixture { request in
                let hasOrigin = request.lowercased().contains("\r\norigin: http://localhost:\(profile == .customer ? 5173 : 5174)\r\n")
                let hasCookie = request.contains("\r\nCookie: \(cookie)\r\n") || request.contains("\r\ncookie: \(cookie)\r\n")
                if request.hasPrefix("GET /auth/session ") {
                    observation.value.withLock { $0 = hasOrigin && hasCookie }
                    return WireReply(status: "200 OK", headers: "Content-Type: application/json\r\n", body: body)
                }
                if request.hasPrefix("POST /auth/logout ") {
                    let hasCSRF = request.lowercased().contains("\r\nx-sauna-csrf: \(csrf.lowercased())\r\n")
                    observation.value.withLock { $0 = $0 && hasOrigin && hasCookie && hasCSRF }
                    return WireReply(status: "204 No Content", headers: "Set-Cookie: __Host-sauna-\(profile.rawValue)-session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict\r\n")
                }
                return WireReply(status: "400 Bad Request")
            }
            let session = SessionTransport.makeEphemeralSession()
            let result: Result<Void, any Error>
            do {
                let vault = SessionVault(scope: .init(environment: .localDevelopment, profile: profile), persistence: MemoryPersistence())
                _ = try await clientSeed(vault)
                let lease = try #require(await vault.restore(now: clientNow))
                let route = OwnedLoopbackRoute(underlying: URLSessionTransport(configuration: .init(session: session, httpBodyProcessingMode: .buffered)), url: fixture.url(""))
                let client = try SessionClient(vault: vault, transport: route, clock: { clientNow })
                _ = try await client.revalidate(lease)
                try await client.logout(lease)
                #expect(observation.value.withLock { $0 })
                result = .success(())
            } catch { result = .failure(error) }
            session.invalidateAndCancel(); await fixture.stop(); try result.get()
        }
    }
    @Test func generatedClientAndBufferedURLSessionNeverForwardSecretsOnRedirect() async throws {
        let observed = RequestObservation()
        let fixture = try LoopbackFixture { request in
            guard request.hasPrefix("GET /auth/session ") else { return nil }
            observed.value.withLock { $0 = request.lowercased().contains("\r\ncookie: __host-sauna-customer-session=")
                && request.lowercased().contains("\r\norigin: http://localhost:5173") }
            return WireReply(status: "302 Found", headers: "Location: /target\r\n")
        }
        let session = SessionTransport.makeEphemeralSession()
        let result: Result<Void, any Error>
        do {
            let vault = SessionVault(scope: clientScope, persistence: MemoryPersistence()); let lease = try await clientSeed(vault)
            let urlSession = URLSessionTransport(configuration: .init(session: session, httpBodyProcessingMode: .buffered))
            let route = OwnedLoopbackRoute(underlying: urlSession, url: fixture.url(""))
            let client = try SessionClient(vault: vault, transport: route, clock: { clientNow })
            await #expect(throws: SessionClientError.invalidResponse) { try await client.revalidate(lease) }
            #expect(observed.value.withLock { $0 })
            #expect(fixture.counts().target == 0)
            result = .success(())
        } catch { result = .failure(error) }
        session.invalidateAndCancel(); await fixture.stop(); try result.get()
    }
}
