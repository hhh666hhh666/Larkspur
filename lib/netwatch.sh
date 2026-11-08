#!/usr/bin/env bash
# 用法：netwatch.sh <父进程 pid>
# 总控用：由 listen.sh --hub 在后台拉起，父进程退出就跟着退出。
# 每隔 LARKSPUR_NET_REFRESH 秒（默认 60，0 关闭）重新做一次网络检测，并原地刷新控制台卡片。
# 控制台卡片还没发过时只检测、不发卡片。每次刷新后接着跑 IP 守卫（ipguard.sh --cached）。间隔从上一轮开始时算，检测和刷新的耗时不额外累加。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"

parent="${1:?缺少父进程 pid}"
cfg_m=$(file_mtime "$LARKSPUR_HOME/config.sh")
while kill -0 "$parent" 2>/dev/null; do
  m=$(file_mtime "$LARKSPUR_HOME/config.sh")   # 改了间隔不用重启
  [ "$m" = "$cfg_m" ] || { cfg_m=$m; . "$LARKSPUR_HOME/common.sh"; }
  case "$NET_REFRESH" in ''|*[!0-9]*|0) sleep 30; continue ;; esac
  start=$(date +%s)
  "$LARKSPUR_HOME/netcheck.sh" >/dev/null 2>&1 && "$LARKSPUR_HOME/console.sh" refresh >/dev/null 2>&1
  "$LARKSPUR_HOME/ipguard.sh" --cached >/dev/null 2>&1
  left=$(( NET_REFRESH - ($(date +%s) - start) )); [ "$left" -ge 5 ] || left=5
  # 分段睡，父进程退出后最多 5 秒内跟着退出
  while [ "$left" -gt 0 ] && kill -0 "$parent" 2>/dev/null; do s=$(( left < 5 ? left : 5 )); sleep "$s"; left=$((left - s)); done
done
