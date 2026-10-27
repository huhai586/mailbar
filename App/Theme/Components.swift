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
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(color.opacity(0.14), in: Capsule())
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
