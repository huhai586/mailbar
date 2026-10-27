import AppKit
import SwiftUI
import WebKit

/// WebView 默认会吞掉滚轮事件；这里转给外层的 ScrollView，整个会话才能顺畅滚动。
private final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

/// 渲染 HTML 邮件：禁用 JavaScript，默认拦截远程资源，点击链接交给系统浏览器；
/// 高度随内容自动撑开（所以多封邮件可以排在同一个时间线里）；深色模式下可反色。
struct HTMLBodyView: NSViewRepresentable {
    /// email：邮件自带的 HTML（深色下反色）；markdown：MarkdownRenderer 渲染出来的片段（用 GitHub 风格的样式表）
    enum Style { case email, markdown }

    let html: String
    let allowRemoteImages: Bool
    let dark: Bool
    var style: Style = .email
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = PassthroughWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.postsFrameChangedNotifications = true
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        let key = "\(allowRemoteImages)|\(dark)|\(style)|\(html.hashValue)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        view.loadHTMLString(Self.document(for: html, allowRemoteImages: allowRemoteImages, dark: dark, style: style), baseURL: nil)
    }

    static func document(for body: String, allowRemoteImages: Bool, dark: Bool, style: Style = .email) -> String {
        // CSP 先于邮件内容生效：默认只允许内嵌的 data: 图片，不发起任何网络请求；表单一律不能提交
        let images = allowRemoteImages ? "data: https: http:" : "data:"
        // 深色：整页反色再转回色相，图片和视频再反一次保持原样
        let darkCSS = dark ? """
          html { background: #f0f3f6; color: #1d1d1f; filter: invert(1) hue-rotate(180deg); }
          img, video, picture, svg, canvas { filter: invert(1) hue-rotate(180deg); }
        """ : "html { background: #fff; color: #1d1d1f; }"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(images); style-src 'unsafe-inline'; font-src data:; form-action 'none'">
        <base target="_blank">
        <style>
          \(style == .markdown ? markdownCSS(dark: dark) : darkCSS)
          body { font: \(Theme.bodyPx)px/1.55 -apple-system, "PingFang SC", sans-serif; margin: 14px 18px; word-wrap: break-word; overflow-x: hidden; }
          img { max-width: 100%; height: auto; }
          pre, code { white-space: pre-wrap; font-family: ui-monospace, "SF Mono", Menlo, monospace; }
          table { max-width: 100%; }
        </style></head><body>\(body)</body></html>
        """
    }

    /// Markdown 渲染结果的样式：接近 GitHub 的外观，深色 / 浅色各一套，背景透明（透出卡片底色）。
    static func markdownCSS(dark: Bool) -> String {
        let c = dark
            ? (text: "#e6edf3", muted: "#8b949e", link: "#58a6ff", border: "#30363d", codeBg: "rgba(110,118,129,0.4)", preBg: "#161b22", scheme: "dark")
            : (text: "#1f2328", muted: "#59636e", link: "#0969da", border: "#d0d7de", codeBg: "rgba(175,184,193,0.2)", preBg: "#f6f8fa", scheme: "light")
        return """
          :root { color-scheme: \(c.scheme); }
          html { background: transparent; color: \(c.text); }
          body { font: \(Theme.bodyPx)px/1.6 -apple-system, "PingFang SC", sans-serif; margin: 0; padding: 14px 18px; word-wrap: break-word; overflow-x: hidden; }
          a { color: \(c.link); text-decoration: none; }
          a:hover { text-decoration: underline; }
          h1, h2, h3, h4, h5 { margin: 18px 0 8px; font-weight: 600; line-height: 1.25; }
          h1:first-child, h2:first-child, h3:first-child { margin-top: 0; }
          h1 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid \(c.border); }
          h2 { font-size: 1.25em; padding-bottom: .3em; border-bottom: 1px solid \(c.border); }
          h3 { font-size: 1.1em; }
          p, ul, ol, blockquote, table, pre, details { margin: 0 0 12px; }
          ul, ol { padding-left: 2em; }
          li + li { margin-top: .2em; }
          blockquote { margin-left: 0; padding: 0 1em; color: \(c.muted); border-left: .25em solid \(c.border); }
          code { font: 12.5px ui-monospace, "SF Mono", Menlo, monospace; background: \(c.codeBg); padding: .15em .4em; border-radius: 6px; }
          pre { background: \(c.preBg); padding: 12px 14px; border-radius: 6px; overflow-x: auto; }
          pre code { background: none; padding: 0; font-size: 12px; }
          table { border-collapse: collapse; font-size: 12.5px; max-width: 100%; }
          th, td { border: 1px solid \(c.border); padding: 4px 10px; text-align: left; }
          th { background: \(c.preBg); font-weight: 600; }
          hr { border: 0; border-top: 1px solid \(c.border); margin: 16px 0; }
          img { max-width: 100%; height: auto; vertical-align: middle; }
          summary { cursor: pointer; color: \(c.muted); }
          input[type=checkbox] { margin: 0 6px 0 -1.4em; vertical-align: middle; }
          .contains-task-list, ul.contains-task-list { list-style: none; padding-left: 1.4em; }
          del { color: \(c.muted); }
        """
    }

    /// 邮件里有没有指向远程服务器的图片
    static func hasRemoteImages(_ html: String) -> Bool {
        html.range(of: #"<img[^>]+src\s*=\s*["']?\s*https?:"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLBodyView
        var loadedKey: String?
        private var frameObserver: NSObjectProtocol?
        private var lastWidth: CGFloat = 0

        init(_ parent: HTMLBodyView) { self.parent = parent }

        deinit { if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) } }

        func observe(_ view: WKWebView) {
            frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self, weak view] _ in
                guard let self, let view, abs(view.frame.width - self.lastWidth) > 1 else { return }
                self.lastWidth = view.frame.width
                self.measure(view)   // 窗口宽度变了，换行变了，高度要重算
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
            // 远程图片陆续加载完会再撑高
            for delay in [0.5, 1.5, 4.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                    if let webView { self?.measure(webView) }
                }
            }
        }

        func measure(_ webView: WKWebView) {
            webView.evaluateJavaScript("Math.max(document.documentElement.scrollHeight, document.body.scrollHeight)") { [weak self] result, _ in
                guard let self else { return }
                let measured = (result as? Double).map { CGFloat($0) }
                DispatchQueue.main.async {
                    // 测不到时给个固定高度兜底
                    let target = max(40, ceil(measured ?? 480))
                    if abs(self.parent.height - target) > 1 { self.parent.height = target }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // 只允许应用自己 loadHTMLString 的那次加载（.other）；点链接交给系统浏览器；其余（表单提交、脚本跳转、重定向）一律拒绝
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
