import Foundation

/// 把 GitHub 评论里的 Markdown（粗体、行内代码、链接）和裸 URL 渲染成可点击的富文本；块级语法原样保留。
enum RichText {
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func make(_ text: String) -> AttributedString {
        var result = (try? AttributedString(
            markdown: text,
            options: .init(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(text)

        // 补上没有写成 Markdown 链接的网址
        let plain = String(result.characters)
        let matches = linkDetector?.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) ?? []
        for match in matches {
            guard let url = match.url, let range = Range(match.range, in: plain),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            if result[lower..<upper].link == nil { result[lower..<upper].link = url }
        }
        return result
    }
}
