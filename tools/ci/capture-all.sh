#!/usr/bin/env bash
# 用法: tools/ci/capture-all.sh <Sift.app 路径> <截图输出目录>
# 依赖环境变量: MAIL_DB（演示邮件库）、MAIL_FAKE_REMOTE=1。
# 逐个状态启动 App（Debug 构建的调试开关），按窗口 ID 截图后退出，再下一个。
set -euo pipefail

APP="${1:?用法: capture-all.sh <Sift.app> <输出目录>}"
OUT="${2:?用法: capture-all.sh <Sift.app> <输出目录>}"
BIN="$APP/Contents/MacOS/Sift"
HELPER="$(cd "$(dirname "$0")" && pwd)/capture-window.swift"
mkdir -p "$OUT"

capture() {
    local name="$1" settle="$2"; shift 2
    echo "== $name (args: $*)"
    "$BIN" "$@" >/dev/null 2>&1 &
    local pid=$!
    local wid=""
    for _ in $(seq 1 40); do
        if wid=$(swift "$HELPER" "$pid" 2>/dev/null); then break; fi
        wid=""
        sleep 0.5
    done
    if [ -z "$wid" ]; then
        echo "!! $name: 20 秒内没等到窗口" >&2
        kill "$pid" 2>/dev/null || true
        return 1
    fi
    sleep "$settle"
    screencapture -x -l "$wid" "$OUT/$name.png"
    echo "   -> $OUT/$name.png"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    sleep 1
}

# 状态清单（调试开关见 App/AppDelegate.swift、App/MailService.swift、App/ReaderModel.swift）
capture 01-main-detail      3 -noSync YES -selectFirstThread YES
capture 02-main-unselected  3 -noSync YES
capture 03-palette          3 -noSync YES -openPalette YES
capture 04-settings-rules   4 -noSync YES -openSettings YES -settingsTab rules
capture 05-settings-general 4 -noSync YES -openSettings YES -settingsTab general
capture 06-toast            5 -noSync YES -demoToast YES

ls -la "$OUT"
