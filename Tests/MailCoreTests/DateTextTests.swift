import Foundation
import Testing
@testable import MailCore

@Suite struct DateTextTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func todayShowsTime() {
        #expect(DateText.list(date(2026, 10, 26, 9, 5), now: date(2026, 10, 26, 22, 0), calendar: calendar) == "09:05")
    }

    @Test func yesterdayAndEarlierThisYearAndOtherYears() {
        let now = date(2026, 10, 26, 22, 0)
        #expect(DateText.list(date(2026, 10, 25, 23, 59), now: now, calendar: calendar) == "昨天")
        #expect(DateText.list(date(2026, 3, 3), now: now, calendar: calendar) == "3月3日")
        #expect(DateText.list(date(2025, 12, 31), now: now, calendar: calendar) == "2025/12/31")
    }

    @Test func fullFormat() {
        #expect(DateText.full(date(2026, 10, 26, 21, 55), calendar: calendar) == "2026年10月26日 21:55")
    }
}
