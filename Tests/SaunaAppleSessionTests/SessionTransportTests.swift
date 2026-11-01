import Dispatch
import Foundation
import Network
import Synchronization
import Testing
@testable import SaunaAppleSession

struct WireReply: Sendable { let status: String; var headers = ""; var body = "" }
private enum FixtureError: Error { case listenerFailure, stopTimedOut }
private final class SharedFixtureState: Sendable {
    struct State: Sendable {
        var stopping = false
        var targetRequests = 0
        var cacheRequests = 0
        var port: UInt16?
        var connections: [NWConnection] = []
    }
    let value = Mutex(State())
}
private final class StopCompletion: Sendable {
    private let continuation: Mutex<CheckedContinuation<Bool, Never>?>
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = Mutex(continuation) }
    func finish(_ cancelled: Bool) {
        let pending = continuation.withLock { stored in let value = stored; stored = nil; return value }
        pending?.resume(returning: cancelled)
    }
}

final class LoopbackFixture: Sendable {
    let port: UInt16
    private let state = SharedFixtureState()
    private let listener: NWListener
    private let queue = DispatchQueue(label: "studio.sauna.tests.owned-loopback")

    init(reply: @escaping @Sendable (String) -> WireReply? = { _ in nil }) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        let state = self.state
        let queue = self.queue
        listener.stateUpdateHandler = { update in
            switch update {
            case .ready:
                state.value.withLock { $0.port = listener.port?.rawValue }
                listener.stateUpdateHandler = nil
                ready.signal()
            case .failed:
                listener.stateUpdateHandler = nil
                ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            let port = state.value.withLock { value -> UInt16? in
                guard !value.stopping else { return nil }
                value.connections.append(connection)
                return value.port
            }
            guard let port else { connection.cancel(); return }
            connection.start(queue: queue)
            Self.receive(connection, state: state, port: port, reply: reply, accumulated: Data())
            queue.asyncAfter(deadline: .now() + 2) { connection.cancel() }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success,
              let port = state.value.withLock({ $0.port }) else {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            throw FixtureError.listenerFailure
        }
        self.port = port
    }

    private static func receive(_ connection: NWConnection, state: SharedFixtureState, port: UInt16,
                                reply: @escaping @Sendable (String) -> WireReply?, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { bytes, _, complete, error in
            var data = accumulated
            if let bytes { data.append(bytes) }
            guard error == nil, data.count <= 8192 else { connection.cancel(); return }
            if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                let request = String(decoding: data, as: UTF8.self)
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                var response = WireReply(status: "200 OK", body: "ok")
                switch path {
                case "/set": response.headers = "Set-Cookie: fixture=value; Path=/\r\n"
                case "/inspect": response.body = request.lowercased().contains("\r\ncookie:") ? "present" : "absent"
                case "/redirect": response = WireReply(status: "302 Found", headers: "Location: http://127.0.0.1:\(port)/target\r\n")
                case "/target": state.value.withLock { $0.targetRequests += 1 }
                case "/cache":
                    state.value.withLock { $0.cacheRequests += 1 }
                    response.headers = "Cache-Control: public, max-age=3600\r\n"
                default: break
                }
                if let custom = reply(request) { response = custom }
                let content = Data("HTTP/1.1 \(response.status)\r\n\(response.headers)Content-Length: \(response.body.utf8.count)\r\nConnection: close\r\n\r\n\(response.body)".utf8)
                connection.send(content: content, completion: .contentProcessed { _ in connection.cancel() })
            } else if complete { connection.cancel() }
            else { receive(connection, state: state, port: port, reply: reply, accumulated: data) }
        }
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func counts() -> (target: Int, cache: Int) { state.value.withLock { ($0.targetRequests, $0.cacheRequests) } }
    func stop() async throws {
        let connections = state.value.withLock { value in
            value.stopping = true
            let connections = value.connections
            value.connections.removeAll()
            return connections
        }
        listener.newConnectionHandler = nil
        for connection in connections { connection.cancel() }
        let cancelled = await withCheckedContinuation { continuation in
            let completion = StopCompletion(continuation)
            listener.stateUpdateHandler = { update in
                if case .cancelled = update { completion.finish(true) }
            }
            listener.cancel()
            queue.asyncAfter(deadline: .now() + 2) { completion.finish(false) }
        }
        listener.stateUpdateHandler = nil
        guard cancelled else { throw FixtureError.stopTimedOut }
    }
}

@Suite(.serialized) struct SessionTransportTests {
    private func withFixture(_ operation: (LoopbackFixture, URLSession) async throws -> Void) async throws {
        let fixture = try LoopbackFixture()
        let session = SessionTransport.makeEphemeralSession()
        let result: Result<Void, any Error>
        do { try await operation(fixture, session); result = .success(()) }
        catch { result = .failure(error) }
        session.invalidateAndCancel()
        try await fixture.stop()
        try result.get()
    }
    @Test func responseCookiesAreNotAutomaticallyReplayed() async throws {
        try await withFixture { server, session in
            _ = try await session.data(from: server.url("/set"))
            let (body, _) = try await session.data(from: server.url("/inspect"))
            let absent = String(decoding: body, as: UTF8.self) == "absent"
            #expect(absent)
        }
    }
    @Test func redirectsAreReturnedWithoutForwardingToTheTarget() async throws {
        try await withFixture { server, session in
            let (_, response) = try await session.data(from: server.url("/redirect"))
            #expect((response as? HTTPURLResponse)?.statusCode == 302)
            #expect(server.counts().target == 0)
        }
    }
    @Test func cacheableResponsesDoNotAvoidSubsequentServerRequests() async throws {
        try await withFixture { server, session in
            _ = try await session.data(from: server.url("/cache"))
            _ = try await session.data(from: server.url("/cache"))
            #expect(server.counts().cache == 2)
        }
    }
}
