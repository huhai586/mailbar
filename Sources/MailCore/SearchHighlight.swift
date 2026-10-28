import Foundation

/// 搜索词的匹配和高亮：不区分大小写和变音符号，和列表搜索的口径一致。
public enum SearchHighlight {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// 搜索词在文字里出现的所有位置（不重叠，从前往后）。
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let found = text.range(of: query, options: options, range: start..<text.endIndex) {
            result.append(found)
            start = found.upperBound
        }
        return result
    }

    public static func contains(_ query: String, in text: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !query.isEmpty && text.range(of: query, options: options) != nil
    }

    /// 列表里的正文片段：从第一个匹配前面一点开始截，让关键字落在能看到的地方。没有匹配返回 nil。
    public static func excerpt(_ text: String, query: String, before: Int = 40, length: Int = 220) -> String? {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let first = ranges(of: query, in: flat).first else { return nil }
        let start = flat.index(first.lowerBound, offsetBy: -before, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(start, offsetBy: length, limitedBy: flat.endIndex) ?? flat.endIndex
        var piece = String(flat[start..<end])
        if start > flat.startIndex { piece = "…" + piece }
        if end < flat.endIndex { piece += "…" }
        return piece
    }

    /// 把网页里（标签之外、脚本和样式之外的）文字中的搜索词包上 `<mark class="mb-hit">`。返回新网页和标记了几处。
    public static func markHTML(_ html: String, query: String) -> (html: String, count: Int) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, contains(query, in: html) else { return (html, 0) }
        var output = ""
        output.reserveCapacity(html.count + 64)
        var count = 0
        var skipUntil: String?          // 在 <script> / <style> / <title> 里面时，等它的结束标签
        var index = html.startIndex
        while index < html.endIndex {
            if html[index] == "<" {
                let tagEnd = html[index...].firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
                let tag = html[index..<tagEnd]
                output += tag
                let lower = tag.lowercased()
                if let closing = skipUntil {
                    if lower.hasPrefix(closing) { skipUntil = nil }
                } else {
                    for name in ["script", "style", "title"] where lower.hasPrefix("<\(name)") {
                        skipUntil = "</\(name)"
                    }
                }
                index = tagEnd
                continue
            }
            let textEnd = html[index...].firstIndex(of: "<") ?? html.endIndex
            let text = String(html[index..<textEnd])
            if skipUntil == nil {
                var cursor = text.startIndex
                for hit in ranges(of: query, in: text) {
                    output += text[cursor..<hit.lowerBound]
                    output += "<mark class=\"mb-hit\">\(text[hit])</mark>"
                    cursor = hit.upperBound
                    count += 1
                }
                output += text[cursor...]
            } else {
                output += text
            }
            index = textEnd
        }
        return (output, count)
    }
}
