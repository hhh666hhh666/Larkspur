#!/usr/bin/env bash
# Larkspur · Claude Code Stop 钩子（asyncRewake：在后台运行，退出码 2 时唤醒 Claude 处理 stderr 里的话）。
# 总控按需唤醒：总控会话每个回合结束时，在后台起一个等待进程（listen-wait.sh），有飞书事件才唤醒总控；
# 空闲时不调用模型，也不需要 Monitor 续期。不是总控的会话直接退出。任何异常都静默退出。
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh" 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
[ -n "$sid" ] || exit 0
nested_in_session "$sid" && exit 0
hf=$(hub_state) || exit 0
hsid=$(jq -r '.session_id' "$hf"); hdesk=$(jq -r '.desktop_id // ("local_" + .session_id)' "$hf")
host="${CLAUDE_CODE_HOST_SESSION_ID:-}"
[ "$sid" = "$hsid" ] || { [ -n "$host" ] && [ "$host" = "$hdesk" ]; } || exit 0
exec "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/listen-wait.sh" "$sid" "$hdesk"
