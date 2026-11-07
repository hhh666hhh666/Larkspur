#!/usr/bin/env bash
# Larkspur · Claude Code SessionEnd 钩子。
# 进程退出（桌面端重启、上下文压缩、关窗口）不等于主人不想同步了，所以默认**保留**同步：
# 下次这个会话有回合结束时，ensure-listener.sh 会让 Claude 把监听重新启动，并补发漏掉的消息。
# 只有 /clear（换成新会话）和登出时才把同步标记为关闭。群始终保留。
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh" 2>/dev/null || exit 0
input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
reason=$(printf '%s' "$input" | jq -r '.reason // "other"' 2>/dev/null)
[ -n "$sid" ] || exit 0
f=$(resolve_state "$sid")
[ -f "$f" ] && [ "$(jq -r '.active' "$f")" = "true" ] || exit 0
case "$reason" in
  clear|logout) "$LARKSPUR_HOME/off.sh" "$sid" "会话已结束" >/dev/null 2>&1 ;;
  *) fs_log "session-end-kept sid=$sid reason=$reason" ;;
esac
exit 0
