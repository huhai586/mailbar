import cmark_gfm
import cmark_gfm_extensions
import Foundation

/// GitHub 风格 Markdown（GFM）→ HTML：标题、列表、引用、代码块、表格、任务列表、删除线、自动链接。
/// 底层是 GitHub 自己用的 cmark-gfm，所以和你在 GitHub 网页上看到的一致。
public enum MarkdownRenderer {
    private static let registerExtensions: Void = { cmark_gfm_core_extensions_ensure_registered() }()

    /// 渲染成 HTML 片段。保留原文里的 HTML（GitHub 评论里常有 `<img>`、`<details>`、`<sub>`），
    /// 安全由显示端负责（WebView 禁用 JS、CSP 拦截远程资源、拦截表单和跳转）。
    /// 单个换行当作 `<br>`，和 GitHub 评论的行为一致。
    public static func html(from markdown: String) -> String {
        _ = registerExtensions
        let options = CMARK_OPT_UNSAFE | CMARK_OPT_HARDBREAKS
        guard let parser = cmark_parser_new(options) else { return escape(markdown) }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tasklist"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        normalized.withCString { _ = cmark_parser_feed(parser, $0, strlen($0)) }
        guard let document = cmark_parser_finish(parser) else { return escape(markdown) }
        defer { cmark_node_free(document) }
        guard let rendered = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser)) else { return escape(markdown) }
        defer { free(rendered) }
        return String(cString: rendered)
    }

    private static func escape(_ text: String) -> String {
        "<pre>" + text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;") + "</pre>"
    }

    // MARK: - 是不是 Markdown

    private static func count(_ pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// 纯文本邮件正文看起来是不是 Markdown。强信号（表格、代码块、标题、Markdown 链接）算 2 分，
    /// 弱信号（列表、粗体、行内代码、引用）算 1 分，达到 2 分就当作 Markdown。
    public static func looksLikeMarkdown(_ text: String) -> Bool {
        var score = 0
        if count(#"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$"#, in: text) > 0 { score += 2 }       // 表格分隔行
        if count(#"^\s{0,3}(```|~~~)"#, in: text) > 0 { score += 2 }                                    // 围栏代码块
        if count(#"^\s{0,3}#{1,6}\s+\S"#, in: text) > 0 { score += 2 }                                  // 标题
        if count(#"\[[^\]\n]+\]\(https?://[^)\s]+\)"#, in: text) > 0 { score += 2 }                      // [文字](链接)
        if count(#"^\s*([-*+]|\d+\.)\s+\S"#, in: text) >= 2 { score += 1 }                              // 列表（至少两项）
        if count(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, in: text) > 0 { score += 1 }                           // 粗体
        if count(#"`[^`\n]+`"#, in: text) > 0 { score += 1 }                                            // 行内代码
        if count(#"^\s{0,3}>\s?\S"#, in: text) > 0 { score += 1 }                                       // 引用
        return score >= 2
    }
}
