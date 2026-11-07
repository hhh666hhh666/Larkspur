# Larkspur 公共配置（被其他脚本 source）
# 个人配置在 $LARKSPUR_HOME/config.sh，由 install.sh 生成。

LARKSPUR_HOME="${LARKSPUR_HOME:-$HOME/.claude/larkspur}"
[ -f "$LARKSPUR_HOME/config.sh" ] && . "$LARKSPUR_HOME/config.sh"

OPEN_ID="${LARKSPUR_OPEN_ID:-}"                       # 唯一被放行的发送者（你自己的 open_id）
LARK="${LARKSPUR_LARK_CLI:-}"
[ -n "$LARK" ] || LARK=$(command -v lark-cli 2>/dev/null || echo "$HOME/.local/bin/lark-cli")
STATE_DIR="$LARKSPUR_HOME/sessions"                   # 每个会话一个 <session_id>.json
INBOX="${LARKSPUR_INBOX:-$HOME/files/larkspur-inbox}" # 图片下载目录（须在 lark-cli 允许的根目录内）
IMAGE_WAIT="${LARKSPUR_IMAGE_WAIT:-3}"                # 图片后等待文字合并的秒数
GROUP_PREFIX="${LARKSPUR_GROUP_PREFIX:-Claude}"       # 群名前缀
PROJECTS_ROOT="${LARKSPUR_PROJECTS_ROOT:-$HOME}"      # 总控「新会话 <名字>」时，相对目录的根
SPAWN_MODE="${LARKSPUR_SPAWN_PERMISSION_MODE-bypassPermissions}"  # 总控新建的会话导入后切到的权限模式，留空不切换
LOG="$LARKSPUR_HOME/larkspur.log"                     # 只记事件，不记消息内容
RUN_DIR="$LARKSPUR_HOME/run"                          # 监听进程的 pid、启动时间和已处理消息
BACKFILL_HOURS="${LARKSPUR_BACKFILL_HOURS:-12}"       # 监听重启时，最多补取多少小时内漏掉的消息
BACKFILL_MAX="${LARKSPUR_BACKFILL_MAX:-20}"           # 一次最多补发几条

mkdir -p "$STATE_DIR" "$INBOX" "$RUN_DIR"

fs_log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
state_file() { printf '%s/%s.json' "$STATE_DIR" "$1"; }
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
iso_time() { date -d "@$1" -Iseconds 2>/dev/null || date -r "$1" +%Y-%m-%dT%H:%M:%S%z; }
