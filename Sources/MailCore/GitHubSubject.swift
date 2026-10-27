import Foundation

/// 解析 GitHub 通知邮件的主题：`Re: [owner/repo] 标题 (PR #123)`。
public struct GitHubSubject: Equatable, Sendable {
    public let repo: String
    /// "PR" / "Issue" / "Discussion"；没有编号时为 nil
    public let kind: String?
    public let number: Int?
    /// 去掉 Re:、[owner/repo] 前缀和 (PR #n) 后缀之后的标题
    public let title: String

    /// "PR #7125" 这样的短标签；没有编号时为 nil
    public var reference: String? {
        guard let number else { return nil }
        return "\(kind ?? "#") #\(number)".replacingOccurrences(of: "# #", with: "#")
    }

    /// 这个 PR / Issue / 仓库在 GitHub 上的地址（主题里没有编号时指向仓库）
    public var url: URL? {
        var path = repo
        if let number {
            switch kind {
            case "PR": path += "/pull/\(number)"
            case "Discussion": path += "/discussions/\(number)"
            default: path += "/issues/\(number)"
            }
        }
        return URL(string: "https://github.com/\(path)")
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:re|fwd?|回复)\s*[:：]\s*)*\[([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\]\s*(.*?)(?:\s*\((PR|Issue|Discussion)\s+#(\d+)\))?\s*$"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    /// CI 失败通知：`[owner/repo] PR run failed: <工作流> - <PR 标题>`。通知里没有 PR 编号，只能靠标题对上 PR。
    public struct CIRun: Equatable, Sendable {
        public let repo: String
        public let workflow: String
        public let prTitle: String
        /// 主题末尾括号里的提交号（如 2a35293）
        public let commit: String?
    }

    private static let ciPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:re|fwd?)\s*:\s*)*\[([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\]\s*PR run failed:\s*(.+?)\s+-\s+(.+?)\s*$"#,
        options: [.caseInsensitive])

    public static func parseCIRun(_ subject: String) -> CIRun? {
        let range = NSRange(subject.startIndex..., in: subject)
        guard let match = ciPattern.firstMatch(in: subject, range: range),
              let repo = Range(match.range(at: 1), in: subject), let workflow = Range(match.range(at: 2), in: subject),
              let title = Range(match.range(at: 3), in: subject) else { return nil }
        var prTitle = String(subject[title])
        var commit: String?
        // 主题形如 "… PR 标题 (2a35293)"：末尾的括号是提交号，不属于标题
        if let sha = prTitle.range(of: #"\s*\(([0-9a-f]{7,40})\)\s*$"#, options: [.regularExpression, .caseInsensitive]) {
            commit = String(prTitle[sha]).trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
            prTitle.removeSubrange(sha)
        }
        return CIRun(repo: String(subject[repo]), workflow: String(subject[workflow]), prTitle: prTitle, commit: commit)
    }

    /// 同一个 PR / Issue 的稳定标识：`owner/repo#123`。
    public static func prKey(repo: String, number: Int) -> String { "\(repo)#\(number)" }

    /// 从 prKey 拆回仓库和编号。
    public static func splitPRKey(_ key: String) -> (repo: String, number: Int)? {
        guard let hash = key.lastIndex(of: "#"), let number = Int(key[key.index(after: hash)...]) else { return nil }
        return (String(key[..<hash]), number)
    }

    /// 邮件里指向的 PR 的 key：优先看主题里的 (PR #n)，再看正文里的 github.com/owner/repo/pull/n 链接（Jira 的自动化通知就是这样提到 PR 的）。
    public static func prKey(subject: String, body: String) -> String? {
        if let parsed = parse(subject), let number = parsed.number { return prKey(repo: parsed.repo, number: number) }
        let head = String(body.prefix(6000))
        guard let match = bodyLink.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
              let repo = Range(match.range(at: 1), in: head), let number = Range(match.range(at: 2), in: head).flatMap({ Int(head[$0]) })
        else { return nil }
        return prKey(repo: String(head[repo]), number: number)
    }

    private static let bodyLink = try! NSRegularExpression(pattern: #"github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/(\d+)"#)

    /// 标题的比较形式：小写、压缩空白。
    static func normalizedTitle(_ title: String) -> String {
        title.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func parse(_ subject: String) -> GitHubSubject? {
        let range = NSRange(subject.startIndex..., in: subject)
        guard let match = pattern.firstMatch(in: subject, range: range) else { return nil }
        func group(_ i: Int) -> String? { Range(match.range(at: i), in: subject).map { String(subject[$0]) } }
        guard let repo = group(1) else { return nil }
        return GitHubSubject(repo: repo, kind: group(3), number: group(4).flatMap(Int.init), title: group(2) ?? "")
    }
}

/// GitHub 通知邮件正文的整理。
public enum GitHubText {
    /// 去掉末尾的页脚：以 "--" / "—" 分隔线开头，后面是 "View it on GitHub"、"Reply to this email directly"、
    /// "You are receiving this because …"。找不到分隔线时，只在页脚提示行处截断。
    public static func stripFooter(_ text: String) -> String { split(text).body }

    /// 页脚里值得留着的几行（"Reply to this email directly…"、"You are receiving this because you were mentioned."），
    /// 界面把它们以安静的小字放在正文下面；"Message ID" 这类噪音去掉。没有页脚返回 nil。
    public static func footerNote(_ text: String) -> String? {
        let note = split(text).footer
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "--" && $0 != "—" && !$0.hasPrefix("Message ID:") }
            .joined(separator: "\n")
        return note.isEmpty ? nil : note
    }

    static func split(_ text: String) -> (body: String, footer: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // 页脚里会出现的提示行；推送类通知没有 "You are receiving…"，只有 "View it on GitHub"
        let footerHints = ["Message ID:", "You are receiving this because", "Reply to this email directly", "View it on GitHub"]
        guard let marker = lines.lastIndex(where: { line in footerHints.contains { line.contains($0) } }) else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        func isSeparator(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            return t == "--" || t == "—"
        }
        // 页脚通常只有几行：往上最多找 8 行的分隔线，从它开始整段去掉
        var cut = marker
        if let separator = stride(from: marker, through: max(0, marker - 8), by: -1).first(where: { isSeparator(lines[$0]) }) {
            cut = separator
        } else {
            while cut > 0 && lines[cut - 1].trimmingCharacters(in: .whitespaces).isEmpty { cut -= 1 }
        }
        return (lines[..<cut].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                lines[cut...].joined(separator: "\n"))
    }

    /// CI 失败通知的摘要：头部信息（仓库、工作流、耗时、结果链接）+ 失败的任务。
    /// 原文是几十行 "* 任务名 succeeded (…)"，真正需要看的只有失败的那几个。不是 CI 通知（没有 "Jobs:" 清单）返回 nil。
    public static func ciDigest(_ text: String) -> String? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let jobsIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "Jobs:" }) else { return nil }
        let jobs = lines[(jobsIndex + 1)...].map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("* ") || $0.hasPrefix("- ") }
        guard !jobs.isEmpty else { return nil }
        let failed = jobs.filter { $0.range(of: #"\bfailed\b|\bcancelled\b|timed out"#, options: [.regularExpression, .caseInsensitive]) != nil }

        let head = lines[..<jobsIndex].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
        var result = head + "\n\n共 \(jobs.count) 个任务，失败 \(failed.count) 个，其余成功或跳过"
        if !failed.isEmpty {
            result += "\n\n失败的任务：\n" + failed.map { "  ✗ " + $0.dropFirst(2) }.joined(separator: "\n")
        }
        return result
    }

    /// 让 GitHub 评论的 Markdown 在纯文本视图里更好读：去掉 HTML 注释和常见的内嵌标签，把 `## 标题` 变成粗体。
    public static func prettify(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        // 图片标签整个去掉；粗体 / 斜体 / 行内代码的 HTML 写法转成 Markdown；其余常见的排版标签只去标签留文字
        result = result.replacingOccurrences(of: "<img\\b[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "</?(?:b|strong)\\b[^>]*>", with: "**", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "</?(?:i|em)\\b[^>]*>", with: "*", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "</?code\\b[^>]*>", with: "`", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "</?(?:sub|sup|details|summary|p|div|span|h[1-6])\\b[^>]*>", with: "",
                                             options: [.regularExpression, .caseInsensitive])
        let lines = result.components(separatedBy: "\n").map { line -> String in
            guard let range = line.range(of: #"^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$"#, options: .regularExpression) else { return line }
            let heading = line[range].drop(while: { $0 == " " || $0 == "#" }).trimmingCharacters(in: CharacterSet(charactersIn: " #"))
            return "**\(heading)**"
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
