import Foundation

/// 同步引擎依赖的 Gmail 接口，便于在测试里替换成假实现。
protocol GmailAPI: Sendable {
    func profile() async throws -> GmailProfile
    func labels() async throws -> [GmailLabel]
    /// 最新的邮件在前，最多返回 limit 个 id（不含垃圾箱和垃圾邮件）。
    func listMessageIDs(limit: Int) async throws -> [String]
    /// 邮件已不存在时返回 nil。
    func message(id: String) async throws -> GmailMessage?
    /// 只取 X-GitHub-Reason 头：返回头的值（小写），没有这个头返回 ""，邮件已不存在返回 nil。
    func reasonHeader(id: String) async throws -> String?
    /// 批量增删标签（标记已读 = 去掉 UNREAD）。授权范围不够时抛 MailError.reauthorizationRequired。
    func batchModify(ids: [String], addLabelIds: [String], removeLabelIds: [String]) async throws
    /// startHistoryId 过期时抛出 MailError.historyExpired。
    func history(since startHistoryId: String) async throws -> (records: [HistoryRecord], historyId: String?)
}

struct GmailClient: GmailAPI {
    let oauth: OAuthClient
    /// 结构体被拷贝时共享同一个限速器
    let pacer = RequestPacer()

    func profile() async throws -> GmailProfile {
        try await get("profile")
    }

    func labels() async throws -> [GmailLabel] {
        let list: GmailLabelList = try await get("labels")
        return list.labels ?? []
    }

    func listMessageIDs(limit: Int) async throws -> [String] {
        var ids: [String] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "maxResults", value: String(min(500, limit - ids.count)))]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: GmailMessageList = try await get("messages", query: query)
            ids += (page.messages ?? []).map(\.id)
            pageToken = page.nextPageToken
        } while pageToken != nil && ids.count < limit
        return ids
    }

    func message(id: String) async throws -> GmailMessage? {
        do {
            return try await get("messages/\(id)", query: [URLQueryItem(name: "format", value: "full")])
        } catch MailError.http(let status, _) where status == 404 {
            return nil
        }
    }

    func history(since startHistoryId: String) async throws -> (records: [HistoryRecord], historyId: String?) {
        var records: [HistoryRecord] = []
        var latest: String?
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "startHistoryId", value: startHistoryId),
                         URLQueryItem(name: "maxResults", value: "500")]
            for type in ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"] {
                query.append(URLQueryItem(name: "historyTypes", value: type))
            }
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: HistoryList
            do {
                page = try await get("history", query: query)
            } catch MailError.http(let status, _) where status == 404 {
                throw MailError.historyExpired
            }
            records += page.history ?? []
            latest = page.historyId ?? latest
            pageToken = page.nextPageToken
        } while pageToken != nil
        return (records, latest)
    }

    // MARK: - HTTP

    private static let serverErrorStatuses: Set<Int> = [500, 502, 503, 504]
    private static let maxAttempts = 8

    func reasonHeader(id: String) async throws -> String? {
        do {
            let query = [URLQueryItem(name: "format", value: "metadata"), URLQueryItem(name: "metadataHeaders", value: "X-GitHub-Reason")]
            let message: GmailMessage = try await get("messages/\(id)", query: query)
            return (message.payload?.header("X-GitHub-Reason") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        } catch MailError.http(let status, _) where status == 404 {
            return nil
        }
    }

    func batchModify(ids: [String], addLabelIds: [String], removeLabelIds: [String]) async throws {
        guard !ids.isEmpty else { return }
        // Gmail 一次最多处理 1000 封
        for start in stride(from: 0, to: ids.count, by: 1000) {
            let chunk = Array(ids[start..<min(start + 1000, ids.count)])
            let body = try JSONSerialization.data(withJSONObject: ["ids": chunk, "addLabelIds": addLabelIds, "removeLabelIds": removeLabelIds])
            _ = try await request("messages/batchModify", method: "POST", body: body)
        }
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await request(path, query: query))
    }

    /// 带限速、限流退避和 5xx 重试的请求；成功（2xx）返回响应体。
    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var comps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!
        comps.queryItems = query.isEmpty ? nil : query

        var attempt = 0
        while true {
            await pacer.waitTurn()
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            req.setValue("Bearer \(try await oauth.accessToken())", forHTTPHeaderField: "Authorization")
            if let body {
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                await pacer.reportSuccess()
                return data
            }

            let text = String(decoding: data, as: UTF8.self)
            attempt += 1
            if status == 403, text.contains("insufficientPermissions") || text.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT") {
                throw MailError.reauthorizationRequired
            }
            let rateLimited = status == 429 || (status == 403 && text.contains("ateLimitExceeded"))
            if rateLimited && attempt < Self.maxAttempts {
                await pacer.reportRateLimited()   // 下一轮 waitTurn 会等到限流窗口过去
                continue
            }
            if Self.serverErrorStatuses.contains(status) && attempt < Self.maxAttempts {
                try await Task.sleep(nanoseconds: UInt64(500_000_000) << UInt64(min(attempt, 5)))
                continue
            }
            throw MailError.http(status: status, body: text)
        }
    }
}
