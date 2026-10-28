import Testing
@testable import MailCore

@Suite struct SearchHighlightTests {
    @Test func findsAllMatchesIgnoringCaseAndDiacritics() {
        let text = "Café opens. CAFE closes. cafe."
        #expect(SearchHighlight.ranges(of: "cafe", in: text).map { String(text[$0]) } == ["Café", "CAFE", "cafe"])
        #expect(SearchHighlight.ranges(of: "  ", in: text).isEmpty)
        #expect(SearchHighlight.ranges(of: "告警", in: "服务器告警，又告警").count == 2)
    }

    @Test func excerptCentersOnTheFirstMatch() {
        let text = String(repeating: "lorem ", count: 50) + "the KEYWORD is here " + String(repeating: "ipsum ", count: 50)
        let excerpt = try! #require(SearchHighlight.excerpt(text, query: "keyword"))
        #expect(excerpt.hasPrefix("…") && excerpt.hasSuffix("…"))
        #expect(excerpt.contains("KEYWORD"))
        #expect(SearchHighlight.excerpt("short body", query: "nope") == nil)
        #expect(SearchHighlight.excerpt("hello  world\nagain", query: "world") == "hello world again")
    }

    @Test func marksTextButNotTagsScriptsOrStyles() {
        let html = #"<style>.alert{}</style><p class="alert">Alert one</p><a href="x?alert=1">alert two</a><script>alert(1)</script>"#
        let (marked, count) = SearchHighlight.markHTML(html, query: "alert")
        #expect(count == 2)
        #expect(marked.contains(#"<p class="alert"><mark class="mb-hit">Alert</mark> one</p>"#))
        #expect(marked.contains(#"<a href="x?alert=1"><mark class="mb-hit">alert</mark> two</a>"#))
        #expect(marked.contains("<style>.alert{}</style>") && marked.contains("<script>alert(1)</script>"))
    }

    @Test func noMatchLeavesHTMLAlone() {
        let html = "<p>nothing here</p>"
        #expect(SearchHighlight.markHTML(html, query: "zzz") == (html, 0))
        #expect(SearchHighlight.markHTML(html, query: "") == (html, 0))
    }
}
