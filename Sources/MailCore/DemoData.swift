import Foundation

/// CI 截图专用的演示数据：往邮件库里写一批构造好的邮件，覆盖分诊三段
/// （需要处理 / 有新动态 / 仅机器人更新）、PR 会话里例行消息折叠、失败卡、
/// Jira / Google 文档 / 真人邮件和跨天分组等界面状态。
///
/// 用法：`MAIL_DB=/tmp/demo.sqlite swift run mailsync seed-demo`，
/// 之后带 `-noSync YES` 启动 App 即可，全程不碰网络和钥匙串。
/// 正文样本的形状照搬 Tests/MailCoreTests/TriageTests.swift 里来自真实邮箱的样本，
/// 保证分类器（真人 / 例行 / 出问题）的判定和真实邮件一致。
public enum DemoData {
    public static let accountEmail = "demo@example.com"

    public static func seed(store: MailStore) throws {
        try store.upsert(messages())
        try store.setState(["email": accountEmail])
    }

    public static func messages() -> [ParsedMessage] {
        var out: [ParsedMessage] = []

        // MARK: PR #7201：需要处理（真人未读 + CI 失败未读，中间夹一段例行消息供折叠）
        let pr7201 = "Re: [Vungle/Monetize] fix(nemo): restart video when tapping sides (PR #7201)"
        out.append(ghMessage("d06", subject: pr7201, display: "Kevin Obolsky", thread: "T7201", minutesAgo: 100, unread: false, reason: "review_requested", body: """
            @kobolsky-vungle pushed 2 commits.

            9f31ac2  fix(nemo): restart video when tapping sides
            77bd010  test(nemo): cover side taps in blackbox
            """))
        out.append(ghMessage("d05", subject: pr7201, display: "dmx-monetize", thread: "T7201", minutesAgo: 85, unread: false, reason: "review_requested", body: """
            dmx-monetize left a comment (Vungle/Monetize#7201)

            <!-- playwright-report-github-action -- Nemo Previewer Automation Test -->

            ### 🚀 Nemo Previewer Automation Test Summary for commit 9f31ac2

            ![passed](https://x)  **1653 passed**
            ![flaky](https://x)  **2 flaky**
            """))
        out.append(ghMessage("d04", subject: pr7201, display: "\"sonarqubecloud[bot]\"", thread: "T7201", minutesAgo: 70, unread: false, reason: "review_requested", body: """
            sonarqubecloud[bot] left a comment (Vungle/Monetize#7201)

            ## ![Quality Gate Passed](https://x/qg-passed.png 'Quality Gate Passed') **Quality Gate passed for 'Monetize Nemo'**
            """))
        out.append(ghMessage("d03", subject: pr7201, display: "\"github-actions[bot]\"", thread: "T7201", minutesAgo: 55, unread: false, reason: "review_requested", body: """
            github-actions[bot] left a comment (Vungle/Monetize#7201)

            ## :briefcase: Nemo Bundle Size Check

            ### Modern — SDK >= 7.1.0
            | Bundle | Platform | Previous | New | Change |
            | Standard | iOS | 100.39 KB | 100.39 KB | &#128077; -0.00% |
            """))
        out.append(ghMessage("d01", subject: pr7201, display: "dmx-monetize", thread: "T7201", minutesAgo: 38, unread: true, reason: "review_requested", body: """
            dmx-monetize left a comment (Vungle/Monetize#7201)

            ## 🍎 iOS Blackbox Tests Summary [Nemo] (Commit: 9f31ac2)

            | SDK | Status |
            | --- | --- |
            | 7.3.2 | ❌ Fail |
            | 7.1.0 | ✅ Pass |
            """))
        out.append(ghMessage("d02", subject: pr7201, display: "Kevin Obolsky", thread: "T7201", minutesAgo: 24, unread: true, reason: "review_requested", body: """
            kobolsky-vungle left a comment (Vungle/Monetize#7201)

            左右两侧点击的处理没问题，辛苦。CI 里 iOS 黑盒挂了一台设备，先看是不是新引入的——如果和这次改动无关，在 PR 里说明一下就可以。
            """))

        // MARK: PR #7171：只有例行未读（落在「仅机器人更新」段）
        let pr7171 = "Re: [Vungle/Monetize] test(AEP-1650): stop iOS PiP blackbox test failing (PR #7171)"
        out.append(ghMessage("d11", subject: pr7171, display: "Nicholas Byfleet", thread: "T7171", minutesAgo: 180, unread: false, reason: "mention", body: """
            nbyfleet left a comment (Vungle/Monetize#7171)

            Approved. Would be good to get the blackbox test failures figured out, and conflicts resolved.
            """))
        out.append(ghMessage("d12", subject: pr7171, display: "\"github-actions[bot]\"", thread: "T7171", minutesAgo: 150, unread: true, reason: "mention", body: """
            github-actions[bot] left a comment (Vungle/Monetize#7171)

            <!-- review-council -->
            ## 🏛️ Review Council — _in progress_
            """))

        // MARK: Jira 指派
        out.append(message("d21", subject: "[JIRA] (VM-3567) Modular video: prev/next video does not restart when clicking left/right side",
                           from: "\"Automation for Jira (JIRA)\" <jira@liftoff.atlassian.net>", thread: "TJ3567", minutesAgo: 65, unread: true, body: """
            Kevin Obolsky assigned this issue to you.

            VM-3567  Modular video: prev/next video does not restart when clicking left/right side of current video.
            Sprint: VM - Iztaccíhuatl - 28/10-11/11
            """))

        // MARK: Google 文档共享
        out.append(message("d31", subject: "Document shared with you: \"Ad Podding Design\"",
                           from: "\"Ezgi Cengiz (via Google Docs)\" <docs-noreply@google.com>", thread: "TDOC1", minutesAgo: 130, unread: true, body: """
            Ezgi Cengiz shared a document with you:

            Ad Podding Design
            https://docs.google.com/document/d/demo123/edit

            "Hi, this is the latest draft of the ad podding design — comments welcome."
            """))

        // MARK: 真人邮件（今天）
        out.append(message("d41", subject: "明天站会提前十分钟",
                           from: "Alex Li <alex@example.com>", thread: "TH1", minutesAgo: 12, unread: true, body: """
            Hi，明天的 Ad Experience Platform Standup 提前到 17:20，主要过一下新 sprint 的几个 ticket 分工。
            """))

        // MARK: 昨天：一个已读完的 PR 会话 + 一封真人邮件（验证日期分组）
        let pr7045 = "Re: [Vungle/Monetize] chore: bump cmark-gfm (PR #7045)"
        out.append(ghMessage("d52", subject: pr7045, display: "\"github-actions[bot]\"", thread: "T7045", minutesAgo: 1590, unread: false, reason: "subscribed", body: """
            github-actions[bot] left a comment (Vungle/Monetize#7045)

            ## :briefcase: Nemo Bundle Size Check

            ### Modern — SDK >= 7.1.0
            | Bundle | Platform | Previous | New | Change |
            | Standard | iOS | 98.10 KB | 98.12 KB | &#128077; +0.02% |
            """))
        out.append(ghMessage("d51", subject: pr7045, display: "\"sonarqubecloud[bot]\"", thread: "T7045", minutesAgo: 1560, unread: false, reason: "subscribed", body: """
            sonarqubecloud[bot] left a comment (Vungle/Monetize#7045)

            ## [![Quality Gate Failed](https://x/qg-failed.png 'Quality Gate Failed')](https://sonarcloud.io) **Quality Gate failed for 'Monetize Nemo'**
            Failed conditions
            """))
        out.append(message("d61", subject: "Re: SDK patch match 的修复已上线",
                           from: "Yueting Cui <yueting@example.com>", thread: "TH2", minutesAgo: 1620, unread: false, body: """
            部分匹配的修复已经随 7.3.3 发出去了，你那边有空再验一下。
            """))

        return out
    }

    // MARK: - 构造（形状与 Tests 的 makeMessage 保持一致）

    private static func ghMessage(_ id: String, subject: String, display: String, thread: String,
                                  minutesAgo: Double, unread: Bool, reason: String?, body: String) -> ParsedMessage {
        message(id, subject: subject, from: "\(display) <notifications@github.com>", thread: thread,
                minutesAgo: minutesAgo, unread: unread, reason: reason, body: body)
    }

    private static func message(_ id: String, subject: String, from: String, thread: String,
                                minutesAgo: Double, unread: Bool, reason: String? = nil, body: String) -> ParsedMessage {
        let ms = Int64((Date().timeIntervalSince1970 - minutesAgo * 60) * 1000)
        let plain = GmailPart(partId: nil, mimeType: "text/plain", filename: nil, headers: nil,
                              body: GmailBody(attachmentId: nil, size: nil, data: b64url(Data(body.utf8))), parts: nil)
        return ParsedMessage(GmailMessage(
            id: id, threadId: thread, labelIds: unread ? ["INBOX", "UNREAD"] : ["INBOX"],
            snippet: String(body.prefix(80)), historyId: "1", internalDate: String(ms), sizeEstimate: 1,
            payload: GmailPart(partId: nil, mimeType: "multipart/mixed", filename: nil,
                               headers: [GmailHeader(name: "Subject", value: subject),
                                         GmailHeader(name: "From", value: from),
                                         GmailHeader(name: "To", value: accountEmail)]
                                   + (reason.map { [GmailHeader(name: "X-GitHub-Reason", value: $0)] } ?? []),
                               body: nil, parts: [plain])))
    }

    private static func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
