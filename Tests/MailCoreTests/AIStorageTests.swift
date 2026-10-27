import Foundation
import Testing
@testable import MailCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

@Suite struct TodoStoreTests {
    @Test func addListCompleteDelete() throws {
        let store = try MailStore(path: nil)
        let a = try store.addTodo("回复 Alice", groupKey: "o/r#1", now: t0)
        try store.addTodo("写文档", now: t0.addingTimeInterval(10))
        #expect(try store.todos().map(\.text) == ["写文档", "回复 Alice"])     // 同类按创建时间新到旧
        try store.setTodoDone(a.id, done: true, now: t0)
        #expect(try store.todos().map(\.text) == ["写文档"])
        #expect(try store.todos(includeDone: true).map(\.text) == ["写文档", "回复 Alice"])    // 已完成的在后
        try store.deleteTodo(a.id)
        #expect(try store.todos(includeDone: true).count == 1)
    }

    @Test func duplicateOpenTodoIsNotAddedTwice() throws {
        let store = try MailStore(path: nil)
        let first = try store.addTodo("回复 Alice", groupKey: "g", now: t0)
        let second = try store.addTodo("  回复 Alice ", groupKey: "g", now: t0)
        #expect(first.id == second.id)
        #expect(try store.todos().count == 1)
        #expect(try store.addTodo("回复 Alice", groupKey: nil, now: t0).id != first.id)   // 关联不同算另一条
        #expect(throws: MailError.self) { try store.addTodo("   ") }
    }

    @Test func remindersFireOnceWhenDue() throws {
        let store = try MailStore(path: nil)
        let soon = try store.addTodo("A", dueAt: t0.addingTimeInterval(60), now: t0)
        try store.addTodo("B", dueAt: t0.addingTimeInterval(3600), now: t0)
        try store.addTodo("无提醒", now: t0)
        #expect(try store.dueReminders(now: t0).isEmpty)
        #expect(try store.dueReminders(now: t0.addingTimeInterval(120)).map(\.id) == [soon.id])
        try store.markTodoNotified(soon.id)
        #expect(try store.dueReminders(now: t0.addingTimeInterval(120)).isEmpty)
        #expect(try store.dueReminders(now: t0.addingTimeInterval(7200)).map(\.text) == ["B"])
    }

    @Test func completedRemindersNeverFire() throws {
        let store = try MailStore(path: nil)
        let todo = try store.addTodo("A", dueAt: t0, now: t0)
        try store.setTodoDone(todo.id, done: true, now: t0)
        #expect(try store.dueReminders(now: t0.addingTimeInterval(1)).isEmpty)
    }

    @Test func openTodoByIdPrefix() throws {
        let store = try MailStore(path: nil)
        let todo = try store.addTodo("A", now: t0)
        #expect(try store.openTodo(idPrefix: String(todo.id.prefix(8)))?.id == todo.id)
        #expect(try store.openTodo(idPrefix: "zzzz") == nil)
    }
}

@Suite struct MemoryAndFeedbackTests {
    @Test func memoriesAreUniqueAndDeletable() throws {
        let store = try MailStore(path: nil)
        try store.addMemory("Dependabot 不用通知")
        try store.addMemory("Dependabot 不用通知")
        try store.addMemory("Alice 的评论优先")
        let all = try store.memories()
        #expect(all.map(\.text) == ["Dependabot 不用通知", "Alice 的评论优先"])
        try store.deleteMemory(all[0].id)
        #expect(try store.memories().map(\.text) == ["Alice 的评论优先"])
    }

    private func record(_ store: MailStore, _ id: String, notify: Bool, at offset: TimeInterval = 0) throws {
        try store.recordDecision(messageId: id, groupKey: "g", subject: "S-\(id)", from: "bot", source: "github", kind: "human",
                                 notify: notify, reason: "r", ruleName: nil, now: t0.addingTimeInterval(offset))
    }

    @Test func feedbackIsKeptWhenTheSameMailIsJudgedAgain() throws {
        let store = try MailStore(path: nil)
        try record(store, "a", notify: true)
        try store.setFeedback(messageId: "a", value: -1)
        try record(store, "a", notify: false, at: 5)
        let decision = try #require(try store.recentDecisions().first)
        #expect(decision.feedback == -1 && !decision.notify)
        try store.setFeedback(messageId: "a", value: nil)
        #expect(try store.recentDecisions().first?.feedback == nil)
    }

    @Test func contextHasMemoriesAndOnlyCorrectedDecisions() throws {
        let store = try MailStore(path: nil)
        #expect(AIContext.build(store: store).isEmpty)
        try store.addMemory("Dependabot 不用通知")
        try record(store, "ok", notify: true)
        try record(store, "bad", notify: true, at: 1)
        try record(store, "good", notify: false, at: 2)
        try store.setFeedback(messageId: "ok", value: 1)
        try store.setFeedback(messageId: "bad", value: -1)
        let context = AIContext.build(store: store)
        #expect(context.contains("Dependabot 不用通知"))
        #expect(context.contains("S-bad") && context.contains("判断为通知") && context.contains("应该不通知"))
        #expect(!context.contains("S-ok") && !context.contains("S-good"))
    }
}

@Suite struct FollowUpTests {
    private func store() throws -> MailStore {
        let store = try MailStore(path: nil)
        // 一个出问题的机器人（CI 失败）算「需要处理」；时间在 t0
        try store.upsert([makeMessage("ci", subject: "Run failed: build - fix thing", from: "notifications@github.com",
                                      body: "build failed", date: Int64(t0.timeIntervalSince1970 * 1000), labels: ["INBOX", "UNREAD"], thread: "T1")])
        return store
    }

    @Test func staleAttentionIsReportedOnceUntilSomethingNewArrives() throws {
        let s = try store()
        let later = t0.addingTimeInterval(25 * 3600)
        let attention = try s.threads(in: .attention, groupByPR: true, limit: 10)
        #expect(!attention.isEmpty)    // 前提：分诊把 CI 失败判为「需要处理」
        #expect(try FollowUps.collect(store: s, now: t0.addingTimeInterval(3600), olderThan: 24 * 3600).isEmpty)
        #expect(try FollowUps.collect(store: s, now: later, olderThan: 24 * 3600).count == attention.count)
        #expect(try FollowUps.collect(store: s, now: later, olderThan: 24 * 3600).isEmpty)
    }
}

@Suite struct AIDateTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13:20 UTC

    @Test func absoluteFormats() {
        let expected = utc.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 9, minute: 30))
        #expect(AIDate.parse("2026-10-28 09:30", now: now, calendar: utc) == expected)
        #expect(AIDate.parse("2026-10-28T09:30", now: now, calendar: utc) == expected)
        #expect(AIDate.parse("2026-10-28T09:30:00", now: now, calendar: utc) == expected)
    }

    @Test func relativeFormats() {
        #expect(AIDate.parse("+30m", now: now) == now.addingTimeInterval(1800))
        #expect(AIDate.parse("+2h", now: now) == now.addingTimeInterval(7200))
        #expect(AIDate.parse("+1d", now: now) == now.addingTimeInterval(86400))
        #expect(AIDate.parse("+0m", now: now) == nil)
        #expect(AIDate.parse("+5x", now: now) == nil)
    }

    @Test func timeOfDayMeansTodayOrTomorrow() {
        #expect(AIDate.parse("23:00", now: now, calendar: utc) == utc.date(from: DateComponents(year: 2023, month: 11, day: 14, hour: 23)))
        #expect(AIDate.parse("09:00", now: now, calendar: utc) == utc.date(from: DateComponents(year: 2023, month: 11, day: 15, hour: 9)))
    }

    @Test func garbageIsRejected() {
        #expect(AIDate.parse("明天早上", now: now) == nil)
        #expect(AIDate.parse("", now: now) == nil)
    }
}

@Suite struct AssistantWriteToolTests {
    private func tools() throws -> (StoreMailTools, MailStore) {
        let store = try MailStore(path: nil)
        return (StoreMailTools(store: store, now: { t0 }), store)
    }

    @Test func addTodoAndRemindAndDone() throws {
        let (t, store) = try tools()
        #expect(try t.run(tool: "add_todo", arguments: ["text": "回复 Alice", "group": "o/r#1"]).contains("已加入待办"))
        #expect(try t.run(tool: "remind", arguments: ["text": "合并 PR", "when": "+2h"]).contains("已设置提醒"))
        let todos = try store.todos()
        #expect(todos.count == 2)
        #expect(todos.first { $0.text == "合并 PR" }?.dueAt == t0.addingTimeInterval(7200))
        #expect(todos.first { $0.text == "回复 Alice" }?.groupKey == "o/r#1" && todos.allSatisfy { $0.source == "ai" })

        let listing = try t.run(tool: "todos", arguments: [:])
        #expect(listing.contains("回复 Alice") && listing.contains("合并 PR"))
        let id = try #require(todos.first { $0.text == "回复 Alice" }?.id)
        #expect(try t.run(tool: "done_todo", arguments: ["id": String(id.prefix(8))]).contains("已完成"))
        #expect(try store.todos().map(\.text) == ["合并 PR"])
    }

    @Test func invalidReminderInputsExplainThemselves() throws {
        let (t, store) = try tools()
        #expect(try t.run(tool: "remind", arguments: ["text": "x", "when": "明天"]).contains("无法识别"))
        #expect(try t.run(tool: "remind", arguments: ["text": "x", "when": "2001-01-01 00:00"]).contains("已经过去"))
        #expect(try t.run(tool: "remind", arguments: ["when": "+1h"]).contains("缺少参数"))
        #expect(try t.run(tool: "done_todo", arguments: ["id": "nope"]).contains("没有找到"))
        #expect(try store.todos().isEmpty)
        #expect(try t.run(tool: "todos", arguments: [:]).contains("没有待办"))
    }

    @Test func rememberStoresAMemory() throws {
        let (t, store) = try tools()
        #expect(try t.run(tool: "remember", arguments: ["text": "Alice 的评论优先"]).contains("已记住"))
        #expect(try store.memories().map(\.text) == ["Alice 的评论优先"])
    }
}

private struct SpyChat: AIChat {
    final class Box: @unchecked Sendable { var systems: [String] = [] }
    let box: Box
    let reply: String
    func complete(system: String, messages: [AIMessage]) async throws -> String {
        box.systems.append(system)
        return reply
    }
}

@Suite struct AIContextWiringTests {
    @Test func assistantAndJudgePromptsCarryTheContext() async throws {
        let box = SpyChat.Box()
        let chat = SpyChat(box: box, reply: #"{"notify": false}"#)
        _ = try await AINotifyJudge(chat: chat, prompt: "P", context: "【记忆】X").judge(subject: "s", from: "f", source: "github", kind: "human", body: "b")
        #expect(box.systems[0].contains("P") && box.systems[0].contains("【记忆】X") && box.systems[0].contains("JSON"))

        let assistant = AIAssistant(chat: SpyChat(box: box, reply: "好的"), profile: AIProfile(), context: "【记忆】Y")
        _ = try await assistant.ask([AIMessage(.user, "hi")], tools: StoreMailTools(store: try MailStore(path: nil)))
        #expect(box.systems[1].contains("【记忆】Y") && box.systems[1].contains("remind"))
    }

    @Test func configDecodesNewFieldsWithDefaults() throws {
        let path = NSTemporaryDirectory() + "ai-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(#"{"providers":[],"autoSummarize":true}"#.utf8).write(to: URL(fileURLWithPath: path))
        let config = AIConfigStore.read(path: path)
        #expect(config.autoSummarize && !config.briefAuto && config.briefHour == 9 && config.briefMinute == 0 && config.followUpHours == 0)
    }
}
