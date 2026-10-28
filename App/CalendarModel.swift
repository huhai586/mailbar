import Combine
import Foundation
import MailCore

/// 日历模块的视图状态：显示方式、当前选中的日期、要显示的日程。数据来自所有账号的本地日历库。
@MainActor
final class CalendarModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case day, week, month
        var id: String { rawValue }
        var title: String {
            switch self {
            case .day: return "日"
            case .week: return "周"
            case .month: return "月"
            }
        }
    }

    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Pref.calendarMode) }
    }
    /// 选中的日期（当天零点）；日视图显示它，周 / 月视图显示它所在的周 / 月，左边的日程列表从它所在的周开始
    @Published var anchor: Date { didSet { reload() } }
    @Published private(set) var events: [AccountEvent] = []
    /// 在日历里隐藏的账号
    @Published private(set) var hiddenAccounts: Set<String>

    let service: MailService
    private let calendar = Calendar.current
    private var cancellables = Set<AnyCancellable>()
    /// 左边日程列表显示几周
    static let agendaWeeks = 6

    init(service: MailService) {
        self.service = service
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: Pref.calendarMode) ?? "") ?? .day
        anchor = Calendar.current.startOfDay(for: Date())
        hiddenAccounts = Set(UserDefaults.standard.stringArray(forKey: "calendarHiddenAccounts") ?? [])
        service.$calendarRevision.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }.store(in: &cancellables)
        service.$accounts.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }.store(in: &cancellables)
        reload()
    }

    // MARK: - 日期

    var today: Date { calendar.startOfDay(for: Date()) }
    var weekStart: Date { CalendarLayout.startOfWeek(anchor, calendar: calendar) }
    var weekDays: [Date] { CalendarLayout.days(from: weekStart, count: 7, calendar: calendar) }
    var monthDays: [Date] { CalendarLayout.monthGrid(containing: anchor, calendar: calendar) }
    /// 左边日程列表里的各周（每周 7 天）
    var agendaWeeks: [[Date]] {
        (0..<Self.agendaWeeks).compactMap { week in
            calendar.date(byAdding: .day, value: week * 7, to: weekStart).map { CalendarLayout.days(from: $0, count: 7, calendar: calendar) }
        }
    }

    /// 上一个 / 下一个：日视图一天，周视图一周，月视图一个月。
    func step(_ direction: Int) {
        let component: Calendar.Component = mode == .day ? .day : (mode == .week ? .weekOfYear : .month)
        if let next = calendar.date(byAdding: component, value: direction, to: anchor) { anchor = next }
    }

    func goToday() { anchor = today }

    func isToday(_ day: Date) -> Bool { calendar.isDateInToday(day) }
    func isSameDay(_ a: Date, _ b: Date) -> Bool { calendar.isDate(a, inSameDayAs: b) }
    func isInAnchorMonth(_ day: Date) -> Bool { calendar.isDate(day, equalTo: anchor, toGranularity: .month) }

    // MARK: - 数据

    func eventsOn(_ day: Date) -> [AccountEvent] {
        events.filter { !hiddenAccounts.contains($0.accountID) && $0.event.occurs(on: day, calendar: calendar) }
    }

    func toggleAccount(_ id: String) {
        if hiddenAccounts.contains(id) { hiddenAccounts.remove(id) } else { hiddenAccounts.insert(id) }
        UserDefaults.standard.set(Array(hiddenAccounts), forKey: "calendarHiddenAccounts")
    }

    /// 一次取出日 / 周 / 月视图和左边列表都用得上的整段日程（本地库查询，很快）。
    func reload() {
        let monthDays = self.monthDays
        let from = min(monthDays.first ?? weekStart, weekStart)
        let agendaEnd = calendar.date(byAdding: .day, value: Self.agendaWeeks * 7, to: weekStart) ?? weekStart
        let monthEnd = monthDays.last.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? agendaEnd
        let loaded = service.calendarEvents(from: from, to: max(agendaEnd, monthEnd))
        if loaded != events { events = loaded }
    }
}
