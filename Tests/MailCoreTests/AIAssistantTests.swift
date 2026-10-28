import Foundation
import Testing
@testable import MailCore

/// 按顺序吐出预设回复的假模型，同时记下每次收到的 system / messages。
private final class Script: @unchecked Sendable {
    var replies: [String]
    var seen: [(system: String, messages: [AIMessage])] = []
    init(_ replies: [String]) { self.replies = replies }
}

private struct ScriptedChat: AIChat {
    let script: Script
    func complete(system: String, messages: [AIMessage]) async throws -> String {
        script.seen.append((system, messages))
        return script.replies.isEmpty ? "（没有更多回复）" : script.replies.removeFirst()
    }
}

private struct FakeTools: AIMailTools {
    let documentation = "- ping：测试"
    func run(tool: String, arguments: [String: String]) throws -> String {
        if tool == "boom" { throw MailError.config("炸了") }
        return "结果(\(tool),\(arguments["query"] ?? ""))"
    }
}

private func detail(_ id: String, kind: String = "human", from: String = "bob", body: String, date: Double = 1_700_000_000) -> MessageDetail {
    MessageDetail(id: id, threadId: "t", subject: "S", from: from, to: "", date: Date(timeIntervalSince1970: date), snippet: "",
                  bodyText: body, bodyHtml: nil, isUnread: false, hasAttachments: false, labelIds: [], reason: nil, kind: kind)
}

@Suite struct AITranscriptTests {
    @Test func skipsRoutineBotsAndQuotedLinesAndCountsOmissions() {
        let text = AITranscript.make([
            detail("1", body: "请看下\n> 引用的旧内容\n谢谢"),
            detail("2", kind: "bot_routine", from: "sonar", body: "Quality Gate passed"),
            detail("3", kind: "bot_alert", from: "ci", body: "build failed"),
        ])
        #expect(text.contains("请看下\n谢谢"))
        #expect(!text.contains("引用的旧内容"))
        #expect(!text.contains("Quality Gate passed"))
        #expect(text.contains("机器人·出问题"))
        #expect(text.contains("另有 1 条例行机器人消息已省略"))
    }

    @Test func keepsNewestWhenOverBudget() {
        let messages = (1...10).map { detail("\($0)", body: String(repeating: "x", count: 100) + " #\($0)", date: Double($0)) }
        let text = AITranscript.make(messages, budget: 300)
        #expect(text.contains("#10") && !text.contains("#1 "))
        #expect(text.contains("更早的"))
    }
}

@Suite struct AIAssistantTests {
    private func assistant(_ replies: [String]) -> (AIAssistant, Script) {
        let script = Script(replies)
        return (AIAssistant(chat: ScriptedChat(script: script), profile: AIProfile(githubLogin: "howard", jiraName: "Howard Hu")), script)
    }

    @Test func summarizeParsesJSONAndSendsProfile() async throws {
        let (ai, script) = assistant(["```json\n{\"summary\":\"讨论了方案\",\"status\":\"等 review\",\"todos\":[\"回复 Bob\"]}\n```"])
        let summary = try await ai.summarize(title: "PR 标题", messages: [detail("1", body: "hello")])
        #expect(summary == AIThreadSummary(summary: "讨论了方案", status: "等 review", todos: ["回复 Bob"]))
        #expect(script.seen[0].system.contains("howard") && script.seen[0].system.contains("Howard Hu"))
        #expect(script.seen[0].messages[0].content.contains("标题：PR 标题"))
    }

    @Test func summarizeUsesTheConfiguredPromptAndSeesEverything() async throws {
        let (ai, script) = assistant([#"{"summary":"s","status":"","todos":[]}"#])
        _ = try await ai.summarize(title: "t", messages: [
            detail("1", body: "真人的长评论 " + String(repeating: "x", count: 3_000)),
            detail("2", kind: "bot_routine", from: "sonar", body: "Quality Gate passed\nmore lines"),
        ], prompt: "我的总结要求")
        let system = script.seen[0].system
        #expect(system.contains("我的总结要求") && system.contains("JSON"))
        let user = script.seen[0].messages[0].content
        #expect(user.contains(String(repeating: "x", count: 3_000)))      // 长评论不再截到 1200 字
        #expect(user.contains("Quality Gate passed") && !user.contains("more lines"))   // 例行消息也在，但只留一行
    }

    @Test func summarizeFailsOnGarbage() async {
        let (ai, _) = assistant(["不知道"])
        await #expect(throws: MailError.self) { try await ai.summarize(title: "t", messages: []) }
    }

    @Test func askRunsToolsThenAnswersWithSteps() async throws {
        let (ai, script) = assistant([#"{"tool":"search","args":{"query":"mraid"}}"#, "有 1 封，见 [a/b#1]。"])
        let answer = try await ai.ask([AIMessage(.user, "mraid 的事？")], tools: FakeTools())
        #expect(answer.text == "有 1 封，见 [a/b#1]。")
        #expect(answer.steps == ["搜索 mraid"])
        #expect(script.seen.count == 2)
        let second = script.seen[1].messages
        #expect(second.map(\.role) == [.user, .assistant, .user])
        #expect(second[2].content.contains("结果(search,mraid)"))
        #expect(script.seen[0].system.contains("ping"))
    }

    @Test func askPlainReplyIsTheAnswerImmediately() async throws {
        let (ai, script) = assistant(["你好，有什么可以帮你？"])
        let answer = try await ai.ask([AIMessage(.user, "hi")], tools: FakeTools())
        #expect(answer.text == "你好，有什么可以帮你？" && answer.steps.isEmpty && script.seen.count == 1)
    }

    @Test func toolErrorsAreFedBackNotThrown() async throws {
        let (ai, script) = assistant([#"{"tool":"boom"}"#, "查不到。"])
        let answer = try await ai.ask([AIMessage(.user, "q")], tools: FakeTools())
        #expect(answer.text == "查不到。")
        #expect(script.seen[1].messages.last?.content.contains("工具出错：炸了") == true)
    }

    @Test func endlessToolCallsAreCutOffAndForcedToAnswer() async throws {
        let call = #"{"tool":"search","args":{"query":"x"}}"#
        let (ai, script) = assistant(Array(repeating: call, count: 3) + ["最终回答"])
        let answer = try await ai.ask([AIMessage(.user, "q")], tools: FakeTools(), maxSteps: 3)
        #expect(answer.text == "最终回答" && answer.steps.count == 3)
        #expect(script.seen.last?.messages.last?.content.contains("直接回答") == true)
    }

    @Test func numericArgumentsAreAccepted() {
        let call = AIAssistant.toolCall(in: #"好的 {"tool":"recent","args":{"hours":12}}"#)
        #expect(call == AIAssistant.ToolCall(tool: "recent", arguments: ["hours": "12"]))
        #expect(AIAssistant.toolCall(in: "普通回答") == nil)
    }

    @Test func briefGathersThreeToolsAndReturnsTrimmedMarkdown() async throws {
        let (ai, script) = assistant(["\n## 需要你处理\n- x\n"])
        let text = try await ai.brief(tools: FakeTools())
        #expect(text == "## 需要你处理\n- x")
        let user = script.seen[0].messages[0].content
        #expect(user.contains("结果(need_me") && user.contains("结果(unread") && user.contains("结果(recent"))
    }
}

@Suite struct StoreMailToolsTests {
    private func tools() throws -> (StoreMailTools, MailStore) {
        let store = try MailStore(path: nil)
        try store.upsert([
            makeMessage("a", subject: "[o/r] Fix crash (PR #1)", from: "bob@x.com", body: "mraid bridge crash", date: 1_700_000_100_000,
                        labels: ["INBOX", "UNREAD"], thread: "T1", reason: "review_requested"),
            makeMessage("b", subject: "lunch?", from: "amy@x.com", body: "noon", date: 1_700_000_000_000, labels: ["INBOX"], thread: "T2"),
        ])
        return (StoreMailTools(store: store, now: { Date(timeIntervalSince1970: 1_700_000_200) }), store)
    }

    @Test func searchFindsAndReportsGroupKey() throws {
        let (t, _) = try tools()
        let out = try t.run(tool: "search", arguments: ["query": "mraid"])
        #expect(out.contains("Fix crash") && out.contains("（未读）"))
        #expect(try t.run(tool: "search", arguments: ["query": "不存在的词"]).contains("没有找到"))
        #expect(try t.run(tool: "search", arguments: [:]).contains("缺少参数"))
    }

    @Test func unreadAndRecentAndNeedMe() throws {
        let (t, _) = try tools()
        #expect(try t.run(tool: "unread", arguments: [:]).contains("Fix crash"))
        #expect(try !t.run(tool: "unread", arguments: [:]).contains("lunch"))
        let recent = try t.run(tool: "recent", arguments: ["hours": "24"])
        #expect(recent.contains("Fix crash") && recent.contains("lunch"))
        #expect(try t.run(tool: "need_me", arguments: [:]).isEmpty == false)
    }

    @Test func threadShowsContentAndUnknownIdsAreReported() throws {
        let (t, _) = try tools()
        #expect(try t.run(tool: "thread", arguments: ["id": "T2"]).contains("noon"))
        #expect(try t.run(tool: "thread", arguments: ["id": "nope"]).contains("没有找到"))
        #expect(try t.run(tool: "wat", arguments: [:]).contains("没有这个工具"))
    }
}

@Suite struct AISummaryCacheTests {
    @Test func cachedUntilTheLatestMessageChanges() throws {
        let store = try MailStore(path: nil)
        let summary = AIThreadSummary(summary: "s", status: "st", todos: ["t"])
        #expect(try store.aiSummary(group: "g", latestMessageId: "m1") == nil)
        try store.saveAISummary(summary, group: "g", latestMessageId: "m1")
        #expect(try store.aiSummary(group: "g", latestMessageId: "m1") == summary)
        #expect(try store.aiSummary(group: "g", latestMessageId: "m2") == nil)
        let newer = AIThreadSummary(summary: "n", status: "", todos: [])
        try store.saveAISummary(newer, group: "g", latestMessageId: "m2")
        #expect(try store.aiSummary(group: "g", latestMessageId: "m2") == newer)
    }
}

@Suite struct AILinksTests {
    private func link(_ key: String) -> String { AILinks.url(for: key)!.absoluteString }

    @Test func urlRoundTripsKeysWithSpecialCharacters() throws {
        for key in ["Vungle/Monetize#7125", "a.b/c-d_e#1", "18c3f0a1b2c3d4e5"] {
            let url = try #require(AILinks.url(for: key))
            #expect(AILinks.key(from: url) == key)
        }
        #expect(AILinks.key(from: URL(string: "https://example.com")!) == nil)
        #expect(AILinks.key(from: URL(string: "mailbar://thread")!) == nil)
    }

    @Test func linkifiesBracketedBacktickedAndBareKeys() {
        let out = AILinks.linkify("看 [o/r#1]、`[o/r#2]`、o/r#3 和 [18c3f0a1b2c3d4e5]。")
        #expect(out == "看 [o/r#1](\(link("o/r#1")))、[o/r#2](\(link("o/r#2")))、[o/r#3](\(link("o/r#3"))) 和 [18c3f0a1b2c3d4e5](\(link("18c3f0a1b2c3d4e5")))。")
    }

    @Test func leavesExistingLinksAndPlainTextAlone() {
        let existing = "见 [文档](https://x.com/o/r#1) 和普通文字 123"
        #expect(AILinks.linkify(existing) == existing)
        #expect(AILinks.linkify("没有编号 #12 和 a/b") == "没有编号 #12 和 a/b")
    }

    @Test func keysAreCollectedInOrderWithoutDuplicates() {
        let text = AILinks.linkify("[o/r#2] 然后 [o/r#1] 再 [o/r#2]")
        #expect(AILinks.keys(in: text) == ["o/r#2", "o/r#1"])
    }
}
