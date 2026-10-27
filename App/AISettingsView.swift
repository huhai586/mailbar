import MailCore
import SwiftUI

/// 设置 → AI：配置 AI 服务（路由目标），以及「用 AI 判断新邮件要不要通知」的开关和 prompt。
struct AISettingsView: View {
    @ObservedObject var service: MailService
    @State private var config = AIConfigStore.read()
    @State private var keys: [String: String] = [:]
    @State private var status: [String: String] = [:]
    @State private var testing: Set<String> = []
    @State private var samples: [SampleResult] = []
    @State private var trying = false
    @State private var saveError: String?
    @State private var memories: [AIMemory] = []
    @State private var newMemory = ""
    @State private var decisions: [AIDecision] = []

    private struct SampleResult: Identifiable {
        let id: String
        let subject: String
        let outcome: String
        let notify: Bool?
    }

    var body: some View {
        Form {
            Section("AI 判断新邮件是否通知") {
                Toggle("所有新邮件由 AI 决定要不要通知", isOn: $config.notifyEnabled)
                    .disabled(config.providers.isEmpty)
                if config.providers.isEmpty {
                    Text("先在下面添加一个 AI 服务。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("使用的服务", selection: activeBinding) {
                        ForEach(config.providers) { Text($0.name).tag($0.id) }
                    }
                }
                Text("打开后，所有新邮件的通知都由 AI 按下面的 prompt 决定，优先级高于提醒规则：AI 说不通知，规则命中也不会通知；AI 说通知，且邮件命中了规则，就沿用规则的名字、声音和强提醒。AI 出错或超时时，自动回退到原来的规则和「新邮件通知」设置。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("隐私：判断时会把邮件的来源、发件人、主题和正文前 1200 字发给你选的服务。邮件内容敏感的话，建议选本机 Ollama / LM Studio。")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("打开 PR / 会话时自动生成 AI 摘要", isOn: $config.autoSummarize)
                    .disabled(config.providers.isEmpty)
                Text("默认关闭：摘要只在你点「生成」时才调用 AI。打开后每个有新动静的 PR 第一次打开时会自动生成一次（结果缓存在本地，新邮件来了才重新生成）。")
                    .font(.caption).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("判断 prompt")
                        Spacer()
                        Button("恢复默认") { config.notifyPrompt = AINotifyJudge.defaultPrompt }
                            .disabled(config.notifyPrompt == AINotifyJudge.defaultPrompt)
                    }
                    TextEditor(text: $config.notifyPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 150)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    Text("用自然语言写：哪些要通知、哪些不要。程序会自动追加输出格式要求，不用你写 JSON。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button(trying ? "判断中…" : "用最近 5 封邮件试一下") { Task { await trySamples() } }
                        .disabled(trying || config.active == nil || service.store == nil)
                    Text("不会产生通知，只看 AI 的判断").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(samples) { sample in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(sample.notify == true ? "通知" : (sample.notify == false ? "不通知" : "出错"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(sample.notify == true ? Color.orange : (sample.notify == false ? .secondary : Color.red))
                            .frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sample.subject).lineLimit(1)
                            Text(sample.outcome).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }

            Section {
                Toggle("每天自动生成「今日简报」并通知", isOn: $config.briefAuto).disabled(config.providers.isEmpty)
                DatePicker("生成时间", selection: briefTime, displayedComponents: .hourAndMinute).disabled(!config.briefAuto)
                Picker("跟进提醒", selection: $config.followUpHours) {
                    Text("关闭").tag(0)
                    ForEach([4, 8, 24, 48], id: \.self) { Text("需要我处理的事等超过 \($0) 小时就提醒").tag($0) }
                }
                Text("简报在设定的时间之后、应用运行时生成（电脑睡着时会在醒来后补上），一天一份，会调用一次 AI。跟进提醒不调用 AI：「需要你处理」的 PR 或 CI 失败放了太久还没看，会提醒你一次，有新动静才会再提醒。到点的待办提醒不受这里控制，始终会发。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("主动提醒")
            }

            Section {
                ForEach(memories) { memory in
                    HStack {
                        Text(memory.text).font(.callout)
                        Spacer()
                        Button(role: .destructive) { deleteMemory(memory) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("添加一条，比如「Dependabot 的 PR 不用通知我」", text: $newMemory).onSubmit(addMemory)
                    Button("添加", action: addMemory).disabled(newMemory.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("记忆")
            } footer: {
                Text("助手和通知判断都会参考这些。你也可以直接对助手说「记住……」。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if decisions.isEmpty {
                    Text("还没有记录。打开上面的开关后，AI 每次判断都会记在这里。").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(decisions) { decision in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(decision.notify ? "通知" : "不通知")
                            .font(.caption.weight(.semibold)).foregroundStyle(decision.notify ? Color.orange : .secondary)
                            .frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(decision.subject).lineLimit(1)
                            Text(decision.reason.isEmpty ? "（没有给理由）" : decision.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        feedbackButton(decision, value: 1, symbol: "hand.thumbsup")
                        feedbackButton(decision, value: -1, symbol: "hand.thumbsdown")
                    }
                }
            } header: {
                Text("最近的 AI 判断")
            } footer: {
                Text("判断得不对就点 👎，之后遇到类似的邮件，AI 会参考你的纠正。通知上也有同样的 👍 / 👎 按钮。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach($config.providers) { $provider in
                    providerEditor($provider)
                }
                Menu("添加服务") {
                    ForEach(AIProvider.presets, id: \.name) { preset in
                        Button(preset.name) { add(preset) }
                    }
                    Divider()
                    Button("自定义（OpenAI 兼容）") {
                        add(AIProvider(name: "自定义", kind: .openai, baseURL: "", model: ""))
                    }
                }
            } header: {
                Text("AI 服务")
            } footer: {
                Text("本应用不内置模型，只负责调用你配置的服务。OpenAI 兼容格式覆盖 OpenAI、DeepSeek、OpenRouter、Ollama、LM Studio 等绝大多数服务。API Key 存在系统钥匙串里。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            for provider in config.providers { keys[provider.id] = AIKeyStore.key(for: provider.id) }
            reloadAssistantData()
        }
        .onChange(of: config) { _, new in
            do { try AIConfigStore.write(new); saveError = nil } catch { saveError = "保存失败：\(error.localizedDescription)" }
        }
    }

    private var briefTime: Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: config.briefHour, minute: config.briefMinute, second: 0, of: Date()) ?? Date() },
                set: {
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                    config.briefHour = parts.hour ?? 9
                    config.briefMinute = parts.minute ?? 0
                })
    }

    private func reloadAssistantData() {
        memories = (try? service.store?.memories()) ?? []
        decisions = (try? service.store?.recentDecisions(limit: 20)) ?? []
    }

    private func addMemory() {
        guard (try? service.store?.addMemory(newMemory)) != nil else { return }
        newMemory = ""
        reloadAssistantData()
    }

    private func deleteMemory(_ memory: AIMemory) {
        try? service.store?.deleteMemory(memory.id)
        reloadAssistantData()
    }

    private func feedbackButton(_ decision: AIDecision, value: Int, symbol: String) -> some View {
        let selected = decision.feedback == value
        return Button {
            try? service.store?.setFeedback(messageId: decision.messageId, value: selected ? nil : value)
            reloadAssistantData()
        } label: {
            Image(systemName: selected ? symbol + ".fill" : symbol)
                .foregroundStyle(selected ? (value > 0 ? Color.green : Color.red) : .secondary)
        }
        .buttonStyle(.borderless)
        .help(value > 0 ? "判断对了" : "判断错了")
    }

    private var activeBinding: Binding<String> {
        Binding(get: { config.active?.id ?? "" }, set: { config.activeProviderID = $0 })
    }

    private func add(_ provider: AIProvider) {
        var provider = provider
        provider.id = UUID().uuidString
        config.providers.append(provider)
        if config.activeProviderID == nil { config.activeProviderID = provider.id }
        keys[provider.id] = ""
    }

    private func remove(_ provider: AIProvider) {
        AIKeyStore.deleteKey(for: provider.id)
        keys[provider.id] = nil
        config.providers.removeAll { $0.id == provider.id }
        if config.activeProviderID == provider.id { config.activeProviderID = config.providers.first?.id }
        if config.providers.isEmpty { config.notifyEnabled = false }
    }

    private func keyBinding(_ id: String) -> Binding<String> {
        Binding(get: { keys[id] ?? "" }, set: { value in
            keys[id] = value
            do { try AIKeyStore.setKey(value, for: id); saveError = nil } catch { saveError = "Key 保存失败：\(error.localizedDescription)" }
        })
    }

    @ViewBuilder
    private func providerEditor(_ provider: Binding<AIProvider>) -> some View {
        let id = provider.wrappedValue.id
        DisclosureGroup {
            TextField("名称", text: provider.name)
            Picker("接口协议", selection: provider.kind) {
                ForEach(AIProtocol.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            TextField("服务地址", text: provider.baseURL, prompt: Text("https://api.openai.com/v1"))
            TextField("模型", text: provider.model, prompt: Text("模型名"))
            SecureField("API Key", text: keyBinding(id), prompt: Text("本机服务可留空"))
            HStack {
                Button(testing.contains(id) ? "测试中…" : "测试连接") { Task { await test(provider.wrappedValue) } }
                    .disabled(testing.contains(id))
                if let text = status[id] {
                    Text(text).font(.caption).foregroundStyle(text.hasPrefix("✓") ? Color.green : Color.red).lineLimit(2)
                }
                Spacer()
                Button("删除", role: .destructive) { remove(provider.wrappedValue) }
            }
        } label: {
            HStack {
                Text(provider.wrappedValue.name.isEmpty ? "未命名" : provider.wrappedValue.name)
                Text("\(provider.wrappedValue.kind.title) · \(provider.wrappedValue.model)")
                    .font(.caption).foregroundStyle(.secondary)
                if config.active?.id == id { Text("使用中").font(.caption2).foregroundStyle(Color.accentColor) }
            }
        }
    }

    private func client(for provider: AIProvider) -> AIClient {
        AIClient(provider: provider, apiKey: keys[provider.id] ?? AIKeyStore.key(for: provider.id))
    }

    private func test(_ provider: AIProvider) async {
        testing.insert(provider.id)
        defer { testing.remove(provider.id) }
        do {
            let started = Date()
            let reply = try await client(for: provider).complete(system: "只回复 ok", user: "ping")
            status[provider.id] = "✓ 连接成功（\(Int(Date().timeIntervalSince(started) * 1000)) ms）：\(reply.prefix(30))"
        } catch {
            status[provider.id] = "✗ \(error.localizedDescription)"
        }
    }

    private func trySamples() async {
        guard let provider = config.active, let store = service.store else { return }
        trying = true
        defer { trying = false }
        samples = []
        let judge = AINotifyJudge(chat: client(for: provider), prompt: config.notifyPrompt)
        let recent: [AISample]
        do { recent = try store.recentAISamples(limit: 5) } catch {
            samples = [SampleResult(id: "error", subject: "读取本地邮件失败", outcome: error.localizedDescription, notify: nil)]
            return
        }
        if recent.isEmpty {
            samples = [SampleResult(id: "empty", subject: "本地还没有邮件", outcome: "先同步几封邮件再试", notify: nil)]
            return
        }
        for sample in recent {
            do {
                let verdict = try await judge.judge(subject: sample.subject, from: sample.from, source: sample.source,
                                                    kind: sample.kind, body: sample.body)
                samples.append(SampleResult(id: sample.id, subject: sample.subject, outcome: verdict.reason, notify: verdict.notify))
            } catch {
                samples.append(SampleResult(id: sample.id, subject: sample.subject, outcome: error.localizedDescription, notify: nil))
            }
        }
    }
}
