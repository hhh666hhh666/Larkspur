#!/usr/bin/env bash
# 用法：say.sh <chat_id> <Markdown 文本>
# 以机器人身份往指定的群或私聊发一条消息（总控用来在等待桌面端确认前提醒你）。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"
chat="${1:?缺少 chat_id}"; text="${2:?缺少内容}"
"$LARK" im +messages-send --as bot --chat-id "$chat" --markdown "$text" >/dev/null 2>&1 \
  && fs_log "say chat=$chat" || { fs_log "say-failed chat=$chat"; echo "发送失败" >&2; exit 1; }
