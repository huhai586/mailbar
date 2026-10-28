import Testing
@testable import MailCore

@Suite struct SnippetTextTests {
    @Test func stripsGitHubBoilerplateAndFooter() {
        #expect(SnippetText.preview("jason-liftoff left a comment (Vungle/Monetize#7175) @council Response to the latest review — Reply to this email directly, view it on GitHub")
                == "@council Response to the latest review")
        #expect(SnippetText.preview("kobolsky-vungle left a comment (Vungle/Monetize#7110) LGTM, ship it") == "LGTM, ship it")
    }

    @Test func decodesEntitiesAndCollapsesWhitespace() {
        #expect(SnippetText.preview("it&#39;s  &quot;done&quot;\n&amp; merged &#8217;ok&#x2019;") == "it's \"done\" & merged \u{2019}ok\u{2019}")
        #expect(SnippetText.preview("plain text") == "plain text")
    }

    @Test func clipsToALimitWithAnEllipsis() {
        #expect(SnippetText.clip("hello world", to: 5) == "hello…")
        #expect(SnippetText.clip("hello", to: 5) == "hello")
        #expect(SnippetText.clip("hello", to: 0) == "")
        #expect(SnippetText.clip("服务器告警，磁盘使用率超过百分之九十", to: 6) == "服务器告警，…")
    }
}
