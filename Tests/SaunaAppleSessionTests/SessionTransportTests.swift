struct WireReply: Sendable { let status: String; var headers = ""; var body = "" }
import Darwin
import Foundation
import Synchronization
import Testing
@testable import SaunaAppleSession

private enum FixtureError: Error { case socketFailure }
private final class SharedFixtureState: Sendable { let value = Mutex(LoopbackFixture.State()) }
final class LoopbackFixture: Sendable {
    struct State: Sendable { var stopping = false; var targetRequests = 0; var cacheRequests = 0 }
    let port: UInt16
    private let state = SharedFixtureState()
    private let worker: Task<Void, Never>
    init(reply: @escaping @Sendable (String) -> WireReply? = { _ in nil }) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw FixtureError.socketFailure }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { close(listener); throw FixtureError.socketFailure }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        guard status == 0 else { close(listener); throw FixtureError.socketFailure }
        let port = UInt16(bigEndian: address.sin_port)
        self.port = port
        let state = self.state
        worker = Task.detached {
            defer { close(listener) }
            while true {
                let connection = accept(listener, nil, nil)
                guard connection >= 0 else { return }
                if state.value.withLock({ $0.stopping }) { close(connection); return }
                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                _ = withUnsafePointer(to: &timeout) { setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
                var noSignal: Int32 = 1
                _ = withUnsafePointer(to: &noSignal) { setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size)) }
                var data = Data()
                var bytes = [UInt8](repeating: 0, count: 1024)
                while data.count < 8192 && data.range(of: Data("\r\n\r\n".utf8)) == nil {
                    let count = recv(connection, &bytes, bytes.count, 0)
                    if count <= 0 { break }
                    data.append(contentsOf: bytes.prefix(count))
                }
                let request = String(decoding: data, as: UTF8.self)
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                var status = "200 OK"
                var headers = ""
                var body = "ok"
                switch path {
                case "/set": headers = "Set-Cookie: fixture=value; Path=/\r\n"
                case "/inspect": body = request.lowercased().contains("\r\ncookie:") ? "present" : "absent"
                case "/redirect": status = "302 Found"; headers = "Location: http://127.0.0.1:\(port)/target\r\n"
                case "/target": state.value.withLock { $0.targetRequests += 1 }
                case "/cache": state.value.withLock { $0.cacheRequests += 1 }; headers = "Cache-Control: public, max-age=3600\r\n"
                default: break
                }
                if let custom = reply(request) {
                    status = custom.status; headers = custom.headers; body = custom.body
                }
                let response = Data("HTTP/1.1 \(status)\r\n\(headers)Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
                response.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let sent = send(connection, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                        if sent <= 0 { break }; offset += sent
                    }
                }
                close(connection)
            }
        }
    }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func counts() -> (target: Int, cache: Int) { state.value.withLock { ($0.targetRequests, $0.cacheRequests) } }
    func stop() async {
        state.value.withLock { $0.stopping = true }
        let wake = socket(AF_INET, SOCK_STREAM, 0)
        if wake >= 0 {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            address.sin_port = port.bigEndian
            _ = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(wake, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            close(wake)
        }
        await worker.value
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
        await fixture.stop()
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
