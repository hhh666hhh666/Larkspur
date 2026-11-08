#!/usr/bin/env bash
# Larkspur · Claude Code SessionStart 钩子（asyncRewake：在后台运行，退出码 2 时唤醒 Claude 处理 stderr 里的话）。
# 桌面端启动时会自动拉起之前打开的会话，每个会话启动都会触发它：
#   1. IP 守卫：现查 Claude 出口 IP，不是 LARKSPUR_EXPECTED_IP 就运行守卫命令（见 ipguard.sh）；
#   2. 自动恢复总控：这个会话就是总控时，直接在本钩子里等飞书事件（listen-wait.sh），有事件才唤醒它，
#      没有事件就不调用模型；飞书监听本身由常驻服务 larkspurd 负责，不随桌面端重启。
#   3. 总控会话没被桌面端拉起时的后备：等 30 秒（LARKSPUR_HUB_RELAY_DELAY）仍没有总控监听，就唤醒一个开着同步的会话，请它给总控发消息，
#      桌面端会因此拉起总控（5 分钟内只唤醒一个会话）。
# 任何异常都静默退出，不打扰会话。
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh" 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0
H="${LARKSPUR_HOME:-$HOME/.claude/larkspur}"

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
"$H/ipguard.sh" >/dev/null 2>&1; [ $? -eq 3 ] && exit 0   # 守卫已动手，Claude 马上会被结束

[ "${LARKSPUR_HUB_AUTOSTART:-on}" = on ] || exit 0
[ -n "$sid" ] || exit 0
nested_in_session "$sid" && exit 0               # 会话里再起的 claude（如 spawn.sh 的 claude -p）不管
hf=$(hub_state) || exit 0                        # 没有总控记录：主人没开过总控，不自动开
hchat=$(jq -r '.chat_id // empty' "$hf"); [ -n "$hchat" ] || exit 0
hsid=$(jq -r '.session_id' "$hf"); hdesk=$(jq -r '.desktop_id // ("local_" + .session_id)' "$hf")
host="${CLAUDE_CODE_HOST_SESSION_ID:-}"

if [ "$sid" = "$hsid" ] || { [ -n "$host" ] && [ "$host" = "$hdesk" ]; }; then
  fs_log "hub-autostart sid=$sid desktop=$host"
  exec "$H/listen-wait.sh" "$sid" "$hdesk"   # 中断期间排队的事件会立刻交给总控
fi

# 后备：只由开着同步的普通会话来做
f=$(state_file "$sid")
[ -f "$f" ] && [ "$(jq -r '.active' "$f")" = true ] || exit 0
sleep "${LARKSPUR_HUB_RELAY_DELAY:-30}"
hub_reader_ok && exit 0
nag="$RUN_DIR/hub-nag"
[ -f "$nag" ] && [ $(( $(date +%s) - $(cat "$nag") )) -lt 300 ] && exit 0
date +%s > "$nag"
fs_log "hub-autostart-relay sid=$sid hub=$hdesk"
echo "【Larkspur】Claude 桌面端刚启动，飞书总控还没有起来。请用 mcp__ccd_session_mgmt__send_message（未加载时先用 ToolSearch 加载）向 \`$hdesk\` 发送：「【Larkspur】总控的飞书监听已停止，请重新启动。」发送后不要输出任何文字，直接结束本回合。" >&2
exit 2
