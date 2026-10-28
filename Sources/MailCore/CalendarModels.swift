import Foundation

/// 日历里的一个日程（已经整理成界面直接能用的样子）。
public struct CalendarEvent: Identifiable, Equatable, Sendable {
    /// `<日历 id>|<日程 id>`
    public let id: String
    public let calendarId: String
    public let calendarName: String
    /// 日历的颜色（#RRGGBB）
    public let colorHex: String
    public let title: String
    public let start: Date
    /// 全天日程的结束是「最后一天的第二天零点」（不含）
    public let end: Date
    public let isAllDay: Bool
    public let location: String
    public let notes: String
    /// Meet / Zoom 等视频会议链接
    public let meetingURL: String?
    /// 在 Google 日历网页里打开的地址
    public let htmlLink: String?
    /// 这个日历是不是你自己的。订阅的、别人共享给你的日历（同事的日历、节假日……）不是：
    /// 它们只是恰好显示在你的账号里，日程上的回复状态属于日历的主人，不是你。
    public let isOwnCalendar: Bool
    /// 日历主人对这个邀请的回复：accepted / declined / tentative / needsAction。自己的日历上就是「我的回复」，没有回复信息是 nil
    public let myResponse: String?

    /// 你自己拒绝了的日程（别人日历上的拒绝与你无关）
    public var isDeclined: Bool { isOwnCalendar && myResponse == "declined" }

    public init(id: String, calendarId: String, calendarName: String, colorHex: String, title: String, start: Date, end: Date,
                isAllDay: Bool, location: String = "", notes: String = "", meetingURL: String? = nil, htmlLink: String? = nil,
                isOwnCalendar: Bool = true, myResponse: String? = nil) {
        self.id = id
        self.calendarId = calendarId
        self.calendarName = calendarName
        self.colorHex = colorHex
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.meetingURL = meetingURL
        self.htmlLink = htmlLink
        self.isOwnCalendar = isOwnCalendar
        self.myResponse = myResponse
    }

    /// 这个日程在某一天（本地时区）里是否出现。
    public func occurs(on day: Date, calendar: Calendar = .current) -> Bool {
        let start = calendar.startOfDay(for: day)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return false }
        // 零时长日程（start == end）也算在它开始的那天
        return self.start < next && (end > start || self.start >= start)
    }
}

/// 一个 Google 日历（个人日历、订阅的日历、共享日历……）。
public struct CalendarInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let colorHex: String
    public let isPrimary: Bool
    /// 在 Google 日历里是否勾选显示
    public let isSelected: Bool
    /// 是不是你自己的日历（你是所有者）；订阅的、别人共享的是 false
    public let isOwn: Bool
}

// MARK: - Google Calendar API 的返回

struct GCalendarList: Decodable {
    let items: [GCalendar]?
    let nextPageToken: String?
}

struct GCalendar: Decodable {
    let id: String
    let summary: String?
    let summaryOverride: String?
    let backgroundColor: String?
    let primary: Bool?
    let selected: Bool?
    let accessRole: String?
    let deleted: Bool?
}

struct GEventList: Decodable {
    let items: [GEvent]?
    let nextPageToken: String?
}

struct GEventTime: Decodable {
    let date: String?
    let dateTime: String?
}

struct GEvent: Decodable {
    struct Attendee: Decodable {
        let isSelf: Bool?
        let responseStatus: String?
        enum CodingKeys: String, CodingKey { case isSelf = "self", responseStatus }
    }
    struct Conference: Decodable {
        struct Entry: Decodable { let entryPointType: String?; let uri: String? }
        let entryPoints: [Entry]?
    }
    let id: String
    let status: String?
    let summary: String?
    let description: String?
    let location: String?
    let start: GEventTime?
    let end: GEventTime?
    let htmlLink: String?
    let hangoutLink: String?
    let conferenceData: Conference?
    let attendees: [Attendee]?
}

enum CalendarParsing {
    private static let internetDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractionalDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// `2026-10-28`（全天，按本地时区的零点）或 RFC 3339 时间。
    static func parse(_ time: GEventTime?, calendar: Calendar = .current) -> (date: Date, allDay: Bool)? {
        guard let time else { return nil }
        if let day = time.date {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
            return (date, true)
        }
        guard let text = time.dateTime, let date = internetDate.date(from: text) ?? fractionalDate.date(from: text) else { return nil }
        return (date, false)
    }

    /// 视频会议链接：优先 conferenceData 里的 video 入口，其次 hangoutLink，最后在地点 / 描述里找常见的会议网址。
    static func meetingURL(_ event: GEvent) -> String? {
        if let video = event.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri { return video }
        if let hangout = event.hangoutLink { return hangout }
        let haystack = [event.location, event.description].compactMap { $0 }.joined(separator: " ")
        let pattern = #"https://[\w.-]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|webex\.com)/[^\s"<>)]+"#
        if let range = haystack.range(of: pattern, options: .regularExpression) { return String(haystack[range]) }
        return nil
    }
}
