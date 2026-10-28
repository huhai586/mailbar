import Foundation
import Testing
@testable import MailCore

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.firstWeekday = 1
    return c
}

private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

private func event(_ id: String, _ start: String, _ end: String, allDay: Bool = false) -> CalendarEvent {
    CalendarEvent(id: id, calendarId: "c", calendarName: "C", colorHex: "#fff", title: id, start: date(start), end: date(end), isAllDay: allDay)
}

private final class FakeCalendarAPI: CalendarAPI, @unchecked Sendable {
    var calendarList: [GCalendar] = []
    var eventsByCalendar: [String: [GEvent]] = [:]
    var failing: Set<String> = []
    func calendars() async throws -> [GCalendar] { calendarList }
    func events(calendarId: String, from: Date, to: Date) async throws -> [GEvent] {
        if failing.contains(calendarId) { throw MailError.http(status: 500, body: "boom") }
        return eventsByCalendar[calendarId] ?? []
    }
}

private func gEvent(_ json: String) -> GEvent { try! JSONDecoder().decode(GEvent.self, from: Data(json.utf8)) }
private func gCalendar(_ json: String) -> GCalendar { try! JSONDecoder().decode(GCalendar.self, from: Data(json.utf8)) }

@Suite struct CalendarParsingTests {
    @Test func parsesTimedAndAllDayEvents() throws {
        let timed = try #require(CalendarParsing.parse(GEventTime(date: nil, dateTime: "2026-10-28T18:00:00+08:00"), calendar: utc))
        #expect(timed.date == date("2026-10-28T10:00:00Z") && !timed.allDay)
        let allDay = try #require(CalendarParsing.parse(GEventTime(date: "2026-10-28", dateTime: nil), calendar: utc))
        #expect(allDay.date == date("2026-10-28T00:00:00Z") && allDay.allDay)
        #expect(CalendarParsing.parse(GEventTime(date: nil, dateTime: "garbage"), calendar: utc) == nil)
        #expect(CalendarParsing.parse(nil, calendar: utc) == nil)
    }

    @Test func findsMeetingLinks() {
        let withConference = gEvent(#"{"id":"1","conferenceData":{"entryPoints":[{"entryPointType":"phone","uri":"tel:1"},{"entryPointType":"video","uri":"https://meet.google.com/abc"}]}}"#)
        #expect(CalendarParsing.meetingURL(withConference) == "https://meet.google.com/abc")
        let hangout = gEvent(#"{"id":"2","hangoutLink":"https://meet.google.com/xyz"}"#)
        #expect(CalendarParsing.meetingURL(hangout) == "https://meet.google.com/xyz")
        let inDescription = gEvent(#"{"id":"3","description":"Join: https://us02web.zoom.us/j/123?pwd=abc please"}"#)
        #expect(CalendarParsing.meetingURL(inDescription) == "https://us02web.zoom.us/j/123?pwd=abc")
        #expect(CalendarParsing.meetingURL(gEvent(#"{"id":"4","summary":"lunch"}"#)) == nil)
    }
}

@Suite struct CalendarSyncTests {
    private func makeStore() throws -> MailStore { try MailStore(path: nil) }

    @Test func syncsCalendarsAndEventsIntoTheStore() async throws {
        let api = FakeCalendarAPI()
        api.calendarList = [
            gCalendar(##"{"id":"me@x.com","summary":"Me","backgroundColor":"#1d4ed8","primary":true,"selected":true}"##),
            gCalendar(#"{"id":"holidays","summary":"Holidays","selected":false}"#),
        ]
        api.eventsByCalendar["me@x.com"] = [
            gEvent(#"{"id":"e1","summary":"Standup","start":{"dateTime":"2026-10-28T18:00:00Z"},"end":{"dateTime":"2026-10-28T18:30:00Z"},"attendees":[{"self":true,"responseStatus":"accepted"}]}"#),
            gEvent(#"{"id":"e2","summary":"Offsite","start":{"date":"2026-10-29"},"end":{"date":"2026-10-31"}}"#),
            gEvent(#"{"id":"e3","start":{"dateTime":"2026-10-28T09:00:00Z"},"end":{"dateTime":"2026-10-28T09:15:00Z"}}"#),
        ]
        let store = try makeStore()
        let now = date("2026-10-28T12:00:00Z")
        let count = try await CalendarSync(api: api, store: store).sync(now: now, calendar: utc)
        #expect(count == 3)

        let calendars = try store.calendars()
        #expect(calendars.map(\.id) == ["me@x.com", "holidays"] && calendars[0].isPrimary && !calendars[1].isSelected)

        let events = try store.calendarEvents(from: date("2026-10-28T00:00:00Z"), to: date("2026-11-01T00:00:00Z"))
        #expect(events.map(\.title) == ["（无标题）", "Standup", "Offsite"])
        #expect(events[1].myResponse == "accepted" && events[1].colorHex == "#1d4ed8" && events[1].calendarName == "Me")
        #expect(events[2].isAllDay)
        #expect(store.lastCalendarSync == now)
    }

    @Test func subscribedCalendarsAreNotMineAndTheirResponsesAreNotMyResponses() async throws {
        let api = FakeCalendarAPI()
        api.calendarList = [
            gCalendar(#"{"id":"me@x.com","summary":"Me","primary":true,"accessRole":"owner"}"#),
            gCalendar(#"{"id":"alice@x.com","summary":"Alice","selected":true,"accessRole":"reader"}"#),
            gCalendar(#"{"id":"team","summary":"Team","selected":true,"accessRole":"writer"}"#),
            gCalendar(#"{"id":"mine2","summary":"Side project","selected":true,"accessRole":"owner"}"#),
        ]
        let declined = #"{"id":"e","summary":"Sync","start":{"dateTime":"2026-10-28T10:00:00Z"},"end":{"dateTime":"2026-10-28T11:00:00Z"},"attendees":[{"self":true,"responseStatus":"declined"}]}"#
        for id in ["me@x.com", "alice@x.com", "team", "mine2"] { api.eventsByCalendar[id] = [gEvent(declined)] }
        let store = try makeStore()
        try await CalendarSync(api: api, store: store).sync(now: date("2026-10-28T12:00:00Z"), calendar: utc)

        #expect(try store.calendars().map { [$0.id: $0.isOwn] }.reduce(into: [String: Bool]()) { $0.merge($1) { a, _ in a } }
                == ["me@x.com": true, "alice@x.com": false, "team": false, "mine2": true])
        let events = try store.calendarEvents(from: date("2026-10-28T00:00:00Z"), to: date("2026-10-29T00:00:00Z"))
        let byCalendar = Dictionary(uniqueKeysWithValues: events.map { ($0.calendarId, $0) })
        #expect(byCalendar["me@x.com"]?.isOwnCalendar == true && byCalendar["me@x.com"]?.isDeclined == true)
        #expect(byCalendar["alice@x.com"]?.isOwnCalendar == false && byCalendar["alice@x.com"]?.isDeclined == false)
        #expect(byCalendar["alice@x.com"]?.myResponse == "declined")   // 仍记着，界面显示成「Alice 的回复」
    }

    @Test func resyncReplacesEventsAndDropsRemovedCalendars() async throws {
        let api = FakeCalendarAPI()
        api.calendarList = [gCalendar(#"{"id":"a","summary":"A","primary":true}"#), gCalendar(#"{"id":"b","summary":"B","selected":true}"#)]
        api.eventsByCalendar["a"] = [gEvent(#"{"id":"1","summary":"Old","start":{"dateTime":"2026-10-28T10:00:00Z"},"end":{"dateTime":"2026-10-28T11:00:00Z"}}"#)]
        api.eventsByCalendar["b"] = [gEvent(#"{"id":"2","summary":"Other","start":{"dateTime":"2026-10-28T10:00:00Z"},"end":{"dateTime":"2026-10-28T11:00:00Z"}}"#)]
        let store = try makeStore()
        let sync = CalendarSync(api: api, store: store)
        let now = date("2026-10-28T12:00:00Z")
        try await sync.sync(now: now, calendar: utc)

        api.calendarList = [gCalendar(#"{"id":"a","summary":"A","primary":true}"#)]
        api.eventsByCalendar["a"] = [gEvent(#"{"id":"3","summary":"New","start":{"dateTime":"2026-10-28T10:00:00Z"},"end":{"dateTime":"2026-10-28T11:00:00Z"}}"#)]
        try await sync.sync(now: now, calendar: utc)
        let events = try store.calendarEvents(from: date("2026-10-28T00:00:00Z"), to: date("2026-10-29T00:00:00Z"))
        #expect(events.map(\.title) == ["New"])
        #expect(try store.calendars().map(\.id) == ["a"])
    }

    @Test func oneFailingCalendarDoesNotLoseTheOthers() async throws {
        let api = FakeCalendarAPI()
        api.calendarList = [gCalendar(#"{"id":"a","summary":"A","primary":true}"#), gCalendar(#"{"id":"b","summary":"B","selected":true}"#)]
        api.failing = ["a"]
        api.eventsByCalendar["b"] = [gEvent(#"{"id":"2","summary":"Other","start":{"dateTime":"2026-10-28T10:00:00Z"},"end":{"dateTime":"2026-10-28T11:00:00Z"}}"#)]
        let store = try makeStore()
        await #expect(throws: MailError.self) { try await CalendarSync(api: api, store: store).sync(now: date("2026-10-28T12:00:00Z"), calendar: utc) }
        #expect(try store.calendarEvents(from: date("2026-10-28T00:00:00Z"), to: date("2026-10-29T00:00:00Z")).map(\.title) == ["Other"])
        #expect(store.lastCalendarSync == nil)
    }

    @Test func eventsOutsideTheRangeAreExcluded() async throws {
        let api = FakeCalendarAPI()
        api.calendarList = [gCalendar(#"{"id":"a","summary":"A","primary":true}"#)]
        api.eventsByCalendar["a"] = [
            gEvent(#"{"id":"1","summary":"Before","start":{"dateTime":"2026-10-27T10:00:00Z"},"end":{"dateTime":"2026-10-27T11:00:00Z"}}"#),
            gEvent(#"{"id":"2","summary":"Overnight","start":{"dateTime":"2026-10-27T23:00:00Z"},"end":{"dateTime":"2026-10-28T01:00:00Z"}}"#),
            gEvent(#"{"id":"3","summary":"After","start":{"dateTime":"2026-10-29T00:00:00Z"},"end":{"dateTime":"2026-10-29T01:00:00Z"}}"#),
        ]
        let store = try makeStore()
        try await CalendarSync(api: api, store: store).sync(now: date("2026-10-28T12:00:00Z"), calendar: utc)
        let events = try store.calendarEvents(from: date("2026-10-28T00:00:00Z"), to: date("2026-10-29T00:00:00Z"))
        #expect(events.map(\.title) == ["Overnight"])
    }
}

@Suite struct CalendarLayoutTests {
    @Test func overlappingEventsShareColumns() {
        let slots = CalendarLayout.slots(for: [
            event("a", "2026-10-28T18:00:00Z", "2026-10-28T19:00:00Z"),
            event("b", "2026-10-28T18:00:00Z", "2026-10-28T18:30:00Z"),
            event("c", "2026-10-28T18:15:00Z", "2026-10-28T18:25:00Z"),
            event("d", "2026-10-28T20:00:00Z", "2026-10-28T21:00:00Z"),
        ])
        let byID = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0) })
        #expect(byID["a"]?.columns == 3 && byID["b"]?.columns == 3 && byID["c"]?.columns == 3)
        #expect(Set(["a", "b", "c"].compactMap { byID[$0]?.column }) == [0, 1, 2])
        #expect(byID["d"]?.column == 0 && byID["d"]?.columns == 1)
    }

    @Test func backToBackEventsDoNotOverlap() {
        let slots = CalendarLayout.slots(for: [
            event("a", "2026-10-28T10:00:00Z", "2026-10-28T11:00:00Z"),
            event("b", "2026-10-28T11:00:00Z", "2026-10-28T12:00:00Z"),
        ])
        #expect(slots.allSatisfy { $0.columns == 1 && $0.column == 0 })
    }

    @Test func columnIsReusedAfterAnEventEnds() {
        let slots = CalendarLayout.slots(for: [
            event("long", "2026-10-28T10:00:00Z", "2026-10-28T13:00:00Z"),
            event("s1", "2026-10-28T10:00:00Z", "2026-10-28T11:00:00Z"),
            event("s2", "2026-10-28T11:00:00Z", "2026-10-28T12:00:00Z"),
        ])
        #expect(slots.allSatisfy { $0.columns == 2 })
        #expect(slots.first { $0.id == "s2" }?.column == slots.first { $0.id == "s1" }?.column)
    }

    @Test func monthGridIsWholeWeeks() {
        let grid = CalendarLayout.monthGrid(containing: date("2026-10-15T00:00:00Z"), calendar: utc)
        #expect(grid.count % 7 == 0)
        #expect(grid.first == date("2026-09-27T00:00:00Z"))   // 周日起；10 月 1 日是周四
        #expect(grid.last == date("2026-10-31T00:00:00Z"))    // 10 月 31 日是周六
        #expect(CalendarLayout.startOfWeek(date("2026-10-28T15:00:00Z"), calendar: utc) == date("2026-10-25T00:00:00Z"))
    }

    @Test func occursOnDayHandlesMultiDayAndAllDay() {
        let multi = event("m", "2026-10-29T00:00:00Z", "2026-10-31T00:00:00Z", allDay: true)
        #expect(!multi.occurs(on: date("2026-10-28T12:00:00Z"), calendar: utc))
        #expect(multi.occurs(on: date("2026-10-29T12:00:00Z"), calendar: utc) && multi.occurs(on: date("2026-10-30T12:00:00Z"), calendar: utc))
        #expect(!multi.occurs(on: date("2026-10-31T12:00:00Z"), calendar: utc))
    }
}

@Suite struct CalendarReminderTests {
    private let now = date("2026-10-28T10:00:00Z")

    @Test func remindsAtStartOrAheadByLeadTime() {
        let e = event("a", "2026-10-28T10:00:00Z", "2026-10-28T11:00:00Z")
        #expect(CalendarReminders.due([e], now: now, lead: 0).map(\.id) == ["a"])
        #expect(CalendarReminders.due([e], now: now.addingTimeInterval(-300), lead: 300).map(\.id) == ["a"])
        #expect(CalendarReminders.due([e], now: now.addingTimeInterval(-301 - 150), lead: 300).isEmpty)
        // 还没到
        #expect(CalendarReminders.due([e], now: now.addingTimeInterval(-60), lead: 0).isEmpty)
    }

    @Test func catchesUpOnAMissedCheckButNotAnOldEvent() {
        let e = event("a", "2026-10-28T10:00:00Z", "2026-10-28T11:00:00Z")
        #expect(CalendarReminders.due([e], now: now.addingTimeInterval(120), lead: 0).count == 1)
        #expect(CalendarReminders.due([e], now: now.addingTimeInterval(600), lead: 0).isEmpty)
    }

    @Test func skipsEventsOnSomeoneElsesCalendar() {
        let theirs = CalendarEvent(id: "t", calendarId: "alice", calendarName: "Alice", colorHex: "#fff", title: "t", start: now, end: now.addingTimeInterval(3600),
                                   isAllDay: false, isOwnCalendar: false)
        #expect(CalendarReminders.due([theirs], now: now, lead: 0).isEmpty)
    }

    @Test func skipsAllDayAndDeclinedEvents() {
        let allDay = event("d", "2026-10-28T00:00:00Z", "2026-10-29T00:00:00Z", allDay: true)
        let declined = CalendarEvent(id: "x", calendarId: "c", calendarName: "C", colorHex: "#fff", title: "x", start: now, end: now.addingTimeInterval(3600),
                                     isAllDay: false, myResponse: "declined")
        #expect(CalendarReminders.due([allDay, declined], now: now, lead: 0).isEmpty)
    }
}
