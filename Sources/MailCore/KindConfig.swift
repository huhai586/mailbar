import Foundation

/// 判断"真人 / 机器人 / 推送"的全部规则。内置默认值就是原来写死的那套；用户在设置里改的部分存进 classifier.json，
/// 覆盖规则优先于内置判断，所以识别错了永远有办法纠正。
public struct KindConfig: Codable, Equatable, Sendable {
    public struct Override: Codable, Equatable, Sendable, Identifiable {
        public enum Field: String, Codable, Sendable, CaseIterable { case sender, subject, body }

        public var id: String
        public var enabled: Bool
        public var field: Field
        /// 要匹配的文字（不区分大小写）；`regex` 为真时当正则
        public var pattern: String
        public var regex: Bool
        /// MessageKind 的 rawValue
        public var kind: String

        public init(id: String = UUID().uuidString, enabled: Bool = true, field: Field = .sender, pattern: String = "",
                    regex: Bool = false, kind: MessageKind = .human) {
            self.id = id
            self.enabled = enabled
            self.field = field
            self.pattern = pattern
            self.regex = regex
            self.kind = kind.rawValue
        }

        public var messageKind: MessageKind { MessageKind(rawValue: kind) ?? .human }
    }

    /// 按顺序匹配，第一条命中的决定类型
    public var overrides: [Override]
    /// 发件人包含这些词的算机器人账号（之后再按内容分例行 / 出问题 / 其他）。GitHub 机器人账号通常带 `[bot]`
    public var botSenders: [String]
    /// 主题命中就算"出问题"（GitHub Actions 的 CI 失败通知）
    public var subjectAlertPattern: String
    /// 正文开头命中就算推送
    public var pushPattern: String
    /// 评论的标题行命中，说明是固定模板的报告（机器人）
    public var templatePattern: String
    /// 机器人邮件里命中就算"出问题"
    public var alertPattern: String
    /// 机器人邮件里命中就算"例行"
    public var routinePattern: String

    /// 以前发布过的内置默认值；文件里的值恰好等于其中一个，说明用户没改过，可以换成当前默认值。
    private static let legacyTemplatePatterns = [
        #"test summary|test report|test service|ctrf|blackbox|bundle size check|quality gate|review council|playwright-report|bb-failure-context"#
    ]
    private static let legacyRoutinePatterns = [
        #"quality gate passed|all tests passed|test summary|test report|review council.{0,40}in progress|bundle size check"#
    ]

    /// 返回有没有改动。
    mutating func upgradeUntouchedDefaults() -> Bool {
        var changed = false
        if Self.legacyTemplatePatterns.contains(templatePattern) { templatePattern = Self.defaults.templatePattern; changed = true }
        if Self.legacyRoutinePatterns.contains(routinePattern) { routinePattern = Self.defaults.routinePattern; changed = true }
        return changed
    }

    public static let defaults = KindConfig(
        overrides: [Override(id: "default-jira", field: .sender, pattern: "automation for jira", kind: .bot)],
        botSenders: ["[bot]"],
        subjectAlertPattern: #"\brun failed\b"#,
        pushPattern: #"^\s*@?\S+ (?:force-)?pushed \d+ commits?\b"#,
        templatePattern: #"tests? summary|tests? report|test service|ctrf|blackbox|bundle size check|quality gate|review council|playwright-report|bb-failure-context"#,
        alertPattern: #"quality gate failed|\x{1F525}|blackbox fail|\*\*[1-9]\d* failed\*\*|\x{274C}|:x:|\bfailure\b|\d+ tests? failed|bundle size check[\s\S]{0,2000}?(?:\x{26A0}|:warning:|&#9888|&#128308|\x{1F534}|exceed)"#,
        routinePattern: #"quality gate passed|all tests passed|tests? summary|tests? report|review council.{0,40}in progress|bundle size check"#)

    public init(overrides: [Override], botSenders: [String], subjectAlertPattern: String, pushPattern: String,
                templatePattern: String, alertPattern: String, routinePattern: String) {
        self.overrides = overrides
        self.botSenders = botSenders
        self.subjectAlertPattern = subjectAlertPattern
        self.pushPattern = pushPattern
        self.templatePattern = templatePattern
        self.alertPattern = alertPattern
        self.routinePattern = routinePattern
    }

    // 文件里缺的字段用默认值，老文件和手写的精简文件都能读
    public init(from decoder: Decoder) throws {
        let d = KindConfig.defaults
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overrides = try c.decodeIfPresent([Override].self, forKey: .overrides) ?? d.overrides
        botSenders = try c.decodeIfPresent([String].self, forKey: .botSenders) ?? d.botSenders
        subjectAlertPattern = try c.decodeIfPresent(String.self, forKey: .subjectAlertPattern) ?? d.subjectAlertPattern
        pushPattern = try c.decodeIfPresent(String.self, forKey: .pushPattern) ?? d.pushPattern
        templatePattern = try c.decodeIfPresent(String.self, forKey: .templatePattern) ?? d.templatePattern
        alertPattern = try c.decodeIfPresent(String.self, forKey: .alertPattern) ?? d.alertPattern
        routinePattern = try c.decodeIfPresent(String.self, forKey: .routinePattern) ?? d.routinePattern
    }

    /// 非法正则的说明（没有问题返回空）。非法的规则 / 模式在判断时会被跳过。
    public func problems() -> [String] {
        var result: [String] = []
        func check(_ name: String, _ pattern: String) {
            if (try? NSRegularExpression(pattern: pattern)) == nil { result.append("\(name)不是合法的正则") }
        }
        for item in overrides where item.enabled && item.regex && !item.pattern.isEmpty { check("覆盖规则「\(item.pattern)」", item.pattern) }
        check("出问题的主题模式", subjectAlertPattern)
        check("推送模式", pushPattern)
        check("固定模板模式", templatePattern)
        check("出问题模式", alertPattern)
        check("例行模式", routinePattern)
        return result
    }
}

/// 当前生效的配置：识别发生在同步线程，界面在主线程改，所以加锁。
public final class KindConfigStore: @unchecked Sendable {
    public static let shared = KindConfigStore()
    private let lock = NSLock()
    private var value = KindConfig.defaults

    public var config: KindConfig {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }

    public static func defaultPath() -> String {
        if let custom = ProcessInfo.processInfo.environment["MAIL_CLASSIFIER"] { return (custom as NSString).expandingTildeInPath }
        return ("~/Library/Application Support/MailClient/classifier.json" as NSString).expandingTildeInPath
    }

    /// 读文件；没有文件就用默认值。
    public static func read(at path: String = defaultPath()) -> KindConfig {
        guard let data = FileManager.default.contents(atPath: path),
              var config = try? JSONDecoder().decode(KindConfig.self, from: data) else { return .defaults }
        // 保存下来的配置会把当时的默认值一起存进文件；之后内置默认值改进了，没被用户改过的就跟着升级
        if config.upgradeUntouchedDefaults() { try? write(config, at: path) }
        return config
    }

    public static func write(_ config: KindConfig, at path: String = defaultPath()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    /// 启动时调用：把文件里的配置装进来。
    public func load() { config = Self.read() }
}
