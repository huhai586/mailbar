import Foundation
import GRDB

extension MailStore {
    static func registerCalendarMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v17-calendar") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS calendar_list (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    color TEXT NOT NULL,
                    isPrimary INTEGER NOT NULL DEFAULT 0,
                    isSelected INTEGER NOT NULL DEFAULT 1
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS calendar_event (
                    id TEXT PRIMARY KEY,
                    calendarId TEXT NOT NULL,
                    title TEXT NOT NULL,
                    startTs REAL NOT NULL,
                    endTs REAL NOT NULL,
                    allDay INTEGER NOT NULL DEFAULT 0,
                    location TEXT NOT NULL DEFAULT '',
                    notes TEXT NOT NULL DEFAULT '',
                    meetURL TEXT,
                    htmlLink TEXT,
                    myResponse TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS calendar_event_start ON calendar_event (startTs)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS calendar_event_calendar ON calendar_event (calendarId)")
        }
    }

    /// 用最新的日历清单替换本地的，并删掉已经不存在的日历的日程。
    func replaceCalendars(_ calendars: [CalendarInfo]) throws {
        try db.write { db in
            let keep = Set(calendars.map(\.id))
            for id in try String.fetchAll(db, sql: "SELECT id FROM calendar_list") where !keep.contains(id) {
                try db.execute(sql: "DELETE FROM calendar_list WHERE id = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM calendar_event WHERE calendarId = ?", arguments: [id])
            }
            for c in calendars {
                try db.execute(sql: """
                    INSERT INTO calendar_list (id, name, color, isPrimary, isSelected) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name, color = excluded.color,
                        isPrimary = excluded.isPrimary, isSelected = excluded.isSelected
                    """, arguments: [c.id, c.name, c.colorHex, c.isPrimary, c.isSelected])
            }
        }
    }

    /// 把某个日历在 from..<to 窗口内的日程整体换成最新的（窗口外的旧日程保留）。
    func replaceEvents(calendarId: String, from: Date, to: Date, with events: [CalendarEvent]) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM calendar_event WHERE calendarId = ? AND startTs >= ? AND startTs < ?",
                           arguments: [calendarId, from.timeIntervalSince1970, to.timeIntervalSince1970])
            for e in events {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO calendar_event
                        (id, calendarId, title, startTs, endTs, allDay, location, notes, meetURL, htmlLink, myResponse)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [e.id, e.calendarId, e.title, e.start.timeIntervalSince1970, e.end.timeIntervalSince1970,
                                     e.isAllDay, e.location, e.notes, e.meetingURL, e.htmlLink, e.myResponse])
            }
        }
    }

    public func calendars() throws -> [CalendarInfo] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM calendar_list ORDER BY isPrimary DESC, name COLLATE NOCASE").map {
                CalendarInfo(id: $0["id"], name: $0["name"], colorHex: $0["color"], isPrimary: $0["isPrimary"], isSelected: $0["isSelected"])
            }
        }
    }

    /// 和 [from, to) 有交集的日程（只含勾选显示的日历），按开始时间排序；全天日程排在同一天其他日程前面。
    public func calendarEvents(from: Date, to: Date) throws -> [CalendarEvent] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.*, c.name AS calName, c.color AS calColor
                FROM calendar_event e JOIN calendar_list c ON c.id = e.calendarId
                WHERE c.isSelected = 1 AND e.startTs < ? AND (e.endTs > ? OR e.startTs >= ?)
                ORDER BY e.startTs, e.allDay DESC, e.endTs
                """, arguments: [to.timeIntervalSince1970, from.timeIntervalSince1970, from.timeIntervalSince1970]).map {
                CalendarEvent(id: $0["id"], calendarId: $0["calendarId"], calendarName: $0["calName"], colorHex: $0["calColor"],
                              title: $0["title"], start: Date(timeIntervalSince1970: $0["startTs"]), end: Date(timeIntervalSince1970: $0["endTs"]),
                              isAllDay: $0["allDay"], location: $0["location"], notes: $0["notes"], meetingURL: $0["meetURL"],
                              htmlLink: $0["htmlLink"], myResponse: $0["myResponse"])
            }
        }
    }

    public var lastCalendarSync: Date? {
        (try? state("calendarSyncedAt")).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
    }

    func markCalendarSynced(_ date: Date) throws {
        try setState(["calendarSyncedAt": String(date.timeIntervalSince1970)])
    }
}
