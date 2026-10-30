import Foundation
import MailCore

// 用法:
//   mailsync sync [--full] [--max N]   同步邮件（首次全量，之后增量；--max 为首次同步的邮件数，默认 500）
//   mailsync watch [--interval S]      前台常驻：每 S 秒（默认 30）同步一次，命中规则时打印并播放声音
//   mailsync rules [add-recommended]   查看并校验规则文件；add-recommended 添加 GitHub 推荐规则
//   mailsync matches [规则名]           按规则筛选本地邮件（不带规则名则列出各规则命中数）
//   mailsync rematch                   用当前规则重新计算本地邮件的命中
//   mailsync sounds                    列出可用于规则的声音名
//   mailsync recent [N]                列出本地最新 N 封（默认 20）
//   mailsync search <关键词>            搜索本地邮件的主题/发件人/正文
//   mailsync status                    查看同步状态
//   mailsync seed-demo                 往邮件库写入 CI 截图用的演示数据（配合 MAIL_DB 指向临时库）
//   mailsync auth                      查看授权状态（是否允许修改邮件状态）
//   mailsync login                     重新走一遍浏览器授权（升级到"可修改邮件状态"时用）
//   mailsync logout                    清除 Keychain 中保存的 token

setvbuf(stdout, nil, _IOLBF, 0)

let formatter = DateFormatter()
formatter.dateFormat = "yyyy-MM-dd HH:mm"

func printMessages(_ messages: [MessageSummary]) {
    for m in messages {
        print("\(m.isUnread ? "●" : " ") \(formatter.string(from: m.date))  \(m.subject)")
        print("    \(m.from)")
    }
    print("\n共 \(messages.count) 封")
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("错误: \(message)\n".utf8))
    exit(1)
}

func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

func intFlag(_ name: String, from rest: inout ArraySlice<String>) -> Int {
    guard let value = rest.popFirst().flatMap(Int.init), value > 0 else { fail("\(name) 需要正整数") }
    return value
}

let args = Array(CommandLine.arguments.dropFirst())

do {
    switch args.first {
    case "sync":
        var full = false
        var limit = 500
        var rest = args.dropFirst()
        while let flag = rest.popFirst() {
            switch flag {
            case "--full": full = true
            case "--max": limit = intFlag(flag, from: &rest)
            default: fail("未知参数: \(flag)")
            }
        }
        let store = try MailStore(path: MailStore.defaultPath())
        let engine = SyncEngine(oauth: OAuthClient(config: try ClientConfig.load()), store: store, initialLimit: limit)
        let start = Date()
        let s = try await engine.sync(forceFull: full)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(start))
        print("\(s.mode == .full ? "全量" : "增量")同步完成（\(seconds)s）：新增/更新 \(s.fetched)，删除 \(s.deleted)，标签变更 \(s.relabeled)；本地共 \(try store.messageCount()) 封")

    case "watch":
        var interval = 30
        var rest = args.dropFirst()
        while let flag = rest.popFirst() {
            guard flag == "--interval" else { fail("未知参数: \(flag)") }
            interval = intFlag(flag, from: &rest)
        }
        let store = try MailStore(path: MailStore.defaultPath())
        let monitor = MailMonitor(oauth: OAuthClient(config: try ClientConfig.load()), store: store)
        print("监控中，每 \(interval) 秒同步一次（Ctrl-C 退出）。规则文件: \(RuleStore.defaultPath())")
        var lastWarning: String?
        while true {
            do {
                let r = try await monitor.syncOnce()
                if r.ruleWarning != lastWarning {
                    lastWarning = r.ruleWarning
                    if let w = r.ruleWarning { print("[\(timestamp())] ⚠️ 规则: \(w)") }
                }
                if r.summary.fetched + r.summary.deleted + r.summary.relabeled > 0 {
                    print("[\(timestamp())] 同步：新增/更新 \(r.summary.fetched)，删除 \(r.summary.deleted)，标签变更 \(r.summary.relabeled)")
                }
                for hit in r.alerts {
                    print("[\(timestamp())] 🔔 [\(hit.ruleName)] \(hit.subject) — \(hit.from)")
                    if hit.sound?.lowercased() != "none" { SoundLibrary.play(hit.sound ?? "Glass") }
                }
            } catch {
                print("[\(timestamp())] 同步失败: \(error.localizedDescription)")
            }
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
        }

    case "rules":
        if args.dropFirst().first == "add-recommended" {
            let existing = try RuleStore.read()
            let added = RuleTemplates.missing(from: RuleTemplates.all, in: existing)
            try RuleStore.write(existing + added)
            print("已添加 \(added.count) 条推荐规则（GitHub / Jira / Google 文档，仅打标签，不弹通知）")
        }
        print(try RuleStore.describe(path: RuleStore.defaultPath()))

    case "matches":
        let store = try MailStore(path: MailStore.defaultPath())
        if let rule = args.dropFirst().first {
            printMessages(try store.matches(rule: rule, limit: 50))
        } else {
            let counts = try store.matchCounts()
            if counts.isEmpty { print("还没有命中记录。编辑规则后运行 mailsync rematch，或等待下一次同步。") }
            for c in counts { print("\(c.name)：\(c.count) 封") }
        }

    case "rematch":
        let store = try MailStore(path: MailStore.defaultPath())
        let monitor = MailMonitor(offlineStore: store)
        if let problem = monitor.reloadRules() { print("⚠️ \(problem)") }
        try monitor.rematch()
        for c in try store.matchCounts() { print("\(c.name)：\(c.count) 封") }

    case "sounds":
        print(SoundLibrary.availableNames().joined(separator: "\n"))
        print("\n自定义声音：放到 ~/Library/Sounds，或在规则里写文件路径。试听: afplay /System/Library/Sounds/Glass.aiff")

    case "recent":
        let limit = args.dropFirst().first.flatMap(Int.init) ?? 20
        printMessages(try MailStore(path: MailStore.defaultPath()).recent(limit: limit))

    case "search":
        guard args.count >= 2 else { fail("用法: mailsync search <关键词>") }
        printMessages(try MailStore(path: MailStore.defaultPath()).search(args.dropFirst().joined(separator: " "), limit: 50))

    case "status":
        let store = try MailStore(path: MailStore.defaultPath())
        print("数据库: \(MailStore.defaultPath())")
        print("账号: \(store.accountEmail ?? "（尚未同步）")")
        print("historyId: \(store.historyId ?? "-")")
        print("本地邮件: \(try store.messageCount()) 封")

    case "seed-demo":
        let store = try MailStore(path: MailStore.defaultPath())
        try DemoData.seed(store: store)
        print("演示数据已写入 \(MailStore.defaultPath())：\(try store.messageCount()) 封，账号 \(DemoData.accountEmail)")

    case "auth":
        let oauth = OAuthClient(config: try ClientConfig.load(), interactive: false)
        print(oauth.canModify ? "已授权：可读取、可修改邮件状态（标记已读）" : "当前授权：仅可读取。要在应用里标记已读，请运行 mailsync login 或在应用的设置里点「授权」。")

    case "login":
        let oauth = OAuthClient(config: try ClientConfig.load())
        try await oauth.signIn()
        print(oauth.canModify ? "授权完成：可读取、可修改邮件状态" : "授权完成，但没有拿到修改权限")

    case "logout":
        OAuthClient.logout()
        print("已清除本机保存的 token")

    default:
        print("用法: mailsync sync | watch | rules | matches [规则名] | rematch | sounds | recent [N] | search <关键词> | status | seed-demo | auth | login | logout")
        exit(args.isEmpty ? 0 : 2)
    }
} catch {
    fail(error.localizedDescription)
}
