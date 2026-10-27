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
            if let icon { Image(systemName: icon).font(.system(size: 8, weight: .bold)) }
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
                if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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

    private var color: Color {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Self.palette[sum % Self.palette.count]
    }

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
            Text(count > 999 ? "999+" : "\(count)")
                .font(Theme.mono(10.5, .semibold))
                .foregroundStyle(color)
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
    /// 侧栏选中项：淡淡的强调色底 + 左边一条 2px 色带。
    func navSelected(_ selected: Bool) -> some View {
        background(selected ? Theme.accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(Theme.accent).frame(width: 2, height: 14).offset(x: -1) }
            }
    }
}
