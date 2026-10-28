import AppKit
import MailCore
import SwiftUI

/// 侧栏顶部的账号切换器：当前账号 + 下拉列出所有账号（带未读数），可以添加新账号。
struct AccountSwitcher: View {
    @ObservedObject var service: MailService

    var body: some View {
        Menu {
            ForEach(service.accounts) { account in
                Button {
                    service.switchAccount(to: account.id)
                } label: {
                    let unread = service.accountUnread[account.id] ?? 0
                    Text((account.id == service.currentAccountID ? "✓ " : "    ") + account.email + (unread > 0 ? "  (\(unread))" : ""))
                }
            }
            Divider()
            Button("添加 Gmail 账号…") { service.addAccount() }
            Button("管理账号…") { service.openSettings?("account") }
        } label: {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(service.accountEmail ?? "没有账号")
                    .font(Theme.mono(11)).foregroundStyle(Theme.text.opacity(0.9)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                let others = service.accountUnread.filter { $0.key != service.currentAccountID }.values.reduce(0, +)
                if others > 0 { CountBadge(count: others, color: Theme.accent) }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.radius))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("切换账号")
    }

    private var color: Color {
        guard let id = service.currentAccountID, let account = service.accounts.first(where: { $0.id == id }) else { return Theme.faint }
        return Theme.accountColor(account.colorIndex)
    }
}

/// 还没有任何账号（全新安装）时显示的欢迎页。
struct WelcomeView: View {
    @ObservedObject var service: MailService

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Text("欢迎使用 Sift").font(Theme.ui(22, .semibold)).foregroundStyle(Theme.text)
            Text("添加你的 Gmail 账号开始。可以添加多个账号，邮件各自同步，日历会合在一起显示。")
                .font(Theme.ui(13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 380)
            if let error = service.setupError {
                Text(error).font(Theme.ui(12)).foregroundStyle(Theme.red).multilineTextAlignment(.center).frame(maxWidth: 440)
                Button("打开设置，导入 OAuth 客户端文件") { service.openSettings?("account") }
            } else {
                Button {
                    service.addAccount()
                } label: {
                    Text(service.addingAccount ? "请在浏览器里完成授权…" : "添加 Gmail 账号").frame(minWidth: 180)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(service.addingAccount)
            }
            if let message = service.accountMessage {
                Text(message).font(Theme.ui(12)).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}
