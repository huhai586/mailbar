import Foundation

/// 日历同步依赖的接口，便于在测试里替换成假实现。
protocol CalendarAPI: Sendable {
    func calendars() async throws -> [GCalendar]
    /// from..<to 之间的日程，已展开重复日程（每次出现一条），不含已取消的。
    func events(calendarId: String, from: Date, to: Date) async throws -> [GEvent]
}

struct GoogleCalendarClient: CalendarAPI {
    let oauth: OAuthClient

    func calendars() async throws -> [GCalendar] {
        var result: [GCalendar] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "minAccessRole", value: "reader")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: GCalendarList = try await get("users/me/calendarList", query: query)
            result += page.items ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil
        return result
    }

    func events(calendarId: String, from: Date, to: Date) async throws -> [GEvent] {
        let formatter = ISO8601DateFormatter()
        var result: [GEvent] = []
        var pageToken: String?
        let path = "calendars/\(Self.escape(calendarId))/events"
        repeat {
            var query = [URLQueryItem(name: "timeMin", value: formatter.string(from: from)),
                         URLQueryItem(name: "timeMax", value: formatter.string(from: to)),
                         URLQueryItem(name: "singleEvents", value: "true"),
                         URLQueryItem(name: "orderBy", value: "startTime"),
                         URLQueryItem(name: "maxResults", value: "250")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: GEventList = try await get(path, query: query)
            result += (page.items ?? []).filter { $0.status != "cancelled" }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return result
    }

    private static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/@+"))) ?? id
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/\(path)")!
        comps.percentEncodedQuery = query.map { "\($0.name)=\(($0.value ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&")
        // 路径里的邮箱要保持百分号编码：用 percentEncodedPath 直接赋值
        comps.percentEncodedPath = "/calendar/v3/" + path

        var attempt = 0
        while true {
            var req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(try await oauth.accessToken())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return try JSONDecoder().decode(T.self, from: data) }
            let text = String(decoding: data, as: UTF8.self)
            if status == 403 || status == 401 {
                if text.contains("insufficientPermissions") || text.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT") { throw MailError.reauthorizationRequired }
                if text.contains("accessNotConfigured") || text.contains("SERVICE_DISABLED") || text.contains("has not been used") {
                    throw MailError.config("Google 项目还没有启用 Calendar API：到 GCP 控制台 → API 和服务 → 库，搜索 “Google Calendar API” 并启用，再回来刷新。")
                }
            }
            attempt += 1
            if (status == 429 || status >= 500), attempt < 5 {
                try await Task.sleep(nanoseconds: UInt64(500_000_000) << UInt64(attempt))
                continue
            }
            throw MailError.http(status: status, body: text)
        }
    }
}
