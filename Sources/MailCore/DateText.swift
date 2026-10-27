import Foundation

/// 邮件列表和详情里的时间显示。
public enum DateText {
    private static func format(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        return f.string(from: date)
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

    /// 详情里的完整时间：2026年10月26日 21:55
    public static func full(_ date: Date, calendar: Calendar = .current) -> String {
        format(date, "yyyy年M月d日 HH:mm", calendar)
    }
}
