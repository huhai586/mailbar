import MailCore
import SwiftUI

/// 「5 月 3 日 09:30」「明天 09:30」「今天 14:00」。
func todoDueText(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    let time = date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).hour(.twoDigits(amPM: .omitted)).minute())
    if calendar.isDate(date, inSameDayAs: now) { return "今天 \(time)" }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "明天 \(time)" }
    return date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day()) + " " + time
}

/// 今日概览里的待办：手动加、AI 从摘要或对话里加，带到点提醒；点关联的 PR 直接跳到邮件。
struct TodoCard: View {
    @ObservedObject var reader: ReaderModel
    @ObservedObject var service: MailService

    @State private var todos: [Todo] = []
    @State private var draft = ""
    @State private var showDone = false

    private var open: [Todo] { todos.filter { !$0.done } }
    private var done: [Todo] { todos.filter(\.done) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("待办", systemImage: "checklist").font(Theme.ui(13, .semibold)).foregroundStyle(Theme.text)
                if !open.isEmpty { Text("\(open.count)").font(Theme.mono(11)).foregroundStyle(Theme.faint) }
                Spacer()
                if !done.isEmpty {
                    Button(showDone ? "隐藏已完成" : "已完成 \(done.count)") { showDone.toggle() }
                        .buttonStyle(PlainPointerButtonStyle()).font(Theme.ui(11.5)).foregroundStyle(Theme.faint)
                }
            }
            ForEach(open) { row($0) }
            if open.isEmpty { Text("没有待办。可以在下面记一条，或者对助手说「提醒我明早回复 Alice」。").font(Theme.ui(12)).foregroundStyle(Theme.faint) }
            if showDone { ForEach(done) { row($0) } }

            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Theme.faint)
                TextField("记一条待办，回车添加", text: $draft).textFieldStyle(.plain).font(Theme.ui(12.5))
                    .onSubmit(add)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
        .task(id: service.todoRevision) { reload() }
    }

    private func row(_ todo: Todo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { toggle(todo) } label: {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14)).foregroundStyle(todo.done ? Theme.green : Theme.faint)
            }
            .buttonStyle(PlainPointerButtonStyle())
            VStack(alignment: .leading, spacing: 3) {
                Text(todo.text).font(Theme.ui(12.5))
                    .foregroundStyle(todo.done ? Theme.faint : Theme.text)
                    .strikethrough(todo.done)
                HStack(spacing: 8) {
                    if let due = todo.dueAt {
                        let overdue = !todo.done && due < Date()
                        Label(todoDueText(due), systemImage: "bell").font(Theme.mono(10.5))
                            .foregroundStyle(overdue ? Theme.red : Theme.muted)
                    }
                    if let group = todo.groupKey {
                        JumpChip(text: group.count > 30 ? String(group.prefix(28)) + "…" : group, color: Theme.blue, help: "在列表里打开") {
                            service.requestNavigation(mailbox: .allMail, threadId: group)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            Button { remove(todo) } label: { Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(Theme.faint) }
                .buttonStyle(PlainPointerButtonStyle()).help("删除")
        }
    }

    private func reload() { todos = (try? service.store?.todos(includeDone: true, limit: 50)) ?? [] }

    private func add() {
        guard (try? service.store?.addTodo(draft, source: "user")) != nil else { return }
        draft = ""
        service.bumpTodos()
    }

    private func toggle(_ todo: Todo) {
        try? service.store?.setTodoDone(todo.id, done: !todo.done)
        service.bumpTodos()
    }

    private func remove(_ todo: Todo) {
        try? service.store?.deleteTodo(todo.id)
        service.bumpTodos()
    }
}
