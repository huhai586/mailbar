import AppKit
import Combine
import MailCore
import SwiftUI

// MARK: - Model

/// 规则编辑器的状态：把 rules.json 读成可编辑列表，改动后自动校验并保存。
@MainActor
final class RulesEditorModel: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var rule: Rule
    }

    enum SaveState: Equatable { case saved, invalid, failed(String) }

    @Published var entries: [Entry] = []
    @Published var selection: UUID?
    @Published private(set) var problems: [String] = []
    @Published private(set) var warnings: [String] = []
    @Published private(set) var saveState: SaveState = .saved
    @Published private(set) var preview: RulePreview?
    @Published private(set) var loadError: String?

    private let service: MailService
    private var lastSaved: [Rule] = []
    private var cancellables = Set<AnyCancellable>()

    init(service: MailService) {
        self.service = service
        reload()
        $entries.dropFirst().debounce(for: .milliseconds(600), scheduler: DispatchQueue.main).sink { [weak self] _ in
            self?.save()
        }.store(in: &cancellables)
        $entries.dropFirst().debounce(for: .milliseconds(500), scheduler: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshPreview()
        }.store(in: &cancellables)
        $selection.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshPreview() }.store(in: &cancellables)
    }

    var selectedEntry: Entry? { entries.first { $0.id == selection } }

    /// 从文件重新读取。有没保存的无效改动时不覆盖。
    func reload() {
        guard saveState == .saved else { return }
        do {
            let rules = try RuleStore.read()
            lastSaved = rules
            if rules != entries.map(\.rule) { entries = rules.map { Entry(rule: $0) } }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        if selection == nil || selectedEntry == nil { selection = entries.first?.id }
        problems = RuleStore.validate(entries.map(\.rule))
        warnings = RuleStore.warnings(for: entries.map(\.rule))
    }

    func add() {
        let entry = Entry(rule: Rule(name: uniqueName("新规则")))
        entries.append(entry)
        selection = entry.id
    }

    /// 从模板添加规则（已有同名的跳过）。
    func addTemplates(_ templates: [Rule]) {
        let new = RuleTemplates.missing(from: templates, in: entries.map(\.rule))
        guard !new.isEmpty else { return }
        let added = new.map { Entry(rule: $0) }
        entries += added
        selection = added.first?.id
    }

    func duplicate(_ id: UUID) {
        guard let source = entries.first(where: { $0.id == id }) else { return }
        var rule = source.rule
        rule.name = uniqueName(source.rule.name + " 副本")
        let copy = Entry(rule: rule)
        if let index = entries.firstIndex(where: { $0.id == id }) { entries.insert(copy, at: index + 1) }
        selection = copy.id
    }

    func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index)
        if selection == id { selection = entries.indices.contains(index) ? entries[index].id : entries.last?.id }
    }

    func binding(for id: UUID) -> Binding<Rule> {
        Binding(
            get: { self.entries.first { $0.id == id }?.rule ?? Rule(name: "") },
            set: { newValue in
                if let index = self.entries.firstIndex(where: { $0.id == id }) { self.entries[index].rule = newValue }
            })
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(entries.map(\.rule.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func save() {
        let rules = entries.map(\.rule)
        problems = RuleStore.validate(rules)
        warnings = RuleStore.warnings(for: rules)
        guard problems.isEmpty else {
            saveState = .invalid
            return
        }
        guard rules != lastSaved else {
            saveState = .saved
            return
        }
        do {
            try RuleStore.write(rules)
            lastSaved = rules
            saveState = .saved
            service.rulesFileChanged()
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    private func refreshPreview() {
        guard let rule = selectedEntry?.rule, let store = service.store else {
            preview = nil
            return
        }
        preview = try? store.preview(rule: rule, sampleLimit: 4)
    }
}

// MARK: - Views

struct RulesSettingsView: View {
    @ObservedObject var service: MailService
    @StateObject private var model: RulesEditorModel

    init(service: MailService) {
        self.service = service
        _model = StateObject(wrappedValue: RulesEditorModel(service: service))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 220)
                Divider()
                editor.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .onAppear { model.reload() }
    }

    // MARK: Rule list

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(model.entries) { entry in
                    RuleRow(rule: entry.rule).tag(entry.id)
                        .contextMenu {
                            Button("复制") { model.duplicate(entry.id) }
                            Button("删除", role: .destructive) { model.remove(entry.id) }
                        }
                }
                .onMove { source, destination in model.entries.move(fromOffsets: source, toOffset: destination) }
            }
            .listStyle(.inset)
            Divider()
            HStack(spacing: 4) {
                Button { model.add() } label: { Image(systemName: "plus") }.help("新建规则")
                Button {
                    if let id = model.selection { model.remove(id) }
                } label: { Image(systemName: "minus") }
                    .help("删除所选规则")
                    .disabled(model.selection == nil)
                Button {
                    if let id = model.selection { model.duplicate(id) }
                } label: { Image(systemName: "plus.square.on.square") }
                    .help("复制所选规则")
                    .disabled(model.selection == nil)
                Spacer()
                Menu {
                    Button("添加 GitHub + Jira 推荐规则") { model.addTemplates(RuleTemplates.github + RuleTemplates.jira) }
                    ForEach(RuleTemplates.groups, id: \.name) { group in
                        Divider()
                        Button("添加全部 \(group.name) 规则") { model.addTemplates(group.rules) }
                        ForEach(group.rules, id: \.name) { template in
                            Button("   \(template.name)") { model.addTemplates([template]) }
                                .disabled(model.entries.contains { $0.rule.name == template.name })
                        }
                    }
                } label: {
                    Label("模板", systemImage: "wand.and.stars")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    // MARK: Editor

    @ViewBuilder
    private var editor: some View {
        if let id = model.selection, model.selectedEntry != nil {
            RuleEditor(rule: model.binding(for: id), preview: model.preview, problems: model.problems, warnings: model.warnings, service: service)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 36)).foregroundStyle(.tertiary)
                Text(model.entries.isEmpty ? "还没有规则，点左下角的 + 新建" : "选择一条规则").foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            switch model.saveState {
            case .saved:
                Label("已自动保存", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            case .invalid:
                Label("有问题，修正后才会保存", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            case .failed(let message):
                Label("保存失败：\(message)", systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            if let error = model.loadError {
                Text(error).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
            Text("侧栏的「规则」会列出所有启用的规则").font(.caption).foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct RuleRow: View {
    let rule: Rule

    private var icon: String {
        if !rule.notify { return "line.3.horizontal.decrease" }
        return rule.strong ? "exclamationmark.triangle.fill" : "bell.fill"
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.color(for: rule)).frame(width: 8, height: 8)
            Image(systemName: icon)
                .foregroundStyle(rule.strong && rule.notify ? .red : .secondary)
                .frame(width: 16)
            Text(rule.name.isEmpty ? "（未命名）" : rule.name).lineLimit(1)
            Spacer()
        }
        .opacity(rule.enabled ? 1 : 0.45)
    }
}

private enum AlertLevel: String, CaseIterable, Identifiable {
    case filterOnly, normal, strong
    var id: String { rawValue }
    var title: String {
        switch self {
        case .filterOnly: return "仅筛选"
        case .normal: return "通知"
        case .strong: return "强提醒"
        }
    }
}

private struct RuleEditor: View {
    @Binding var rule: Rule
    let preview: RulePreview?
    let problems: [String]
    let warnings: [String]
    let service: MailService
    @State private var previewing: MessageSummary?

    private var level: Binding<AlertLevel> {
        Binding(
            get: { !rule.notify ? .filterOnly : (rule.strong ? .strong : .normal) },
            set: { newValue in
                rule.notify = newValue != .filterOnly
                rule.strong = newValue == .strong
            })
    }

    /// 颜色色块：nil 表示"自动"（按提醒方式取默认色）。
    private func swatch(_ name: String?) -> some View {
        let selected = rule.color == name
        let fill: Color = name.map(Theme.color(named:)) ?? Theme.color(for: Rule(name: "", keywords: ["x"], notify: rule.notify, strong: rule.strong))
        return Button { rule.color = name } label: {
            ZStack {
                Circle().fill(fill).frame(width: 16, height: 16)
                if name == nil { Image(systemName: "a.circle").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                if selected { Circle().stroke(Color.primary, lineWidth: 2).frame(width: 21, height: 21) }
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(PlainPointerButtonStyle())
        .help(name == nil ? "自动" : name!)
    }

    private func fieldBinding(_ field: Rule.Field) -> Binding<Bool> {
        Binding(
            get: { rule.fields.contains(field) },
            set: { on in
                var set = Set(rule.fields)
                if on { set.insert(field) } else { set.remove(field) }
                rule.fields = Rule.Field.allCases.filter(set.contains)   // 保持固定顺序
            })
    }

    private static let knownReasons: [(String, String)] = [
        ("review_requested", "请求你 Review"), ("mention", "被 @ 提及"), ("assign", "指派给你"), ("ci_activity", "CI 活动"),
        ("state_change", "状态变更（合并 / 关闭）"), ("author", "你创建的"), ("comment", "评论"), ("security_alert", "安全告警"),
    ]

    private static let fieldTitles: [Rule.Field: String] = [.subject: "标题", .body: "正文", .from: "发件人", .to: "收件人"]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Text("名称")
                    TextField("", text: $rule.name, prompt: Text("规则名称"))
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).labelsHidden()
                        .frame(maxWidth: .infinity)
                }
                Toggle("启用", isOn: $rule.enabled)
            }

            Section("匹配条件") {
                LabeledContent("在这些位置查找关键词") {
                    HStack(spacing: 12) {
                        ForEach([Rule.Field.subject, .body, .from, .to], id: \.self) { field in
                            Toggle(Self.fieldTitles[field] ?? field.rawValue, isOn: fieldBinding(field))
                        }
                    }
                }
                TokenListEditor(title: "关键词", items: $rule.keywords, placeholder: "输入关键词，回车添加")
                Picker("命中方式", selection: $rule.requireAll) {
                    Text("出现任意一个关键词").tag(false)
                    Text("必须出现全部关键词").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("把关键词当作正则表达式", isOn: $rule.regex)
                TokenListEditor(title: "发件人包含", optional: true, items: $rule.from, placeholder: "例如 boss@company.com")
                // GitHub 通知原因：常用的做成可开关的标签，别的可以手填；它们是同一个列表，不再分成两处
                TokenListEditor(title: "GitHub 通知原因", optional: true, hint: "只匹配带有这些原因的 GitHub 通知邮件（邮件头 X-GitHub-Reason）。",
                                items: $rule.reasons, placeholder: "其他原因，例如 team_mention，回车添加",
                                suggestions: Self.knownReasons.map { TokenListEditor.Suggestion(value: $0.0, label: $0.1) })
                TokenListEditor(title: "排除词", optional: true, hint: "出现这些词的邮件不算命中。", items: $rule.exclude, placeholder: "输入排除词，回车添加")
            }

            Section("命中后") {
                LabeledContent("标签颜色") {
                    HStack(spacing: 6) {
                        swatch(nil)
                        ForEach(Rule.palette, id: \.self) { swatch($0) }
                    }
                }
                Picker("提醒方式", selection: level) {
                    ForEach(AlertLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                switch level.wrappedValue {
                case .filterOnly:
                    Text("只记录命中，不弹通知也不响铃，邮件可在侧栏按这条规则筛选。").font(.caption).foregroundStyle(.secondary)
                case .normal:
                    SoundPicker(title: "提示音", selection: $rule.sound, defaultLabel: "跟随设置里的默认提示音")
                case .strong:
                    SoundPicker(title: "强提醒声音", selection: $rule.sound, defaultLabel: "跟随设置里的强提醒声音")
                    Text("置顶提醒卡片 + 循环响铃 + Dock 图标跳动，直到你处理。具体间隔在「提醒」页设置。").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("试匹配（本地已同步的邮件）") {
                if let preview {
                    Text("会命中 \(preview.matchCount) 封").fontWeight(.medium)
                    ForEach(preview.samples, id: \.id) { sample in
                        Button { previewing = sample } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(sample.subject.isEmpty ? "（无主题）" : sample.subject).lineLimit(1)
                                Text(MailAddress.parse(sample.from).displayName + " · " + DateText.list(sample.date))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("点击预览这封邮件")
                    }
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }

            if !problems.isEmpty || !warnings.isEmpty {
                Section("需要处理") {
                    ForEach(problems, id: \.self) { Label($0, systemImage: "xmark.circle").foregroundStyle(.red).font(.callout) }
                    ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: Binding(get: { previewing.map { PreviewTarget(id: $0.id) } }, set: { if $0 == nil { previewing = nil } })) { target in
            MessagePreviewSheet(messageId: target.id, service: service,
                                caption: "规则「\(rule.name.isEmpty ? "未命名" : rule.name)」会命中这封邮件，看看对不对")
        }
    }
}

private struct PreviewTarget: Identifiable { let id: String }

/// 一组字符串（关键词、发件人、GitHub 原因、排除词）的编辑：已有的显示成可删除的标签，底部一个输入框回车添加。
/// 有「常用项」时（GitHub 原因），常用项做成可开关的标签，选中就是加进了列表；列表里不在常用项里的，显示成可删除的标签。
/// 标题、说明、标签、输入框都在同一列里左对齐，输入框和按钮同高。
struct TokenListEditor: View {
    struct Suggestion: Hashable {
        let value: String
        let label: String
    }

    let title: String
    var optional = false
    var hint: String?
    @Binding var items: [String]
    let placeholder: String
    var suggestions: [Suggestion] = []
    @State private var draft = ""

    private var custom: [String] { items.filter { item in !suggestions.contains { $0.value == item } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                if optional { Text("可选").font(.caption).foregroundStyle(.secondary) }
            }
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }

            if !suggestions.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        let on = items.contains(suggestion.value)
                        Button { toggle(suggestion.value) } label: {
                            HStack(spacing: 4) {
                                if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                                Text(suggestion.label)
                            }
                            .font(.callout)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .background(on ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
                            .overlay(Capsule().stroke(Color.secondary.opacity(on ? 0 : 0.3), lineWidth: 0.5))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(suggestion.value)
                        .accessibilityLabel(suggestion.label)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }

            if !custom.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(custom, id: \.self) { item in
                        HStack(spacing: 5) {
                            Text(item).lineLimit(1)
                            Button { items.removeAll { $0 == item } } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("删除")
                            .accessibilityLabel("删除 \(item)")
                        }
                        .font(.callout)
                        .padding(.leading, 9).padding(.trailing, 5).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                        .overlay(Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 0.5))
                    }
                }
            }

            HStack(spacing: 8) {
                // 输入框占满整行、文字左对齐（Form 默认会把输入框推到右半边、文字右对齐）
                TextField("", text: $draft, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).labelsHidden()
                    .frame(maxWidth: .infinity)
                    .onSubmit(add)
                Button("添加", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func toggle(_ value: String) {
        if items.contains(value) { items.removeAll { $0 == value } } else { items.append(value) }
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        if !items.contains(value) { items.append(value) }
        draft = ""
    }
}
