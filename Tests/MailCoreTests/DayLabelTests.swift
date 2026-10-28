import Foundation
import Testing
@testable import MailCore

@Suite struct DayLabelTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @Test func labels() {
        let now = date(2026, 10, 28, 9)   // 周三
        #expect(DateText.day(date(2026, 10, 28, 0), now: now, calendar: cal) == "今天")
        #expect(DateText.day(date(2026, 10, 27, 23), now: now, calendar: cal) == "昨天")
        #expect(DateText.day(date(2026, 10, 26), now: now, calendar: cal) == "星期一 10月26日")
        #expect(DateText.day(date(2026, 10, 20), now: now, calendar: cal) == "10月20日")
        #expect(DateText.day(date(2025, 12, 3), now: now, calendar: cal) == "2025年12月3日")
    }

    @Test func sameDayShareAKey() {
        #expect(DateText.dayKey(date(2026, 10, 28, 1), calendar: cal) == DateText.dayKey(date(2026, 10, 28, 23), calendar: cal))
        #expect(DateText.dayKey(date(2026, 10, 28), calendar: cal) != DateText.dayKey(date(2026, 10, 27), calendar: cal))
    }
}
