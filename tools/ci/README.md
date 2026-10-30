# CI 截图工具

`capture-all.sh` + `capture-window.swift`：配合 `.github/workflows/screenshots.yml` 使用。

## 怎么触发截图

在任意 PR 上打 **screenshots** label：

1. GitHub 的 macOS 机器构建 Sift（Debug，ad-hoc 签名，不需要证书）；
2. `mailsync seed-demo` 写入演示邮件库（见 `Sources/MailCore/DemoData.swift`）；
3. 逐个状态启动 App 截图：主窗口详情 / 未选中 / 命令面板 / 设置·规则 / 设置·通用 / Toast；
4. 截图作为 artifact 回贴到 PR（保留 5 天），跑完自动摘掉 label，可重复打、重复跑。

也可以在 Actions 页面用 workflow_dispatch 手动触发。

## 本地调试

```bash
MAIL_DB=/tmp/demo.sqlite swift run mailsync seed-demo
MAIL_DB=/tmp/demo.sqlite MAIL_FAKE_REMOTE=1 open /path/to/Sift.app --args -noSync YES -selectFirstThread YES
```
