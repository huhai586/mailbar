import Foundation

/// 一套主题的全部颜色（0xRRGGBB）。界面的颜色都从这里取，加一个新主题只需要在 `Palette.all` 里加一项。
/// 前四套（终端 / 纸质 / 夜间 / 日间）是手工调好的；其余的只给「基础色」，其他的由 `Palette.derived` 推出来，
/// 并自动把文字和语义色调到足够的对比度（见 `ensure`），所以随便换一套参考色也不会出现看不清的文字。
public struct Palette: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let isDark: Bool
    // 表面
    public let bg, panel, raised, border: UInt32
    // 未读行的底色：普通 / 待处理 / 出问题
    public let unreadFill, unreadAttention, unreadAlert: UInt32
    // 文字
    public let text, muted, faint: UInt32
    // 语义色
    public let accent, red, orange, yellow, green, cyan, blue, purple, pink, gray: UInt32
    // 系统开了「增强对比度」时用的变体
    public let borderContrast, mutedContrast, faintContrast: UInt32

    /// 悬停时叠在上面的一层：深色主题叠白，浅色主题叠黑（透明度由界面决定）。
    public var hover: UInt32 { isDark ? 0xFFFFFF : 0x000000 }

    /// 能当文字背景的所有表面（算对比度时都要过）。
    public var surfaces: [UInt32] { [bg, panel, raised, unreadFill, unreadAttention, unreadAlert] }

    // MARK: - 颜色计算

    static func channels(_ c: UInt32) -> (Double, Double, Double) {
        (Double((c >> 16) & 255), Double((c >> 8) & 255), Double(c & 255))
    }

    /// WCAG 相对亮度。
    public static func luminance(_ c: UInt32) -> Double {
        func f(_ v: Double) -> Double { let s = v / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        let (r, g, b) = channels(c)
        return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
    }

    /// WCAG 对比度（1 到 21）。
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// 从 a 向 b 混合 amount（0 到 1）。
    public static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        let (ar, ag, ab) = channels(a), (br, bg, bb) = channels(b)
        func m(_ x: Double, _ y: Double) -> UInt32 { UInt32((x + (y - x) * amount).rounded()) }
        return m(ar, br) << 16 | m(ag, bg) << 8 | m(ab, bb)
    }

    /// 把 color 朝 target 一点点推，直到它对 backgrounds 里每一个的对比度都不低于 ratio；本来就够就原样返回。
    public static func ensure(_ color: UInt32, ratio: Double, on backgrounds: [UInt32], toward target: UInt32) -> UInt32 {
        var amount = 0.0
        while amount < 1, backgrounds.contains(where: { contrast(mix(color, target, amount), $0) < ratio }) { amount += 0.02 }
        return mix(color, target, min(amount, 1))
    }

    // MARK: - 由基础色推出完整主题

    /// 只给基础色，其余推出来：未读底色在背景上轻微偏向强调色 / 红色；文字 ≥ 9:1，次要文字 ≥ 7:1，更淡的 ≥ 4.6:1，语义色 ≥ 4.6:1。
    static func derived(id: String, title: String, isDark: Bool, bg: UInt32, panel: UInt32, raised: UInt32, border: UInt32,
                        text: UInt32, muted: UInt32, faint: UInt32,
                        accent: UInt32, red: UInt32, orange: UInt32, yellow: UInt32, green: UInt32, cyan: UInt32,
                        blue: UInt32, purple: UInt32, pink: UInt32, gray: UInt32) -> Palette {
        let extreme: UInt32 = isDark ? 0xFFFFFF : 0x000000
        let fill = mix(bg, extreme, 0.05)
        let attention = mix(bg, accent, 0.15)
        let alert = mix(bg, red, 0.15)
        let surfaces = [bg, panel, raised, fill, attention, alert]
        func fit(_ c: UInt32, _ ratio: Double) -> UInt32 { ensure(c, ratio: ratio, on: surfaces, toward: extreme) }
        let t = fit(text, 9)
        let m = fit(muted, 7)
        let f = fit(faint, 4.6)
        return Palette(id: id, title: title, isDark: isDark, bg: bg, panel: panel, raised: raised, border: border,
                       unreadFill: fill, unreadAttention: attention, unreadAlert: alert, text: t, muted: m, faint: f,
                       accent: fit(accent, 4.6), red: fit(red, 4.6), orange: fit(orange, 4.6), yellow: fit(yellow, 4.6),
                       green: fit(green, 4.6), cyan: fit(cyan, 4.6), blue: fit(blue, 4.6), purple: fit(purple, 4.6),
                       pink: fit(pink, 4.6), gray: fit(gray, 4.6),
                       borderContrast: mix(border, t, 0.4), mutedContrast: mix(m, extreme, 0.5), faintContrast: m)
    }

    // MARK: - 主题

    /// 终端（深色，暖黑底 + 琥珀招牌色）：应用最初的深色主题。
    public static let terminal = Palette(
        id: "dark", title: "终端（深色）", isDark: true, bg: 0x16130F, panel: 0x1D1912, raised: 0x2A251D, border: 0x332D22,
        unreadFill: 0x241F17, unreadAttention: 0x30271A, unreadAlert: 0x35201A, text: 0xE9E3D6, muted: 0xBBB4A6, faint: 0x989283,
        accent: 0xF5A524, red: 0xFF5F4A, orange: 0xE8803A, yellow: 0xD9B44A, green: 0x7FB069, cyan: 0x5FB3A8,
        blue: 0x7AA2C8, purple: 0xB59AE0, pink: 0xE58AB0, gray: 0x8A8273,
        borderContrast: 0x7C766A, mutedContrast: 0xD2CCBE, faintContrast: 0xBBB4A6)

    /// 纸质（浅色，暖白纸 + 深绿墨色）。
    public static let paper = Palette(
        id: "light", title: "纸质（浅色）", isDark: false, bg: 0xFAF7F1, panel: 0xF3EFE6, raised: 0xE9E3D6, border: 0xE0D9CB,
        unreadFill: 0xF0EBDD, unreadAttention: 0xE4EADB, unreadAlert: 0xF5E3DB, text: 0x1F1D19, muted: 0x4D4940, faint: 0x686459,
        accent: 0x2F5D46, red: 0xB03F2A, orange: 0x94551C, yellow: 0x7F6013, green: 0x456F36, cyan: 0x2B6F6D,
        blue: 0x3B6A8F, purple: 0x6B4FA0, pink: 0xA83E6B, gray: 0x7A756A,
        borderContrast: 0x938E84, mutedContrast: 0x36332C, faintContrast: 0x4D4940)

    /// 夜间（深蓝）。
    public static let night = Palette(
        id: "night", title: "夜间（深蓝）", isDark: true, bg: 0x0B1020, panel: 0x111833, raised: 0x1B2444, border: 0x252F52,
        unreadFill: 0x121A38, unreadAttention: 0x15244F, unreadAlert: 0x2C1A2C, text: 0xDDE4F5, muted: 0xA6B2CF, faint: 0x8490AF,
        accent: 0x5B9DFF, red: 0xFF6B7A, orange: 0xFFA05A, yellow: 0xE6C65C, green: 0x5FCB8C, cyan: 0x4FD1E0,
        blue: 0x6FA8FF, purple: 0xA78BFA, pink: 0xF27CB0, gray: 0x8190B5,
        borderContrast: 0x6F7793, mutedContrast: 0xC2CBE2, faintContrast: 0xA6B2CF)

    /// 日间（浅蓝灰）。
    public static let day = Palette(
        id: "day", title: "日间（浅蓝）", isDark: false, bg: 0xF7F9FC, panel: 0xEEF2F8, raised: 0xE3E9F3, border: 0xD5DCE8,
        unreadFill: 0xEBF0F8, unreadAttention: 0xDDE9FA, unreadAlert: 0xFBE5E6, text: 0x1B2333, muted: 0x414C61, faint: 0x5A677C,
        accent: 0x1E61CA, red: 0xBB353C, orange: 0x9D5417, yellow: 0x865F08, green: 0x1E7547, cyan: 0x10717C,
        blue: 0x2563C9, purple: 0x6E4BC2, pink: 0xB83280, gray: 0x6B778C,
        borderContrast: 0x8B92A0, mutedContrast: 0x2E384A, faintContrast: 0x414C61)

    // 下面是参考 VS Code 自带主题的配色（取各主题的背景、侧栏、前景和语法高亮的代表色）；具体色值是照主题的风格取的近似，
    // 不是逐一抄的，对比度由 `derived` 保证。

    public static let darkModern = derived(
        id: "darkModern", title: "Dark Modern", isDark: true, bg: 0x1F1F1F, panel: 0x181818, raised: 0x2B2B2B, border: 0x3C3C3C,
        text: 0xCCCCCC, muted: 0x9D9D9D, faint: 0x7A7A7A,
        accent: 0x0078D4, red: 0xF85149, orange: 0xD18616, yellow: 0xE2C08D, green: 0x3FB950, cyan: 0x4EC9B0,
        blue: 0x4FC1FF, purple: 0xC586C0, pink: 0xD16D9E, gray: 0x8B949E)

    public static let darkPlus = derived(
        id: "darkPlus", title: "Dark+", isDark: true, bg: 0x1E1E1E, panel: 0x252526, raised: 0x2D2D30, border: 0x3C3C3C,
        text: 0xD4D4D4, muted: 0x9D9D9D, faint: 0x858585,
        accent: 0x007ACC, red: 0xF44747, orange: 0xCE9178, yellow: 0xDCDCAA, green: 0x6A9955, cyan: 0x4EC9B0,
        blue: 0x569CD6, purple: 0xC586C0, pink: 0xD16D9E, gray: 0x808080)

    public static let lightModern = derived(
        id: "lightModern", title: "Light Modern", isDark: false, bg: 0xFFFFFF, panel: 0xF8F8F8, raised: 0xEBEBEB, border: 0xE5E5E5,
        text: 0x3B3B3B, muted: 0x616161, faint: 0x767676,
        accent: 0x005FB8, red: 0xCD3131, orange: 0xA15C00, yellow: 0x795E26, green: 0x116329, cyan: 0x267F99,
        blue: 0x0451A5, purple: 0xAF00DB, pink: 0xC2185B, gray: 0x6E7781)

    public static let monokai = derived(
        id: "monokai", title: "Monokai", isDark: true, bg: 0x272822, panel: 0x1E1F1C, raised: 0x3E3D32, border: 0x3B3A32,
        text: 0xF8F8F2, muted: 0xCFCFC2, faint: 0x90908A,
        accent: 0xA6E22E, red: 0xF92672, orange: 0xFD971F, yellow: 0xE6DB74, green: 0xA6E22E, cyan: 0x66D9EF,
        blue: 0x6796E6, purple: 0xAE81FF, pink: 0xF92672, gray: 0x75715E)

    public static let solarizedDark = derived(
        id: "solarizedDark", title: "Solarized Dark", isDark: true, bg: 0x002B36, panel: 0x00212B, raised: 0x073642, border: 0x0F4552,
        text: 0x93A1A1, muted: 0x839496, faint: 0x657B83,
        accent: 0x268BD2, red: 0xDC322F, orange: 0xCB4B16, yellow: 0xB58900, green: 0x859900, cyan: 0x2AA198,
        blue: 0x268BD2, purple: 0x6C71C4, pink: 0xD33682, gray: 0x586E75)

    public static let solarizedLight = derived(
        id: "solarizedLight", title: "Solarized Light", isDark: false, bg: 0xFDF6E3, panel: 0xEEE8D5, raised: 0xE4DDC8, border: 0xDDD6C1,
        text: 0x586E75, muted: 0x657B83, faint: 0x839496,
        accent: 0x268BD2, red: 0xDC322F, orange: 0xCB4B16, yellow: 0xB58900, green: 0x859900, cyan: 0x2AA198,
        blue: 0x268BD2, purple: 0x6C71C4, pink: 0xD33682, gray: 0x93A1A1)

    public static let quietLight = derived(
        id: "quietLight", title: "Quiet Light", isDark: false, bg: 0xF5F5F5, panel: 0xEDEDED, raised: 0xE4E4E4, border: 0xD4D4D4,
        text: 0x333333, muted: 0x6B6B6B, faint: 0x7B7B7B,
        accent: 0x705697, red: 0xAA3731, orange: 0xAB6526, yellow: 0x9C5D27, green: 0x448C27, cyan: 0x3A7CA5,
        blue: 0x4B83CD, purple: 0x7A3E9D, pink: 0xCB1C74, gray: 0x777777)

    public static let abyss = derived(
        id: "abyss", title: "Abyss", isDark: true, bg: 0x000C18, panel: 0x060621, raised: 0x10192C, border: 0x2B2B4A,
        text: 0x6688CC, muted: 0x5C78B0, faint: 0x4A5F8F,
        accent: 0x3F8CFF, red: 0xF2635E, orange: 0xF5A25D, yellow: 0xDDBB88, green: 0x3FBF6A, cyan: 0x22AAFF,
        blue: 0x6688CC, purple: 0x9966B8, pink: 0xDD6E9E, gray: 0x6E7F9F)

    public static let kimbieDark = derived(
        id: "kimbieDark", title: "Kimbie Dark", isDark: true, bg: 0x221A0F, panel: 0x362712, raised: 0x4A3720, border: 0x5E452B,
        text: 0xD3AF86, muted: 0xB29A78, faint: 0x8C7A5F,
        accent: 0xF79A32, red: 0xDC3958, orange: 0xF79A32, yellow: 0xE4A33B, green: 0x889B4A, cyan: 0x4C9F94,
        blue: 0x8AB1B0, purple: 0x98676A, pink: 0xDC3958, gray: 0x7E602C)

    public static let tomorrowNightBlue = derived(
        id: "tomorrowNightBlue", title: "Tomorrow Night Blue", isDark: true, bg: 0x002451, panel: 0x001733, raised: 0x003F8E, border: 0x00346E,
        text: 0xFFFFFF, muted: 0xBBDAFF, faint: 0x7285B7,
        accent: 0x80A6FF, red: 0xFF9DA4, orange: 0xFFC58F, yellow: 0xFFEEAD, green: 0xD1F1A9, cyan: 0x99FFFF,
        blue: 0xBBDAFF, purple: 0xEBBBFF, pink: 0xFF9DD0, gray: 0x7285B7)

    /// Darcula：JetBrains（WebStorm / IntelliJ）的经典深色主题，背景 #2B2B2B、侧栏 #3C3F41、文字 #A9B7C6，
    /// 强调色是它的蓝（#4B6EAF），语法色取自它的代码配色：橙 #CC7832、绿 #6A8759、黄 #BBB529、紫 #9876AA、青 #6897BB。
    public static let darcula = derived(
        id: "darcula", title: "Darcula（WebStorm）", isDark: true, bg: 0x2B2B2B, panel: 0x3C3F41, raised: 0x4E5254, border: 0x515151,
        text: 0xA9B7C6, muted: 0x9AA5B1, faint: 0x808B95,
        accent: 0x589DF6, red: 0xFF6B68, orange: 0xCC7832, yellow: 0xBBB529, green: 0x6A8759, cyan: 0x299999,
        blue: 0x6897BB, purple: 0x9876AA, pink: 0xD06FA8, gray: 0x808080)

    /// 设置里「主题」列表的顺序：先是应用自己的四套，再是参考 VS Code 的。
    public static let builtIn: [Palette] = [terminal, paper, night, day]
    public static let vscodeInspired: [Palette] = [darkModern, darkPlus, lightModern, monokai, solarizedDark, solarizedLight,
                                                   quietLight, abyss, kimbieDark, tomorrowNightBlue]
    public static let jetbrains: [Palette] = [darcula]
    public static let all: [Palette] = builtIn + vscodeInspired + jetbrains

    /// 按设置里存的标识找主题；「system」或不认识的标识返回 nil（由调用方按系统明暗选终端或纸质）。
    public static func named(_ id: String?) -> Palette? { all.first { $0.id == id } }

    /// 当前该用哪一套：设置里选了具体主题就用它；跟随系统时按系统的明暗选终端（深）或纸质（浅）。
    public static func resolve(id: String?, systemDark: Bool) -> Palette {
        named(id) ?? (systemDark ? terminal : paper)
    }
}
