#!/usr/bin/env bash
# 用法：guard-kill.sh [--list]
# IP 守卫专用的「结束 Claude」命令（设为 LARKSPUR_IP_GUARD_CMD）：结束命令行里带 claude 的所有进程，
# 关闭浏览器里标题含 Claude 的窗口，但放过 Larkspur 常驻服务自己——服务本身，以及它运行的 Larkspur 脚本
# （飞书监听、网络检测等）。守卫动手后网页控制台照常能打开，可以直接在里面改期望 IP，飞书提醒也照常。
# 服务启动的桌面端、闸门、curl 等不是 Larkspur 脚本的进程照样结束。
# 和桌面上手动用的「结束Claude进程」互不相干：那个照旧连 Larkspur 一起结束。
# 不提问、不等回车（守卫在后台运行它）。
#   --list  只列出会结束的进程和窗口，不动手
# 退出码：0 都已结束（或本来就没有），1 还有没结束的
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"
ONLY="${LARKSPUR_GUARD_ONLY:-}"   # 测试用：只看命令行里含这段文字的进程，并且不碰浏览器窗口
BROWSER_RE='Firefox|Chrome|Chromium|Brave|Microsoft Edge|Vivaldi|Opera'
me=$(basename "$0")

# 自己、守卫外壳和它们的子 shell 靠命令行里有本脚本的名字认出来（见 procs）；不按祖先认，
# 免得会话启动钩子里触发守卫时，把还没退出的那个 Claude 进程也当成祖先放过
keep=" "
dp=$(jq -r '.pid // empty' "$RUN_DIR/daemon.json" 2>/dev/null)
if [ -n "$dp" ] && daemon_alive; then
  keep+="$dp "
  walk() {   # 只沿着 Larkspur 脚本（和它们起的 lark-cli）往下找：别的进程（桌面端、闸门、curl）和它们的子孙都不放过
    local c a
    for c in $(pgrep -P "$1" 2>/dev/null); do
      a=$(tr '\0' ' ' < "/proc/$c/cmdline" 2>/dev/null)
      case "$a" in *"$LARKSPUR_HOME/"*.sh*|*lark-cli\ *) keep+="$c "; walk "$c" ;; esac   # 监听脚本的子 shell 挂在 lark-cli 底下
    done
  }
  walk "$dp"
fi

procs() {
  ps -u "$(id -u)" -o pid=,stat=,args= | while read -r pid st args; do
    case "$st" in Z*) continue ;; esac   # 已经结束、只等父进程回收的
    case "${args,,}" in *claude*) ;; *) continue ;; esac
    case "$keep" in *" $pid "*) continue ;; esac
    case "$args" in *"$me"*) continue ;; esac   # 自己、守卫外壳、子 shell
    [ -n "$ONLY" ] && case "$args" in *"$ONLY"*) ;; *) continue ;; esac
    kill -0 "$pid" 2>/dev/null && printf '%s %s\n' "$pid" "$args"
  done
}
wins() {
  [ -z "$ONLY" ] && command -v wmctrl >/dev/null || return 0
  wmctrl -l 2>/dev/null | awk -v re="$BROWSER_RE" '{ id=$1; $1=$2=$3=""; sub(/^ +/,""); if ($0 ~ /[Cc]laude/ && $0 ~ re) print id "\t" $0 }'
}

P=$(procs); W=$(wins)
if [ "${1:-}" = --list ]; then
  [ -n "$P" ] && { echo "【进程】"; printf '%s\n' "$P" | cut -c1-160; }
  [ -n "$W" ] && { echo "【浏览器窗口】"; printf '%s\n' "$W"; }
  exit 0
fi
np=$(printf '%s' "$P" | grep -c .); nw=$(printf '%s' "$W" | grep -c .)
echo "$(date '+%F %T') 守卫结束 Claude：进程 $np 个，浏览器窗口 $nw 个（放过 Larkspur 服务的 $(echo $keep | wc -w) 个进程）"
[ -n "$P" ] && printf '%s\n' "$P" | cut -c1-160
[ -n "$W" ] && printf '%s\n' "$W" | while IFS=$'\t' read -r id _; do wmctrl -ic "$id"; done
[ -n "$P" ] && kill $(printf '%s\n' "$P" | awk '{print $1}') 2>/dev/null
for _ in 1 2 3 4 5 6; do [ -n "$(procs)" ] || break; sleep 0.5; done
L=$(procs)
[ -n "$L" ] && { kill -9 $(printf '%s\n' "$L" | awk '{print $1}') 2>/dev/null; sleep 1; L=$(procs); }
fs_log "guard-kill procs=$np windows=$nw left=$(printf '%s' "$L" | grep -c .)"
[ -z "$L" ] || { echo "没结束的："; printf '%s\n' "$L" | cut -c1-160; exit 1; }
echo "已全部结束"
