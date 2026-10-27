import Foundation

/// 解析 From / To 头里的 `"Name" <addr@host>` 形式。
public struct MailAddress: Equatable, Sendable {
    public let name: String?
    public let address: String

    /// 列表里显示用：有名字用名字，否则用地址。
    public var displayName: String { name ?? address }

    public static func parse(_ raw: String) -> MailAddress {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close else {
            return MailAddress(name: nil, address: text)
        }
        let address = String(text[text.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        var name = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") { name = String(name.dropFirst().dropLast()) }
        name = name.replacingOccurrences(of: "\\\"", with: "\"").trimmingCharacters(in: .whitespaces)
        return MailAddress(name: name.isEmpty ? nil : name, address: address.isEmpty ? text : address)
    }

    /// 逗号分隔的收件人列表；引号里的逗号（如 "Doe, John"）不算分隔符。
    public static func parseList(_ raw: String) -> [MailAddress] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for ch in raw {
            switch ch {
            case "\"": inQuotes.toggle(); current.append(ch)
            case "<" where !inQuotes: inAngle = true; current.append(ch)
            case ">" where !inQuotes: inAngle = false; current.append(ch)
            case "," where !inQuotes && !inAngle: parts.append(current); current = ""
            default: current.append(ch)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map(parse)
    }
}
