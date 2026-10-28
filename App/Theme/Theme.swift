import AppKit
import MailCore
import SwiftUI

/// 极客风配色：深色用 GitHub Dark 的调色板，浅色用 GitHub Light，随系统外观或设置里的外观切换。
enum Theme {
    private static func ns(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// 系统设置里开了「增强对比度」：次要文字、分隔线用更强的变体（Palette 里的 *Contrast 颜色）。
    private static var increasedContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    /// 当前主题。设置里选了具体主题就用它；选「跟随系统」时按系统的明暗取终端（深）或纸质（浅）。
    static func palette(systemDark: Bool) -> Palette {
        Palette.resolve(id: UserDefaults.standard.string(forKey: Pref.appearance), systemDark: systemDark)
    }

    /// 从当前主题里取一个颜色。颜色在每次绘制时才解析，所以主题一换（RootView 用主题标识当 id 重建界面）立刻生效。
    /// contrast：增强对比度时改取的那一个颜色。
    private static func token(_ color: KeyPath<Palette, UInt32>, alpha: CGFloat = 1, contrast: KeyPath<Palette, UInt32>? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let p = palette(systemDark: isDark)
            let key = (contrast != nil && increasedContrast) ? contrast! : color
            return ns(p[keyPath: key], alpha: alpha)
        })
    }

    // 所有颜色都来自 Palette（MailCore/Palette.swift）：一个主题一份调色板，文字对比度由测试保证。
    // 颜色只为"有含义的事"服务：accent = 需要你；red = 出问题；其余都收成灰。
    // 表面
    static let bg = token(\.bg)
    static let panel = token(\.panel)
    static let raised = token(\.raised)
    static let border = token(\.border, contrast: \.borderContrast)
    static let hover = token(\.hover, alpha: 0.045)
    static let selection = token(\.accent, alpha: 0.16)

    // 未读行的底色：普通 / 待处理 / 出问题
    static let unreadFill = token(\.unreadFill)
    static let unreadAttention = token(\.unreadAttention)
    static let unreadAlert = token(\.unreadAlert)

    // 文字：text ≥ 7:1，muted ≥ 7:1，faint ≥ 4.5:1（苹果建议正文至少 4.5:1）；增强对比度时 muted 再加强，faint 提到 muted 的水平。
    static let text = token(\.text)
    static let muted = token(\.muted, contrast: \.mutedContrast)
    static let faint = token(\.faint, contrast: \.faintContrast)

    // 语义色
    static let accent = token(\.accent)
    static let red = token(\.red)
    static let orange = token(\.orange)
    static let yellow = token(\.yellow)
    static let green = token(\.green)
    static let cyan = token(\.cyan)
    static let blue = token(\.blue)
    static let purple = token(\.purple)
    static let pink = token(\.pink)
    static let gray = token(\.gray)

    /// 账号的识别色（和 AccountRegistry.paletteSize 个数一致）：账号切换器、日历里的日程都用它区分账号。
    static var accountColors: [Color] { [blue, green, orange, purple, pink, cyan, yellow, red] }
    static func accountColor(_ index: Int) -> Color {
        let colors = accountColors
        return colors[((index % colors.count) + colors.count) % colors.count]
    }

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
        fontSet.mono(max(10, size + fontOffset), weight)
    }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        fontSet.sans(max(10, size + fontOffset), weight)
    }

    /// 标题字体：跟随字体套装的正文字体，深色 / 浅色主题一样（字体设置全局统一）。
    static func title(_ size: CGFloat, _ weight: Font.Weight = .regular, scheme: ColorScheme) -> Font {
        fontSet.sans(max(10, size + fontOffset), weight)
    }

    static let radius: CGFloat = 6
}

extension View {
    /// 设置里的主题：每个主题自己知道是深色还是浅色；「跟随系统」不强制。
    func applyAppearance(_ value: String) -> some View {
        preferredColorScheme(Palette.named(value).map { $0.isDark ? .dark : .light })
    }
}
