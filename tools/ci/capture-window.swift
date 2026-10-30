import CoreGraphics
import Foundation

// 用法: swift tools/ci/capture-window.swift <pid>
// 打印指定进程面积最大的普通窗口（layer 0）的 window ID；找不到时以非零状态退出。
guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: capture-window.swift <pid>\n".utf8))
    exit(2)
}

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}

var best: (id: Int, area: Double) = (0, 0)
for window in list {
    guard let owner = window[kCGWindowOwnerPID as String] as? Int, Int32(owner) == pid,
          let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
          let number = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Double],
          let width = bounds["Width"], let height = bounds["Height"]
    else { continue }
    let area = width * height
    if area > best.area { best = (number, area) }
}

guard best.id != 0 else { exit(1) }
print(best.id)
