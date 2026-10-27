import Foundation
import Testing
@testable import MailCore

@Suite struct GitHubSubjectTests {
    @Test func prAndIssueSubjects() {
        let pr = GitHubSubject.parse("Re: [Vungle/Monetize] chore(ci): retire ViewMaster from GitHub Actions (PR #7125)")
        #expect(pr == GitHubSubject(repo: "Vungle/Monetize", kind: "PR", number: 7125, title: "chore(ci): retire ViewMaster from GitHub Actions"))
        #expect(pr?.reference == "PR #7125")

        let issue = GitHubSubject.parse("[acme/web.app] Crash on login (Issue #42)")
        #expect(issue?.repo == "acme/web.app" && issue?.kind == "Issue" && issue?.number == 42 && issue?.title == "Crash on login")
    }

    @Test func subjectWithoutNumberAndStackedPrefixes() {
        let run = GitHubSubject.parse("[Vungle/Monetize] PR run failed: Nemo Blackbox Tests - fix(VM-3565)")
        #expect(run?.number == nil && run?.reference == nil)
        #expect(run?.title == "PR run failed: Nemo Blackbox Tests - fix(VM-3565)")
        #expect(GitHubSubject.parse("Re: RE: [a/b] hello (PR #1)")?.title == "hello")
    }

    @Test func nonGitHubSubjectsAreRejected() {
        #expect(GitHubSubject.parse("Your invoice") == nil)
        #expect(GitHubSubject.parse("[JIRA-123] something") == nil)       // 方括号里没有 owner/repo
        #expect(GitHubSubject.parse("") == nil)
    }
}

@Suite struct ReasonAndImportanceTests {
    private func gmail(_ id: String, reason: String?, subject: String = "[a/b] x (PR #1)") -> GmailMessage {
        var headers = [GmailHeader(name: "Subject", value: subject)]
        if let reason { headers.append(GmailHeader(name: "X-GitHub-Reason", value: reason)) }
        return GmailMessage(id: id, threadId: "t-\(id)", labelIds: ["INBOX", "UNREAD"], snippet: "s", historyId: nil, internalDate: "1700000000000",
                            sizeEstimate: 1, payload: GmailPart(partId: nil, mimeType: "text/plain", filename: nil, headers: headers,
                                                                body: GmailBody(attachmentId: nil, size: nil, data: b64url(Data("body".utf8))), parts: nil))
    }

    @Test func reasonIsParsedFromHeaderAndStored() throws {
        let store = try MailStore(path: nil)
        let withReason = ParsedMessage(gmail("a", reason: " Review_Requested "))
        let without = ParsedMessage(gmail("b", reason: nil))
        #expect(withReason.reason == "review_requested")
        #expect(without.reason == "")                  // 确认过没有，不是"未知"
        try store.upsert([withReason, without])
        #expect(try store.messageIDsMissingReason(limit: 10).isEmpty)
    }

    @Test func reasonRules() {
        func hit(_ rule: Rule, reason: String) -> Bool {
            !RuleSet(rules: [rule]).matching(Matchable(subject: "s", from: "f", body: "b", reason: reason)).isEmpty
        }
        let review = Rule(name: "r", reasons: ["review_requested"])
        #expect(hit(review, reason: "review_requested"))
        #expect(!hit(review, reason: "mention"))
        #expect(!hit(review, reason: ""))
        #expect(hit(Rule(name: "m", reasons: ["mention"]), reason: "team_mention"))      // 包含即可
        // reasons 与 keywords 同时设置：两者都要满足
        let both = Rule(name: "b", keywords: ["failed"], fields: [.subject], reasons: ["ci_activity"])
        #expect(!RuleSet(rules: [both]).matching(Matchable(subject: "run failed", from: "", body: "", reason: "mention")).isEmpty == false)
        #expect(!RuleSet(rules: [both]).matching(Matchable(subject: "run failed", from: "", body: "", reason: "ci_activity")).isEmpty)
    }

    @Test func backfillFillsOnlyUnknownReasonsAndRematchesRules() async throws {
        let api = FakeGmail()
        api.add("old1"); api.add("old2")
        api.reasonHeaders = ["old1": "review_requested"]
        let store = try MailStore(path: nil)
        // 模拟升级前同步的旧数据：reason 为 NULL
        try store.upsert([makeMessage("old1"), makeMessage("old2")])
        try await store.db.write { try $0.execute(sql: "UPDATE message SET reason = NULL") }
        #expect(try store.messageIDsMissingReason(limit: 10).count == 2)

        let path = NSTemporaryDirectory() + "rules-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try RuleStore.write([Rule(name: "评审", reasons: ["review_requested"], notify: false)], to: path)
        let monitor = MailMonitor(api: api, store: store, rulesPath: path)
        _ = monitor.reloadRules()

        #expect(try await monitor.backfillReasons(limit: 10) == 2)
        #expect(try store.matches(rule: "评审", limit: 10).map(\.id) == ["old1"])      // 补上后规则才能命中
        #expect(try await monitor.backfillReasons(limit: 10) == 0)                    // 补完不再请求
        #expect(api.reasonCalls == 2)
    }

    @Test func messageGoneFromGmailIsMarkedCheckedSoItIsNotRetried() async throws {
        let api = FakeGmail()   // 邮箱里没有这封
        let store = try MailStore(path: nil)
        try store.upsert([makeMessage("ghost")])
        try await store.db.write { try $0.execute(sql: "UPDATE message SET reason = NULL") }
        let engine = SyncEngine(api: api, store: store, log: { _ in })
        #expect(try await engine.backfillReasons(limit: 5) == 1)
        #expect(try store.messageIDsMissingReason(limit: 5).isEmpty)
    }

    @Test func threadRowsCarryReasonAndRuleNamesAndImportantViewWorks() throws {
        let store = try MailStore(path: nil)
        var a = ParsedMessage(gmail("a", reason: "review_requested"))
        a.internalDate = 2000
        var b = ParsedMessage(gmail("b", reason: nil))
        b.internalDate = 1000
        try store.upsert([a, b])
        _ = try store.recordMatch(messageId: "a", ruleName: "请求你 Review")
        _ = try store.recordMatch(messageId: "a", ruleName: "紧急")

        let rows = try store.threads(in: .allMail)
        let first = try #require(rows.first)
        #expect(first.id == "t-a" && first.reason == "review_requested" && first.ruleNames == ["紧急", "请求你 Review"].sorted())
        #expect(rows.last?.reason == nil && rows.last?.ruleNames.isEmpty == true)

        #expect(try store.threads(in: .anyRule(["紧急", "不存在"])).map(\.id) == ["t-a"])
        #expect(try store.threads(in: .anyRule([])).isEmpty)
        #expect(try store.unreadThreadCount(in: .anyRule(["紧急"])) == 1)
        #expect(try store.unreadThreadCount(in: .allMail) == 2)
    }

    @Test func unreadOnlyFilterAndCount() throws {
        let store = try MailStore(path: nil)
        try store.upsert([makeMessage("r", date: 1000, labels: ["INBOX"], thread: "T"), makeMessage("u", date: 2000, labels: ["INBOX", "UNREAD"], thread: "T"),
                          makeMessage("x", date: 3000, labels: ["INBOX"])])
        #expect(try store.threads(in: .label("INBOX")).count == 2)
        let unread = try store.threads(in: .label("INBOX"), unreadOnly: true)
        #expect(unread.map(\.id) == ["T"] && unread.first?.messageCount == 1)
        #expect(try store.unreadThreadCount(in: .label("INBOX")) == 1)
    }
}

@Suite struct RuleTemplateTests {
    @Test func githubTemplatesAreValidFilterOnlyAndColored() {
        #expect(RuleStore.validate(RuleTemplates.github).isEmpty)
        #expect(RuleTemplates.github.allSatisfy { !$0.notify && $0.color != nil && $0.enabled })
        #expect(Set(RuleTemplates.github.map(\.name)).count == RuleTemplates.github.count)
    }

    @Test func missingSkipsAlreadyPresentNames() {
        let existing = [Rule(name: "CI 失败", keywords: ["x"]), Rule(name: "自己的", keywords: ["y"])]
        let missing = RuleTemplates.missing(from: RuleTemplates.github, in: existing)
        #expect(missing.count == RuleTemplates.github.count - 1)
        #expect(!missing.contains { $0.name == "CI 失败" })
    }

    @Test func colorMustBeInThePalette() {
        #expect(RuleStore.validate([Rule(name: "a", keywords: ["k"], color: "teal")]).contains { $0.contains("颜色") })
        #expect(RuleStore.validate([Rule(name: "a", keywords: ["k"], color: "red")]).isEmpty)
    }

    @Test func newFieldsRoundTrip() throws {
        let path = NSTemporaryDirectory() + "rules-\(UUID().uuidString)/rules.json"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try RuleStore.write(RuleTemplates.github, to: path)
        #expect(try RuleStore.read(path: path) == RuleTemplates.github)
    }
}

@Suite struct GitHubTextTests {
    @Test func footerIsRemovedWithItsSeparator() {
        let text = "LGTM, ship it.\n\n— \nReply to this email directly, view it on GitHub, or unsubscribe.\nYou are receiving this because your review was requested.\n"
        #expect(GitHubText.stripFooter(text) == "LGTM, ship it.")
        let dash = "Body line\n\n—\nReply to this email directly, view it on GitHub: https://x\nYou are receiving this because you were mentioned."
        #expect(GitHubText.stripFooter(dash) == "Body line")
    }

    @Test func textWithoutFooterIsOnlyTrimmed() {
        #expect(GitHubText.stripFooter("\n  hello world \n\n") == "hello world")
        #expect(GitHubText.stripFooter("") == "")
    }

    @Test func receivingLineAloneIsAlsoACutPoint() {
        #expect(GitHubText.stripFooter("text\n--\nYou are receiving this because you commented.") == "text")
    }

    @Test func urlsForPullIssueDiscussionAndRepo() {
        #expect(GitHubSubject.parse("[a/b] t (PR #5)")?.url?.absoluteString == "https://github.com/a/b/pull/5")
        #expect(GitHubSubject.parse("[a/b] t (Issue #6)")?.url?.absoluteString == "https://github.com/a/b/issues/6")
        #expect(GitHubSubject.parse("[a/b] t (Discussion #7)")?.url?.absoluteString == "https://github.com/a/b/discussions/7")
        #expect(GitHubSubject.parse("[a/b] PR run failed")?.url?.absoluteString == "https://github.com/a/b")
    }
}

@Suite struct GitHubTextCleanupTests {
    @Test func footerStartingAtSeparatorIsRemovedEvenWithUrlLinesInside() {
        let text = """
        @kobolsky pushed 1 commit.

        cf16dbf refactor(nemo): follow the findings

        -- 
        View it on GitHub:
        https://github.com/a/b/pull/7110/changes/abc..def
        You are receiving this because you are subscribed to this thread.
        """
        #expect(GitHubText.stripFooter(text) == "@kobolsky pushed 1 commit.\n\ncf16dbf refactor(nemo): follow the findings")
    }

    @Test func separatorFartherThanEightLinesAboveIsNotUsed() {
        let body = (1...12).map { "line \($0)" }.joined(separator: "\n")
        let text = "intro\n--\n\(body)\nYou are receiving this because x"
        // 分隔线离页脚提示太远，当作正文里的普通分隔线，只在提示行截断
        #expect(GitHubText.stripFooter(text).hasSuffix("line 12"))
        #expect(GitHubText.stripFooter(text).contains("--"))
    }

    @Test func prettifyRemovesCommentsTagsAndTurnsHeadingsBold() {
        let text = "<!-- review-council -->\n## 🏛 Review Council — in progress\n\n> quoted\n\nSetup: see docs<sub>small</sub><br>next\n\n\n\nend"
        #expect(GitHubText.prettify(text) == "**🏛 Review Council — in progress**\n\n> quoted\n\nSetup: see docssmall\nnext\n\nend")
    }

    @Test func prettifyLeavesOrdinaryTextAlone() {
        #expect(GitHubText.prettify("just text\nwith # not a heading\n#hashtag") == "just text\nwith # not a heading\n#hashtag")
        #expect(GitHubText.prettify("### Title ###") == "**Title**")
    }
}

@Suite struct GitHubFooterVariantsTests {
    @Test func pushNotificationFooterWithOnlyViewItOnGitHub() {
        let text = "@a pushed 1 commit.\n\ncf16dbf msg\n\n-- \nView it on GitHub:\nhttps://github.com/a/b/pull/1/changes/x..y\nYou are receiving this because you are subscribed to this thread.Message ID: <a/b/pull/1/before/x/after/y@github.com>"
        #expect(GitHubText.stripFooter(text) == "@a pushed 1 commit.\n\ncf16dbf msg")
        let noReceivingLine = "body\n\n--\nView it on GitHub:\nhttps://github.com/a/b/pull/1#issuecomment-1\n"
        #expect(GitHubText.stripFooter(noReceivingLine) == "body")
    }

    @Test func crlfLineEndingsAreHandled() {
        let text = "## Title\r\n\r\ntext\r\n\r\n-- \r\nReply to this email directly or view it on GitHub:\r\nhttps://x\r\nYou are receiving this because you commented.\r\n"
        #expect(GitHubText.prettify(GitHubText.stripFooter(text)) == "**Title**\n\ntext")
    }
}

@Suite struct CIDigestTests {
    private let sample = """
    [Vungle/Monetize] Nemo Blackbox Tests workflow run

    Repository: Vungle/Monetize
    Workflow: Nemo Blackbox Tests
    Duration: 1 hour, 3 minutes, and 38.0 seconds
    Finished: 2026-10-26 10:46:14 UTC

    View results: https://github.com/Vungle/Monetize/actions/runs/40301645014

    Jobs:
      * check-label succeeded (1 annotation)
      * Build Nautilus succeeded (2 annotations)
      * Execute Android tests (7.7.9, 16.0, Samsung Galaxy S26) failed (2 annotations)
      * exit-early skipped (0 annotations)
      * Execute iOS tests (16, 7.3.2, iPhone 14 Pro Max-16, 16.4) failed (2 annotations)
    """

    @Test func keepsHeaderAndOnlyTheFailedJobs() throws {
        let digest = try #require(GitHubText.ciDigest(sample))
        #expect(digest.contains("Workflow: Nemo Blackbox Tests"))
        #expect(digest.contains("View results: https://github.com/Vungle/Monetize/actions/runs/40301645014"))
        #expect(digest.contains("共 5 个任务，失败 2 个，其余成功或跳过"))
        #expect(digest.contains("✗ Execute Android tests (7.7.9, 16.0, Samsung Galaxy S26) failed (2 annotations)"))
        #expect(digest.contains("✗ Execute iOS tests"))
        #expect(!digest.contains("check-label") && !digest.contains("Build Nautilus"))     // 成功的任务不出现
    }

    @Test func allSucceededOrNotACIMail() {
        let ok = "Header\nWorkflow: W\n\nJobs:\n  * a succeeded\n  * b succeeded"
        #expect(GitHubText.ciDigest(ok)?.contains("失败 0 个") == true)
        #expect(GitHubText.ciDigest(ok)?.contains("失败的任务") == false)
        #expect(GitHubText.ciDigest("just a comment") == nil)
        #expect(GitHubText.ciDigest("Jobs:\nnothing listed") == nil)
    }
}

@Suite struct GitHubHTMLInTextTests {
    @Test func imagesAreDroppedAndInlineHTMLBecomesMarkdown() {
        let text = #"## <img src="https://cdn.simpleicons.org/android/000000" alt="Android" height="28" align="absmiddle"> Android Tests <b>Summary</b> and <code>x</code> and <em>y</em>"#
        #expect(GitHubText.prettify(text) == "** Android Tests **Summary** and `x` and *y***".replacingOccurrences(of: "** Android", with: "**Android"))
    }

    @Test func plainTextStaysUntouched() {
        #expect(GitHubText.prettify("a < b and c > d") == "a < b and c > d")
    }
}
