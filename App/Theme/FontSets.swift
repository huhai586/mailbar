import AppKit
import CoreText
import SwiftUI

/// 内置字体套装（都是 SIL OFL 许可的开源字体，文件在 App/Fonts，打进应用里，不需要另外安装）。
/// 套装决定两件事：等宽字体（编号、发件人、代码、深色主题的标题）和界面无衬线字体。中文自动回落到系统的苹方。
enum FontSet: String, CaseIterable, Identifiable {
    /// JetBrains Mono + 系统无衬线：给程序员的默认搭配
    case jetbrains
    /// IBM Plex Sans + IBM Plex Mono：整套统一的工程风
    case plex
    /// 完全用系统的 SF 和 SF Mono
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jetbrains: return "JetBrains Mono（默认）"
        case .plex: return "IBM Plex"
        case .system: return "系统字体"
        }
    }

    var detail: String {
        switch self {
        case .jetbrains: return "等宽用 JetBrains Mono，界面用系统字体。为读代码设计，易区分 0 / O、1 / l。"
        case .plex: return "界面用 IBM Plex Sans，等宽用 IBM Plex Mono。整套统一，偏工程文档的气质。"
        case .system: return "界面用 SF，等宽用 SF Mono。"
        }
    }

    private var monoPrefix: String? {
        switch self {
        case .jetbrains: return "JetBrainsMono"
        case .plex: return "IBMPlexMono"
        case .system: return nil
        }
    }

    private var sansPrefix: String? { self == .plex ? "IBMPlexSans" : nil }

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

    func mono(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        guard let prefix = monoPrefix else { return .system(size: size, weight: weight, design: .monospaced) }
        return .custom(Self.postScript(prefix, weight), fixedSize: size)
    }

    func sans(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        guard let prefix = sansPrefix else { return .system(size: size, weight: weight) }
        return .custom(Self.postScript(prefix, weight), fixedSize: size)
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
