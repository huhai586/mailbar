import Foundation
import Testing
@testable import MailCore

/// 固定"当前时间"，让测试邮件（internalDate = 1_700_000_000_000）看起来是刚到的。
private let fixedNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_100) }

private struct Harness {
    let api = FakeGmail()
    let store: MailStore
    let monitor: MailMonitor
    let rulesPath: String

    init(rules: String) throws {
        rulesPath = NSTemporaryDirectory() + "monitor-\(UUID().uuidString).json"
        try Data(rules.utf8).write(to: URL(fileURLWithPath: rulesPath))
        store = try MailStore(path: nil)
        monitor = MailMonitor(api: api, store: store, rulesPath: rulesPath, now: fixedNow)
    }

    func setRules(_ json: String) throws { try Data(json.utf8).write(to: URL(fileURLWithPath: rulesPath)) }
    func cleanup() { try? FileManager.default.removeItem(atPath: rulesPath) }
}

private let alertRules = """
{"rules":[
  {"name":"告警","keywords":["告警","alert"],"sound":"Sosumi"},
  {"name":"老板","from":["boss@corp.com"],"sound":"Glass"}
]}
"""

@Suite struct MailMonitorTests {
    @Test func fullSyncRecordsMatchesButNeverAlerts() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        h.api.add("a", subject: "服务器告警")
        h.api.add("b", subject: "hello")

        let result = try await h.monitor.syncOnce()
        #expect(result.summary.mode == .full)
        #expect(result.alerts.isEmpty)
        #expect(result.ruleWarning == nil)
        #expect(try h.store.matchCounts().map(\.name) == ["告警"])
        #expect(try h.store.matches(rule: "告警", limit: 10).map(\.id) == ["a"])
    }

    @Test func newMatchingMailAlertsExactlyOnce() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        h.api.add("old")
        _ = try await h.monitor.syncOnce()

        h.api.add("new", subject: "磁盘告警 90%", from: "mon@corp.com")
        let first = try await h.monitor.syncOnce()
        #expect(first.alerts == [RuleHit(messageId: "new", threadId: "t-new", ruleName: "告警", subject: "磁盘告警 90%",
                                         from: "mon@corp.com", snippet: "snip", sound: "Sosumi", strong: false)])

        // 之后的标签变化不会让同一封邮件再次提醒
        h.api.removeLabel("UNREAD", from: "new")
        let second = try await h.monitor.syncOnce()
        #expect(second.alerts.isEmpty)
    }

    @Test func eachMatchingMailCarriesItsOwnRuleAndSound() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        _ = try await h.monitor.syncOnce()
        h.api.add("x", subject: "alert!")
        h.api.add("y", subject: "lunch?", from: "Boss <boss@corp.com>")
        let result = try await h.monitor.syncOnce()
        #expect(Set(result.alerts.map { "\($0.messageId):\($0.sound ?? "-")" }) == ["x:Sosumi", "y:Glass"])
    }

    @Test func mailMatchingTwoRulesAlertsOnceButRecordsBoth() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        _ = try await h.monitor.syncOnce()
        h.api.add("z", subject: "alert from boss", from: "boss@corp.com")
        let result = try await h.monitor.syncOnce()
        #expect(result.alerts.count == 1)
        #expect(result.alerts.first?.ruleName == "告警")   // 规则文件里排在前面的那条
        #expect(try h.store.matchCounts().map(\.name) == ["告警", "老板"])
    }

    @Test func onlyUnreadInboxRecentMailAlerts() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        _ = try await h.monitor.syncOnce()
        h.api.add("read", subject: "alert", labels: ["INBOX"])
        h.api.add("sent", subject: "alert", labels: ["SENT"])
        h.api.add("archived", subject: "alert", labels: ["UNREAD"])
        h.api.add("stale", subject: "alert", date: 1_700_000_000_000 - 48 * 3600 * 1000)
        h.api.add("fresh", subject: "alert")

        let result = try await h.monitor.syncOnce()
        #expect(result.alerts.map(\.messageId) == ["fresh"])
        // 不提醒的也照样记录命中，用于筛选
        #expect(try h.store.matches(rule: "告警", limit: 10).count == 5)
    }

    @Test func strongRulesProduceStrongHits() async throws {
        let h = try Harness(rules: #"{"rules":[{"name":"P0","keywords":["p0"],"strong":true},{"name":"普通","keywords":["fyi"]}]}"#); defer { h.cleanup() }
        _ = try await h.monitor.syncOnce()
        h.api.add("a", subject: "P0 outage")
        h.api.add("b", subject: "fyi only")
        let result = try await h.monitor.syncOnce()
        let byRule = Dictionary(uniqueKeysWithValues: result.alerts.map { ($0.ruleName, $0.strong) })
        #expect(byRule == ["P0": true, "普通": false])
    }

    @Test func alertMaxAgeIsConfigurable() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        _ = try await h.monitor.syncOnce()
        h.monitor.alertMaxAge = 50          // 测试邮件已到达 100 秒
        h.api.add("old", subject: "alert 1")
        #expect(try await h.monitor.syncOnce().alerts.isEmpty)
        h.monitor.alertMaxAge = 200
        h.api.add("new", subject: "alert 2")
        #expect(try await h.monitor.syncOnce().alerts.map(\.messageId) == ["new"])
    }

    @Test func notifyFalseRuleOnlyRecords() async throws {
        let h = try Harness(rules: #"{"rules":[{"name":"quiet","keywords":["newsletter"],"notify":false}]}"#); defer { h.cleanup() }
        _ = try await h.monitor.syncOnce()
        h.api.add("n", subject: "weekly newsletter")
        let result = try await h.monitor.syncOnce()
        #expect(result.alerts.isEmpty)
        #expect(try h.store.matches(rule: "quiet", limit: 10).map(\.id) == ["n"])
    }

    @Test func quotedHistoryInRepliesDoesNotTrigger() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        _ = try await h.monitor.syncOnce()
        h.api.add("reply", subject: "Re: status", body: "ok thanks\n> the alert from last week")
        #expect(try await h.monitor.syncOnce().alerts.isEmpty)
    }

    @Test func editingRulesRematchesExistingMailWithoutAlerting() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        h.api.add("a", subject: "quarterly invoice")
        h.api.add("b", subject: "告警")
        _ = try await h.monitor.syncOnce()
        #expect(try h.store.matches(rule: nil, limit: 10).map(\.id) == ["b"])

        try h.setRules(#"{"rules":[{"name":"财务","keywords":["invoice"],"sound":"Glass"}]}"#)
        let result = try await h.monitor.syncOnce()
        #expect(result.alerts.isEmpty)
        #expect(try h.store.matchCounts().map(\.name) == ["财务"])   // 旧规则的命中被清掉
        #expect(try h.store.matches(rule: "财务", limit: 10).map(\.id) == ["a"])
    }

    @Test func resultReportsRuleReloadsAndChanges() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        h.api.add("a")
        let first = try await h.monitor.syncOnce()
        #expect(first.rulesChanged && first.hasChanges)          // 首次加载规则 + 全量拉取

        let idle = try await h.monitor.syncOnce()
        #expect(!idle.rulesChanged && !idle.hasChanges)

        try h.setRules(#"{"rules":[{"name":"x","keywords":["y"]}]}"#)
        h.api.add("b")
        let changed = try await h.monitor.syncOnce()
        #expect(changed.rulesChanged && changed.hasChanges)
    }

    @Test func invalidRulesFileKeepsPreviousRulesAndReportsProblem() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        _ = try await h.monitor.syncOnce()

        try h.setRules(#"{"rules":[{"name":"broken"}]}"#)
        h.api.add("x", subject: "alert")
        let result = try await h.monitor.syncOnce()
        #expect(result.ruleWarning?.contains("至少要有 keywords、from 或 reasons") == true)
        #expect(result.alerts.map(\.messageId) == ["x"])   // 仍按上一份有效规则提醒

        try h.setRules(alertRules)
        #expect(try await h.monitor.syncOnce().ruleWarning == nil)
    }

    @Test func missingRulesFileGetsDisabledSample() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        try FileManager.default.removeItem(atPath: h.rulesPath)
        _ = try await h.monitor.syncOnce()
        #expect(FileManager.default.fileExists(atPath: h.rulesPath))
        h.api.add("x", subject: "alert")
        #expect(try await h.monitor.syncOnce().alerts.isEmpty)   // 示例规则全部关闭
    }

    @Test func alertsSurviveASyncFailureAndAreDeliveredNextTime() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        _ = try await h.monitor.syncOnce()
        h.api.add("a", subject: "alert one")
        h.api.add("b", subject: "alert two")
        // 第一封拉取成功入库并记录命中，之后限流失败
        h.api.failMessageCallsAfter = h.api.calls + 1
        await #expect(throws: MailError.self) { try await h.monitor.syncOnce() }

        h.api.stopFailing()
        let ids = try await h.monitor.syncOnce().alerts.map(\.messageId).sorted()
        // 失败前已记录命中的那封不会丢；未处理的那封也会在重试时提醒
        #expect(ids == ["a", "b"])
    }
}

@Suite struct NewMailAlertTests {
    @Test func defaultOnlyAlertsForRules() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        _ = try await h.monitor.syncOnce()
        h.api.add("p", subject: "lunch?")
        #expect(try await h.monitor.syncOnce().alerts.isEmpty)
    }

    @Test func allModeAlertsEveryNewMailAndRulesWin() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        h.monitor.newMailAlerts = .all
        _ = try await h.monitor.syncOnce()
        h.api.add("p", subject: "lunch?")
        h.api.add("q", subject: "磁盘告警")
        let result = try await h.monitor.syncOnce()
        let byId = Dictionary(uniqueKeysWithValues: result.alerts.map { ($0.messageId, $0) })
        #expect(byId["p"]?.ruleName == "新邮件")
        #expect(byId["q"]?.ruleName == "告警")      // 命中规则的邮件保留规则的声音和名字
        #expect(byId["q"]?.sound == "Sosumi")
        #expect(result.alerts.count == 2)
    }

    @Test func fullSyncNeverAlertsEvenInAllMode() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        h.monitor.newMailAlerts = .all
        h.api.add("a", subject: "hello")
        #expect(try await h.monitor.syncOnce().alerts.isEmpty)
    }

    @Test func importantModeSkipsRoutineBots() {
        #expect(NewMailAlerts.important.accepts(kind: "human"))
        #expect(NewMailAlerts.important.accepts(kind: "bot_alert"))
        #expect(!NewMailAlerts.important.accepts(kind: "bot_routine"))
        #expect(!NewMailAlerts.important.accepts(kind: "push"))
        #expect(!NewMailAlerts.off.accepts(kind: "human"))
    }
}

private struct FakeChat: AIChat {
    let reply: @Sendable (String) throws -> String
    func complete(system: String, user: String) async throws -> String { try reply(user) }
}

@Suite struct AINotifyMonitorTests {
    private func judge(_ reply: @escaping @Sendable (String) throws -> String) -> AINotifyJudge {
        AINotifyJudge(chat: FakeChat(reply: reply), prompt: "p")
    }

    @Test func aiDecidesWhichNewMailsNotify() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        h.monitor.aiJudge = judge { user in
            user.contains("urgent") ? #"{"notify": true, "reason": "要紧"}"# : #"{"notify": false, "reason": "无关"}"#
        }
        _ = try await h.monitor.syncOnce()
        h.api.add("p", subject: "urgent question")
        h.api.add("q", subject: "lunch?")
        h.api.add("r", subject: "磁盘告警")
        let result = try await h.monitor.syncOnce()
        let byId = Dictionary(uniqueKeysWithValues: result.alerts.map { ($0.messageId, $0) })
        #expect(byId["p"]?.ruleName == "AI 判定")
        #expect(byId["p"]?.snippet == "AI：要紧")
        #expect(byId["q"] == nil)
        #expect(byId["r"] == nil)      // 命中规则也要听 AI 的：AI 说不通知就不通知
        #expect(result.alerts.count == 1)
    }

    @Test func ruleMailApprovedByAIKeepsRuleSoundAndName() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        h.monitor.aiJudge = judge { _ in #"{"notify": true, "reason": "线上告警"}"# }
        _ = try await h.monitor.syncOnce()
        h.api.add("r", subject: "磁盘告警")
        let alert = try #require(try await h.monitor.syncOnce().alerts.first)
        #expect(alert.ruleName == "告警")
        #expect(alert.sound == "Sosumi")
        #expect(alert.snippet == "AI：线上告警")
    }

    @Test func ruleMailFallsBackToRuleWhenAIFails() async throws {
        struct Boom: Error {}
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        h.monitor.aiJudge = judge { _ in throw Boom() }
        _ = try await h.monitor.syncOnce()
        h.api.add("r", subject: "磁盘告警")
        let alerts = try await h.monitor.syncOnce().alerts
        #expect(alerts.map(\.ruleName) == ["告警"])
    }

    @Test func aiFailureFallsBackToNewMailSetting() async throws {
        struct Boom: Error {}
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        h.monitor.newMailAlerts = .all
        h.monitor.aiJudge = judge { _ in throw Boom() }
        _ = try await h.monitor.syncOnce()
        h.api.add("p", subject: "hello")
        #expect(try await h.monitor.syncOnce().alerts.map(\.ruleName) == ["新邮件"])

        h.monitor.newMailAlerts = .off
        h.api.add("q", subject: "hello again")
        #expect(try await h.monitor.syncOnce().alerts.isEmpty)
    }

    @Test func unparsableReplyCountsAsFailure() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        h.monitor.newMailAlerts = .all
        h.monitor.aiJudge = judge { _ in "我觉得应该通知" }
        _ = try await h.monitor.syncOnce()
        h.api.add("p", subject: "hello")
        #expect(try await h.monitor.syncOnce().alerts.map(\.ruleName) == ["新邮件"])
    }

    @Test func everyVerdictIsRecordedAndCorrectionsReachTheNextPrompt() async throws {
        final class Seen: @unchecked Sendable { var systems: [String] = [] }
        struct Spy: AIChat {
            let seen: Seen
            func complete(system: String, messages: [AIMessage]) async throws -> String {
                seen.systems.append(system)
                return #"{"notify": true, "reason": "原因"}"#
            }
        }
        let seen = Seen()
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        h.monitor.aiJudge = AINotifyJudge(chat: Spy(seen: seen), prompt: "P")
        _ = try await h.monitor.syncOnce()
        h.api.add("p", subject: "hello there")
        _ = try await h.monitor.syncOnce()
        let decision = try #require(try h.store.recentDecisions().first)
        #expect(decision.messageId == "p" && decision.notify && decision.reason == "原因" && decision.subject == "hello there")

        try h.store.setFeedback(messageId: "p", value: -1)
        try h.store.addMemory("别烦我")
        h.api.add("q", subject: "another")
        _ = try await h.monitor.syncOnce()
        let last = try #require(seen.systems.last)
        #expect(last.contains("别烦我") && last.contains("hello there"))
    }

    @Test func noJudgeKeepsOldBehaviour() async throws {
        let h = try Harness(rules: alertRules); defer { h.cleanup() }
        _ = try await h.monitor.syncOnce()
        h.api.add("p", subject: "hello")
        #expect(try await h.monitor.syncOnce().alerts.isEmpty)
    }
}
