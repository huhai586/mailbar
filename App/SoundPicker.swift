import AppKit
import MailCore
import SwiftUI

/// 选提示音：默认 / 静音 / 系统与用户声音 / 自己选的音频文件，带试听。
struct SoundPicker: View {
    let title: String
    /// nil = 默认，"none" = 静音，其余为声音名或文件路径
    @Binding var selection: String?
    var defaultLabel = "默认"

    private static let names = SoundLibrary.availableNames()

    private var customPath: String? {
        guard let selection, selection.contains("/") else { return nil }
        return selection
    }

    var body: some View {
        HStack {
            Picker(title, selection: $selection) {
                Text(defaultLabel).tag(String?.none)
                Text("静音").tag(String?.some("none"))
                Divider()
                ForEach(Self.names, id: \.self) { Text($0).tag(String?.some($0)) }
                if let customPath {
                    Divider()
                    Text("自定义：" + (customPath as NSString).lastPathComponent).tag(String?.some(customPath))
                }
            }
            Button {
                if let selection, selection != "none" { SoundLibrary.play(selection) }
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help("试听")
            .disabled(selection == nil || selection == "none")
            Button("选择文件…") { chooseFile() }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            selection = url.path
        }
    }
}

/// 把用 "" 表示"默认"的 String 设置项适配成 SoundPicker 需要的 String?。
extension Binding where Value == String {
    var optionalSound: Binding<String?> {
        Binding<String?>(get: { wrappedValue.isEmpty ? nil : wrappedValue }, set: { wrappedValue = $0 ?? "" })
    }
}
