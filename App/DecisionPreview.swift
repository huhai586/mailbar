import MailCore
import SwiftUI

/// 设置里「最近的 AI 判断」点开的邮件预览：上面是 AI 的判断和理由，下面是邮件原文，看完可以直接点 👍 / 👎。
struct DecisionPreview: View {
    let decision: AIDecision
    @ObservedObject var service: MailService
    var onFeedback: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Pref.appearance) private var appearance = "dark"
    @State private var message: MessageDetail?
    @State private var expanded = true
    @State private var feedback: Int?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                if let message {
                    MessageCard(message: message, info: NotificationClassifier.classify(subject: message.subject, from: message.from, reason: message.reason, body: String(message.snippet.prefix(600))),
                                githubLogin: nil, expanded: $expanded)
                        .padding(12)
                } else {
                    Text("这封邮件已经不在本地了").font(Theme.ui(12.5)).foregroundStyle(Theme.faint).padding(.top, 40)
                }
            }
        }
        .frame(width: 760, height: 620)
        .background(Theme.bg)
        .applyAppearance(appearance)
        .onAppear {
            feedback = decision.feedback
            message = try? service.store?.message(id: decision.messageId)
        }
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(decision.notify ? "通知" : "不通知")
                .font(Theme.mono(11, .bold)).foregroundStyle(decision.notify ? Theme.orange : Theme.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI 的理由：" + (decision.reason.isEmpty ? "（没有给理由）" : decision.reason))
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.text).textSelection(.enabled)
                Text("判断为 \(decision.kind) · 来源 \(decision.source)" + (decision.ruleName.map { " · 规则 \($0)" } ?? ""))
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
            }
            Spacer()
            feedbackButton(1, symbol: "hand.thumbsup")
            feedbackButton(-1, symbol: "hand.thumbsdown")
            Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
        .background(Theme.panel)
    }

    private func feedbackButton(_ value: Int, symbol: String) -> some View {
        let selected = feedback == value
        return Button {
            feedback = selected ? nil : value
            try? service.store?.setFeedback(messageId: decision.messageId, value: feedback)
            onFeedback()
        } label: {
            Image(systemName: selected ? symbol + ".fill" : symbol)
                .foregroundStyle(selected ? (value > 0 ? Color.green : Color.red) : Theme.muted)
        }
        .buttonStyle(.borderless)
        .help(value > 0 ? "判断对了" : "判断错了")
    }
}

/// 设置里点开一封邮件的预览（试匹配的样例等）：顶部一句说明，下面是邮件原文。
struct MessagePreviewSheet: View {
    let messageId: String
    @ObservedObject var service: MailService
    let caption: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Pref.appearance) private var appearance = "dark"
    @State private var message: MessageDetail?
    @State private var expanded = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(caption).font(Theme.ui(12.5)).foregroundStyle(Theme.text)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .background(Theme.panel)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                if let message {
                    MessageCard(message: message, info: NotificationClassifier.classify(subject: message.subject, from: message.from, reason: message.reason, body: String(message.snippet.prefix(600))),
                                githubLogin: nil, expanded: $expanded)
                        .padding(12)
                } else {
                    Text("这封邮件已经不在本地了").font(Theme.ui(12.5)).foregroundStyle(Theme.faint).padding(.top, 40)
                }
            }
        }
        .frame(width: 760, height: 620)
        .background(Theme.bg)
        .applyAppearance(appearance)
        .onAppear { message = try? service.store?.message(id: messageId) }
    }
}
