#!/usr/bin/env bash
# Larkspur · Claude Code SessionEnd 钩子：会话结束时，把该会话的飞书同步标记为关闭，
# 避免以后恢复会话时出现「AI 回复照发、飞书消息却没人收」的半开状态。群保留。
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh" 2>/dev/null || exit 0
sid=$(jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0
f=$(state_file "$sid")
[ -f "$f" ] && [ "$(jq -r '.active' "$f")" = "true" ] || exit 0
"$LARKSPUR_HOME/off.sh" "$sid" "会话已结束" >/dev/null 2>&1
exit 0
