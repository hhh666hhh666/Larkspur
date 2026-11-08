# Larkspur 公共配置（被其他脚本 source）
# 个人配置在 $LARKSPUR_HOME/config.sh，由 install.sh 生成。

LARKSPUR_HOME="${LARKSPUR_HOME:-$HOME/.claude/larkspur}"
[ -f "$LARKSPUR_HOME/config.sh" ] && . "$LARKSPUR_HOME/config.sh"

OPEN_ID="${LARKSPUR_OPEN_ID:-}"                       # 唯一被放行的发送者（你自己的 open_id）
LARK="${LARKSPUR_LARK_CLI:-}"
[ -n "$LARK" ] || LARK=$(command -v lark-cli 2>/dev/null || echo "$HOME/.local/bin/lark-cli")
# npm 装的 lark-cli 是个 node 启动壳，只负责拉起同目录 bin/ 下的 Go 程序。直接调用 Go 程序，
# 每个常驻监听能省下一个 node 进程（约 20 MB）。
_lark_real=$(readlink -f "$LARK" 2>/dev/null || echo "$LARK")
case "$_lark_real" in */scripts/run.js)
  [ -x "${_lark_real%/scripts/run.js}/bin/lark-cli" ] && LARK="${_lark_real%/scripts/run.js}/bin/lark-cli" ;; esac
unset _lark_real
STATE_DIR="$LARKSPUR_HOME/sessions"                   # 每个会话一个 <session_id>.json
INBOX="${LARKSPUR_INBOX:-$HOME/files/larkspur-inbox}" # 图片下载目录（须在 lark-cli 允许的根目录内）
IMAGE_WAIT="${LARKSPUR_IMAGE_WAIT:-3}"                # 图片后等待文字合并的秒数
GROUP_PREFIX="${LARKSPUR_GROUP_PREFIX:-Claude}"       # 群名前缀
PROJECTS_ROOT="${LARKSPUR_PROJECTS_ROOT:-$HOME}"      # 总控「新会话 <名字>」时，相对目录的根
SPAWN_MODE="${LARKSPUR_SPAWN_PERMISSION_MODE-bypassPermissions}"  # 总控新建的会话导入后切到的权限模式，留空不切换
LOG="$LARKSPUR_HOME/larkspur.log"                     # 只记事件，不记消息内容
RUN_DIR="$LARKSPUR_HOME/run"                          # 监听进程的 pid、启动时间和已处理消息
ACK_EMOJI="${LARKSPUR_ACK_EMOJI-Get}"                # 收到消息时给它加的表情回复（Get 即「了解」），留空不加
DISPLAY_TZ="${LARKSPUR_DISPLAY_TZ:-Asia/Shanghai}"   # 控制台显示时间用的时区（默认 UTC+8）
ALERTS="${LARKSPUR_ALERTS:-on}"                       # 转发或发回失败时，在总控私聊里提醒
BACKFILL_HOURS="${LARKSPUR_BACKFILL_HOURS:-12}"       # 监听重启时，最多补取多少小时内漏掉的消息
EXPECTED_IP="${LARKSPUR_EXPECTED_IP:-}"                # 三个出口 IP 都应是它；空则不检查（见 ipguard.sh、desktop-gate.sh）
IP_GUARD_CMD="${LARKSPUR_IP_GUARD_CMD:-}"              # 出口 IP 不符时运行的命令（stdin 会收到 "y"）
IP_GUARD="${LARKSPUR_IP_GUARD:-on}"                    # 运行中的 IP 守卫开关（on/off）
DESKTOP_GATE="${LARKSPUR_DESKTOP_GATE:-on}"            # 桌面端启动闸门开关（on/off）
WEB_PORT="${LARKSPUR_WEB_PORT:-random}"                # 本地网页控制台端口（只监听 127.0.0.1）；random：首次随机挑一个高位端口并记下
NET_REFRESH="${LARKSPUR_NET_REFRESH:-60}"              # 总控在跑时，每隔多少秒重新做一次网络检测并刷新控制台，0 关闭
BACKFILL_MAX="${LARKSPUR_BACKFILL_MAX:-20}"           # 一次最多补发几条

mkdir -p "$STATE_DIR" "$INBOX" "$RUN_DIR"

fs_log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
state_file() { printf '%s/%s.json' "$STATE_DIR" "$1"; }
# 会话的同步记录：先按会话 ID 找；找不到、而且查的就是当前会话时，再按桌面端会话 ID 找。
# 桌面端重启或压缩上下文后，同一个桌面端会话可能换了新的会话 ID（CLAUDE_CODE_SESSION_ID），
# 但桌面端会话 ID（CLAUDE_CODE_HOST_SESSION_ID，即 local_…）不变；找到后把记录迁到新的会话 ID 下。
# 总是输出记录文件的路径（可能不存在），调用方自己判断 [ -f ]。
# 例外：会话里再起的 claude（如总控用 claude -p 新建会话）会继承父会话的桌面端会话 ID，
# 它的钩子不能把父会话的记录当成自己的迁走，见 nested_in_session。
resolve_state() {
  local sid="$1" f old h="${CLAUDE_CODE_HOST_SESSION_ID:-}" claim
  f=$(state_file "$sid")
  if [ ! -f "$f" ] && [ -n "$h" ] && [ "$sid" = "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    for old in "$STATE_DIR"/*.json; do
      [ -f "$old" ] && jq -e --arg h "$h" '.desktop_id == $h' "$old" >/dev/null 2>&1 || continue
      if nested_in_session "$sid"; then
        fs_log "state-migrate-skipped old=$(basename "$old" .json) sid=$sid desktop=$h reason=nested"
        break
      fi
      # 先把旧记录原子地挪走再改写：同时触发的几个钩子只有一个能迁成功，不会互相覆盖
      claim="$f.claim.$$"
      mv "$old" "$claim" 2>/dev/null || break
      if jq --arg s "$sid" '.session_id = $s' "$claim" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"; then
        rm -f "$claim"
        fs_log "state-migrated old=$(basename "$old" .json) sid=$sid desktop=$h"
      else
        rm -f "$f.tmp.$$"; mv "$claim" "$old"
      fi
      break
    done
  fi
  printf '%s' "$f"
}
# 当前进程是不是嵌在另一个会话里：找到最近的 claude 祖先进程（即运行本钩子的那个 claude），
# 看它启动时的环境里有没有别的 CLAUDE_CODE_SESSION_ID。桌面端直接拉起的 claude 进程环境里
# 没有这个变量（只有它再拉起的 shell 里才有），而在会话的 shell 里跑的 claude 会继承父会话的。
# 只在有 /proc 的系统上能判断；判断不了时当作不是。
nested_in_session() {
  local me="$1" p="$PPID" v n=0 a0 a1
  [ -d /proc/self ] || return 1
  while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$n" -lt 30 ]; do
    { IFS= read -r -d '' a0; IFS= read -r -d '' a1; } < "/proc/$p/cmdline" 2>/dev/null
    case "${a0##*/} ${a1:-}" in
      "claude "*|node*claude-code*)
        v=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | sed -n 's/^CLAUDE_CODE_SESSION_ID=//p' | head -1)
        [ -n "$v" ] && [ "$v" != "$me" ]
        return ;;
    esac
    a0=""; a1=""
    p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null); n=$((n+1))
  done
  return 1
}
require_open_id() {
  [ -n "$OPEN_ID" ] || { echo "未配置 LARKSPUR_OPEN_ID，请编辑 $LARKSPUR_HOME/config.sh" >&2; exit 1; }
}

# ---- 监听进程：每个群每种监听只留一个实例 ----
# 名字形如 <chat_id>.msg（消息监听）或 <chat_id>.cards（卡片监听）
listener_pid_ok() { [ -n "${1:-}" ] && ps -p "$1" -o args= 2>/dev/null | grep -q 'listen'; }
listener_alive()  { listener_pid_ok "$(cat "$RUN_DIR/$1.pid" 2>/dev/null)"; }
kill_tree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done; kill "$1" 2>/dev/null; }
claim_listener() {   # 顶替同名的旧实例（连同它的 lark-cli 子进程），再登记自己
  local pf="$RUN_DIR/$1.pid" old
  old=$(cat "$pf" 2>/dev/null)
  if [ -n "$old" ] && [ "$old" != "$$" ] && listener_pid_ok "$old"; then
    kill_tree "$old"; fs_log "listener-takeover $1 old=$old new=$$"
  fi
  echo "$$" > "$pf"
  trap "release_listener '$1'" EXIT
}
release_listener() { [ "$(cat "$RUN_DIR/$1.pid" 2>/dev/null)" = "$$" ] && rm -f "$RUN_DIR/$1.pid"; }
# 给 lark-cli event consume 占住 stdin：它读到 EOF 约 2 秒内退出。hold_stdin <本脚本 pid> <秒数> [其他 pid…]
# 在这些进程任何一个退出、或到了秒数时结束，lark-cli 随之退出（卡片、菜单监听还要看着总控的 listen.sh）。所以 consume 不能带 --timeout：带了 --timeout
# lark-cli 就不理会 stdin 的 EOF，监听脚本被杀（桌面端重启）后它会成为孤儿，继续占着事件直到到时。
# 到时结束前留一个标记，is_normal_exit 据此把这次退出当作正常续期。
hold_stdin() {
  local me="$1" secs="${2:-0}" end p
  end=$(( $(date +%s) + secs )); shift 2
  while kill -0 "$me" 2>/dev/null; do
    for p in "$@"; do [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null && return; done
    if [ "$secs" -gt 0 ] && [ "$(date +%s)" -ge "$end" ]; then : > "$RUN_DIR/renew.$me"; return; fi
    sleep "${LARKSPUR_HOLD_POLL:-10}"
  done
}
# lark-cli 的退出行：到时是正常续期（旧写法 reason: timeout，或 hold_stdin 到时留了标记），不必通知 Claude
is_normal_exit() {
  case "$1" in *exited*"reason: timeout"*) return 0 ;; esac
  [ -f "$RUN_DIR/renew.$$" ] && { rm -f "$RUN_DIR/renew.$$"; return 0; }
  return 1
}
# 清掉上一轮监听留下的孤儿 lark-cli：就是 $LARK、同一个事件键、带着本人 open_id 的筛选条件、父进程已不是监听脚本。
# 正常情况下 hold_stdin 会让它们自己退出；这里兜底，免得新监听和孤儿抢同一路事件。
reap_orphan_consumers() {   # <事件键>
  local p pp
  for p in $(pgrep -u "$(id -u)" -f "event consume $1" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    # 必须就是 lark-cli 本身（命令行以「$LARK event consume <键> 」开头，前面最多一个解释器），且筛选条件里有本人 open_id
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | awk -v l="$LARK event consume $1 " -v o="$OPEN_ID" \
      '{ i = index($0, l) } i == 1 || (i > 1 && substr($0, 1, i - 1) !~ / ./) { if (index($0, o)) ok = 1 } END { exit !ok }' || continue
    pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -n "$pp" ] && ps -o args= -p "$pp" 2>/dev/null | grep -q 'listen' && continue
    kill "$p" 2>/dev/null && fs_log "orphan-reaped key=$1 pid=$p"
  done
}
iso_time() { date -d "@$1" -Iseconds 2>/dev/null || date -r "$1" +%Y-%m-%dT%H:%M:%S%z; }

# ---- 路由模式：有活动的总控时，由总控统一监听所有群，并用 send_message 把消息投进各会话 ----
hub_state() {   # 输出活动总控的状态文件路径
  local f; for f in "$STATE_DIR"/*.json; do
    [ -f "$f" ] && jq -e '.role == "hub" and .active == true' "$f" >/dev/null 2>&1 && { echo "$f"; return 0; }
  done; return 1
}
router_active() { hub_state >/dev/null; }
route_target() {   # <chat_id> → 「desktop_id<TAB>群名」，没有对应的活动会话时输出空
  local f; for f in "$STATE_DIR"/*.json; do [ -f "$f" ] || continue
    jq -r --arg c "$1" 'select(.chat_id == $c and .active == true and .role != "hub")
      | [(.desktop_id // ("local_" + .session_id)), (.group_name // "")] | @tsv' "$f" 2>/dev/null
  done | head -1
}
routed_chats() {   # 所有活动的非总控会话的群
  local f; for f in "$STATE_DIR"/*.json; do [ -f "$f" ] || continue
    jq -r 'select(.active == true and .role != "hub") | .chat_id // empty' "$f" 2>/dev/null
  done | sort -u
}

# ---- 常驻服务 larkspurd ----
daemon_alive() {   # 常驻服务是否在运行
  local p; p=$(jq -r '.pid // empty' "$RUN_DIR/daemon.json" 2>/dev/null)
  [ -n "$p" ] && tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'larkspurd'
}

# ---- Claude 桌面端 ----
desktop_state() {   # running（在运行）| starting（启动闸门正在检查出口 IP）| stopped
  local p a st=stopped
  for p in $(pgrep -u "$(id -u)" -x "${LARKSPUR_DESKTOP_COMM:-claude-desktop}" 2>/dev/null); do   # 测试里换成假进程名
    a=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    case "$a" in
      *--type=*) ;;                                   # Electron 的子进程
      */bash\ *|bash\ *|*/sh\ *|sh\ *) st=starting ;;   # 启动闸门（脚本）
      *) echo running; return ;;
    esac
  done
  echo "$st"
}
desktop_gate_last() {   # 启动闸门最近一次的结果（日志原文，没有时为空）
  grep -E ' desktop-gate (pass|refused|off)' "$LOG" 2>/dev/null | tail -n 1
}

# ---- 控制台与提醒 ----
console_refresh() {   # 状态变化时顺手刷新控制台卡片（后台进行；控制台自己触发的不重复刷新）
  [ -n "${LARKSPUR_NO_CONSOLE_REFRESH:-}" ] && return 0
  [ -x "$LARKSPUR_HOME/console.sh" ] && [ -f "$RUN_DIR/console.json" ] || return 0
  ( "$LARKSPUR_HOME/console.sh" refresh >/dev/null 2>&1 & )
}
alert() {   # <chat_id> <去重键> <Markdown 文本>：异常提醒，同一个键 10 分钟内只提醒一次
  [ "$ALERTS" = on ] || return 0
  local f="$RUN_DIR/alert-$2" now; now=$(date +%s)
  [ -f "$f" ] && [ $(( now - $(cat "$f") )) -lt 600 ] && return 0
  echo "$now" > "$f"
  ( "$LARK" im +messages-send --as bot --chat-id "$1" --markdown "$3" >/dev/null 2>&1 & )
  fs_log "alert key=$2"
}
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
