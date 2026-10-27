import Foundation
import Testing
@testable import MailCore

private func matches(_ rule: Rule, subject: String = "", from: String = "", to: String = "", body: String = "") -> Bool {
    !RuleSet(rules: [rule]).matching(Matchable(subject: subject, from: from, to: to, body: body)).isEmpty
}

@Suite struct RuleMatcherTests {
    @Test func anyKeywordInDefaultFields() {
        let rule = Rule(name: "r", keywords: ["alert", "P0"])
        #expect(matches(rule, subject: "Server ALERT: disk"))
        #expect(matches(rule, body: "this is a p0 incident"))
        #expect(!matches(rule, subject: "hello", body: "nothing"))
    }

    @Test func fieldsRestrictWhereToLook() {
        let rule = Rule(name: "r", keywords: ["invoice"], fields: [.subject])
        #expect(matches(rule, subject: "Invoice #1"))
        #expect(!matches(rule, body: "invoice inside body"))

        let sender = Rule(name: "s", keywords: ["noreply"], fields: [.from])
        #expect(matches(sender, from: "Bot <noreply@x.com>"))
    }

    @Test func chineseAndDiacriticInsensitive() {
        let rule = Rule(name: "r", keywords: ["告警", "cafe"])
        #expect(matches(rule, subject: "服务器告警通知"))
        #expect(matches(rule, body: "Café opens"))
    }

    @Test func fromAndKeywordsBothRequired() {
        let rule = Rule(name: "r", keywords: ["urgent"], from: ["boss@corp.com"])
        #expect(matches(rule, subject: "urgent", from: "Boss <boss@corp.com>"))
        #expect(!matches(rule, subject: "urgent", from: "other@corp.com"))
        #expect(!matches(rule, subject: "hello", from: "boss@corp.com"))
    }

    @Test func fromOnlyRule() {
        let rule = Rule(name: "r", from: ["boss@corp.com"])
        #expect(matches(rule, subject: "anything", from: "boss@corp.com"))
        #expect(!matches(rule, subject: "anything", from: "x@corp.com"))
    }

    @Test func excludeWins() {
        let rule = Rule(name: "r", keywords: ["deploy"], exclude: ["staging"])
        #expect(matches(rule, subject: "deploy prod"))
        #expect(!matches(rule, subject: "deploy staging"))
    }

    @Test func regexMode() {
        let rule = Rule(name: "r", keywords: [#"\bP[0-2]\b"#, #"PR #\d{4}"#], regex: true)
        #expect(matches(rule, subject: "got a P1 here"))
        #expect(matches(rule, subject: "Re: fix (PR #7125)"))
        #expect(!matches(rule, subject: "P9 and PR #12"))
    }

    @Test func disabledAndCriterialessRulesNeverMatch() {
        #expect(!matches(Rule(name: "r", enabled: false, keywords: ["x"]), subject: "x"))
        #expect(!matches(Rule(name: "r"), subject: "x"))
    }

    @Test func quotedReplyTextIsIgnored() {
        let body = "Thanks, will do.\n> earlier: the SERVER ALERT fired\n  > nested quote alert"
        let rule = Rule(name: "r", keywords: ["alert"])
        #expect(!matches(rule, body: body))
        #expect(matches(rule, body: "new alert\n> old"))
    }

    @Test func requireAllNeedsEveryKeyword() {
        let rule = Rule(name: "r", keywords: ["deploy", "prod"], requireAll: true)
        #expect(matches(rule, subject: "deploy to prod"))
        #expect(matches(rule, subject: "deploy", body: "target: prod"))      // 关键词可以分散在不同字段
        #expect(!matches(rule, subject: "deploy to staging"))
        #expect(matches(Rule(name: "r", keywords: ["deploy", "prod"]), subject: "deploy to staging"))   // 默认任一
    }

    @Test func recipientField() {
        let rule = Rule(name: "r", keywords: ["team@corp.com"], fields: [.to])
        #expect(matches(rule, subject: "x", to: "Team <team@corp.com>"))
        #expect(!matches(rule, subject: "team@corp.com", to: "me@corp.com"))
    }

    @Test func multipleRulesReportedInFileOrder() {
        let set = RuleSet(rules: [Rule(name: "a", keywords: ["x"]), Rule(name: "b", keywords: ["y"]), Rule(name: "c", keywords: ["x"])])
        #expect(set.matching(Matchable(subject: "x", from: "", body: "")).map(\.name) == ["a", "c"])
    }
}

@Suite struct RuleStoreTests {
    private func parse(_ json: String) throws -> LoadedRules { try RuleStore.parse(Data(json.utf8)) }

    @Test func defaultsApplyToMissingFields() throws {
        let loaded = try parse(#"{"rules":[{"name":"n","keywords":["k"]}]}"#)
        let r = loaded.rules[0]
        #expect(r.enabled && r.notify && !r.regex)
        #expect(r.fields == [.subject, .body])
        #expect(r.sound == nil && r.from.isEmpty && r.exclude.isEmpty)
    }

    @Test func fingerprintChangesWithContent() throws {
        let a = try parse(#"{"rules":[{"name":"n","keywords":["k"]}]}"#)
        let b = try parse(#"{"rules":[{"name":"n","keywords":["k2"]}]}"#)
        let a2 = try parse(#"{"rules":[{"name":"n","keywords":["k"]}]}"#)
        #expect(a.fingerprint != b.fingerprint)
        #expect(a.fingerprint == a2.fingerprint)
    }

    @Test func reportsAllProblemsAtOnce() {
        let json = """
        {"rules":[
          {"name":"dup","keywords":["a"]},
          {"name":"dup","keywords":["b"]},
          {"name":"","keywords":["c"]},
          {"name":"none"},
          {"name":"badre","keywords":["("],"regex":true},
          {"name":"empty","keywords":[""]}
        ]}
        """
        do {
            _ = try parse(json)
            Issue.record("应该抛错")
        } catch {
            let text = error.localizedDescription
            #expect(text.contains("name 重复"))
            #expect(text.contains("缺少 name"))
            #expect(text.contains("至少要有 keywords、from 或 reasons"))
            #expect(text.contains("正则无效"))
            #expect(text.contains("空关键词"))
        }
    }

    @Test func invalidJSONIsReported() {
        #expect(throws: MailError.self) { try parse("{not json") }
        #expect(throws: MailError.self) { try parse(#"{"rules":[{"name":"n","keywords":"oops"}]}"#) }
    }

    @Test func missingSoundIsWarningNotError() throws {
        let loaded = try parse(#"{"rules":[{"name":"n","keywords":["k"],"sound":"NoSuchSound123"}]}"#)
        #expect(loaded.warnings.count == 1)
        let ok = try parse(#"{"rules":[{"name":"n","keywords":["k"],"sound":"none"}]}"#)
        #expect(ok.warnings.isEmpty)
    }

    @Test func sampleIsValidAndAllDisabled() throws {
        let loaded = try parse(RuleStore.sample)
        #expect(!loaded.rules.isEmpty)
        #expect(loaded.rules.allSatisfy { !$0.enabled })
    }

    @Test func newFieldsRoundTripThroughWriteAndRead() throws {
        let path = NSTemporaryDirectory() + "rules-\(UUID().uuidString)/rules.json"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let rules = [
            Rule(name: "强", keywords: ["a", "b"], fields: [.subject, .to], exclude: ["x"], requireAll: true, strong: true, sound: "Glass"),
            Rule(name: "仅筛选", from: ["boss@x.com"], notify: false),
        ]
        try RuleStore.write(rules, to: path)
        #expect(try RuleStore.read(path: path) == rules)
    }

    @Test func writeRefusesInvalidRulesAndKeepsTheOldFile() throws {
        let path = NSTemporaryDirectory() + "rules-\(UUID().uuidString)/rules.json"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let good = [Rule(name: "ok", keywords: ["k"])]
        try RuleStore.write(good, to: path)
        #expect(throws: MailError.self) { try RuleStore.write([Rule(name: "bad")], to: path) }
        #expect(try RuleStore.read(path: path) == good)
    }

    @Test func validateListsProblemsForTheEditor() {
        #expect(RuleStore.validate([Rule(name: "ok", keywords: ["k"])]).isEmpty)
        #expect(RuleStore.validate([Rule(name: "a"), Rule(name: "a", keywords: ["x"])]).count == 2)   // 无条件 + 重名
        #expect(RuleStore.warnings(for: [Rule(name: "s", keywords: ["k"], sound: "NoSuchSound123")]).count == 1)
    }

    @Test func sampleFileCreatedOnlyIfMissing() throws {
        let dir = NSTemporaryDirectory() + "rules-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/rules.json"
        try RuleStore.createSampleIfMissing(at: path)
        #expect(FileManager.default.fileExists(atPath: path))
        try Data("{\"rules\":[]}".utf8).write(to: URL(fileURLWithPath: path))
        try RuleStore.createSampleIfMissing(at: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "{\"rules\":[]}")
    }
}

@Suite struct SoundLibraryTests {
    @Test func resolvesFilesByPathAndNameInDirectories() throws {
        let dir = NSTemporaryDirectory() + "sounds-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/Ding.wav"
        FileManager.default.createFile(atPath: file, contents: Data([0]))

        #expect(SoundLibrary.resolve("Ding", directories: [dir])?.path == file)
        #expect(SoundLibrary.resolve(file)?.path == file)
        #expect(SoundLibrary.resolve("Missing", directories: [dir]) == nil)
        #expect(SoundLibrary.resolve(dir + "/nope.wav") == nil)
    }

    @Test func systemSoundsAreAvailable() {
        #expect(SoundLibrary.resolve("Glass") != nil)
        #expect(SoundLibrary.availableNames().contains("Glass"))
    }
}
