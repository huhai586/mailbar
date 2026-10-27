import Foundation
import Network

/// 只监听 127.0.0.1 的一次性 HTTP 服务，用来接收 Google 的授权回调。
final class LoopbackServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-server")
    private var continuation: CheckedContinuation<[String: String], Error>?

    init() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// 先登记等待，再调用 onListening（打开浏览器），避免回调早于等待。
    func awaitCallback(timeout: TimeInterval = 300, onListening: () -> Void) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.sync { continuation = cont }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(MailError.timeout))
            }
            onListening()
        }
    }

    func stop() { listener.cancel() }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(with: result)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            // 请求行形如: GET /?code=...&state=... HTTP/1.1
            let parts = text.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1" + parts[1]) else {
                conn.cancel()
                return
            }
            var params: [String: String] = [:]
            for item in comps.queryItems ?? [] { params[item.name] = item.value ?? "" }

            guard params["code"] != nil || params["error"] != nil else {
                self.respond(conn, status: "404 Not Found", html: "")
                return
            }
            let ok = params["code"] != nil
            self.respond(conn, status: "200 OK",
                         html: "<html><body style=\"font-family:-apple-system;text-align:center;margin-top:20vh\"><h2>\(ok ? "授权成功，可以关闭此页面" : "授权失败，请回到终端查看原因")</h2></body></html>")
            self.finish(.success(params))
        }
    }

    private func respond(_ conn: NWConnection, status: String, html: String) {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }
}
