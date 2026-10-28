import Foundation

/// 列表里显示的正文概览：Gmail 给的 snippet 是 HTML 转义过的纯文本，GitHub 通知还带着固定的开场白。
public enum SnippetText {
    /// GitHub 通知开头那句没有信息量的话（"xxx left a comment (owner/repo#123)"、"xxx requested changes on this pull request." 之类）
    private static let boilerplate = try! NSRegularExpression(pattern: #"^\s*@?[\w.\-\[\]]+ (left a comment|commented|left a review comment|reviewed) \([^)]*\)\s*"#)

    public static func preview(_ snippet: String) -> String {
        var text = decodeEntities(snippet)
        let range = NSRange(text.startIndex..., in: text)
        text = boilerplate.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        // 页脚开头就截断（snippet 很短，常常一半是 "Reply to this email directly…"）
        for footer in ["Reply to this email directly", "You are receiving this because", "— Reply to this email"] {
            if let cut = text.range(of: footer) { text = String(text[..<cut.lowerBound]) }
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " —–-"))
    }

    /// 截到最多 limit 个字，被截掉了就加「…」。limit <= 0 返回空（表示不显示预览）。
    public static func clip(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, char) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        // 数字实体（&#8217; 之类）
        let numeric = try! NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);")
        for match in numeric.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let whole = Range(match.range, in: result), let codeRange = Range(match.range(at: 1), in: result) else { continue }
            let code = result[codeRange]
            let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            if let value, let scalar = Unicode.Scalar(value) { result.replaceSubrange(whole, with: String(Character(scalar))) }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
