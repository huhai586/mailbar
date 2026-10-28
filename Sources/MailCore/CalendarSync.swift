import Foundation

/// 把一个账号的 Google 日历同步到本地：先取日历清单，再取每个日历在时间窗口内的日程。
public struct CalendarSync: Sendable {
    private let api: any CalendarAPI
    private let store: MailStore
    /// 同步的时间窗口：今天往前 / 往后多少天
    public static let daysBack = 45
    public static let daysForward = 120

    init(api: any CalendarAPI, store: MailStore) {
        self.api = api
        self.store = store
    }

    public init(oauth: OAuthClient, store: MailStore) {
        self.init(api: GoogleCalendarClient(oauth: oauth), store: store)
    }

    /// 同步一次。个别日历失败不影响其他日历；全部成功才记下同步时间，并返回第一个错误（如果有）。
    @discardableResult
    public func sync(now: Date = Date(), calendar: Calendar = .current) async throws -> Int {
        let today = calendar.startOfDay(for: now)
        guard let from = calendar.date(byAdding: .day, value: -Self.daysBack, to: today),
              let to = calendar.date(byAdding: .day, value: Self.daysForward, to: today) else { return 0 }

        let remote = try await api.calendars().filter { $0.deleted != true }
        let infos = remote.map {
            CalendarInfo(id: $0.id, name: $0.summaryOverride ?? $0.summary ?? $0.id, colorHex: $0.backgroundColor ?? "#4285F4",
                         isPrimary: $0.primary ?? false, isSelected: $0.selected ?? ($0.primary ?? false),
                         // 只有你是所有者的日历才算自己的；订阅的、共享给你的（reader / writer）都是别人的
                         isOwn: $0.primary == true || $0.accessRole == "owner")
        }
        try store.replaceCalendars(infos)

        var total = 0
        var firstError: Error?
        for info in infos where info.isSelected {
            do {
                let events = try await api.events(calendarId: info.id, from: from, to: to)
                let mapped = events.compactMap { Self.map($0, calendar: info, calendarTime: calendar) }
                try store.replaceEvents(calendarId: info.id, from: from, to: to, with: mapped)
                total += mapped.count
            } catch {
                if error is CancellationError { throw error }
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
        try store.markCalendarSynced(now)
        return total
    }

    static func map(_ e: GEvent, calendar info: CalendarInfo, calendarTime: Calendar = .current) -> CalendarEvent? {
        guard let start = CalendarParsing.parse(e.start, calendar: calendarTime) else { return nil }
        let end = CalendarParsing.parse(e.end, calendar: calendarTime)?.date ?? start.date
        let mine = e.attendees?.first { $0.isSelf == true }?.responseStatus
        let title = (e.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarEvent(id: "\(info.id)|\(e.id)", calendarId: info.id, calendarName: info.name, colorHex: info.colorHex,
                             title: title.isEmpty ? "（无标题）" : title, start: start.date, end: end, isAllDay: start.allDay,
                             location: e.location ?? "", notes: e.description ?? "", meetingURL: CalendarParsing.meetingURL(e),
                             htmlLink: e.htmlLink, isOwnCalendar: info.isOwn, myResponse: mine)
    }
}
