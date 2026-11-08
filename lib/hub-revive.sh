#!/usr/bin/env bash
# 用法：hub-revive.sh [来源]
# 把停着的总控拉起来：飞书事件排在队列里、而总控没在接收（hub_reader_state 为 stopped，常见于桌面端重启后
# 总控会话没被自动打开）时，常驻服务调用它。做法是打开 claude://claude.ai/epitaxy/<总控的桌面端会话 ID>：
# 桌面端会启动这个会话的 Claude 进程，总控的 SessionStart 钩子随即开始等事件、把排队的事件交给总控，
# 不需要先调用模型。桌面端的窗口会切到总控会话。
#   - 桌面端没在运行时不做：链接会把桌面端启动起来，而桌面端只能手动启动；
#   - 总控的 Claude 进程已经在跑（只是没在等事件）时，链接拉不起它，只记日志；
#   - 每 LARKSPUR_REVIVE_INTERVAL 秒（默认 120）最多试一次，不论成败。
# 退出码：0 已打开链接，1 不需要（没有总控、总控在接收、队列是空的），2 做不到（见日志），3 刚试过
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"

hf=$(hub_state) || exit 1
[ "$(hub_reader_state)" = stopped ] || exit 1
[ -s "$RUN_DIR/hub-queue" ] || exit 1
stamp="$RUN_DIR/hub-revive"
last=$(cat "$stamp" 2>/dev/null || echo 0)
[ $(( $(date +%s) - ${last:-0} )) -ge "${LARKSPUR_REVIVE_INTERVAL:-120}" ] || exit 3
date +%s > "$stamp"

hdesk=$(jq -r '.desktop_id // empty' "$hf")
case "$hdesk" in local_*) ;; *) fs_log "hub-revive-skipped reason=no-desktop-id"; exit 2 ;; esac
if [ "$(desktop_state)" != running ]; then
  fs_log "hub-revive-skipped reason=desktop-not-running"; exit 2
fi
if p=$(hub_process "$hdesk"); then
  fs_log "hub-revive-skipped reason=process-running pid=$p"; exit 2
fi

# 直接把链接交给桌面端程序（它会转给正在运行的那个实例）。xdg-open 在 systemd 服务的环境里不可靠：
# 返回成功，桌面端却收不到链接。桌面端已在运行，启动闸门会直接放行
opener="${LARKSPUR_OPENER:-}"   # 测试用
if [ -z "$opener" ]; then
  opener="$HOME/.local/bin/claude-desktop"
  grep -q 'Claude 桌面端的启动闸门' "$opener" 2>/dev/null || opener=$(command -v claude-desktop 2>/dev/null)
fi
[ -n "$opener" ] && [ -x "$opener" ] || { fs_log "hub-revive-skipped reason=no-desktop-binary"; exit 2; }
fs_log "hub-revive source=${1:-cli} desktop=$hdesk"
# 打开链接的进程不带 Larkspur 服务的环境（同 desktop-start.sh）
for v in $(compgen -e); do
  case "$v" in LARKSPUR_*|INVOCATION_ID|JOURNAL_STREAM|SYSTEMD_EXEC_PID|MEMORY_PRESSURE_WATCH|MEMORY_PRESSURE_WRITE|MANAGERPID) unset "$v" ;; esac
done
setsid -f "$opener" "claude://claude.ai/epitaxy/$hdesk" </dev/null >/dev/null 2>&1
