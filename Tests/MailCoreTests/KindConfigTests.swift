import Foundation
import Testing
@testable import MailCore

@Suite struct KindConfigTests {
    private let gh = "notifications@github.com"

    @Test func overrideBeatsBuiltInLogic() {
        var config = KindConfig.defaults
        let body = "dmx-monetize left a comment (Vungle/Monetize#1)\n\nplain words from a person"
        #expect(MessageClassifier.kind(subject: "s", from: "dmx-monetize <\(gh)>", body: body, config: config) == .human)
        config.overrides.insert(.init(field: .sender, pattern: "dmx-monetize", kind: .bot), at: 0)
        #expect(MessageClassifier.kind(subject: "s", from: "dmx-monetize <\(gh)>", body: body, config: config) == .bot)
    }

    @Test func bodyAndRegexOverrides() {
        var config = KindConfig.defaults
        config.overrides.insert(.init(field: .body, pattern: #"deploy(ed)? to prod"#, regex: true, kind: .botRoutine), at: 0)
        #expect(MessageClassifier.kind(subject: "s", from: "Bob <bob@example.com>", body: "We deployed to prod", config: config) == .botRoutine)
        config.overrides[0].enabled = false
        #expect(MessageClassifier.kind(subject: "s", from: "Bob <bob@example.com>", body: "We deployed to prod", config: config) == .human)
    }

    @Test func botSendersMakeAccountsBots() {
        var config = KindConfig.defaults
        let body = "ci-account left a comment (Vungle/Monetize#1)\n\nsome report text"
        #expect(MessageClassifier.kind(subject: "s", from: "ci-account <\(gh)>", body: body, config: config) == .human)
        config.botSenders.append("ci-account")
        #expect(MessageClassifier.kind(subject: "s", from: "ci-account <\(gh)>", body: body, config: config) == .bot)
    }

    @Test func invalidRegexIsReportedAndSkipped() {
        var config = KindConfig.defaults
        config.overrides.insert(.init(field: .subject, pattern: "(", regex: true, kind: .bot), at: 0)
        #expect(!config.problems().isEmpty)
        #expect(MessageClassifier.kind(subject: "hello", from: "Bob <bob@example.com>", body: "hi", config: config) == .human)
    }

    @Test func missingFieldsFallBackToDefaultsAndRoundTrips() throws {
        let partial = try JSONDecoder().decode(KindConfig.self, from: Data(#"{"botSenders":["x-bot"]}"#.utf8))
        #expect(partial.botSenders == ["x-bot"])
        #expect(partial.alertPattern == KindConfig.defaults.alertPattern)
        let path = NSTemporaryDirectory() + "classifier-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try KindConfigStore.write(partial, at: path)
        #expect(KindConfigStore.read(at: path) == partial)
    }

    @Test func reclassifyAppliesNewConfigToStoredMessages() throws {
        let store = try MailStore(path: nil)
        try store.upsert([makeMessage("1", subject: "s", from: "dmx-monetize <\(gh)>", body: "dmx-monetize left a comment (Vungle/Monetize#1)\n\nhello")])
        var config = KindConfig.defaults
        #expect(try store.reclassifyKinds(config: config) == 0)
        config.overrides.insert(.init(field: .sender, pattern: "dmx-monetize", kind: .botRoutine), at: 0)
        #expect(try store.reclassifyKinds(config: config) == 1)
        #expect(try store.reclassifyKinds(config: config) == 0)
    }
}

@Suite struct UnreadRuleCountTests {
    @Test func countsUnreadGroupsAndDropsAfterRead() throws {
        let store = try MailStore(path: nil)
        let a = makeMessage("a", subject: "[o/r] t (PR #1)", labels: ["INBOX", "UNREAD"], thread: "t1")
        let b = makeMessage("b", subject: "[o/r] t (PR #1)", labels: ["INBOX", "UNREAD"], thread: "t2")
        try store.upsert([a, b])
        _ = try store.recordMatch(messageId: "a", ruleName: "R")
        _ = try store.recordMatch(messageId: "b", ruleName: "R")
        #expect(try store.matchCounts().first?.count == 2)
        #expect(try store.unreadMatchCounts().first?.count == 1)       // 同一个 PR 算一个
        try store.setLabels(messageId: "a", labelIds: ["INBOX"])
        try store.setLabels(messageId: "b", labelIds: ["INBOX"])
        #expect(try store.unreadMatchCounts().isEmpty)
    }
}

@Suite struct ReasonScopeTests {
    @Test func reviewRequestedOnlyDescribesTheRequestEmail() {
        #expect(GitHubReason.describesThisMessage(reason: "review_requested", body: "@mlevy-liftoff requested your review on: Vungle/Monetize#7151 feat(nemo)"))
        #expect(!GitHubReason.describesThisMessage(reason: "review_requested", body: "dmx-monetize left a comment (Vungle/Monetize#7125)\n\nBlackbox summary"))
        #expect(GitHubReason.describesThisMessage(reason: "mention", body: "anything"))
        #expect(!GitHubReason.describesThisMessage(reason: "assign", body: "x left a comment"))
        // 机器人写 "Triggered by @you" 不算提及；真人 @ 了你才算
        #expect(!GitHubReason.describesThisMessage(reason: "mention", body: "Triggered by @howard-57blocks", kind: .botRoutine, login: "howard-57blocks"))
        #expect(GitHubReason.describesThisMessage(reason: "mention", body: "@howard-57blocks can you look?", kind: .human, login: "howard-57blocks"))
        #expect(!GitHubReason.describesThisMessage(reason: "mention", body: "LGTM, thanks", kind: .human, login: "howard-57blocks"))
        #expect(GitHubReason.effective(reason: "mention", kind: .bot) == "")
        #expect(GitHubReason.effective(reason: "review_requested", kind: .bot) == "review_requested")
    }
}
