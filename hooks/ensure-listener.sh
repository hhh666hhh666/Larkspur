#!/usr/bin/env bash
# Larkspur · Claude Code Stop 钩子（同步）：开着飞书同步的会话，每回合结束时检查监听是否还活着。
# 进程重启、上下文压缩都会让 Monitor 随旧进程一起消失，而会话本身并不知道。
# 飞书监听由常驻服务 larkspurd 负责，总控只挂一个读事件队列的 Monitor（listen-inbox.sh）：它停了就用
# decision:block 让总控重启；普通会话发现总控没在读，就提醒总控；Larkspur 没在运行时只在群里提醒；
# 没有总控时，只在群里提醒主人开总控，不允许普通会话自己监听。
# 只拦一次（stop_hook_active 为 true 时放行），不会死循环；任何异常都静默放行。

. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh" 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false')" = "true" ] && exit 0
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
[ -n "$sid" ] || exit 0
f=$(resolve_state "$sid")
[ -f "$f" ] && [ "$(jq -r '.active' "$f")" = "true" ] || exit 0
chat=$(jq -r '.chat_id // empty' "$f"); [ -n "$chat" ] || exit 0
role=$(jq -r '.role // ""' "$f")

reader_missing() {   # 总控会话的队列读取（listen-inbox.sh）是否没在跑；刚启动的 Monitor 可能还没登记，给它几秒
  local try
  for try in 1 2 3 4; do listener_alive inbox && return 1; [ "$try" -lt 4 ] && sleep 1; done
  return 0
}
H="${LARKSPUR_HOME:-$HOME/.claude/larkspur}"
block() { jq -cn --arg r "$1" '{decision:"block", reason:$r}'; exit 0; }

if [ "$role" = "hub" ]; then
  reader_missing || exit 0
  fs_log "listener-missing sid=$sid chat=$chat need=inbox"
  block "【Larkspur】本会话是飞书总控，但读取飞书事件的 Monitor 已经停止（通常是进程重启或上下文压缩造成的）。请现在用 Monitor 重新启动：command \`$H/listen-inbox.sh\`，description \`飞书私聊（总控）\`，timeout_ms \`1800000\`。
飞书监听由常驻服务 Larkspur 负责，停掉这段时间的事件都排在队列里，重新启动后会一次补上。启动后不要输出任何文字，直接结束本回合。"
fi

if hf=$(hub_state); then
  # 路由模式：本会话的飞书消息由 Larkspur 收下、总控转发
  if ! daemon_alive; then   # 主人在网页控制台关掉了 Larkspur，或者还没打开：只在群里提醒，不唤醒谁
    fs_log "daemon-down sid=$sid chat=$chat"
    alert "$chat" "daemon-down" "**Larkspur 没在运行**，在这个群里发的消息暂时送不进 Claude 会话（AI 的回复照常会发过来）。在电脑桌面点「Larkspur」打开它即可，打开后会补发中断期间的消息。"
    exit 0
  fi
  hdesk=$(jq -r '.desktop_id // ("local_" + .session_id)' "$hf")
  reader_missing || exit 0
  nag="$RUN_DIR/hub-nag"   # 多个会话同时发现时，5 分钟内只提醒一次
  [ -f "$nag" ] && [ $(( $(date +%s) - $(cat "$nag") )) -lt 300 ] && exit 0
  date +%s > "$nag"
  fs_log "hub-listener-missing sid=$sid hub=$hdesk need=inbox"
  block "【Larkspur】飞书总控没有在读取飞书事件，各会话暂时收不到飞书消息。请用 mcp__ccd_session_mgmt__send_message（未加载时先用 ToolSearch 加载）向 \`$hdesk\` 发送：「【Larkspur】总控的飞书监听已停止，请重新启动。」发送后不要输出任何文字，直接结束本回合。"
fi

# 没有总控：不允许本会话自己监听，也不让 Claude 启动监听。直接在本会话的群里提醒（脚本发，不唤醒 Claude）。
fs_log "no-hub sid=$sid chat=$chat"
alert "$chat" "no-hub-$chat" "**现在没有飞书总控**，你在这个群里发的消息暂时送不进 Claude 会话（AI 的回复照常会发过来）。请在一个常开的会话里执行 \`/feishu hub\`，总控开启后会自动补发中断期间的消息。"
exit 0
