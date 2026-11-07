#!/usr/bin/env bash
# 用法：hub-on.sh <session_id>
# 把当前会话设为「总控」：同步对象是你和机器人的私聊（不另建群）。
# 成功时 stdout 只输出一行私聊的 chat_id。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"
require_open_id

sid="${1:?缺少 session_id}"
f=$(state_file "$sid")

out=$("$LARK" im +messages-send --as bot --user-id "$OPEN_ID" --markdown "**Larkspur 总控已开启**

在这里发：
- \`新会话 <目录> [标题]\`：在该目录新建一个 Claude Code 会话，它会有自己的飞书群，并出现在桌面端
- 其他内容：直接和总控对话

目录可写绝对路径，或 \`$PROJECTS_ROOT\` 下的名字。" 2>&1)
chat=$(printf '%s' "$out" | jq -r '.data.chat_id // empty' 2>/dev/null)
[ -n "$chat" ] || { echo "获取私聊失败：" >&2; printf '%s\n' "$out" >&2; exit 1; }

jq -n --arg sid "$sid" --arg chat "$chat" --arg cwd "$PWD" --arg t "$(date -Iseconds)" \
   '{session_id:$sid, chat_id:$chat, cwd:$cwd, active:true, role:"hub", enabled_at:$t, last_sent_hash:""}' > "$f"
fs_log "hub-on sid=$sid chat=$chat"
echo "$chat"
