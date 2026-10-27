import Foundation

public enum SoundLibrary {
    static let extensions = ["", "aiff", "aif", "caf", "wav", "mp3", "m4a"]

    static var searchDirectories: [String] {
        [("~/Library/Sounds" as NSString).expandingTildeInPath, "/Library/Sounds", "/System/Library/Sounds"]
    }

    /// 把规则里的 sound 配置解析成文件：系统/用户声音名（Glass）或文件路径（~/x.aiff、/abs/x.wav）。
    public static func resolve(_ spec: String, directories: [String]? = nil) -> URL? {
        let expanded = (spec as NSString).expandingTildeInPath
        let fm = FileManager.default
        if expanded.contains("/") {
            return fm.fileExists(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        for dir in directories ?? searchDirectories {
            for ext in extensions {
                let path = (dir as NSString).appendingPathComponent(ext.isEmpty ? expanded : "\(expanded).\(ext)")
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    /// 后台播放，不阻塞；找不到文件时什么都不做。
    @discardableResult
    public static func play(_ spec: String) -> Bool {
        guard let url = resolve(spec) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (try? process.run()) != nil
    }

    /// 可直接写进规则的声音名（用户目录里的优先列出）。
    public static func availableNames() -> [String] {
        var names: [String] = []
        for dir in searchDirectories {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for file in files.sorted() {
                let name = (file as NSString).deletingPathExtension
                if !name.hasPrefix("."), !names.contains(name) { names.append(name) }
            }
        }
        return names
    }
}
