import AppKit
import CoreText
import SwiftUI
import WebKit

/// 字体套装：选一次，全局统一——列表、详情标题、界面文字用「正文字体」，编号 / 代码 / 元信息用「等宽字体」，
/// 邮件正文（HTML / Markdown）也用同一套。中文自动回落到系统的苹方。
/// 打包进应用的字体（App/Fonts，SIL OFL 开源许可）不需要另外安装；其余用每台 Mac 都自带的系统字体。
enum FontSet: String, CaseIterable, Identifiable {
    /// JetBrains Mono + 系统无衬线：给程序员的默认搭配
    case jetbrains
    /// 全部用 JetBrains Mono
    case jetbrainsAll
    /// IBM Plex Sans + IBM Plex Mono：整套统一的工程风
    case plex
    /// 全部用 IBM Plex Mono
    case plexMonoAll
    /// 完全用系统的 SF 和 SF Mono
    case system
    /// 全部用 SF Mono
    case sfMonoAll
    /// SF Rounded + SF Mono：圆润柔和
    case rounded
    /// Helvetica Neue + Menlo：经典 Mac 开发者搭配
    case menlo
    /// Avenir Next + SF Mono：几何感、更舒展
    case avenir
    /// Charter 衬线 + SF Mono：适合长时间阅读
    case charter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jetbrains: return "JetBrains Mono（默认）"
        case .jetbrainsAll: return "JetBrains Mono 全等宽"
        case .plex: return "IBM Plex"
        case .plexMonoAll: return "IBM Plex Mono 全等宽"
        case .system: return "系统字体（SF）"
        case .sfMonoAll: return "SF Mono 全等宽"
        case .rounded: return "SF Rounded 圆体"
        case .menlo: return "Helvetica Neue + Menlo"
        case .avenir: return "Avenir Next"
        case .charter: return "Charter 衬线"
        }
    }

    var detail: String {
        switch self {
        case .jetbrains: return "正文用系统字体，等宽用 JetBrains Mono。为读代码设计，易区分 0 / O、1 / l。"
        case .jetbrainsAll: return "所有文字都用 JetBrains Mono，最像终端和编辑器。"
        case .plex: return "正文用 IBM Plex Sans，等宽用 IBM Plex Mono。整套统一，偏工程文档的气质。"
        case .plexMonoAll: return "所有文字都用 IBM Plex Mono，比 JetBrains Mono 更圆润一些。"
        case .system: return "正文用 SF，等宽用 SF Mono，和 macOS 自带应用一致。"
        case .sfMonoAll: return "所有文字都用 SF Mono，干净的系统等宽风格。"
        case .rounded: return "正文用 SF Rounded 圆体，等宽用 SF Mono，看起来更柔和。"
        case .menlo: return "正文用 Helvetica Neue，等宽用 Menlo（Xcode 和终端的老默认）。"
        case .avenir: return "正文用 Avenir Next，等宽用 SF Mono。几何感，字形更舒展。"
        case .charter: return "正文用 Charter 衬线体，等宽用 SF Mono。像读文档，适合大段文字。"
        }
    }

    /// 一种字体的来源。
    enum Face {
        /// 系统字体（SF 家族的某种设计）
        case system(Font.Design)
        /// 打包在应用里的字体，参数是 PostScript 名前缀
        case bundled(String)
        /// 系统自带的其他字体家族
        case family(String)
    }

    var sansFace: Face {
        switch self {
        case .jetbrains, .system: return .system(.default)
        case .jetbrainsAll: return .bundled("JetBrainsMono")
        case .plex: return .bundled("IBMPlexSans")
        case .plexMonoAll: return .bundled("IBMPlexMono")
        case .sfMonoAll: return .system(.monospaced)
        case .rounded: return .system(.rounded)
        case .menlo: return .family("Helvetica Neue")
        case .avenir: return .family("Avenir Next")
        case .charter: return .family("Charter")
        }
    }

    var monoFace: Face {
        switch self {
        case .jetbrains, .jetbrainsAll: return .bundled("JetBrainsMono")
        case .plex, .plexMonoAll: return .bundled("IBMPlexMono")
        case .menlo: return .family("Menlo")
        case .system, .sfMonoAll, .rounded, .avenir, .charter: return .system(.monospaced)
        }
    }

    func sans(_ size: CGFloat, _ weight: Font.Weight) -> Font { Self.font(sansFace, size, weight) }
    func mono(_ size: CGFloat, _ weight: Font.Weight) -> Font { Self.font(monoFace, size, weight) }

    private static func font(_ face: Face, _ size: CGFloat, _ weight: Font.Weight) -> Font {
        switch face {
        case .system(let design): return .system(size: size, weight: weight, design: design)
        case .bundled(let prefix): return .custom(postScript(prefix, weight), fixedSize: size)
        case .family(let name): return .custom(name, fixedSize: size).weight(weight)
        }
    }

    /// 各家字体的 PostScript 名不一样：IBM Plex 的是 "IBMPlexMono"（Regular）、"-Medm"、"-SmBld"，JetBrains Mono 是 "-Regular / -Medium / -SemiBold"。
    private static func postScript(_ prefix: String, _ weight: Font.Weight) -> String {
        let plex = prefix.hasPrefix("IBMPlex")
        switch weight {
        case .ultraLight, .thin, .light, .regular: return plex ? prefix : "\(prefix)-Regular"
        case .medium: return "\(prefix)-\(plex ? "Medm" : "Medium")"
        case .semibold: return "\(prefix)-\(plex ? "SmBld" : "SemiBold")"
        default: return "\(prefix)-Bold"
        }
    }

    // MARK: 邮件正文（网页）用的同一套字体

    /// 正文和等宽字体在 CSS 里的写法，以及需要的 @font-face（打包的字体由 FontSchemeHandler 提供给网页）。
    var css: (faces: String, sans: String, mono: String) {
        var faces: [String] = []
        func family(_ face: Face, mono: Bool) -> String {
            let fallback = mono ? #"ui-monospace, "SF Mono", Menlo, "PingFang SC", monospace"# : #"-apple-system, "PingFang SC", sans-serif"#
            switch face {
            case .system(.monospaced): return #"ui-monospace, "SF Mono", Menlo, "PingFang SC", monospace"#
            case .system(.rounded): return #"ui-rounded, -apple-system, "PingFang SC", sans-serif"#
            case .system: return fallback
            case .family(let name): return "\"\(name)\", \(fallback)"
            case .bundled(let prefix):
                let alias = "MailBar \(prefix)"
                for (weight, file) in [(400, "Regular"), (500, "Medium"), (600, "SemiBold"), (700, "Bold")] {
                    faces.append(#"@font-face { font-family: "\#(alias)"; font-weight: \#(weight); src: url("\#(FontSchemeHandler.scheme):///\#(prefix)-\#(file).ttf") format("truetype"); }"#)
                }
                return "\"\(alias)\", \(fallback)"
            }
        }
        let sans = family(sansFace, mono: false)
        let mono = family(monoFace, mono: true)
        return (Array(Set(faces)).sorted().joined(separator: "\n"), sans, mono)
    }
}

enum AppFonts {
    /// 把打包在应用里的 .ttf 注册给本进程用（启动时调用一次）。
    static func registerBundled() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

/// 网页内容在单独的进程里渲染，看不到本进程注册的字体：用自定义网址把打包的字体文件直接交给网页。
final class FontSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mailbarfont"
    static let shared = FontSchemeHandler()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let file = Bundle.main.url(forResource: url.deletingPathExtension().lastPathComponent, withExtension: "ttf"),
              let data = try? Data(contentsOf: file),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "font/ttf", "Access-Control-Allow-Origin": "*",
                                                            "Cache-Control": "max-age=31536000"]) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
