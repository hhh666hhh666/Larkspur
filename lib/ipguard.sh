#!/usr/bin/env bash
# 用法：ipguard.sh [--cached]
# IP 守卫：三个出口 IP（国内网站、Cloudflare、Claude 看到的，见 exit-ips.sh）里任何一个不是 LARKSPUR_EXPECTED_IP 时，
# 运行 LARKSPUR_IP_GUARD_CMD（例如结束所有 Claude 进程的脚本）。
#   --cached  先看上一次网络检测的结果（面板刷新后用，不多发请求）；都相符就结束，有不符的再现查确认
#   不带参数  直接现查（会话启动时用）
# 只在「查到的 IP 与期望不同」时动手，而且要连续两次现查（间隔 2 秒）都不符；查不到（断网、超时）不算不符。
# 没设 LARKSPUR_EXPECTED_IP、或 LARKSPUR_IP_GUARD=off 时什么都不做。
# 守卫命令放在新的会话组里运行（setsid），不会随调用它的 Claude 进程一起被结束；它的 stdin 收到 "y"，
# 用来回答交互式脚本的确认提问。动手前先在总控私聊里发一条提醒（最多等 5 秒）。
# 退出码：0 相符或无法判断，3 不符并已运行守卫命令（或 60 秒内已运行过），4 不符但没有配置守卫命令。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"

[ -n "$EXPECTED_IP" ] && [ "$IP_GUARD" != off ] || exit 0
check() { "$LARKSPUR_HOME/exit-ips.sh" "$EXPECTED_IP"; }   # 输出 JSON；退出码 1 = 确定不符

if [ "${1:-}" = --cached ]; then
  "$LARKSPUR_HOME/netcheck.sh" --cached | jq -e --arg e "$EXPECTED_IP" \
    '[.cn.ip?, .cloudflare.ip?, .claude.ip?] | map(select(. != null and . != "")) | all(. == $e)' >/dev/null 2>&1 && exit 0
fi
got=$(check); [ $? -eq 1 ] || exit 0
sleep 2
got=$(check); [ $? -eq 1 ] || exit 0              # 连续两次都不符，排除切换线路时的瞬时结果
bad=$(printf '%s' "$got" | jq -r --arg e "$EXPECTED_IP" \
  '[{k:"国内出口", v:.cn}, {k:"Cloudflare 出口", v:.cf}, {k:"Claude 出口", v:.claude}]
   | map(select(.v != "" and .v != $e) | "\(.k) \(.v)") | join("，")')

lock="$RUN_DIR/ipguard.fired"                     # 多个调用方同时发现时只动手一次
if [ -f "$lock" ] && [ $(( $(date +%s) - $(cat "$lock") )) -lt 60 ]; then exit 3; fi
date +%s > "$lock"
fs_log "ipguard-mismatch $(printf '%s' "$got" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(" ")') expected=$EXPECTED_IP cmd=${IP_GUARD_CMD:-none}"

if hf=$(hub_state); then
  hc=$(jq -r '.chat_id // empty' "$hf")
  [ -n "$hc" ] && timeout 5 "$LARK" im +messages-send --as bot --chat-id "$hc" --markdown \
    "**⚠️ 出口 IP 异常**：$bad，应为 \`$EXPECTED_IP\`。$( [ -n "$IP_GUARD_CMD" ] && echo '正在结束所有 Claude 进程。' || echo '没有配置守卫命令，未做处理。')" >/dev/null 2>&1
fi
[ -n "$IP_GUARD_CMD" ] || exit 4
setsid bash -c 'printf "y\n\n" | "$1" >> "$2" 2>&1' _ "$IP_GUARD_CMD" "$RUN_DIR/ipguard.out" </dev/null >/dev/null 2>&1 &
exit 3
