import SwiftUI

@main
struct MailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 单窗口：关掉后应用继续留在菜单栏，同步和提醒照常运行
        Window("邮件", id: "main") {
            RootView(service: delegate.service)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 780)
        .commands { AppCommands(service: delegate.service) }

        Settings {
            SettingsView(service: delegate.service)
        }
    }
}
