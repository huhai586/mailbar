import Foundation

/// 日 / 周视图里一个日程的位置：同一时间段重叠的日程并排显示（column / columns 决定横向的第几列、共几列）。
public struct EventSlot: Identifiable, Equatable, Sendable {
    public var id: String { event.id }
    public let event: CalendarEvent
    public let column: Int
    public let columns: Int
}

public enum CalendarLayout {
    /// 给一天里的定时日程排列：时间有交集的归成一组，组内贪心分列，组内所有日程共用这组的最大列数。
    public static func slots(for events: [CalendarEvent]) -> [EventSlot] {
        let sorted = events.sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
        var result: [EventSlot] = []
        var group: [(event: CalendarEvent, column: Int)] = []
        var groupEnd = Date.distantPast
        var columnEnds: [Date] = []

        func flush() {
            let count = max(columnEnds.count, 1)
            result += group.map { EventSlot(event: $0.event, column: $0.column, columns: count) }
            group = []
            columnEnds = []
        }

        for event in sorted {
            // 时长为零的日程按 15 分钟算，避免被别的日程完全盖住
            let end = max(event.end, event.start.addingTimeInterval(15 * 60))
            if !group.isEmpty, event.start >= groupEnd { flush() }
            var column = columnEnds.firstIndex { $0 <= event.start } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(end) } else { columnEnds[column] = end }
            column = min(column, columnEnds.count - 1)
            group.append((event, column))
            groupEnd = max(groupEnd, end)
        }
        flush()
        return result
    }

    /// 从 start 起连续 count 天（每天零点）。
    public static func days(from start: Date, count: Int, calendar: Calendar = .current) -> [Date] {
        let first = calendar.startOfDay(for: start)
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    /// 包含 date 的那一周的第一天（跟随系统设置的每周起始日）。
    public static func startOfWeek(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// 月视图的格子：从包含月初的那一周开始，到包含月末的那一周结束，总是整周。
    public static func monthGrid(containing date: Date, calendar: Calendar = .current) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: date) else { return [] }
        let first = startOfWeek(month.start, calendar: calendar)
        let lastDay = calendar.date(byAdding: .day, value: -1, to: month.end) ?? month.end
        let lastWeekStart = startOfWeek(lastDay, calendar: calendar)
        guard let end = calendar.date(byAdding: .day, value: 7, to: lastWeekStart) else { return [] }
        let count = calendar.dateComponents([.day], from: first, to: end).day ?? 0
        return days(from: first, count: count, calendar: calendar)
    }
}

public enum CalendarReminders {
    /// 现在该提醒的日程：提醒时刻（开始时间减去提前量）落在 [now - window, now] 里。全天日程、已拒绝的日程、订阅的他人日历上的日程不提醒。
    /// window 让错过一两次检查的提醒还能补上，应用晚启动很久才发现的就不补了。
    public static func due(_ events: [CalendarEvent], now: Date, lead: TimeInterval, window: TimeInterval = 150) -> [CalendarEvent] {
        events.filter { event in
            guard !event.isAllDay, event.isOwnCalendar, !event.isDeclined else { return false }
            let dueAt = event.start.addingTimeInterval(-lead)
            return dueAt <= now && now.timeIntervalSince(dueAt) <= window
        }
    }
}
