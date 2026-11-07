#!/usr/bin/env bash
# 用法：on.sh <session_id> <cwd> [标题]
# 为会话开启飞书同步：已有群则复用，否则由机器人新建独立群（你为群主）。
# 群名为「<前缀> · 项目目录名 · 标题」；没给标题时用开启时间。给了标题且群已存在，会同步改名。
# 成功时 stdout 只输出一行 chat_id。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"
require_open_id

sid="${1:?缺少 session_id}"; cwd="${2:-$PWD}"; title="${3:-}"
f=$(state_file "$sid")
name="$GROUP_PREFIX · $(basename "$cwd") · ${title:-$(date '+%m-%d %H:%M')}"
name="${name:0:60}"

chat_id=""
[ -f "$f" ] && chat_id=$(jq -r '.chat_id // empty' "$f")

if [ -n "$chat_id" ] && [ -n "$title" ]; then
  "$LARK" im +chat-update --as bot --chat-id "$chat_id" --name "$name" >/dev/null 2>&1 \
    && fs_log "renamed sid=$sid chat=$chat_id"
fi

if [ -z "$chat_id" ]; then
  out=$("$LARK" im +chat-create --as bot --name "$name" \
        --description "Claude Code 会话 $sid" \
        --owner "$OPEN_ID" --users "$OPEN_ID" 2>&1)
  chat_id=$(printf '%s' "$out" | jq -r '.data.chat_id // empty' 2>/dev/null)
  if [ -z "$chat_id" ]; then
    fs_log "on-failed sid=$sid"
    echo "建群失败：" >&2; printf '%s\n' "$out" >&2
    exit 1
  fi
  fs_log "group-created sid=$sid chat=$chat_id"
fi

jq -n --arg sid "$sid" --arg chat "$chat_id" --arg cwd "$cwd" --arg t "$(date -Iseconds)" --arg name "$name" \
   '{session_id:$sid, chat_id:$chat, group_name:$name, cwd:$cwd, active:true, enabled_at:$t, last_sent_hash:""}' > "$f"

"$LARK" im +messages-send --as bot --chat-id "$chat_id" \
  --markdown "**飞书同步已开启**
目录：$cwd
会话：\`$sid\`

在这个群里发的消息会转给这个会话，AI 的回复也会发到这里。" >/dev/null 2>&1

fs_log "on sid=$sid chat=$chat_id"
echo "$chat_id"
