import MailCore
import SwiftUI

/// 小标签：仓库、PR 编号、规则名、GitHub 原因都用它。
struct Chip: View {
    let text: String
    var color: Color = Theme.muted
    var filled = false
    var mono = true
    var icon: String?

    var body: some View {
        HStack(spacing: 3) {
            if let icon { IconImage(name: icon, size: 8) }
            Text(text).lineLimit(1)
        }
        .font(mono ? Theme.mono(10.5, .medium) : Theme.ui(10.5, .medium))
        .foregroundStyle(filled ? Color.white : color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(filled ? color : color.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(filled ? 0 : 0.35), lineWidth: 0.5))
        .fixedSize()
    }
}

/// 可点击的标签：链接蓝 + 下划线 + 右上箭头，悬停时加深并变成手型指针；和普通标签一眼能分开。
struct LinkChip: View {
    let text: String
    let url: URL
    var icon: String?
    var help: String?
    @State private var hovering = false

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 3) {
                if let icon {
                    if icon == "github" || icon == "jira" {
                        ServiceIcon(source: icon, size: 12, color: hovering ? Theme.text : Theme.blue)
                    } else {
                        Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                    }
                }
                Text(text).underline(true, pattern: .dot).lineLimit(1)
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold)).opacity(0.7)
            }
            .font(Theme.mono(11.5, .medium))
            .foregroundStyle(hovering ? Theme.text : Theme.blue)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Theme.blue.opacity(hovering ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
        }
        .buttonStyle(PlainPointerButtonStyle())
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help(help ?? "在浏览器中打开 \(url.absoluteString)")
    }
}

/// 点一下在页面里跳转的标签（如"被 @ 提及"）：保持自己的颜色，但带下划线、跳转图标、手型指针和悬停加深，表示可点。
struct JumpChip: View {
    let text: String
    var color: Color
    var badge: String?
    var help: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(text).underline().lineLimit(1)
                if let badge { Text(badge).font(Theme.mono(9.5, .semibold)).opacity(0.85) }
                Image(systemName: "arrow.down.right").font(.system(size: 7, weight: .bold))
            }
            .font(Theme.ui(10.5, .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(hovering ? 0.30 : 0.13), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(hovering ? 0.95 : 0.6), lineWidth: 0.8))
            .fixedSize()
        }
        .buttonStyle(PlainPointerButtonStyle())
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help(help ?? "")
    }
}

/// 发件人头像：首字母 + 按名字稳定取色。
struct Avatar: View {
    let name: String
    var size: CGFloat = 24

    private static let palette: [Color] = [Theme.blue, Theme.purple, Theme.green, Theme.orange, Theme.pink, Theme.cyan, Theme.yellow]

    /// 统一用强调色：头像只是"谁"的记号，不该为彩色再加噪音。
    private var color: Color { Theme.accent }

    var body: some View {
        Text(String(name.first(where: { $0.isLetter || $0.isNumber }) ?? "?").uppercased())
            .font(Theme.mono(size * 0.46, .bold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.28))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28).stroke(color.opacity(0.4), lineWidth: 0.5))
    }
}

/// 数字徽标（未读数、命中数）。
struct CountBadge: View {
    let count: Int
    var color: Color = Theme.muted
    var body: some View {
        if count > 0 {
            // 小胶囊：低饱和底 + 细边，数字不抢眼（参照新版设计稿）
            Text(count > 999 ? "999+" : "\(count)")
                .font(Theme.mono(10.5, .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(Theme.raised.opacity(0.7), in: Capsule())
                .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
        }
    }
}

/// 一行快捷键提示：`j` `k` 移动。
struct KeyHint: View {
    let keys: String
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(Theme.mono(10, .semibold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border, lineWidth: 0.5))
            Text(label).font(Theme.ui(10.5))
        }
        .foregroundStyle(Theme.muted)
    }
}

extension View {
    /// 侧栏选中项：柔和的中性浅填充（文字色的 6%，各主题自动适配）+ 左边一条细的强调色带，是整个侧栏唯一明确的高亮。
    func navSelected(_ selected: Bool) -> some View {
        background(selected ? Theme.text.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(Theme.accent.opacity(0.75)).frame(width: 2).padding(.vertical, 7).offset(x: -1) }
            }
    }
}

/// 服务图标：GitHub / Jira / Google 文档用官方品牌图标（见 BrandIcons），其余用 SF Symbols。
struct ServiceIcon: View {
    let source: String
    var size: CGFloat = 14
    var color: Color? = Theme.muted   // nil = 继承外面的前景色

    private var brand: NSImage? {
        switch source {
        case "github": return BrandIcons.github
        case "jira": return BrandIcons.jira
        case "googleDocs": return BrandIcons.googleDocs
        default: return nil
        }
    }

    var body: some View {
        if let brand {
            Image(nsImage: brand).renderingMode(.template).resizable().scaledToFit()
                .frame(width: size, height: size).foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.foreground))
        } else {
            Image(systemName: "envelope").font(.system(size: size * 0.85)).foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.foreground))
        }
    }
}

/// 图标名里 "brand.github / brand.jira / brand.googleDocs" 画官方品牌图标，其余当 SF Symbol 用。
struct IconImage: View {
    let name: String
    var size: CGFloat = 11
    var body: some View {
        if name.hasPrefix("brand.") {
            ServiceIcon(source: String(name.dropFirst(6)), size: size + 1, color: nil)
        } else {
            Image(systemName: name).font(.system(size: size))
        }
    }
}

/// 无边框按钮，鼠标悬停时变成手型指针；按下略微变淡。App 里所有 "plain" 按钮都用它。
struct PlainPointerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .pointerStyle(.link)
    }
}


extension View {
    /// 纯图标按钮的点击区域不小于 24×24（苹果在 macOS 上建议至少 20×20，默认 28×28）：图标本身可以小，可点的范围不能小。
    func iconHitTarget(_ size: CGFloat = 24) -> some View {
        frame(minWidth: size, minHeight: size).contentShape(Rectangle())
    }
}

/// 显示 / 隐藏侧栏的按钮（和「视图 > 隐藏侧栏」、⌃⌘S 是同一个开关）。
struct SidebarToggleButton: View {
    @AppStorage(Pref.sidebarVisible) private var visible = true

    var body: some View {
        Button { visible.toggle() } label: {
            Image(systemName: "sidebar.left").font(.system(size: 13)).iconHitTarget()
        }
        .buttonStyle(PlainPointerButtonStyle())
        .foregroundStyle(Theme.muted)
        .help(visible ? "隐藏侧栏（⌃⌘S）" : "显示侧栏（⌃⌘S）")
        .accessibilityLabel(visible ? "隐藏侧栏" : "显示侧栏")
    }
}
