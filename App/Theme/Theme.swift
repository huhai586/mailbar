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

    // 两套主题：深色 = 「终端控制台」（暖黑底 + 琥珀招牌色），浅色 = 「纸质」（暖白纸 + 深绿墨色）。
    // 颜色只为"有含义的事"服务：accent = 需要你；red = 出问题；其余都收成灰。
    // 表面
    static let bg = dynamic(0x16130F, 0xFAF7F1)
    static let panel = dynamic(0x1D1912, 0xF3EFE6)
    static let raised = dynamic(0x2A251D, 0xE9E3D6)
    static let border = dynamic(0x332D22, 0xE0D9CB)
    static let hover = dynamic(0xFFF1D6, 0x000000, alpha: 0.04)
    static let selection = dynamic(0xF5A524, 0x2F5D46, alpha: 0.16)

    // 文字
    static let text = dynamic(0xE9E3D6, 0x1F1D19)
    static let muted = dynamic(0x8A8273, 0x6B665A)
    static let faint = dynamic(0x6F6858, 0x8B8577)

    // 语义色
    static let accent = dynamic(0xF5A524, 0x2F5D46)
    static let red = dynamic(0xFF5F4A, 0xB3402A)
    static let orange = dynamic(0xE8803A, 0xB5651D)
    static let yellow = dynamic(0xD9B44A, 0x8F6B12)
    static let green = dynamic(0x7FB069, 0x4A7A3A)
    static let cyan = dynamic(0x5FB3A8, 0x2D7A78)
    static let blue = dynamic(0x7AA2C8, 0x3B6A8F)
    static let purple = dynamic(0xB59AE0, 0x6B4FA0)
    static let pink = dynamic(0xE58AB0, 0xA83E6B)
    static let gray = dynamic(0x8A8273, 0x7A756A)

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
        case .github: return blue
        case .jira: return cyan
        case .googleDocs: return green
        }
    }

    /// 规则的重要程度：强提醒 > 通知 > 仅筛选，用来决定列表左侧色条取哪条规则的颜色。
    static func priority(of rule: Rule) -> Int {
        if !rule.notify { return 1 }
        return rule.strong ? 3 : 2
    }

    // 字号偏移和整体密度：设置里改，RootView 用它们当 id，改了就整体重建界面。
    static var fontOffset: CGFloat { CGFloat(UserDefaults.standard.double(forKey: Pref.fontOffset)) }
    /// 间距倍率：紧凑 0.8、标准 1、宽松 1.3。
    static var space: CGFloat {
        switch UserDefaults.standard.string(forKey: Pref.uiDensity) {
        case "compact": return 0.8
        case "spacious": return 1.3
        default: return 1
        }
    }
    static var isCompact: Bool { UserDefaults.standard.string(forKey: Pref.uiDensity) == "compact" }
    static var isSpacious: Bool { UserDefaults.standard.string(forKey: Pref.uiDensity) == "spacious" }
    /// 邮件正文（HTML / Markdown）的字号。
    static var bodyPx: Int { max(10, 14 + Int(fontOffset.rounded())) }
    static func pad(_ v: CGFloat) -> CGFloat { (v * space * 2).rounded() / 2 }

    // 字体（都带上字号偏移；字体套装见 FontSets.swift）
    static var fontSet: FontSet { FontSet(rawValue: UserDefaults.standard.string(forKey: Pref.fontSet) ?? "") ?? .jetbrains }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        fontSet.mono(max(9, size + fontOffset), weight)
    }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        fontSet.sans(max(9, size + fontOffset), weight)
    }

    /// 标题字体：深色（终端）用无衬线，浅色（纸质）用衬线；等宽留给元信息和编号。
    static func title(_ size: CGFloat, _ weight: Font.Weight = .regular, scheme: ColorScheme) -> Font {
        scheme == .dark ? fontSet.sans(max(9, size + fontOffset), weight)
                        : .system(size: max(9, size + 2 + fontOffset), weight: weight, design: .serif)
    }

    static let radius: CGFloat = 6
}

extension View {
    /// 设置里的外观：深色 / 浅色 / 跟随系统。
    func applyAppearance(_ value: String) -> some View {
        preferredColorScheme(value == "dark" ? .dark : (value == "light" ? .light : nil))
    }
}
