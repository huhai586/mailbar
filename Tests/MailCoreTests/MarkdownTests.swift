import Testing
@testable import MailCore

@Suite struct MarkdownRendererTests {
    private func html(_ markdown: String) -> String { MarkdownRenderer.html(from: markdown) }

    @Test func headingsEmphasisAndInlineCode() {
        let out = html("## Title\n\nSome **bold**, *italic* and `code`.")
        #expect(out.contains("<h2>Title</h2>"))
        #expect(out.contains("<strong>bold</strong>") && out.contains("<em>italic</em>") && out.contains("<code>code</code>"))
    }

    @Test func tablesFromTestReports() {
        let out = html("| SDK | OS | Status |\n|-----|----|--------|\n| 6.12.1 | 11.0 | ✅ Pass |\n| 7.1.0 | 13.0 | ❌ Fail |")
        #expect(out.contains("<table>") && out.contains("<th>SDK</th>"))
        #expect(out.contains("<td>✅ Pass</td>") && out.contains("<td>❌ Fail</td>"))
    }

    @Test func listsQuotesAndFencedCode() {
        let out = html("- one\n- two\n\n> quoted\n\n```swift\nlet x = 1 < 2\n```")
        #expect(out.contains("<ul>") && out.contains("<li>one</li>"))
        #expect(out.contains("<blockquote>"))
        #expect(out.contains("<pre") && out.contains("let x = 1 &lt; 2"))      // 代码块里的 < 被转义
    }

    @Test func gfmExtensions() {
        #expect(html("~~gone~~").contains("<del>gone</del>"))
        #expect(html("- [x] done\n- [ ] todo").contains("type=\"checkbox\""))
        #expect(html("see https://example.com/a?b=1 now").contains("<a href=\"https://example.com/a?b=1\">"))
    }

    @Test func singleNewlinesBecomeLineBreaksLikeGitHubComments() {
        #expect(html("line one\nline two").contains("<br"))
    }

    @Test func rawHTMLFromGitHubCommentsIsPassedThrough() {
        let out = html("<details><summary>Skipped</summary>\n\nitem\n\n</details>\n\n<sub>small</sub> <img src=\"https://x/a.png\" alt=\"A\">")
        #expect(out.contains("<details>") && out.contains("<summary>Skipped</summary>"))
        #expect(out.contains("<sub>small</sub>") && out.contains("<img src=\"https://x/a.png\""))
    }

    @Test func realReviewCouncilComment() {
        let out = html("<!-- review-council -->\n## 🏛️ Review Council — _in progress_\n\n> Triggered by **@kobolsky-vungle** · commit `c289f51`\n\n| Reviewer | Model | Status |\n|---|---|---|\n| claude | opus | ⏳ thinking… |")
        #expect(out.contains("<h2>🏛️ Review Council — <em>in progress</em></h2>"))
        #expect(out.contains("<blockquote>") && out.contains("<strong>@kobolsky-vungle</strong>") && out.contains("<td>⏳ thinking…</td>"))
    }

    @Test func crlfAndEmptyInput() {
        #expect(html("a\r\n\r\nb").contains("<p>a</p>") && html("a\r\n\r\nb").contains("<p>b</p>"))
        #expect(html("").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

@Suite struct LooksLikeMarkdownTests {
    @Test func strongSignals() {
        #expect(MarkdownRenderer.looksLikeMarkdown("## Heading\ntext"))
        #expect(MarkdownRenderer.looksLikeMarkdown("| a | b |\n|---|---|\n| 1 | 2 |"))
        #expect(MarkdownRenderer.looksLikeMarkdown("before\n```\ncode\n```"))
        #expect(MarkdownRenderer.looksLikeMarkdown("see [the docs](https://example.com/x)"))
    }

    @Test func combinedWeakSignals() {
        #expect(MarkdownRenderer.looksLikeMarkdown("Notes:\n- first\n- second\n\nthis is **important**"))
        #expect(MarkdownRenderer.looksLikeMarkdown("run `make` then\n> quoted line"))
    }

    @Test func plainTextIsNotMarkdown() {
        #expect(!MarkdownRenderer.looksLikeMarkdown("Hi Howard,\n\nCan we meet tomorrow at 3pm?\n\nThanks,\nBob"))
        #expect(!MarkdownRenderer.looksLikeMarkdown("a single - dash and one `tick`"))             // 弱信号一条不够
        #expect(!MarkdownRenderer.looksLikeMarkdown("- one bullet only"))
        #expect(!MarkdownRenderer.looksLikeMarkdown("price: 5 > 3 and #hashtag"))                    // 没有空格的 # 不是标题
        #expect(!MarkdownRenderer.looksLikeMarkdown(""))
    }
}
