import AppKit
import MailCore
import SwiftUI

/// 日历文字格式：固定用中文，24 小时制。
enum CalendarFormat {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = format
        return f
    }
    private static let year = formatter("yyyy年M月")
    private static let dayTitle = formatter("yyyy年M月d日 EEEE")
    private static let monthDay = formatter("M月d日")
    private static let weekday = formatter("EEE")
    private static let dayNumber = formatter("d")
    private static let month = formatter("M月")
    private static let clock = formatter("HH:mm")

    static func title(mode: CalendarModel.Mode, anchor: Date) -> String {
        mode == .day ? dayTitle.string(from: anchor) : year.string(from: anchor)
    }
    static func weekdayShort(_ d: Date) -> String { weekday.string(from: d) }
    static func dayNumber(_ d: Date) -> String { dayNumber.string(from: d) }
    static func monthShort(_ d: Date) -> String { month.string(from: d) }
    static func clock(_ d: Date) -> String { clock.string(from: d) }

    /// 「本周 (10月25日–31日)」这样的周标题。
    static func weekTitle(_ days: [Date], thisWeekStart: Date) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        let cal = Calendar.current
        let weeks = cal.dateComponents([.weekOfYear], from: thisWeekStart, to: first).weekOfYear ?? 0
        let name = weeks == 0 ? "本周" : (weeks == 1 ? "下周" : "")
        let sameMonth = cal.isDate(first, equalTo: last, toGranularity: .month)
        let range = monthDay.string(from: first) + "–" + (sameMonth ? dayNumber.string(from: last) + "日" : monthDay.string(from: last))
        return name.isEmpty ? range : "\(name)（\(range)）"
    }

    /// 日程的时间描述：全天 / 18:00–18:30 / 跨天的写出日期。
    static func timeRange(_ e: CalendarEvent) -> String {
        let cal = Calendar.current
        if e.isAllDay {
            let last = cal.date(byAdding: .day, value: -1, to: e.end) ?? e.start
            return cal.isDate(last, inSameDayAs: e.start) ? "全天" : "全天 · \(monthDay.string(from: e.start))–\(monthDay.string(from: last))"
        }
        if cal.isDate(e.start, inSameDayAs: e.end) || e.end <= e.start { return "\(clock.string(from: e.start))–\(clock.string(from: e.end))" }
        return "\(monthDay.string(from: e.start)) \(clock.string(from: e.start)) – \(monthDay.string(from: e.end)) \(clock.string(from: e.end))"
    }
}

/// 日历右边的主区域：顶部栏 + 提示 + 日 / 周 / 月视图。左边的日程列表是 CalendarAgenda，两个都放在侧栏右边。
struct CalendarMain: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject var service: MailService

    var body: some View {
        VStack(spacing: 0) {
            CalendarHeader(model: model, service: service)
            CalendarNotices(service: service)
            Group {
                switch model.mode {
                case .day: TimeGridView(model: model, days: [model.anchor])
                case .week: TimeGridView(model: model, days: model.weekDays)
                case .month: MonthGridView(model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .onAppear { Task { await service.syncCalendars(force: false) } }
    }
}

// MARK: - 顶部栏

private struct CalendarHeader: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject var service: MailService

    var body: some View {
        HStack(spacing: 10) {
            Text(CalendarFormat.title(mode: model.mode, anchor: model.anchor))
                .font(Theme.ui(20, .semibold)).foregroundStyle(Theme.text)
            HStack(spacing: 2) {
                navButton("chevron.left") { model.step(-1) }
                Button("今天") { model.goToday() }.buttonStyle(.bordered).controlSize(.small)
                navButton("chevron.right") { model.step(1) }
            }
            Spacer()
            Picker("", selection: $model.mode) {
                ForEach(CalendarModel.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            Button { service.manualSync() } label: { SyncIcon(syncing: service.calendarSyncing) }
                .buttonStyle(PlainPointerButtonStyle())
                .foregroundStyle(service.calendarSyncing ? Theme.accent : Theme.muted)
                .help("立即同步日历")
        }
        .padding(.horizontal, 16)
        .padding(.top, 34)
        .padding(.bottom, 10)
    }

    private func navButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22) }
            .buttonStyle(PlainPointerButtonStyle()).foregroundStyle(Theme.muted)
    }
}

/// 没授权日历的账号、同步出错的提示。
private struct CalendarNotices: View {
    @ObservedObject var service: MailService

    var body: some View {
        VStack(spacing: 6) {
            ForEach(service.accountsNeedingCalendarAuth, id: \.id) { session in
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(Theme.orange)
                    Text("\(session.account.email) 还没有授权读取日历").font(Theme.ui(12)).foregroundStyle(Theme.text)
                    Spacer()
                    Button("授权…") { service.reauthorize(session) }.controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Theme.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radius))
            }
            ForEach(service.calendarErrors, id: \.self) { error in
                Text("⚠️ " + error).font(Theme.ui(11.5)).foregroundStyle(Theme.red)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, service.accountsNeedingCalendarAuth.isEmpty && service.calendarErrors.isEmpty ? 0 : 8)
    }
}

// MARK: - 左边的日程列表

struct CalendarAgenda: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject var service: MailService

    var body: some View {
        VStack(spacing: 0) {
            Text("日程").font(Theme.ui(13, .semibold)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 38).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.agendaWeeks.enumerated()), id: \.offset) { _, week in
                        Text(CalendarFormat.weekTitle(week, thisWeekStart: CalendarLayout.startOfWeek(Date())))
                            .font(Theme.ui(12.5, .medium)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                        ForEach(week, id: \.self) { day in AgendaDayRow(model: model, day: day) }
                    }
                }
            }
            accountLegend
        }
        .background(Theme.panel)
    }

    /// 底部：各账号的颜色，点一下显示 / 隐藏这个账号的日程。
    private var accountLegend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(Theme.border)
            ForEach(service.accounts) { account in
                let hidden = model.hiddenAccounts.contains(account.id)
                Button { model.toggleAccount(account.id) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: hidden ? "circle" : "circle.fill").font(.system(size: 8)).foregroundStyle(Theme.accountColor(account.colorIndex))
                        Text(account.email).font(Theme.mono(10.5)).foregroundStyle(hidden ? Theme.faint : Theme.muted).lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainPointerButtonStyle())
                .help(hidden ? "显示这个账号的日程" : "隐藏这个账号的日程")
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 10).padding(.top, 2)
    }
}

private struct AgendaDayRow: View {
    @ObservedObject var model: CalendarModel
    let day: Date

    var body: some View {
        let selected = model.isSameDay(day, model.anchor)
        let today = model.isToday(day)
        let events = model.eventsOn(day)
        Button { model.anchor = day } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    Text(CalendarFormat.weekdayShort(day)).font(Theme.ui(11.5, .medium))
                    Text(CalendarFormat.dayNumber(day)).font(Theme.ui(24, .regular))
                    Text(CalendarFormat.monthShort(day)).font(Theme.ui(9.5, .semibold))
                }
                .foregroundStyle(selected ? Color.white : (today ? Theme.accent : Theme.text))
                .frame(width: 44)
                VStack(alignment: .leading, spacing: 3) {
                    if events.isEmpty {
                        Label("无日程", systemImage: "calendar").font(Theme.ui(11)).foregroundStyle(selected ? Color.white.opacity(0.8) : Theme.faint)
                            .padding(.top, 14)
                    } else {
                        ForEach(events.prefix(3)) { item in
                            HStack(spacing: 6) {
                                Text(item.event.isAllDay ? "全天" : CalendarFormat.clock(item.event.start))
                                    .font(Theme.mono(10.5)).foregroundStyle(selected ? Color.white.opacity(0.8) : Theme.muted)
                                    .frame(width: 34, alignment: .leading)
                                Circle().fill(selected ? Color.white : Theme.accountColor(item.colorIndex)).frame(width: 5, height: 5)
                                Text(item.event.title).font(Theme.ui(12, .medium)).lineLimit(1)
                                    .foregroundStyle(selected ? Color.white : Theme.text)
                                    .strikethrough(item.event.isDeclined)
                            }
                        }
                        if events.count > 3 {
                            Text("还有 \(events.count - 3) 项…").font(Theme.ui(10.5)).foregroundStyle(selected ? Color.white.opacity(0.8) : Theme.faint)
                                .padding(.leading, 40)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(selected ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPointerButtonStyle())
    }
}

// MARK: - 日程详情（点日程弹出）

private struct EventPopover: ViewModifier {
    let item: AccountEvent
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .onTapGesture { showing = true }
            .popover(isPresented: $showing, arrowEdge: .trailing) { EventDetail(item: item) }
    }
}

extension View {
    fileprivate func eventPopover(_ item: AccountEvent) -> some View { modifier(EventPopover(item: item)) }
}

private struct EventDetail: View {
    let item: AccountEvent

    private var responseText: String? {
        switch item.event.myResponse {
        case "accepted": return "已接受"
        case "declined": return "已拒绝"
        case "tentative": return "待定"
        case "needsAction": return "未回复"
        default: return nil
        }
    }

    var body: some View {
        let e = item.event
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accountColor(item.colorIndex)).frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title).font(Theme.ui(15, .semibold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    Text(dayText(e) + "  " + CalendarFormat.timeRange(e)).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                }
            }
            row("calendar", "\(e.calendarName) · \(item.accountEmail)")
            if !e.location.isEmpty { row("mappin.and.ellipse", e.location) }
            if let responseText { row("person.crop.circle.badge.checkmark", "我的回复：\(responseText)") }
            if !e.notes.isEmpty {
                Text(String(e.notes.prefix(500))).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(8).textSelection(.enabled)
            }
            HStack {
                if let meeting = e.meetingURL.flatMap(URL.init(string:)) {
                    Button("加入会议") { NSWorkspace.shared.open(meeting) }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                if let link = e.htmlLink.flatMap(URL.init(string:)) {
                    Button("在 Google 日历中打开") { NSWorkspace.shared.open(link) }.controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    private func dayText(_ e: CalendarEvent) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        return f.string(from: e.start)
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.faint).frame(width: 14)
            Text(text).font(Theme.ui(12)).foregroundStyle(Theme.text).textSelection(.enabled)
        }
    }
}

// MARK: - 日 / 周视图

private struct TimeGridView: View {
    @ObservedObject var model: CalendarModel
    let days: [Date]
    private let hourHeight: CGFloat = 56
    private let gutter: CGFloat = 54

    var body: some View {
        VStack(spacing: 0) {
            if days.count > 1 { dayHeaders }
            allDayRow
            Divider().overlay(Theme.border)
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in hourRow(hour).id(hour) }
                        }
                        GeometryReader { geo in
                            let columnWidth = (geo.size.width - gutter) / CGFloat(max(days.count, 1))
                            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                                dayColumn(day, x: gutter + CGFloat(index) * columnWidth, width: columnWidth)
                            }
                            nowLine(width: geo.size.width, columnWidth: columnWidth)
                        }
                        .frame(height: hourHeight * 24)
                    }
                }
                .onAppear { scroll(proxy) }
                .onChange(of: days) { _, _ in scroll(proxy) }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        let now = Calendar.current.component(.hour, from: Date())
        let target = days.contains { model.isToday($0) } ? max(0, now - 2) : 7
        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
    }

    private var dayHeaders: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days, id: \.self) { day in
                let today = model.isToday(day)
                Button { model.anchor = day; model.mode = .day } label: {
                    HStack(spacing: 5) {
                        Text(CalendarFormat.weekdayShort(day)).font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                        Text(CalendarFormat.dayNumber(day)).font(Theme.ui(13, .semibold))
                            .foregroundStyle(today ? Color.white : Theme.text)
                            .frame(width: 24, height: 24).background(today ? Theme.accent : Color.clear, in: Circle())
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainPointerButtonStyle())
            }
        }
    }

    private var allDayRow: some View {
        let perDay = days.map { day in model.eventsOn(day).filter { $0.event.isAllDay } }
        let rows = perDay.map(\.count).max() ?? 0
        return HStack(alignment: .top, spacing: 0) {
            Text("全天").font(Theme.ui(10.5)).foregroundStyle(Theme.faint)
                .frame(width: gutter, alignment: .trailing).padding(.trailing, 8).padding(.top, 5)
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 2) {
                    ForEach(model.eventsOn(day).filter { $0.event.isAllDay }) { item in
                        Text(item.event.title).font(Theme.ui(11, .medium)).lineLimit(1)
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accountColor(item.colorIndex).opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                            .eventPopover(item)
                    }
                }
                .padding(.horizontal, 2).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(minHeight: rows == 0 ? 26 : nil)
    }

    private func hourRow(_ hour: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(String(format: "%02d:00", hour)).font(Theme.mono(10)).foregroundStyle(Theme.faint)
                .frame(width: gutter, alignment: .trailing).padding(.trailing, 8).offset(y: -6)
            Rectangle().fill(Theme.border.opacity(0.7)).frame(height: 1)
        }
        .frame(height: hourHeight, alignment: .top)
    }

    private func dayColumn(_ day: Date, x: CGFloat, width: CGFloat) -> some View {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        let timed = model.eventsOn(day).filter { !$0.event.isAllDay }
        let byID = Dictionary(timed.map { ($0.event.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.border.opacity(0.5)).frame(width: 1, height: hourHeight * 24).offset(x: 0)
            ForEach(CalendarLayout.slots(for: timed.map(\.event))) { slot in
                if let item = byID[slot.event.id] {
                    let top = max(slot.event.start, start).timeIntervalSince(start) / 3600 * hourHeight
                    let bottom = min(slot.event.end, end).timeIntervalSince(start) / 3600 * hourHeight
                    let height = max(bottom - top, 20)
                    let slotWidth = (width - 4) / CGFloat(slot.columns)
                    EventBlock(item: item, height: height)
                        .frame(width: slotWidth - 2, height: height - 1)
                        .offset(x: 2 + CGFloat(slot.column) * slotWidth, y: top)
                }
            }
        }
        .frame(width: width, height: hourHeight * 24, alignment: .topLeading)
        .offset(x: x)
    }

    /// 当前时间的红线（只在今天所在的列画），左边的时间标签压在小时刻度上。
    @ViewBuilder
    private func nowLine(width: CGFloat, columnWidth: CGFloat) -> some View {
        if let index = days.firstIndex(where: { model.isToday($0) }) {
            TimelineView(.everyMinute) { context in
                let cal = Calendar.current
                let y = context.date.timeIntervalSince(cal.startOfDay(for: context.date)) / 3600 * hourHeight
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Theme.accent).frame(width: columnWidth, height: 1.5)
                        .offset(x: gutter + CGFloat(index) * columnWidth, y: y)
                    Text(CalendarFormat.clock(context.date)).font(Theme.mono(10, .semibold)).foregroundStyle(Color.white)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: gutter - 46, y: y - 8)
                }
            }
        }
    }
}

private struct EventBlock: View {
    let item: AccountEvent
    let height: CGFloat

    var body: some View {
        let color = Theme.accountColor(item.colorIndex)
        HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.event.title).font(Theme.ui(11.5, .semibold)).lineLimit(height > 40 ? 2 : 1)
                    .strikethrough(item.event.isDeclined)
                if height > 34 {
                    Text(CalendarFormat.timeRange(item.event)).font(Theme.ui(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 6).padding(.vertical, 3)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(item.event.isDeclined ? 0.1 : 0.22), in: RoundedRectangle(cornerRadius: 5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .eventPopover(item)
    }
}

// MARK: - 月视图

private struct MonthGridView: View {
    @ObservedObject var model: CalendarModel

    var body: some View {
        let days = model.monthDays
        let rows = max(days.count / 7, 1)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(days.prefix(7).enumerated()), id: \.offset) { _, day in
                    Text(CalendarFormat.weekdayShort(day)).font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
            }
            Divider().overlay(Theme.border)
            GeometryReader { geo in
                let cellHeight = geo.size.height / CGFloat(rows)
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(days[(row * 7)..<min(row * 7 + 7, days.count)], id: \.self) { day in
                                MonthCell(model: model, day: day, maxChips: max(Int((cellHeight - 26) / 18), 1))
                                    .frame(height: cellHeight)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct MonthCell: View {
    @ObservedObject var model: CalendarModel
    let day: Date
    let maxChips: Int

    var body: some View {
        let events = model.eventsOn(day)
        let today = model.isToday(day)
        let dim = !model.isInAnchorMonth(day)
        let shown = events.count > maxChips ? maxChips - 1 : events.count
        VStack(alignment: .leading, spacing: 2) {
            Button { model.anchor = day; model.mode = .day } label: {
                Text(CalendarFormat.dayNumber(day)).font(Theme.ui(12, today ? .semibold : .regular))
                    .foregroundStyle(today ? Color.white : (dim ? Theme.faint : Theme.text))
                    .frame(width: 22, height: 22).background(today ? Theme.accent : Color.clear, in: Circle())
            }
            .buttonStyle(PlainPointerButtonStyle())
            ForEach(events.prefix(max(shown, 0))) { item in
                HStack(spacing: 4) {
                    if !item.event.isAllDay {
                        Text(CalendarFormat.clock(item.event.start)).font(Theme.mono(9.5)).foregroundStyle(Theme.muted)
                    }
                    Text(item.event.title).font(Theme.ui(11, .medium)).lineLimit(1).strikethrough(item.event.isDeclined)
                }
                .foregroundStyle(dim ? Theme.muted : Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Theme.accountColor(item.colorIndex).opacity(item.event.isAllDay ? 0.3 : 0.14), in: RoundedRectangle(cornerRadius: 3))
                .eventPopover(item)
            }
            if events.count > shown {
                Button { model.anchor = day; model.mode = .day } label: {
                    Text("还有 \(events.count - shown) 项").font(Theme.ui(10.5)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(PlainPointerButtonStyle())
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topLeading) { Rectangle().fill(Theme.border.opacity(0.6)).frame(height: 1) }
        .overlay(alignment: .leading) { Rectangle().fill(Theme.border.opacity(0.6)).frame(width: 1) }
    }
}
