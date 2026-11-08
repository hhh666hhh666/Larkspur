#!/usr/bin/env bash
# 用法：larkspurctl.sh start | stop | restart | status | open
#   start    启动常驻服务 larkspurd（装了 systemd 用户服务就用它，否则直接在后台运行）
#   stop     关闭（和网页控制台上的「关闭 Larkspur」一样）
#   status   输出运行状态和网页控制台地址
#   open     先启动（已在运行就跳过），再用浏览器打开网页控制台——桌面上的「Larkspur」图标就是它
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"

UNIT=larkspur.service
has_unit() { [ -z "${LARKSPUR_NO_SYSTEMD:-}" ] && command -v systemctl >/dev/null && systemctl --user cat "$UNIT" >/dev/null 2>&1; }   # 测试里设 LARKSPUR_NO_SYSTEMD=1，不碰真的服务
port() { jq -r '.port // empty' "$RUN_DIR/daemon.json" 2>/dev/null; }
url() { local p; p=$(port); [ -n "$p" ] && echo "http://localhost:$p/"; }

start() {
  daemon_alive && return 0
  if has_unit; then
    # 让服务能用桌面（守卫命令可能要关浏览器窗口、弹通知）
    systemctl --user import-environment DISPLAY XAUTHORITY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS 2>/dev/null
    systemctl --user start "$UNIT" || return 1
  else
    setsid nohup python3 "$LARKSPUR_HOME/larkspurd.py" >> "$RUN_DIR/daemon.out" 2>&1 < /dev/null &
  fi
  for _ in $(seq 1 50); do daemon_alive && [ -n "$(port)" ] && return 0; sleep 0.1; done
  echo "Larkspur 没能启动，见 $LOG" >&2; return 1
}

stop() {
  if has_unit && systemctl --user is-active --quiet "$UNIT"; then systemctl --user stop "$UNIT"; return; fi
  local p; p=$(jq -r '.pid // empty' "$RUN_DIR/daemon.json" 2>/dev/null)
  [ -n "$p" ] || return 0
  kill "$p" 2>/dev/null
  for _ in $(seq 1 100); do kill -0 "$p" 2>/dev/null || return 0; sleep 0.1; done   # 等进程真正退出（端口、锁都释放）
}

case "${1:-status}" in
  start)   start && echo "Larkspur 已运行：$(url)" ;;
  stop)    stop; echo "Larkspur 已关闭" ;;
  restart) stop; start && echo "Larkspur 已运行：$(url)" ;;
  status)  if daemon_alive; then echo "运行中：$(url)$(jq -r 'if .note != "" then "（" + .note + "）" else "" end' "$RUN_DIR/daemon.json" 2>/dev/null)"
           else echo "没在运行"; exit 3; fi ;;
  open)    if start; then
             u=$(url); { command -v xdg-open >/dev/null && xdg-open "$u"; } >/dev/null 2>&1 || echo "$u"
           else
             command -v notify-send >/dev/null && notify-send -u critical "Larkspur 没能启动" "详情见 $LOG"
             exit 1
           fi ;;
  *) echo "用法：larkspurctl.sh start|stop|restart|status|open" >&2; exit 1 ;;
esac
