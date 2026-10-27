import AppKit
import MailCore
import SwiftUI

/// 极客风配色：深色用 GitHub Dark 的调色板，浅色用 GitHub Light，随系统外观或设置里的外观切换。
enum Theme {
    private static func ns(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func dynamic(_ dark: UInt32, _ light: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark, alpha: alpha) : ns(light, alpha: alpha)
        })
    }

    // 表面
    static let bg = dynamic(0x0D1117, 0xFFFFFF)
    static let panel = dynamic(0x161B22, 0xF6F8FA)
    static let raised = dynamic(0x21262D, 0xEAEEF2)
    static let border = dynamic(0x30363D, 0xD0D7DE)
    static let hover = dynamic(0xFFFFFF, 0x000000, alpha: 0.04)
    static let selection = dynamic(0x1F6FEB, 0x0969DA, alpha: 0.22)

    // 文字
    static let text = dynamic(0xE6EDF3, 0x1F2328)
    static let muted = dynamic(0x8B949E, 0x59636E)
    static let faint = dynamic(0x6E7681, 0x818B98)

    // 语义色
    static let accent = dynamic(0x58A6FF, 0x0969DA)
    static let red = dynamic(0xF85149, 0xCF222E)
    static let orange = dynamic(0xDB6D28, 0xBC4C00)
    static let yellow = dynamic(0xD29922, 0x9A6700)
    static let green = dynamic(0x3FB950, 0x1A7F37)
    static let cyan = dynamic(0x39C5CF, 0x1B7C83)
    static let blue = accent
    static let purple = dynamic(0xBC8CFF, 0x8250DF)
    static let pink = dynamic(0xF778BA, 0xBF3989)
    static let gray = dynamic(0x8B949E, 0x6E7781)

    static func color(named name: String) -> Color {
        switch name {
        case "red": return red
        case "orange": return orange
        case "yellow": return yellow
        case "green": return green
        case "cyan": return cyan
        case "blue": return blue
        case "purple": return purple
        case "pink": return pink
        default: return gray
        }
    }

    /// 规则在界面里的颜色：用户选的优先，否则强提醒红、通知橙、仅筛选蓝。
    static func color(for rule: Rule) -> Color {
        if let name = rule.color { return color(named: name) }
        if !rule.notify { return blue }
        return rule.strong ? red : orange
    }

    /// 各服务在界面里的代表色。
    static func color(for service: NotificationInfo.Service) -> Color {
        switch service {
        case .github: return accent
        case .jira: return cyan
        case .googleDocs: return green
        }
    }

    /// 规则的重要程度：强提醒 > 通知 > 仅筛选，用来决定列表左侧色条取哪条规则的颜色。
    static func priority(of rule: Rule) -> Int {
        if !rule.notify { return 1 }
        return rule.strong ? 3 : 2
    }

    // 字体
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static let radius: CGFloat = 6
}

extension View {
    /// 设置里的外观：深色 / 浅色 / 跟随系统。
    func applyAppearance(_ value: String) -> some View {
        preferredColorScheme(value == "dark" ? .dark : (value == "light" ? .light : nil))
    }
}
