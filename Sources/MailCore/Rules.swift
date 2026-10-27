import CryptoKit
import Foundation

/// 一条提醒规则。`rules.json` 里每个字段都可省略，默认值见 init(from:)。
public struct Rule: Codable, Equatable, Sendable {
    public enum Field: String, Codable, Sendable, CaseIterable { case subject, from, to, body }

    public var name: String
    public var enabled: Bool
    /// 关键词，在 fields 指定的字段里找；命中方式见 requireAll
    public var keywords: [String]
    public var fields: [Field]
    /// 发件人包含任意一个即可；与 keywords 同时设置时两者都要满足
    public var from: [String]
    /// 命中任意一个就排除这封邮件（在 fields 指定的字段里找）
    public var exclude: [String]
    /// GitHub 通知邮件的 X-GitHub-Reason（mention / review_requested / assign / ci_activity / state_change …）；
    /// 包含其中任意一个即命中，与 keywords、from 同时设置时都要满足
    public var reasons: [String]
    /// true 时 keywords / from / exclude / reasons 按正则解释
    public var regex: Bool
    /// true 时 keywords 必须全部出现；false（默认）时出现任意一个即可
    public var requireAll: Bool
    /// false 时只记录命中（用于侧栏筛选），不弹通知也不响
    public var notify: Bool
    /// true 时是"强提醒"：置顶提醒卡片 + 循环响铃 + Dock 图标跳动，直到用户处理
    public var strong: Bool
    /// nil = 默认通知音；"none" = 静音；其余为系统声音名（如 Glass）或音频文件路径
    public var sound: String?
    /// 列表里这条规则的标签颜色，取值见 Rule.palette；nil 时按提醒方式取默认色
    public var color: String?

    public static let palette = ["red", "orange", "yellow", "green", "cyan", "blue", "purple", "pink", "gray"]

    public init(name: String, enabled: Bool = true, keywords: [String] = [], fields: [Field] = [.subject, .body],
                from: [String] = [], reasons: [String] = [], exclude: [String] = [], regex: Bool = false,
                requireAll: Bool = false, notify: Bool = true, strong: Bool = false, sound: String? = nil,
                color: String? = nil) {
        self.name = name
        self.enabled = enabled
        self.keywords = keywords
        self.fields = fields
        self.from = from
        self.reasons = reasons
        self.exclude = exclude
        self.regex = regex
        self.requireAll = requireAll
        self.notify = notify
        self.strong = strong
        self.sound = sound
        self.color = color
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        fields = try c.decodeIfPresent([Field].self, forKey: .fields) ?? [.subject, .body]
        from = try c.decodeIfPresent([String].self, forKey: .from) ?? []
        reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        regex = try c.decodeIfPresent(Bool.self, forKey: .regex) ?? false
        requireAll = try c.decodeIfPresent(Bool.self, forKey: .requireAll) ?? false
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? true
        strong = try c.decodeIfPresent(Bool.self, forKey: .strong) ?? false
        sound = try c.decodeIfPresent(String.self, forKey: .sound)
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }
}

struct RuleFile: Codable {
    var rules: [Rule]
}

/// 用来匹配规则的邮件内容。
struct Matchable: Equatable {
    var subject: String
    var from: String
    var to: String
    var body: String
    var reason: String

    init(subject: String, from: String, to: String = "", body: String, reason: String = "") {
        self.subject = subject
        self.from = from
        self.to = to
        self.body = Self.strippingQuotedReplies(body)
        self.reason = reason
    }

    init(_ message: ParsedMessage) {
        self.init(subject: message.subject, from: message.from, to: message.to, body: message.bodyText, reason: GitHubReason.effective(reason: message.reason ?? "", kind: MessageKind(rawValue: message.kind) ?? .human))
    }

    /// 回复邮件会引用整段历史（以 ">" 开头的行），不应让旧内容里的关键词重复触发。
    static func strippingQuotedReplies(_ text: String) -> String {
        guard text.contains(">") else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(">") }
            .joined(separator: "\n")
    }
}

private enum Pattern {
    case literal(String)
    case regex(NSRegularExpression)

    func matches(_ text: String) -> Bool {
        switch self {
        case .literal(let s):
            return text.range(of: s, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .regex(let re):
            return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }
}

/// 预编译后的规则集合：正则只编译一次。
struct RuleSet {
    private struct Compiled {
        let rule: Rule
        let keywords: [Pattern]
        let from: [Pattern]
        let reasons: [Pattern]
        let exclude: [Pattern]
    }

    private let compiled: [Compiled]
    var rules: [Rule] { compiled.map(\.rule) }

    static let empty = RuleSet(rules: [])

    /// 规则本身应已通过 RuleStore 校验；这里遇到非法正则会直接跳过该规则。
    init(rules: [Rule]) {
        compiled = rules.compactMap { rule in
            func patterns(_ list: [String]) -> [Pattern]? {
                var result: [Pattern] = []
                for item in list {
                    if rule.regex {
                        guard let re = try? NSRegularExpression(pattern: item, options: [.caseInsensitive]) else { return nil }
                        result.append(.regex(re))
                    } else {
                        result.append(.literal(item))
                    }
                }
                return result
            }
            guard rule.enabled, let k = patterns(rule.keywords), let f = patterns(rule.from), let r = patterns(rule.reasons),
                  let e = patterns(rule.exclude) else { return nil }
            guard !k.isEmpty || !f.isEmpty || !r.isEmpty else { return nil }
            return Compiled(rule: rule, keywords: k, from: f, reasons: r, exclude: e)
        }
    }

    func matching(_ m: Matchable) -> [Rule] {
        compiled.filter { Self.matches($0, m) }.map(\.rule)
    }

    private static func text(_ field: Rule.Field, in m: Matchable) -> String {
        switch field {
        case .subject: return m.subject
        case .from: return m.from
        case .to: return m.to
        case .body: return m.body
        }
    }

    private static func matches(_ c: Compiled, _ m: Matchable) -> Bool {
        let haystacks = c.rule.fields.map { text($0, in: m) }
        let found: (Pattern) -> Bool = { p in haystacks.contains(where: p.matches) }
        if !c.from.isEmpty, !c.from.contains(where: { $0.matches(m.from) }) { return false }
        if !c.reasons.isEmpty, !c.reasons.contains(where: { $0.matches(m.reason) }) { return false }
        if !c.keywords.isEmpty {
            let ok = c.rule.requireAll ? c.keywords.allSatisfy(found) : c.keywords.contains(where: found)
            if !ok { return false }
        }
        if c.exclude.contains(where: found) { return false }
        return true
    }
}

struct LoadedRules {
    var rules: [Rule]
    var fingerprint: String
    var warnings: [String]
}

public enum RuleStore {
    public static func defaultPath() -> String {
        if let custom = ProcessInfo.processInfo.environment["MAIL_RULES"] { return (custom as NSString).expandingTildeInPath }
        return ("~/Library/Application Support/MailClient/rules.json" as NSString).expandingTildeInPath
    }

    static let sample = """
    {
      "rules": [
        {
          "name": "示例：服务器告警",
          "enabled": false,
          "keywords": ["告警", "alert", "P0"],
          "fields": ["subject", "body"],
          "strong": true,
          "sound": "Sosumi"
        },
        {
          "name": "示例：重要联系人",
          "enabled": false,
          "from": ["boss@example.com"],
          "sound": "Glass"
        }
      ]
    }

    """

    /// 文件不存在时写入示例（示例规则默认关闭）。
    public static func createSampleIfMissing(at path: String) throws {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(sample.utf8).write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Validation

    /// 逐条检查规则：problems 会阻止保存/生效，warnings 只是提示。
    static func check(_ rules: [Rule]) -> (problems: [String], warnings: [String]) {
        var problems: [String] = []
        var warnings: [String] = []
        var seen = Set<String>()
        for (index, rule) in rules.enumerated() {
            let label = rule.name.isEmpty ? "第 \(index + 1) 条规则" : "规则「\(rule.name)」"
            if rule.name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(label) 缺少 name") }
            if !seen.insert(rule.name).inserted { problems.append("\(label) 的 name 重复") }
            if rule.keywords.isEmpty && rule.from.isEmpty && rule.reasons.isEmpty {
                problems.append("\(label) 至少要有 keywords、from 或 reasons")
            }
            if rule.fields.isEmpty { problems.append("\(label) 的 fields 不能为空") }
            if (rule.keywords + rule.from + rule.reasons + rule.exclude).contains(where: { $0.isEmpty }) { problems.append("\(label) 含有空关键词") }
            if let color = rule.color, !Rule.palette.contains(color) { problems.append("\(label) 的颜色「\(color)」无效") }
            if rule.regex {
                for pattern in rule.keywords + rule.from + rule.reasons + rule.exclude where (try? NSRegularExpression(pattern: pattern)) == nil {
                    problems.append("\(label) 的正则无效: \(pattern)")
                }
            }
            if rule.enabled, let sound = rule.sound, sound.lowercased() != "none", SoundLibrary.resolve(sound) == nil {
                warnings.append("\(label) 的声音「\(sound)」找不到，将使用静音")
            }
        }
        return (problems, warnings)
    }

    /// 给界面用：规则里有哪些必须先改掉的问题。
    public static func validate(_ rules: [Rule]) -> [String] { check(rules).problems }

    /// 给界面用：不影响保存的提示（比如声音文件找不到）。
    public static func warnings(for rules: [Rule]) -> [String] { check(rules).warnings }

    /// 解析并校验规则；任何错误都会一次性列出，抛 MailError.config。
    static func parse(_ data: Data) throws -> LoadedRules {
        let file: RuleFile
        do {
            file = try JSONDecoder().decode(RuleFile.self, from: data)
        } catch {
            throw MailError.config("规则文件不是合法 JSON，或字段类型不对: \(error.localizedDescription)")
        }
        let result = check(file.rules)
        if !result.problems.isEmpty { throw MailError.config("规则文件有问题:\n- " + result.problems.joined(separator: "\n- ")) }

        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return LoadedRules(rules: file.rules, fingerprint: fingerprint, warnings: result.warnings)
    }

    // MARK: - Read / write (for the settings UI)

    /// 读取规则列表；文件不存在时先写入示例。
    public static func read(path: String = defaultPath()) throws -> [Rule] {
        try createSampleIfMissing(at: path)
        guard let data = FileManager.default.contents(atPath: path) else { throw MailError.config("读不到规则文件: \(path)") }
        return try parse(data).rules
    }

    /// 校验后原子写入；有问题时不写并抛错。
    public static func write(_ rules: [Rule], to path: String = defaultPath()) throws {
        let problems = check(rules).problems
        guard problems.isEmpty else { throw MailError.config("规则有问题:\n- " + problems.joined(separator: "\n- ")) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(RuleFile(rules: rules))
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// 给命令行用：人类可读的规则列表；文件有问题时抛错。
    public static func describe(path: String) throws -> String {
        try createSampleIfMissing(at: path)
        guard let data = FileManager.default.contents(atPath: path) else { throw MailError.config("读不到规则文件: \(path)") }
        let loaded = try parse(data)
        var lines = ["规则文件: \(path)"]
        if loaded.rules.isEmpty { lines.append("（还没有规则）") }
        for rule in loaded.rules {
            var parts: [String] = []
            if !rule.keywords.isEmpty {
                parts.append("关键词 \(rule.keywords)（\(rule.fields.map(\.rawValue).joined(separator: "/"))，\(rule.requireAll ? "全部" : "任一")）")
            }
            if !rule.from.isEmpty { parts.append("发件人 \(rule.from)") }
            if !rule.reasons.isEmpty { parts.append("GitHub 原因 \(rule.reasons)") }
            if !rule.exclude.isEmpty { parts.append("排除 \(rule.exclude)") }
            if rule.regex { parts.append("正则") }
            parts.append(rule.notify ? "\(rule.strong ? "强提醒" : "通知")，声音 \(rule.sound ?? "默认")" : "仅记录")
            lines.append("\(rule.enabled ? "✓" : "✗") \(rule.name)：\(parts.joined(separator: "，"))")
        }
        lines += loaded.warnings.map { "⚠️ \($0)" }
        return lines.joined(separator: "\n")
    }
}
