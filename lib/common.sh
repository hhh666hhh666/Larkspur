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
LOG="$LARKSPUR_HOME/larkspur.log"                     # 只记事件，不记消息内容

mkdir -p "$STATE_DIR" "$INBOX"

fs_log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
state_file() { printf '%s/%s.json' "$STATE_DIR" "$1"; }
require_open_id() {
  [ -n "$OPEN_ID" ] || { echo "未配置 LARKSPUR_OPEN_ID，请编辑 $LARKSPUR_HOME/config.sh" >&2; exit 1; }
}
