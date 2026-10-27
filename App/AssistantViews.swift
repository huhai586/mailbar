import MailCore
import SwiftUI

// MARK: - 接入点

enum AIRuntime {
    /// 按设置里选中的 AI 服务建一个助手；没配服务时返回 nil（界面据此隐藏 / 引导）。
    /// 记忆和用户纠正过的判断会一起带上。
    static func assistant(store: MailStore?, githubLogin: String?) -> AIAssistant? {
        let config = AIConfigStore.read()
        guard let provider = config.active else { return nil }
        let client = AIClient(provider: provider, apiKey: AIKeyStore.key(for: provider.id), timeout: 90, maxTokens: 1500)
        let jira = (UserDefaults.standard.string(forKey: Pref.jiraName) ?? "").trimmingCharacters(in: .whitespaces)
        let login = githubLogin ?? (UserDefaults.standard.string(forKey: Pref.githubLogin) ?? "")
        let context = store.map(AIContext.build(store:)) ?? ""
        return AIAssistant(chat: client, profile: AIProfile(githubLogin: login, jiraName: jira), context: context)
    }
}

/// 今日简报的缓存（一天一份）：手动生成和每天自动生成共用。
enum BriefCache {
    private static let key = "aiBriefCache"

    static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static func load() -> String? {
        guard let cache = UserDefaults.standard.dictionary(forKey: key) as? [String: String], cache["date"] == today else { return nil }
        return cache["text"]
    }

    static func save(_ text: String) {
        UserDefaults.standard.set(["date": today, "text": text], forKey: key)
    }
}

extension ReaderModel {
    func makeAssistant() -> AIAssistant? { AIRuntime.assistant(store: service.store, githubLogin: githubLogin) }

    var aiConfigured: Bool { AIConfigStore.read().active != nil }
}

// MARK: - 助手的状态（对话 + 今日简报）

@MainActor
final class AssistantModel: ObservableObject {
    struct Turn: Identifiable {
        let id = UUID()
        let role: AIMessage.Role
        let text: String
        var steps: [String] = []
        var isError = false
    }

    @Published private(set) var turns: [Turn] = []
    @Published var input = ""
    @Published private(set) var busy = false

    @Published private(set) var brief: String?
    @Published private(set) var briefLoading = false
    @Published private(set) var briefError: String?

    /// 读当天缓存的简报（不联网）。
    func loadCachedBrief() {
        if let cached = BriefCache.load(), cached != brief { brief = cached }
    }

    func generateBrief(reader: ReaderModel) {
        guard !briefLoading, let assistant = reader.makeAssistant(), let tools = reader.mailTools else { return }
        briefLoading = true
        briefError = nil
        Task {
            defer { briefLoading = false }
            do {
                let text = try await assistant.brief(tools: tools)
                brief = text
                BriefCache.save(text)
            } catch {
                briefError = error.localizedDescription
            }
        }
    }

    func send(_ question: String? = nil, reader: ReaderModel) {
        let text = (question ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        guard let assistant = reader.makeAssistant() else {
            turns.append(Turn(role: .assistant, text: "还没有配置 AI 服务：设置 → AI 里添加一个。", isError: true))
            return
        }
        guard let tools = reader.mailTools else {
            turns.append(Turn(role: .assistant, text: "邮件库还没有准备好，稍等一下再问。", isError: true))
            return
        }
        input = ""
        turns.append(Turn(role: .user, text: text))
        // 带上最近的对话（不含出错的回合）；对话要以用户的话开头
        var history = turns.filter { !$0.isError }.suffix(12).map { AIMessage($0.role, $0.text) }
        while history.first?.role == .assistant { history.removeFirst() }
        busy = true
        Task {
            defer { busy = false }
            do {
                let answer = try await assistant.ask(history, tools: tools)
                reader.service.bumpTodos()   // 助手可能刚加了待办 / 提醒
                turns.append(Turn(role: .assistant, text: answer.text.isEmpty ? "（没有得到回答，换个问法试试）" : answer.text, steps: answer.steps))
            } catch {
                turns.append(Turn(role: .assistant, text: error.localizedDescription, isError: true))
            }
        }
    }

    func clear() { turns = [] }
}

// MARK: - 今日概览里的助手

struct AssistantPanel: View {
    @ObservedObject var reader: ReaderModel
    @ObservedObject var service: MailService
    @ObservedObject var model: AssistantModel

    private let suggestions = ["今天有什么需要我处理的？", "谁 review 或评论了我的 PR？", "总结一下昨晚到现在的动态"]

    var body: some View {
        if !reader.aiConfigured {
            VStack(alignment: .leading, spacing: 6) {
                Label("AI 助手", systemImage: "sparkles").font(Theme.ui(13, .semibold)).foregroundStyle(Theme.text)
                Text("配置一个 AI 服务后，这里可以生成今日简报、给 PR 写摘要和待办，也能直接向助手提问。")
                    .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                Button("去设置 AI 服务") { service.openSettings?("ai") }
                    .buttonStyle(PlainPointerButtonStyle()).font(Theme.ui(12)).foregroundStyle(Theme.accent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
        } else {
            VStack(alignment: .leading, spacing: 16) {
                briefCard
                chat
            }
            .onChange(of: service.briefRevision) { model.loadCachedBrief() }   // 后台自动生成好了
            .onAppear {
                model.loadCachedBrief()
                #if DEBUG
                // 调试用：`--args -aiBrief YES` 自动生成简报，`-aiAsk "问题"` 自动提问，方便截图检查
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {   // 等邮件库打开
                    if UserDefaults.standard.bool(forKey: "aiBrief") { model.generateBrief(reader: reader) }
                    if let question = UserDefaults.standard.string(forKey: "aiAsk") { model.send(question, reader: reader) }
                }
                #endif
            }
        }
    }

    // MARK: 简报

    private var briefCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("今日简报", systemImage: "sparkles").font(Theme.ui(13, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                if model.briefLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button(model.brief == nil ? "生成" : "重新生成") { model.generateBrief(reader: reader) }
                        .buttonStyle(PlainPointerButtonStyle()).font(Theme.ui(12)).foregroundStyle(Theme.accent)
                }
            }
            if let brief = model.brief {
                AssistantText(text: brief, reader: reader, service: service)
            } else if !model.briefLoading {
                Text("把未读和最近的动态整理成一份简报：先说需要你处理的，再说值得关注的进展。")
                    .font(Theme.ui(12)).foregroundStyle(Theme.faint)
            }
            if let error = model.briefError { Text(error).font(Theme.ui(11.5)).foregroundStyle(Theme.red) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
    }

    // MARK: 对话

    private var chat: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("问助手").font(Theme.mono(10.5, .semibold)).tracking(0.6).foregroundStyle(Theme.faint)
                Spacer()
                if !model.turns.isEmpty {
                    Button("清空对话") { model.clear() }
                        .buttonStyle(PlainPointerButtonStyle()).font(Theme.ui(11.5)).foregroundStyle(Theme.faint)
                }
            }
            ForEach(model.turns) { turn in
                bubble(turn)
            }
            if model.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在查邮件…").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                }
            }
            if model.turns.isEmpty {
                FlowChips(items: suggestions) { model.send($0, reader: reader) }
            }
            HStack(spacing: 8) {
                TextField("问点什么，比如「#7125 现在卡在哪？」", text: $model.input)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(13))
                    .onSubmit { model.send(reader: reader) }
                Button { model.send(reader: reader) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                        .foregroundStyle(model.input.trimmingCharacters(in: .whitespaces).isEmpty || model.busy ? Theme.faint : Theme.accent)
                }
                .buttonStyle(PlainPointerButtonStyle())
                .disabled(model.busy)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func bubble(_ turn: AssistantModel.Turn) -> some View {
        if turn.role == .user {
            Text(turn.text)
                .font(Theme.ui(13)).foregroundStyle(Theme.text)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !turn.steps.isEmpty {
                    Text("查了：" + turn.steps.joined(separator: " · "))
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.faint).lineLimit(2)
                }
                if turn.isError {
                    Text(turn.text).font(Theme.ui(12.5)).foregroundStyle(Theme.red)
                } else {
                    AssistantText(text: turn.text, reader: reader, service: service)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
        }
    }
}

/// 一排可点的建议问题。
private struct FlowChips: View {
    let items: [String]
    let action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button { action(item) } label: {
                    Text(item).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.raised, in: Capsule())
                        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                }
                .buttonStyle(PlainPointerButtonStyle())
            }
        }
    }
}

// MARK: - 助手文字（轻量 Markdown + 可点的 PR 编号）

struct AssistantText: View {
    let text: String
    @ObservedObject var reader: ReaderModel
    @ObservedObject var service: MailService

    /// PR 编号 / 会话 id 先换成 mailbar:// 链接，点击时跳到对应的邮件。
    private var linked: String { AILinks.linkify(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(linked.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .tint(Theme.blue)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard let key = AILinks.key(from: url) else { return .systemAction }   // 普通网址照旧用浏览器打开
            service.requestNavigation(mailbox: .allMail, threadId: key)
            return .handled
        })
    }

    @ViewBuilder
    private func row(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            Color.clear.frame(height: 3)
        } else if line.hasPrefix("#") {
            Text(inline(line.drop(while: { $0 == "#" || $0 == " " }).description))
                .font(Theme.ui(13, .semibold)).foregroundStyle(Theme.text).padding(.top, 4)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(Theme.faint)
                Text(inline(String(line.dropFirst(2)))).foregroundStyle(Theme.text)
            }
            .font(Theme.ui(12.5))
        } else {
            Text(inline(line)).font(Theme.ui(12.5)).foregroundStyle(Theme.text)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

// MARK: - 线程摘要卡片（PR / 会话详情顶部）

struct AISummaryCard: View {
    @ObservedObject var reader: ReaderModel
    let groupKey: String
    let messages: [MessageDetail]
    let title: String

    @State private var summary: AIThreadSummary?
    @State private var loading = false
    @State private var error: String?
    @State private var attempted = ""
    /// 这个会话里已经加进待办的（按文字）
    @State private var added: Set<String> = []

    private var latestID: String { messages.last?.id ?? "" }
    private var token: String { "\(groupKey)|\(latestID)" }
    /// 只有真人或出问题的机器人消息才值得摘要；整个会话只有例行机器人时没什么可总结
    private var summarizable: Bool { messages.contains { $0.kind != MessageKind.botRoutine.rawValue } }

    var body: some View {
        if reader.aiConfigured, summarizable {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("AI 摘要", systemImage: "sparkles").font(Theme.mono(10.5, .semibold)).tracking(0.4).foregroundStyle(Theme.accent)
                    Spacer()
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(summary == nil ? "生成" : "重新生成") { generate() }
                            .buttonStyle(PlainPointerButtonStyle()).font(Theme.ui(11.5)).foregroundStyle(Theme.accent)
                    }
                }
                if let summary {
                    Text(summary.summary).font(Theme.ui(13)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    if !summary.status.isEmpty {
                        Text("进展：" + summary.status).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    }
                    if !summary.todos.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("待办").font(Theme.mono(10.5, .semibold)).foregroundStyle(Theme.orange)
                            ForEach(summary.todos, id: \.self) { todo in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: "circle").font(.system(size: 8)).foregroundStyle(Theme.orange)
                                    Text(todo).font(Theme.ui(12.5)).foregroundStyle(Theme.text)
                                    Spacer(minLength: 8)
                                    if added.contains(todo) {
                                        Label("已加入", systemImage: "checkmark").font(Theme.ui(11)).foregroundStyle(Theme.faint)
                                    } else {
                                        Button("加入待办") { addTodo(todo) }
                                            .buttonStyle(PlainPointerButtonStyle()).font(Theme.ui(11.5)).foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                        }
                    }
                } else if !loading, error == nil {
                    Text("让 AI 读完这个讨论，告诉你发生了什么、结论是什么、该你做什么。").font(Theme.ui(12)).foregroundStyle(Theme.faint)
                }
                if let error { Text(error).font(Theme.ui(11.5)).foregroundStyle(Theme.red) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.25), lineWidth: 1))
            .task(id: token) { await load() }
        }
    }

    /// 先读缓存；没有缓存且设置了「自动生成」才联网。
    private func load() async {
        guard !latestID.isEmpty, let store = reader.service.store else { return }
        summary = try? store.aiSummary(group: groupKey, latestMessageId: latestID)
        added = Set(((try? store.todos()) ?? []).filter { $0.groupKey == groupKey }.map(\.text))
        error = nil
        if summary == nil, AIConfigStore.read().autoSummarize, attempted != token { generate() }
    }

    private func addTodo(_ text: String) {
        guard let store = reader.service.store, (try? store.addTodo(text, groupKey: groupKey, source: "ai")) != nil else { return }
        added.insert(text)
        reader.service.bumpTodos()
    }

    private func generate() {
        guard !loading, let assistant = reader.makeAssistant(), let store = reader.service.store else { return }
        let key = groupKey, latest = latestID, messages = messages, title = title
        attempted = token
        loading = true
        error = nil
        Task {
            defer { loading = false }
            do {
                let result = try await assistant.summarize(title: title, messages: messages)
                try? store.saveAISummary(result, group: key, latestMessageId: latest)
                if key == groupKey { summary = result }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
