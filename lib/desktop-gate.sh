#!/usr/bin/env bash
# Claude 桌面端的启动闸门。安装为 ~/.local/bin/claude-desktop：菜单、面板图标、claude:// 链接（xdg-open）
# 都是按 PATH 找 claude-desktop 的，而 ~/.local/bin 排在最前，所以每次启动桌面端都会先经过这里。
#
# 设了 LARKSPUR_EXPECTED_IP 时：先查三个出口 IP（国内网站、Cloudflare、Claude 看到的，见 exit-ips.sh），
# 三个都查到且都等于它才启动真正的桌面端；有不符的、或有查不到的，就在 LARKSPUR_DESKTOP_GATE_WAIT 秒（默认 30）内每 3 秒重查（开机时代理可能还没起来），
# 期满仍不通过就不启动——桌面端根本不会运行，也就不会联网。拒绝时弹出桌面通知，并尽量在飞书私聊里提醒。
# LARKSPUR_DESKTOP_GATE=off 时不检查（桌面上的「IP 闸门」设置程序可以切换）。
# 桌面端已经在运行时（例如点 claude:// 链接），只是把参数交给它，直接放行；运行中的 IP 变化由 ipguard.sh 负责。
set -u
H="${LARKSPUR_HOME:-$HOME/.claude/larkspur}"
EXPECTED=$( [ -f "$H/config.sh" ] && . "$H/config.sh" >/dev/null 2>&1; printf '%s' "${LARKSPUR_EXPECTED_IP:-}")
GATE=$( [ -f "$H/config.sh" ] && . "$H/config.sh" >/dev/null 2>&1; printf '%s' "${LARKSPUR_DESKTOP_GATE:-on}")
WAIT=$( [ -f "$H/config.sh" ] && . "$H/config.sh" >/dev/null 2>&1; printf '%s' "${LARKSPUR_DESKTOP_GATE_WAIT:-30}")
LOG="$H/larkspur.log"
log() { [ -d "$H" ] && printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# 真正的桌面端：PATH 里排在本脚本之后的 claude-desktop
self=$(readlink -f "$0")
real=""
IFS=: read -ra dirs <<< "$PATH"
for d in "${dirs[@]}"; do
  c="$d/claude-desktop"; [ -x "$c" ] || continue
  [ "$(readlink -f "$c")" = "$self" ] && continue
  real="$c"; break
done
[ -n "$real" ] || real=/usr/lib/claude-desktop/claude-desktop
[ -x "$real" ] || { echo "找不到 Claude 桌面端" >&2; exit 1; }
real_bin=$(readlink -f "$real")

# 已经在运行：放行（这次调用只是把链接交给运行中的实例）
for p in $(pgrep -u "$(id -u)" -x claude-desktop 2>/dev/null); do
  args=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
  case "$args" in *--type=*) ;; "$real_bin"*|claude-desktop*) exec "$real" "$@" ;; esac
done

[ -n "$EXPECTED" ] || exec "$real" "$@"   # 没配置期望 IP：不设闸
[ "$GATE" = off ] && { log "desktop-gate off"; exec "$real" "$@"; }   # 在「IP 闸门」设置程序里关掉了

case "$WAIT" in ''|*[!0-9]*) WAIT=30 ;; esac
[ -x "$H/exit-ips.sh" ] || { echo "缺少 $H/exit-ips.sh，无法检测 IP，不启动" >&2; exit 1; }   # 设了期望 IP 就不放空闸
end=$(( $(date +%s) + WAIT )); got=""
while :; do
  got=$("$H/exit-ips.sh" "$EXPECTED"); rc=$?
  if [ "$rc" = 0 ]; then log "desktop-gate pass ip=$EXPECTED"; exec "$real" "$@"; fi
  [ "$(date +%s)" -lt "$end" ] || break
  sleep 3
done

why=$(printf '%s' "$got" | jq -r --arg e "$EXPECTED" \
  '[{k:"国内出口", v:.cn}, {k:"Cloudflare 出口", v:.cf}, {k:"Claude 出口", v:.claude}]
   | map(if .v == "" then "\(.k)查不到" elif .v != $e then "\(.k) \(.v)" else empty end) | join("，") + "（应为 \($e)）"' 2>/dev/null)
[ -n "$why" ] || why="出口 IP 检测失败（应为 $EXPECTED）"
log "desktop-gate refused $(printf '%s' "$got" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(" ")' 2>/dev/null) expected=$EXPECTED"
command -v notify-send >/dev/null && notify-send -u critical -i dialog-warning "Claude 桌面端未启动" "$why。检查代理后再打开。" 2>/dev/null
echo "Claude 桌面端未启动：$why" >&2
# 尽量在飞书总控私聊里提醒（lark-cli 不经过桌面端；最多等 5 秒）
if [ -f "$H/common.sh" ]; then
  ( . "$H/common.sh" >/dev/null 2>&1
    hf=$(hub_state) && hc=$(jq -r '.chat_id // empty' "$hf") && [ -n "$hc" ] &&
      timeout 5 "$LARK" im +messages-send --as bot --chat-id "$hc" --markdown "**⚠️ 已阻止 Claude 桌面端启动**：$why。" >/dev/null 2>&1 ) || true
fi
exit 1
