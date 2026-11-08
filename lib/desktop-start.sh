#!/usr/bin/env bash
# 用法：desktop-start.sh [来源]
# 手动启动 Claude 桌面端（本地网页控制台、飞书控制台卡片上的「启动桌面端」按钮用它）。
# Larkspur 从不自动启动或重启桌面端，桌面端只在主人点按钮（或自己打开）时启动。
#   - 一律经过启动闸门（~/.local/bin/claude-desktop）：出口 IP 不符就不启动；
#   - 放进单独的 systemd scope，和从桌面图标打开时一样，不属于 Larkspur 服务，关掉 Larkspur 不会连带关掉桌面端。
# 退出码：0 已发出启动（闸门检查完才真正启动），3 桌面端已在运行或正在启动，1 找不到桌面端。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"

case "$(desktop_state)" in
  running)  echo "Claude 桌面端已在运行"; exit 3 ;;
  starting) echo "Claude 桌面端正在启动（检查出口 IP 中）"; exit 3 ;;
esac
launcher="${LARKSPUR_DESKTOP_LAUNCHER:-}"   # 测试用
if [ -z "$launcher" ]; then
  launcher="$HOME/.local/bin/claude-desktop"
  grep -q 'Claude 桌面端的启动闸门' "$launcher" 2>/dev/null || launcher=$(command -v claude-desktop 2>/dev/null)
fi
[ -n "$launcher" ] && [ -x "$launcher" ] || { echo "找不到 Claude 桌面端" >&2; exit 1; }

fs_log "desktop-start source=${1:-cli}"
if [ -z "${LARKSPUR_NO_SYSTEMD:-}" ] && command -v systemd-run >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
  setsid -f systemd-run --user --scope --collect --quiet --unit="app-com.anthropic.Claude-larkspur-$(date +%s)" \
    -- "$launcher" </dev/null >/dev/null 2>&1
else
  setsid -f "$launcher" </dev/null >/dev/null 2>&1
fi
echo "正在启动 Claude 桌面端（先检查出口 IP，通过后才启动）"
