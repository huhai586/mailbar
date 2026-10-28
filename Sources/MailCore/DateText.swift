import Foundation

/// 邮件列表和详情里的时间显示。
public enum DateText {
    /// DateFormatter 创建一次要几十微秒（列表每次重绘每行都要用好几个），按（格式、日历、时区）缓存起来复用。
    private static let formatters = FormatterCache()

    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: DateFormatter] = [:]

        func string(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
            let key = "\(pattern)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
            return lock.withLock {
                if let f = cache[key] { return f.string(from: date) }
                let f = DateFormatter()
                f.calendar = calendar
                f.locale = Locale(identifier: "zh_CN")
                f.timeZone = calendar.timeZone
                f.dateFormat = pattern
                cache[key] = f
                return f.string(from: date)
            }
        }
    }

    private static func format(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        formatters.string(date, pattern, calendar)
    }

    /// 列表里的简短时间：今天 14:05 / 昨天 / 10月3日 / 2024/12/3
    public static func list(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return format(date, "HH:mm", calendar) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return format(date, "M月d日", calendar) }
        return format(date, "yyyy/M/d", calendar)
    }

    /// 一天之内的时间：14:05。
    public static func clock(_ date: Date, calendar: Calendar = .current) -> String { format(date, "HH:mm", calendar) }

    /// 列表里每一行底部的「最后更新」：今天只写时间（14:05），其余带上日期（昨天 14:05 / 10月26日 14:05）。
    public static func updated(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return clock(date, calendar: calendar) }
        let startOfToday = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? 0
        if days == 1 { return "昨天 " + clock(date, calendar: calendar) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return format(date, "M月d日", calendar) + " " + clock(date, calendar: calendar)
        }
        return format(date, "yyyy/M/d", calendar) + " " + clock(date, calendar: calendar)
    }

    /// 列表里按天分组的标题：今天 / 昨天 / 周一 10月26日（一周内）/ 10月20日 / 2025年12月3日。
    public static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "今天" }
        let startOfToday = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startOfToday).day ?? 0
        if days == 1 { return "昨天" }
        if days > 1, days < 7 { return format(date, "EEEE M月d日", calendar) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return format(date, "M月d日", calendar) }
        return format(date, "yyyy年M月d日", calendar)
    }

    /// 同一天的邮件分到一组用的键。
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        // 只取年月日三个数，比格式化成字符串快得多（列表分组对每一行都要算）
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 详情里的完整时间：2026年10月26日 21:55
    public static func full(_ date: Date, calendar: Calendar = .current) -> String {
        format(date, "yyyy年M月d日 HH:mm", calendar)
    }
}
