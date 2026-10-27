import Foundation

enum Charset {
    /// 按 IANA 字符集名解码；无法识别时按 UTF-8 宽松解码。
    static func decode(_ data: Data, charset: String?) -> String {
        guard let name = charset?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased(), !name.isEmpty else {
            return String(decoding: data, as: UTF8.self)
        }
        let encoding: String.Encoding?
        switch name {
        case "utf-8", "utf8": encoding = .utf8
        case "gb2312", "gbk", "gb18030": encoding = gb18030
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            encoding = cf == kCFStringEncodingInvalidId
                ? nil
                : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
        if let encoding, let text = String(data: data, encoding: encoding) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    // GBK/GB2312 邮件经常实际含有扩展字符，统一按 GB18030 解码更稳。
    private static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
}

enum Base64URL {
    static func decode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

/// RFC 2047：解码 =?charset?B/Q?...?= 形式的邮件头。
enum HeaderDecoder {
    private static let encodedWord = try! NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?]*)\?="#)
    private static let wordGap = try! NSRegularExpression(pattern: #"(\?=)\s+(=\?)"#)

    static func decode(_ raw: String?) -> String {
        guard var text = raw, text.contains("=?") else { return raw ?? "" }
        // 相邻的编码词之间的空白不属于内容
        text = wordGap.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1$2")

        var result = ""
        var last = text.startIndex
        for match in encodedWord.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let whole = Range(match.range, in: text)!
            result += text[last..<whole.lowerBound]
            let charset = String(text[Range(match.range(at: 1), in: text)!])
            let kind = text[Range(match.range(at: 2), in: text)!].uppercased()
            let payload = String(text[Range(match.range(at: 3), in: text)!])
            let data = kind == "B" ? Data(base64Encoded: payload) : decodeQ(payload)
            result += data.map { Charset.decode($0, charset: charset) } ?? String(text[whole])
            last = whole.upperBound
        }
        result += text[last...]
        return result
    }

    private static func decodeQ(_ payload: String) -> Data {
        var out = Data()
        let bytes = Array(payload.utf8)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "_") {
                out.append(0x20)
            } else if b == UInt8(ascii: "="), i + 2 < bytes.count,
                      let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                out.append(UInt8(hi * 16 + lo))
                i += 2
            } else {
                out.append(b)
            }
            i += 1
        }
        return out
    }

    private static func hexValue(_ b: UInt8) -> Int? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(b - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(b - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return Int(b - UInt8(ascii: "A")) + 10
        default: return nil
        }
    }
}

enum HTMLText {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static let blocks = regex(#"<(script|style|head)\b.*?</\1\s*>"#)
    private static let lineBreaks = regex(#"<br\s*/?>|</(p|div|tr|li|h[1-6]|table|blockquote)\s*>"#)
    private static let tags = regex(#"<[^>]*>"#)
    private static let entity = regex(#"&(#x[0-9a-f]+|#[0-9]+|[a-z]+);"#)
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "copy": "©", "reg": "®", "hellip": "…", "mdash": "—", "ndash": "–",
    ]

    static func plainText(from html: String) -> String {
        var text = replace(blocks, in: html, with: "")
        text = replace(lineBreaks, in: text, with: "\n")
        text = replace(tags, in: text, with: "")
        text = decodeEntities(text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ re: NSRegularExpression, in text: String, with template: String) -> String {
        re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = ""
        var last = text.startIndex
        for match in entity.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let whole = Range(match.range, in: text)!
            result += text[last..<whole.lowerBound]
            let name = String(text[Range(match.range(at: 1), in: text)!])
            let replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[name.lowercased()]
            }
            result += replacement ?? String(text[whole])
            last = whole.upperBound
        }
        result += text[last...]
        return result
    }
}

struct ParsedBody: Equatable {
    var text: String
    var html: String?
    var hasAttachments: Bool
}

enum MimeParser {
    /// 遍历 Gmail 返回的 MIME 树，提取正文文本、HTML 和是否有附件。
    static func parse(_ payload: GmailPart?) -> ParsedBody {
        var texts: [String] = []
        var htmls: [String] = []
        var hasAttachments = false
        if let payload { walk(payload, texts: &texts, htmls: &htmls, hasAttachments: &hasAttachments) }

        let html = htmls.isEmpty ? nil : htmls.joined(separator: "\n")
        // 统一成 \n：GitHub 等发来的纯文本是 \r\n，行尾的 \r 会让后面的文本处理出错
        var text = texts.joined(separator: "\n").replacingOccurrences(of: "\r\n", with: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let html {
            text = HTMLText.plainText(from: html)
        }
        return ParsedBody(text: text, html: html, hasAttachments: hasAttachments)
    }

    private static func walk(_ part: GmailPart, texts: inout [String], htmls: inout [String], hasAttachments: inout Bool) {
        let mime = (part.mimeType ?? "").lowercased()
        let isAttachment = !(part.filename ?? "").isEmpty

        if isAttachment {
            hasAttachments = true
        } else if mime == "text/plain" || mime == "text/html", let text = decodeBody(part) {
            if mime == "text/plain" { texts.append(text) } else { htmls.append(text) }
        } else if part.body?.attachmentId != nil, part.parts == nil, !mime.hasPrefix("text/") {
            hasAttachments = true
        }
        for child in part.parts ?? [] {
            walk(child, texts: &texts, htmls: &htmls, hasAttachments: &hasAttachments)
        }
    }

    private static func decodeBody(_ part: GmailPart) -> String? {
        guard let encoded = part.body?.data, let data = Base64URL.decode(encoded) else { return nil }
        return Charset.decode(data, charset: charset(in: part.header("Content-Type")))
    }

    private static func charset(in contentType: String?) -> String? {
        guard let contentType,
              let range = contentType.range(of: #"charset\s*=\s*"?([^";\s]+)"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let match = contentType[range]
        return match.split(separator: "=", maxSplits: 1).last.map(String.init)
    }
}
