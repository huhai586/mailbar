import Foundation

/// 一次需要提醒用户的规则命中。
public struct RuleHit: Equatable, Sendable {
    public let messageId: String
    public let threadId: String
    public let ruleName: String
    public let subject: String
    public let from: String
    public let snippet: String
    /// 规则里配置的声音（nil = 默认通知音，"none" = 静音）
    public let sound: String?
    /// 规则是"强提醒"
    public let strong: Bool

    public init(messageId: String, threadId: String, ruleName: String, subject: String, from: String,
                snippet: String, sound: String?, strong: Bool) {
        self.messageId = messageId
        self.threadId = threadId
        self.ruleName = ruleName
        self.subject = subject
        self.from = from
        self.snippet = snippet
        self.sound = sound
        self.strong = strong
    }
}

/// 没命中任何提醒规则的新邮件要不要也通知。界面在每次同步前把设置写进来。
public enum NewMailAlerts: String, Sendable, CaseIterable {
    /// 每一封新邮件都通知
    case all
    /// 只通知真人写的和出问题的机器人（CI 失败等）；例行机器人、推送、其他机器人不通知
    case important
    /// 只按规则通知
    case off

    func accepts(kind: String) -> Bool {
        switch self {
        case .all: return true
        case .important: return kind == MessageKind.human.rawValue || kind == MessageKind.botAlert.rawValue
        case .off: return false
        }
    }
}

public struct MonitorResult: Sendable {
    public let summary: SyncSummary
    /// 本轮新到、命中规则且需要提醒的邮件（同一封邮件命中多条规则只提醒一次）
    public let alerts: [RuleHit]
    /// 规则文件的问题（语法错误等）；有错误时继续使用上一份有效规则
    public let ruleWarning: String?
    /// 本轮重新加载了规则（命中记录已重新计算），界面需要刷新规则计数
    public let rulesChanged: Bool

    /// 本轮有没有改动本地邮件库
    public var hasChanges: Bool { summary.fetched + summary.deleted + summary.relabeled > 0 }
}

/// 入库后的规则匹配状态：记录命中（用于筛选）并挑出需要提醒的邮件。
final class MonitorState: @unchecked Sendable {
    private let store: MailStore
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var ruleSet = RuleSet.empty
    private var pending: [RuleHit] = []
    private var newMailAlertsValue = NewMailAlerts.off
    var newMailAlerts: NewMailAlerts {
        get { lock.withLock { newMailAlertsValue } }
        set { lock.withLock { newMailAlertsValue = newValue } }
    }

    private var aiJudgeValue: AINotifyJudge?
    private var aiCandidates: [AICandidate] = []

    /// 等 AI 判断的邮件，连同它命中的提醒规则（AI 说要通知时沿用规则的声音 / 强提醒）。
    struct AICandidate { let message: ParsedMessage; let ruleHits: [RuleHit] }
    /// 设置了就由 AI 决定所有新邮件要不要通知（高于提醒规则，规则只负责声音 / 强提醒）；出错时回退到规则和 newMailAlerts。
    var aiJudge: AINotifyJudge? {
        get { lock.withLock { aiJudgeValue } }
        set { lock.withLock { aiJudgeValue = newValue } }
    }

    /// 一轮同步里最多交给 AI 的邮件数，超出的按 newMailAlerts 处理，避免一次积压几百封把费用打爆。
    static let maxAICandidates = 20

    /// 太旧的邮件（比如电脑睡了几天后才同步到）不弹提醒，只记录命中
    static let defaultMaxAlertAge: TimeInterval = 24 * 3600
    private var maxAlertAgeValue = MonitorState.defaultMaxAlertAge
    var maxAlertAge: TimeInterval {
        get { lock.withLock { maxAlertAgeValue } }
        set { lock.withLock { maxAlertAgeValue = newValue } }
    }

    init(store: MailStore, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.now = now
    }

    var rules: RuleSet {
        get { lock.withLock { ruleSet } }
        set { lock.withLock { ruleSet = newValue } }
    }

    func handle(_ messages: [ParsedMessage], mode: SyncSummary.Mode) throws {
        let set = rules
        let judging = aiJudge != nil
        for message in messages {
            var ruleHits: [RuleHit] = []
            for rule in set.matching(Matchable(message)) {
                let first = try store.recordMatch(messageId: message.id, ruleName: rule.name)
                guard first, mode == .incremental, rule.notify, isAlertable(message) else { continue }
                let hit = RuleHit(messageId: message.id, threadId: message.threadId, ruleName: rule.name,
                                  subject: message.subject, from: message.from, snippet: message.snippet,
                                  sound: rule.sound, strong: rule.strong)
                if judging { ruleHits.append(hit) } else { lock.withLock { pending.append(hit) } }
            }
            if judging, mode == .incremental, isAlertable(message) {
                lock.withLock { aiCandidates.append(AICandidate(message: message, ruleHits: ruleHits)) }
                continue
            }
            if judging, !ruleHits.isEmpty { lock.withLock { pending.append(contentsOf: ruleHits) } }   // 不会交给 AI 的（全量同步 / 太旧）保持原样
            // 没命中规则的新邮件：按"新邮件通知"设置也提醒。放在规则命中之后，takeAlerts 按邮件去重时规则命中（声音、强提醒）优先。
            if mode == .incremental, newMailAlerts.accepts(kind: message.kind), isAlertable(message) {
                let hit = RuleHit(messageId: message.id, threadId: message.threadId, ruleName: "新邮件",
                                  subject: message.subject, from: message.from, snippet: message.snippet,
                                  sound: nil, strong: false)
                lock.withLock { pending.append(hit) }
            }
        }
    }

    /// 让 AI 逐封判断本轮收集到的候选邮件，通知的加入待提醒；AI 出错的邮件回退到"新邮件通知"设置。
    func judgeCandidates() async {
        guard let baseJudge = aiJudge else { return }
        let judge = baseJudge.withContext(AIContext.build(store: store))
        let all = lock.withLock { () -> [AICandidate] in
            defer { aiCandidates = [] }
            return aiCandidates
        }
        let batch = Array(all.prefix(Self.maxAICandidates))
        var hits: [RuleHit] = []
        for candidate in all.dropFirst(Self.maxAICandidates) { hits.append(contentsOf: fallbackHits(for: candidate)) }

        await withTaskGroup(of: [RuleHit].self) { group in
            var iterator = batch.makeIterator()
            func addNext() -> Bool {
                guard let candidate = iterator.next() else { return false }
                let message = candidate.message
                group.addTask { [self] in
                    do {
                        let verdict = try await judge.judge(subject: message.subject, from: message.from, source: message.source,
                                                            kind: message.kind, body: message.bodyText)
                        try? store.recordDecision(messageId: message.id, groupKey: message.prKey ?? message.threadId, subject: message.subject,
                                                  from: message.from, source: message.source, kind: message.kind, notify: verdict.notify,
                                                  reason: verdict.reason, ruleName: candidate.ruleHits.first?.ruleName, now: now())
                        guard verdict.notify else { return [] }
                        let snippet = verdict.reason.isEmpty ? message.snippet : "AI：\(verdict.reason)"
                        if !candidate.ruleHits.isEmpty {
                            // 沿用规则的名字、声音和强提醒，只把理由换成 AI 的
                            return candidate.ruleHits.map {
                                RuleHit(messageId: $0.messageId, threadId: $0.threadId, ruleName: $0.ruleName, subject: $0.subject,
                                        from: $0.from, snippet: snippet, sound: $0.sound, strong: $0.strong)
                            }
                        }
                        return [RuleHit(messageId: message.id, threadId: message.threadId, ruleName: "AI 判定",
                                        subject: message.subject, from: message.from, snippet: snippet, sound: nil, strong: false)]
                    } catch {
                        return fallbackHits(for: candidate)
                    }
                }
                return true
            }
            for _ in 0..<4 where addNext() {}
            while let found = await group.next() {
                hits.append(contentsOf: found)
                _ = addNext()
            }
        }
        lock.withLock { pending.append(contentsOf: hits) }
    }

    /// AI 不可用时的回退：命中的提醒规则照常通知，没命中规则的按"新邮件通知"设置。
    private func fallbackHits(for candidate: AICandidate) -> [RuleHit] {
        if !candidate.ruleHits.isEmpty { return candidate.ruleHits }
        let message = candidate.message
        guard newMailAlerts.accepts(kind: message.kind) else { return [] }
        return [RuleHit(messageId: message.id, threadId: message.threadId, ruleName: "新邮件",
                       subject: message.subject, from: message.from, snippet: message.snippet, sound: nil, strong: false)]
    }

    /// 只提醒收件箱里还没读的、足够新的邮件。
    private func isAlertable(_ m: ParsedMessage) -> Bool {
        guard m.labelIds.contains("INBOX"), m.isUnread else { return false }
        let age = now().timeIntervalSince1970 - Double(m.internalDate) / 1000
        return age <= maxAlertAge
    }

    func takeAlerts() -> [RuleHit] {
        let hits = lock.withLock { () -> [RuleHit] in
            defer { pending = [] }
            return pending
        }
        var seen = Set<String>()
        return hits.filter { seen.insert($0.messageId).inserted }
    }
}

private struct OfflineGmail: GmailAPI {
    func profile() async throws -> GmailProfile { throw MailError.loginRequired }
    func labels() async throws -> [GmailLabel] { throw MailError.loginRequired }
    func listMessageIDs(limit: Int) async throws -> [String] { throw MailError.loginRequired }
    func message(id: String) async throws -> GmailMessage? { throw MailError.loginRequired }
    func history(since startHistoryId: String) async throws -> (records: [HistoryRecord], historyId: String?) {
        throw MailError.loginRequired
    }
    func batchModify(ids: [String], addLabelIds: [String], removeLabelIds: [String]) async throws {
        throw MailError.loginRequired
    }
    func reasonHeader(id: String) async throws -> String? { throw MailError.loginRequired }
}

/// 常驻程序的核心：每次 syncOnce 先刷新规则文件，再同步邮件并返回需要提醒的命中。
public final class MailMonitor: @unchecked Sendable {
    private let store: MailStore
    private let rulesPath: String
    private let state: MonitorState
    private let engine: SyncEngine
    private let lock = NSLock()
    private var loadedFingerprint: String?

    init(api: any GmailAPI, store: MailStore, rulesPath: String, initialLimit: Int = 500,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.rulesPath = rulesPath
        let state = MonitorState(store: store, now: now)
        self.state = state
        engine = SyncEngine(api: api, store: store, initialLimit: initialLimit, log: { _ in },
                            onStored: { messages, mode in try state.handle(messages, mode: mode) })
    }

    public convenience init(oauth: OAuthClient, store: MailStore, rulesPath: String = RuleStore.defaultPath(), initialLimit: Int = 500) {
        self.init(api: GmailClient(oauth: oauth), store: store, rulesPath: rulesPath, initialLimit: initialLimit)
    }

    /// 不联网的实例，只用来重新加载规则 / 重新匹配本地邮件（syncOnce 会抛 loginRequired）。
    public convenience init(offlineStore store: MailStore, rulesPath: String = RuleStore.defaultPath()) {
        self.init(api: OfflineGmail(), store: store, rulesPath: rulesPath)
    }

    /// 立即读取规则文件（规则有变化时会自动重新匹配）。返回规则文件的问题，没有则 nil。
    public func reloadRules() -> String? { refreshRules() }

    /// 给升级前同步的旧邮件补上 X-GitHub-Reason（每次最多 limit 封，细水长流以免占用配额）。
    /// 有补到就重新匹配规则；返回本次补了多少封，0 表示已经补完。
    public func backfillReasons(limit: Int) async throws -> Int {
        let done = try await engine.backfillReasons(limit: limit)
        if done > 0 { _ = refreshRules(); try rematch() }
        return done
    }

    /// 邮件到达多久之内才提醒（秒）。更早的只记录命中，不弹通知。
    public var alertMaxAge: TimeInterval {
        get { state.maxAlertAge }
        set { state.maxAlertAge = newValue }
    }

    /// 向前多拉一些历史邮件，使本地总数达到 limit 封左右。不改变同步位置，不产生提醒。返回新拉取的数量。
    public func loadOlder(limit: Int) async throws -> Int {
        _ = refreshRules()
        return try await engine.loadOlder(limit: limit)
    }

    /// 没命中提醒规则的新邮件要不要通知（默认只按规则）。
    public var newMailAlerts: NewMailAlerts {
        get { state.newMailAlerts }
        set { state.newMailAlerts = newValue }
    }

    /// 设置后，没命中提醒规则的新邮件由 AI 判断要不要通知；nil = 不用 AI。
    public var aiJudge: AINotifyJudge? {
        get { state.aiJudge }
        set { state.aiJudge = newValue }
    }

    public func syncOnce(forceFull: Bool = false) async throws -> MonitorResult {
        let rules = refreshRulesReportingChange()
        let summary = try await engine.sync(forceFull: forceFull)
        await state.judgeCandidates()
        // 同步失败时已记录的待提醒命中会留到下一次成功时再返回
        return MonitorResult(summary: summary, alerts: state.takeAlerts(), ruleWarning: rules.warning,
                             rulesChanged: rules.changed)
    }

    /// 用当前规则重新计算所有本地邮件的命中记录（不产生提醒）。规则文件变化时会自动执行。
    public func rematch() throws {
        try store.relinkPRs()
        try store.clearMatches()
        let rules = state.rules
        var after: Int64 = 0
        while true {
            let page = try store.matchables(afterSeq: after, limit: 200)
            guard let last = page.last else { break }
            for item in page {
                for rule in rules.matching(item.matchable) {
                    _ = try store.recordMatch(messageId: item.id, ruleName: rule.name)
                }
            }
            after = last.seq
        }
    }

    /// 读取规则文件；内容变化时换用新规则并重新匹配。返回需要告知用户的问题（没有则 nil）。
    func refreshRules() -> String? { refreshRulesReportingChange().warning }

    func refreshRulesReportingChange() -> (warning: String?, changed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        do {
            try RuleStore.createSampleIfMissing(at: rulesPath)
            guard let data = FileManager.default.contents(atPath: rulesPath) else {
                throw MailError.config("读不到规则文件: \(rulesPath)")
            }
            let loaded = try RuleStore.parse(data)
            if loaded.fingerprint != loadedFingerprint {
                state.rules = RuleSet(rules: loaded.rules)
                if try store.state("rulesFingerprint") != loaded.fingerprint {
                    try rematch()
                    try store.setState(["rulesFingerprint": loaded.fingerprint])
                }
                loadedFingerprint = loaded.fingerprint
                changed = true
            }
            return (loaded.warnings.isEmpty ? nil : loaded.warnings.joined(separator: "\n"), changed)
        } catch {
            return (error.localizedDescription, changed)
        }
    }
}
