import AppKit
import MailCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var service: MailService
    @AppStorage(Pref.appearance) private var appearance = "dark"
    @AppStorage(Pref.settingsTab) private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView(service: service)
                .tabItem { Label("通用", systemImage: "gearshape") }.tag("general")
            AlertSettingsView(service: service)
                .tabItem { Label("提醒", systemImage: "bell") }.tag("alerts")
            RulesSettingsView(service: service)
                .tabItem { Label("规则", systemImage: "line.3.horizontal.decrease.circle") }.tag("rules")
            KindSettingsView(service: service)
                .tabItem { Label("识别", systemImage: "person.badge.shield.checkmark") }.tag("kinds")
            AccountSettingsView(service: service)
                .tabItem { Label("账号与同步", systemImage: "person.crop.circle") }.tag("account")
        }
        .frame(width: 800, height: 640)
        .applyAppearance(appearance)
    }
}

// MARK: - 通用

private struct GeneralSettingsView: View {
    @ObservedObject var service: MailService
    @AppStorage(Pref.appearance) private var appearance = "dark"
    @AppStorage(Pref.listDensity) private var density = "compact"
    @AppStorage(Pref.monoBody) private var monoBody = true
    @AppStorage(Pref.showSnippets) private var showSnippets = true
    @AppStorage(Pref.renderMarkdown) private var renderMarkdown = true
    @AppStorage(Pref.githubTextView) private var githubText = true
    @AppStorage(Pref.invertEmails) private var invertEmails = true
    @AppStorage(Pref.landing) private var landing = "attention"
    @AppStorage(Pref.autoCleanRoutine) private var autoClean = false
    @AppStorage(Pref.pollInterval) private var poll = 10
    @AppStorage(Pref.openWindowAtLaunch) private var openAtLaunch = true
    @AppStorage(Pref.loadRemoteImages) private var remoteImages = true
    @AppStorage(Pref.markReadMode) private var markMode = MarkReadMode.onOpen.rawValue
    @AppStorage(Pref.markReadDelay) private var markDelay = 3
    @AppStorage(Pref.markReadWholeThread) private var wholeThread = true
    @AppStorage(Pref.groupByPR) private var groupByPR = true
    @AppStorage(Pref.githubLogin) private var githubLogin = ""
    @AppStorage(Pref.jiraName) private var jiraName = ""
    @AppStorage(Pref.sidebarShown) private var shownRaw = "UNREAD,ALL"
    @State private var allLabels: [LabelInfo] = []
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $appearance) {
                    Text("深色").tag("dark")
                    Text("浅色").tag("light")
                    Text("跟随系统").tag("system")
                }
                Picker("列表密度", selection: $density) {
                    Text("紧凑（一屏看更多）").tag("compact")
                    Text("舒适").tag("comfortable")
                }
                Toggle("正文使用等宽字体", isOn: $monoBody)
                Toggle("没有标签的邮件在列表里显示摘要", isOn: $showSnippets)
            }

            Section("同步") {
                Picker("检查新邮件的间隔", selection: $poll) {
                    Text("3 秒").tag(3)
                    Text("5 秒").tag(5)
                    Text("10 秒").tag(10)
                    Text("15 秒").tag(15)
                    Text("30 秒").tag(30)
                    Text("1 分钟").tag(60)
                    Text("5 分钟").tag(300)
                }
                Text("每次检查只请求一次 Gmail 的变更列表，开销很小；切回应用时也会立刻同步一次。").font(.caption).foregroundStyle(.secondary)
            }

            Section("列表") {
                TextField("GitHub 用户名", text: $githubLogin, prompt: Text("留空自动识别\(detectedLoginHint)"))
                Text("用来判断一封邮件有没有真的 @ 你。机器人报告里常写 “Triggered by @你”，GitHub 会因此把整个 PR 之后的邮件都标成“提及”；只有真人写的、并且正文里确实有 @ 你的才会显示「提及你」。").font(.caption).foregroundStyle(.secondary)
                TextField("Jira 显示名", text: $jiraName, prompt: Text("例如 Howard Hu"))
                Text("你在 Jira 里被 @ 时显示的名字。Jira 邮件的正文里出现这个名字，才会显示可点击的「提到你」，点击跳到对应的那封邮件；留空则所有 Jira「提到你」都算。").font(.caption).foregroundStyle(.secondary)
                Toggle("按 PR 聚合", isOn: $groupByPR)
                Text("同一个 PR 的评论、推送、CI 结果、Jira 联动合成一行；关闭后按 Gmail 会话逐条列出。列表顶部的「会话 | PR」和快捷键 p 也可随时切换。").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(SystemMailbox.all) { item in
                    Toggle(item.title, isOn: shownBinding(item.key))
                }
                ForEach(allLabels.filter { SystemMailbox.categoryNames[$0.id] != nil }) { label in
                    Toggle("分类 · \(SystemMailbox.categoryNames[label.id] ?? label.name)", isOn: shownBinding(label.id))
                }
                ForEach(allLabels.filter { $0.type == "user" }) { label in
                    Toggle("标签 · \(label.name)", isOn: shownBinding(label.id))
                }
            } header: {
                Text("侧栏显示")
            } footer: {
                Text("勾选的邮箱、Gmail 分类和自建标签会出现在侧栏；默认只显示「未读」和「所有邮件」。")
            }
            Section("分诊") {
                Picker("启动时先看", selection: $landing) {
                    Text("待处理").tag("attention")
                    Text("收件箱").tag("inbox")
                }
                Toggle("自动把例行机器人邮件标为已读", isOn: $autoClean)
                Text("质量门通过、包体积检查、测试汇总、评审进行中这类「一切正常」的机器人邮件，收到后直接标为已读，不再占用未读数。出问题的（CI 失败、质量门失败、测试有失败）和真人的邮件不受影响。需要「修改邮件状态」的授权。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("启动") {
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in setLaunchAtLogin(enabled) }
                if let launchError { Text(launchError).font(.caption).foregroundStyle(.red) }
                Toggle("启动时打开主窗口", isOn: $openAtLaunch)
                Text("关闭后，应用启动时只显示菜单栏图标，需要时再从菜单里打开窗口。").font(.caption).foregroundStyle(.secondary)
            }

            Section("阅读") {
                Toggle("渲染 Markdown", isOn: $renderMarkdown)
                Text("GitHub 评论和 Markdown 格式的邮件会渲染成表格、列表、代码块等，和 GitHub 网页上一致。每封邮件右上角的小标签可在 MD / 原文 / HTML 之间切换。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("GitHub 通知默认显示正文（而不是 HTML 排版）", isOn: $githubText)
                Text("正文版去掉了页脚和机器人排版，更适合快速扫读。").font(.caption).foregroundStyle(.secondary)
                Toggle("深色主题下把 HTML 邮件反色显示", isOn: $invertEmails)
                Toggle("默认加载邮件里的远程图片", isOn: $remoteImages)
                Text("关闭后会拦截远程图片（防止发件人通过图片得知你已读），可在每封邮件上单独加载。").font(.caption).foregroundStyle(.secondary)

                Picker("标记已读", selection: $markMode) {
                    ForEach(MarkReadMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if markMode == MarkReadMode.afterDelay.rawValue {
                    Stepper("停留 \(markDelay) 秒后标记", value: $markDelay, in: 1...30)
                }
                if markMode != MarkReadMode.manual.rawValue {
                    Picker("标记范围", selection: $wholeThread) {
                        Text("整个会话").tag(true)
                        Text("只标记当前这封").tag(false)
                    }
                }
                if !service.canModify {
                    HStack {
                        Label("标记已读需要「修改邮件状态」的授权", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("授权…") { service.signIn() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { allLabels = (try? service.store?.labels()) ?? [] }
    }

    private var detectedLoginHint: String {
        (try? service.store?.detectedGitHubLogin()).flatMap { $0 }.map { "（现在识别为 \($0)）" } ?? ""
    }

    private func shownBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { Pref.parseShown(shownRaw).contains(key) },
            set: { on in
                var set = Pref.parseShown(shownRaw)
                if on { set.insert(key) } else { set.remove(key) }
                shownRaw = Pref.joinShown(set)
            })
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = "设置失败：\(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - 提醒

private struct AlertSettingsView: View {
    @ObservedObject var service: MailService
    @AppStorage(Pref.alertsEnabled) private var enabled = true
    @AppStorage(Pref.alertMaxAgeHours) private var maxAge = 24
    @AppStorage(Pref.summaryThreshold) private var threshold = 5
    @AppStorage(Pref.defaultSound) private var defaultSound = ""
    @AppStorage(Pref.strongRepeatSeconds) private var repeatSeconds = 10
    @AppStorage(Pref.strongMaxMinutes) private var maxMinutes = 5
    @AppStorage(Pref.strongBounceDock) private var bounce = true
    @AppStorage(Pref.strongSound) private var strongSound = "Sosumi"

    var body: some View {
        Form {
            Section("提醒") {
                Toggle("命中规则时提醒", isOn: $enabled)
                Text("关闭后不再弹通知、不响铃，但仍会记录命中，侧栏的规则筛选照常可用。").font(.caption).foregroundStyle(.secondary)
                Picker("只提醒这段时间内到达的邮件", selection: $maxAge) {
                    Text("1 小时").tag(1)
                    Text("6 小时").tag(6)
                    Text("24 小时").tag(24)
                    Text("3 天").tag(72)
                    Text("不限").tag(0)
                }
                Text("电脑睡眠后才同步到的旧邮件不会让你被一堆通知淹没。").font(.caption).foregroundStyle(.secondary)
                Stepper("一次超过 \(threshold) 封时合并成一条通知", value: $threshold, in: 1...20)
                SoundPicker(title: "默认提示音", selection: $defaultSound.optionalSound, defaultLabel: "系统默认通知音")
                Text("规则没有单独指定声音时使用。").font(.caption).foregroundStyle(.secondary)
            }
            .disabled(false)

            Section("强提醒") {
                Text("规则设为「强提醒」后：屏幕上弹出始终置顶的提醒卡片，循环响铃，Dock 图标持续跳动，直到你点「查看」或「忽略」。")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("每 \(repeatSeconds) 秒响铃一次", value: $repeatSeconds, in: 3...120)
                Picker("最长持续", selection: $maxMinutes) {
                    Text("1 分钟").tag(1)
                    Text("5 分钟").tag(5)
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                    Text("直到处理").tag(0)
                }
                Toggle("Dock 图标跳动", isOn: $bounce)
                SoundPicker(title: "默认强提醒声音", selection: $strongSound.optionalSound, defaultLabel: "Sosumi")
                HStack {
                    Spacer()
                    Button("试一下强提醒") { service.strongAlerts.show([Self.demoHit]) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static let demoHit = RuleHit(messageId: "demo", threadId: "demo", ruleName: "示例规则", subject: "这是一条强提醒的预览",
                                         from: "提醒测试 <demo@example.com>", snippet: "点击「忽略」关闭；真实的强提醒会一直响到你处理。",
                                         sound: nil, strong: true)
}

// MARK: - 账号与同步

private struct AccountSettingsView: View {
    @ObservedObject var service: MailService
    @AppStorage(Pref.initialSyncLimit) private var initialLimit = 500
    @AppStorage(Pref.loadOlderBatch) private var olderBatch = 50
    @State private var confirmResync = false
    @State private var confirmSignOut = false
    @State private var clientResult: (ok: Bool, message: String)?
    @State private var dropTargeted = false

    private var clientID: String? { ClientConfig.installedClientID() }

    private func importClient(_ url: URL) {
        clientResult = service.importClientJSON(from: url)
    }

    private func chooseClientFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 GCP 下载的 OAuth 客户端 JSON"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { importClient(url) }
    }

    private var localCount: Int { (try? service.store?.messageCount()) ?? 0 }

    var body: some View {
        Form {
            Section("账号") {
                LabeledContent("邮箱", value: service.accountEmail ?? "（尚未同步）")
                LabeledContent("授权") {
                    if service.loginRequired {
                        Label("需要重新登录", systemImage: "xmark.circle").foregroundStyle(.red)
                    } else if service.canModify {
                        Label("可读取、可修改邮件状态", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        Label("仅可读取（标记已读需要升级）", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                HStack {
                    Button(service.canModify && !service.loginRequired ? "重新授权…" : "授权 / 升级授权…") { service.signIn() }
                    Button("退出登录…", role: .destructive) { confirmSignOut = true }
                }
                Text("授权只会用来读取邮件和修改「已读 / 未读」状态，不会发送或删除邮件。").font(.caption).foregroundStyle(.secondary)
            }

            Section("OAuth 客户端") {
                LabeledContent("状态") {
                    if let clientID {
                        Label("已配置 · \(clientID.prefix(12))…", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        Label("未配置", systemImage: "xmark.circle").foregroundStyle(.red)
                    }
                }
                HStack {
                    Button("导入 JSON…") { chooseClientFile() }
                    Text("或把文件拖到这里").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                                                                           style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    importClient(url)
                    return true
                } isTargeted: { dropTargeted = $0 }
                if let clientResult {
                    Text(clientResult.message).font(.caption).foregroundStyle(clientResult.ok ? Color.secondary : Color.red)
                }
                Text("在 GCP 控制台 → API 和服务 → 凭据 → 创建凭据 → OAuth 客户端 ID → 应用类型选「桌面应用」，下载 JSON 导入这里。导入后文件会存到 \(ClientConfig.filePath)（仅自己可读）。换电脑时在新电脑上导入同一个文件即可。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("本地邮件") {
                LabeledContent("已同步", value: "\(localCount) 封")
                Picker("首次 / 重新同步的邮件数", selection: $initialLimit) {
                    ForEach([200, 500, 1000, 2000, 5000], id: \.self) { Text("最近 \($0) 封").tag($0) }
                }
                HStack {
                    Picker("向前加载", selection: $olderBatch) {
                        ForEach([50, 100, 200, 500, 1000], id: \.self) { Text("\($0) 封").tag($0) }
                    }
                    Button(service.loadingOlder ? "加载中…" : "加载更早的邮件") {
                        Task { await service.loadOlder(count: olderBatch) }
                    }
                    .disabled(service.loadingOlder)
                }
                Text("列表滚到底会自动按这个数量继续加载更早的邮件。受 Gmail 配额限制，大约每分钟能拉 100 封，数量大时需要等一会儿。").font(.caption).foregroundStyle(.secondary)
                Button("按上面的数量重新完整同步…") { confirmResync = true }
                    .disabled(service.syncing)
            }

            Section("文件") {
                LabeledContent("数据库") {
                    HStack {
                        Text(MailStore.defaultPath()).font(.caption).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: MailStore.defaultPath())])
                        }
                    }
                }
                LabeledContent("规则文件") {
                    HStack {
                        Text(RuleStore.defaultPath()).font(.caption).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button("用文本编辑器打开") { openRulesFile() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("按设置的数量重新完整同步？", isPresented: $confirmResync) {
            Button("重新同步") { Task { await service.resyncAll() } }
        } message: {
            Text("会重新拉取最近 \(initialLimit) 封邮件，受配额限制可能需要几分钟。")
        }
        .confirmationDialog("退出登录？", isPresented: $confirmSignOut) {
            Button("退出登录", role: .destructive) { service.signOut() }
        } message: {
            Text("会删除本机保存的授权。之后需要重新登录才能同步。本地已下载的邮件不会被删除。")
        }
    }

    private func openRulesFile() {
        try? RuleStore.createSampleIfMissing(at: RuleStore.defaultPath())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-t", RuleStore.defaultPath()]
        try? process.run()
    }
}


// MARK: - 识别（真人 / 机器人）

private struct KindSettingsView: View {
    @ObservedObject var service: MailService
    @State private var config = KindConfig.defaults
    @State private var loaded = false

    private static let kinds: [(MessageKind, String)] = [
        (.human, "真人"), (.botRoutine, "例行机器人"), (.botAlert, "出问题的机器人"), (.bot, "其他机器人"), (.push, "推送"),
    ]

    var body: some View {
        Form {
            Section {
                Text("MailBar 靠这些规则判断一封邮件是真人写的、机器人的例行报告、机器人报出的问题，还是有人推送了提交。识别错了，在这里加一条覆盖规则就能纠正；改动立刻保存，并对本地所有邮件重新分类。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if config.overrides.isEmpty {
                    Text("还没有覆盖规则。也可以在邮件卡片右上角的「归类」菜单里直接改。").font(.caption).foregroundStyle(.secondary)
                }
                ForEach($config.overrides) { $item in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $item.enabled).labelsHidden()
                        Picker("", selection: $item.field) {
                            Text("发件人").tag(KindConfig.Override.Field.sender)
                            Text("主题").tag(KindConfig.Override.Field.subject)
                            Text("正文").tag(KindConfig.Override.Field.body)
                        }.labelsHidden().frame(width: 80)
                        Text(item.regex ? "匹配" : "包含").foregroundStyle(.secondary).font(.caption)
                        TextField("", text: $item.pattern, prompt: Text("文字")).labelsHidden().textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                        Toggle("正则", isOn: $item.regex).toggleStyle(.checkbox).font(.caption)
                        Text("→").foregroundStyle(.secondary)
                        Picker("", selection: $item.kind) {
                            ForEach(Self.kinds, id: \.0) { Text($0.1).tag($0.0.rawValue) }
                        }.labelsHidden().frame(width: 130)
                        Button { config.overrides.removeAll { $0.id == item.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("删除这条规则")
                    }
                }
                Button { config.overrides.insert(.init(), at: 0) } label: { Label("添加覆盖规则", systemImage: "plus") }
            } header: {
                Text("覆盖规则（从上到下，第一条命中的生效）")
            }

            Section {
                TextField("每个词用逗号分隔", text: Binding(
                    get: { config.botSenders.joined(separator: ", ") },
                    set: { config.botSenders = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                Text("发件人名字里含这些词的，当作机器人账号，再按内容分成例行 / 出问题 / 其他。GitHub 的机器人账号通常带 [bot]；有的服务账号不带，比如 CI 报告专用的账号，把它的名字加进来。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("机器人账号")
            }

            Section {
                patternField("出问题（主题）", $config.subjectAlertPattern, "GitHub Actions 的失败通知邮件主题")
                patternField("出问题（正文）", $config.alertPattern, "机器人报告里出现这些就算出问题，比如 Quality Gate failed、🔥、N tests failed")
                patternField("例行（正文）", $config.routinePattern, "机器人报告里出现这些算例行，比如 Quality Gate passed、测试汇总")
                patternField("固定模板（标题行）", $config.templatePattern, "评论第一行是这些词，就是机器人的报告；真人评论里顺口提到不算")
                patternField("推送（开头）", $config.pushPattern, "邮件开头形如 “@x pushed 1 commit.”")
                HStack {
                    Spacer()
                    Button("全部恢复默认") {
                        var fresh = KindConfig.defaults
                        fresh.overrides = config.overrides
                        fresh.botSenders = config.botSenders
                        config = fresh
                    }
                }
            } header: {
                Text("高级：内置的识别模式（正则，不区分大小写）")
            }

            Section {
                let problems = config.problems()
                ForEach(problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
                HStack {
                    Text(service.kindStatus ?? "改动会自动保存并重新分类。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("按当前规则重新分类") { service.reclassifyNow() }
                }
                Text("规则保存在 ~/Library/Application Support/MailClient/classifier.json，也可以直接编辑这个文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { config = service.kindConfig; loaded = true }
        .onChange(of: config) { _, new in if loaded { service.updateKindConfig(new) } }
        .onChange(of: service.kindConfig) { _, new in if new != config { config = new } }
    }

    private func patternField(_ title: String, _ value: Binding<String>, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            TextField("", text: value).textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }
}
