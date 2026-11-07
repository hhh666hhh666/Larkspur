#!/usr/bin/env bash
# Larkspur · Claude Code Stop 钩子（同步）：开着飞书同步的会话，每回合结束时检查监听是否还活着。
# 进程重启、上下文压缩都会让 Monitor 随旧进程一起消失，而会话本身并不知道。
# 发现监听已停止时，用 decision:block 让 Claude 接着把监听重新启动，然后安静结束本回合。
# 只拦一次（stop_hook_active 为 true 时放行），不会死循环；任何异常都静默放行。

. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh" 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false')" = "true" ] && exit 0
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
[ -n "$sid" ] || exit 0
f=$(state_file "$sid")
[ -f "$f" ] && [ "$(jq -r '.active' "$f")" = "true" ] || exit 0
chat=$(jq -r '.chat_id // empty' "$f"); [ -n "$chat" ] || exit 0
role=$(jq -r '.role // ""' "$f")

missing() {   # 列出缺少的监听；刚启动的 Monitor 可能还没登记，给它几秒
  local try out
  for try in 1 2 3 4; do
    out=""
    listener_alive "$chat.msg" || out="$out msg"
    [ "$role" = "hub" ] && { listener_alive "$chat.cards" || out="$out cards"; }
    [ -z "$out" ] && return 0
    [ "$try" -lt 4 ] && sleep 1
  done
  printf '%s' "$out"
}
need=$(missing)
[ -n "$need" ] || exit 0

H="${LARKSPUR_HOME:-$HOME/.claude/larkspur}"
if [ "$role" = "hub" ]; then
  steps="command \`$H/listen.sh $chat --with-cards\`，description \`飞书私聊（总控）\`，timeout_ms \`1800000\`"
else
  steps="command \`$H/listen.sh $chat\`，description \`飞书群消息（本会话）\`，timeout_ms \`1800000\`"
fi

fs_log "listener-missing sid=$sid chat=$chat need=$need"
reason="【Larkspur】本会话开着飞书同步，但飞书监听已经停止（通常是进程重启或上下文压缩造成的）。请现在用 Monitor 重新启动：$steps。
新监听会自动顶替同名的旧监听，并补发中断期间漏掉的飞书消息。启动后不要输出任何文字，直接结束本回合。"
jq -cn --arg r "$reason" '{decision:"block", reason:$r}'
exit 0
