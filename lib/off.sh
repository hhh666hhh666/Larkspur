#!/usr/bin/env bash
# 用法：off.sh <session_id> [原因]
# 关闭会话的飞书同步：标记为非活动（保留群与对照记录，以便再次开启时复用同一个群）。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"

sid="${1:?缺少 session_id}"; reason="${2:-已手动关闭}"
f=$(resolve_state "$sid")
[ -f "$f" ] || { echo "该会话未开启过飞书同步"; exit 0; }

chat_id=$(jq -r '.chat_id' "$f")
was_active=$(jq -r '.active' "$f")
tmp=$(mktemp) && jq '.active=false' "$f" > "$tmp" && mv "$tmp" "$f"

if [ "$was_active" = "true" ]; then
  "$LARK" im +messages-send --as bot --chat-id "$chat_id" \
    --text "飞书同步已关闭（$reason）。群会保留，之后在该会话里再开启会继续用这个群。" >/dev/null 2>&1
fi
fs_log "off sid=$sid chat=$chat_id reason=$reason"
console_refresh
echo "已关闭：$chat_id"
