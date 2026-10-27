# MailBar：给程序员用的 Gmail 阅读 + 提醒工具（Mac 原生，只读）

每天几百封 GitHub / Jira / 文档通知，找出真正重要的、不漏掉、一眼看明白。

## 它做什么
- **分诊，而不是罗列**：每封邮件先判断是"真人 / 例行机器人 / 出问题的机器人"。收件箱按来源（GitHub / Jira / Google 文档 / 其他）和"要不要你管"分段：**需要处理**（出问题了，或和你相关的 PR 上有真人的新评论）→ 有新动态 → 仅机器人更新（默认折叠，可一键清理）→ 已读。启动先落在"待处理"。
- **PR 行是活动摘要**：`12 条新评论 · 17 次失败 · 例行 47 · Jira 1`，左边色条标出轻重；打开 PR，例行机器人消息折成一行，只展开真人和出问题的。
- **快速更新**：默认每 10 秒检查一次（可调到 3 秒），切回应用立即同步。
- **重点标记**：按关键词 / 发件人 / GitHub 通知原因 打彩色标签；"重点"视图汇总所有命中；菜单栏图标旁显示未读重点数。
- **强提醒**：规则设为"强提醒"后，屏幕上弹出始终置顶的卡片，循环响铃，Dock 图标跳动，直到你处理。
- **Markdown 渲染**：GitHub 评论和 Markdown 格式的邮件渲染成表格、列表、引用、代码块、任务列表，和 GitHub 网页一致（底层是 GitHub 官方的 cmark-gfm）；纯文本邮件会自动判断是不是 Markdown。每封邮件右上角的小标签在 `MD / 原文 / HTML` 之间切换。
- **一键清理**：把"质量门通过、包体积没变、测试全过、评审进行中"这类例行机器人未读一键标为已读，也可以在设置里设成自动。
- **GitHub**：按 **PR 聚合** —— 一个 PR 的评论、推送、CI 失败（只列失败的任务）、Jira 联动合成一行；识别 `X-GitHub-Reason`（请求 Review、被 @、指派…）；PR 标题里的 Jira 编号可一键跳转。
- **Jira**：识别 `[JIRA] (KEY-1) 标题`，从正文判断事件（指派给你、提到你、PR 已合并、状态变更…）；周报摘要单独标出。
- **Google 文档**：识别共享、评论、@提及、分配、请求访问、建议修改（中英文）。
- **极客界面**：GitHub 深色调色板、等宽字体、紧凑列表；`j/k` 移动、`m` 已读、`/` 搜索、`g` 在原服务打开、`p` 切换 PR 聚合、`⌘K` 命令面板。
- **设置项齐全**：外观、同步间隔、阅读、已读策略、提醒、强提醒、规则（可视化编辑 + 试匹配）、账号与同步。

## 打开项目
**用 Xcode 打开 `Mail.xcodeproj`**（双击，或 `xed .`），scheme 选 **MailBar**、目标 **My Mac**，⌘R。

```
Mail.xcodeproj        由 project.yml 生成（不要手改；增删 App/ 下文件后运行 `xcodegen generate`）
App/                  macOS App：菜单栏、主窗口（SwiftUI）、设置、强提醒、图标资源
Sources/MailCore      核心库：OAuth、Gmail API、SQLite、同步、规则、通知识别、阅读查询
Sources/mailsync      命令行工具
Tests/MailCoreTests   Swift Testing 单元测试（`swift test`）
tools/make-icon.swift 生成 App 图标和菜单栏图标：swift tools/make-icon.swift
```

## 一、准备 OAuth 客户端（只需一次）
> 下载好 JSON 后，直接在 App 里 设置 → 账号与同步 → OAuth 客户端 → 导入 JSON（或把文件拖进去）；下面第 3 步手动放文件也可以。换电脑同理。
1. 公司 GCP 组织下建项目，启用 **Gmail API**。
2. OAuth 同意屏幕用户类型选 **内部**。
3. 建 **桌面应用** 类型的客户端，下载 JSON 放到 `~/.config/mail-client/client_secret.json`（或用 `MAIL_CLIENT_JSON` 指定）。不要提交到公开仓库。

## 二、首次使用
1. 运行后若弹出钥匙串授权框（"MailBar 想要使用…"），输入登录密码并点 **始终允许**。
2. 主窗口顶部提示"需要升级授权"时，点 **授权…** 在浏览器里同意一次（允许修改已读 / 未读状态；只用来标记已读，不会发信或删除）。
3. 侧栏"规则"下点 **添加推荐规则（GitHub / Jira / 文档）**，推荐规则默认只打标签、不弹通知；想要提醒，在 设置 → 规则 里把提醒方式改成「通知」或「强提醒」。

## 规则
设置 → 规则 里可视化编辑（自动保存、实时校验、"试匹配"显示会命中多少封本地邮件），也可以直接改 `~/Library/Application Support/MailClient/rules.json`。

| 字段 | 说明 |
|---|---|
| `keywords` / `fields` | 关键词（任一或全部，`requireAll`）与查找位置：subject / body / from / to |
| `from` | 发件人包含 |
| `reasons` | GitHub 通知原因：review_requested / mention / assign / ci_activity / state_change … |
| `exclude`、`regex` | 排除词；把以上都当作正则 |
| `notify` / `strong` / `sound` | 仅筛选 / 通知 / 强提醒；声音名、文件路径或 none |
| `color` | 标签颜色：red orange yellow green cyan blue purple pink gray |

## 命令行
```bash
swift run mailsync sync [--full] [--max N]   # 同步
swift run mailsync watch                     # 前台监控并播放声音
swift run mailsync rules [add-recommended]   # 查看规则；添加推荐规则
swift run mailsync matches [规则名] | rematch | sounds | recent | search <词> | status | auth | login | logout
```

## 分诊规则（`Sources/MailCore/MessageKind.swift`）
| 类型 | 判断依据 |
|---|---|
| 例行机器人 | GitHub 机器人评论（`[bot]` 账号、评论里藏的 `<!-- 标记 -->`、固定模板），内容是 Quality Gate passed、Bundle Size Check（没有警告）、Test Summary / Report（没有失败）、All tests passed、Review Council in progress |
| 出问题的机器人 | CI `run failed` 通知、Quality Gate failed、`🔥` / `Blackbox fail`、`**N failed**`、`N tests failed`、`❌`（表头里的 "Failed ❌" 不算）、包体积警告 |
| 真人 | 其余 GitHub 评论，以及所有非 GitHub 邮件 |

"待处理" = 有出问题的未读，或（你和这个 PR 有明确关系 —— 被请求 Review / 被提及 / 指派 / 你自己的 PR —— 且有真人的未读）。这些规则按你邮箱里的真实样本调过（见 `Tests/MailCoreTests/TriageTests.swift`）；如果你的 CI 有别的模板，把一两封样例发给我，加进去即可。

### 识别规则可配置
设置 → **识别**：覆盖规则（发件人 / 主题 / 正文 包含某词或匹配正则 → 指定类型，从上到下第一条命中的生效）、机器人账号名单、内置识别模式（正则，可一键恢复默认）。改动立即保存并对本地所有邮件重新分类；邮件卡片右上角的「归类」菜单可以一键把某个发件人改成别的类型。配置文件：`~/Library/Application Support/MailClient/classifier.json`（环境变量 `MAIL_CLASSIFIER` 可改路径），删掉它就回到默认。

## 已知情况与限制
- **只读 + 标记已读**：授权范围是 `gmail.modify`，应用只调用"标记已读 / 未读"。回复、归档、删除请用"在 Gmail 中打开"。
- **推送是轮询**：不是 Gmail Pub/Sub 实时推送（那需要在 GCP 里另建 Pub/Sub 主题和订阅）。间隔 3–10 秒时延迟已经很低，且每次请求开销很小。
- **Gmail 配额**：本项目实测约每分钟 100 次 `messages.get` 就限流，应用会自动降速重试。所以首次同步 500 封要 5–8 分钟；增量同步几秒。
- **本地只镜像最近的邮件**：默认 500 封，可在 设置 → 账号与同步 里"加载更早的邮件"。
- **PR 聚合**：靠主题里的 `(PR #n)` 和正文里的 PR 链接；CI 失败邮件没有编号，按"仓库 + PR 标题"对上。
- **钥匙串授权**：工程用团队 `N29KZ7R4WK` 的开发证书签名，钥匙串按团队放行，首次运行点一次「始终允许」之后，重新编译不会再问。证书一年一过期，过期后运行 `xcodebuild -project Mail.xcodeproj -scheme MailBar -allowProvisioningUpdates build` 让 Xcode 自动续签。
- **Google 文档的识别没有在真实邮件上验证**（你的邮箱里暂时没有这类邮件），按官方通知的发件人和措辞实现，有单元测试。
- 邮件渲染：禁用 JavaScript；远程图片默认加载（可在设置里关闭）；深色主题下 HTML 邮件反色显示。
- 开机自动启动时会同时打开主窗口（可在 设置 → 通用 里关掉"启动时打开主窗口"）。

## 调试开关（仅 Debug 构建）
`open MailBar.app --args -noSync YES`（不同步，只用本地数据，不会触发钥匙串）、`-selectFirstThread YES`、`-selectGroup "owner/repo#123"`、`-openPalette YES`、`-openSettings YES -settingsTab rules`。
