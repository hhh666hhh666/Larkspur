#!/usr/bin/env bash
# 用法：spawn.sh <目录> [标题]
# 由总控会话调用：在 <目录> 里后台新建一个 Claude Code 会话，为它建专属飞书群，
# 然后导入 Claude 桌面端（会出现在侧边栏，并抢走窗口焦点）。
# 目录可以是绝对路径，或 $PROJECTS_ROOT 下的名字。
# 输出一行 JSON：{ok, session_id, desktop_id, chat_id, group_name, dir, permission_mode} 或 {ok:false, error}
# permission_mode 是总控随后要把新会话切到的模式（桌面端导入的会话一律是「手动」），空字符串表示不切换。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"
require_open_id

fail() { jq -cn --arg e "$1" '{ok:false, error:$e}'; exit 1; }

dir="${1:-}"; title="${2:-}"
[ -n "$dir" ] || fail "缺少目录"
case "$dir" in
  /*) ;;
  ~*) dir="${dir/#\~/$HOME}" ;;
  *)  dir="$PROJECTS_ROOT/$dir" ;;
esac
[ -d "$dir" ] || fail "目录不存在：$dir"
dir=$(cd "$dir" && pwd -P)

claude_bin="${LARKSPUR_CLAUDE_BIN:-}"
[ -n "$claude_bin" ] || claude_bin=$(command -v claude 2>/dev/null || true)
[ -n "$claude_bin" ] || claude_bin=$(ls -d "$HOME"/.config/Claude/claude-code/*/*/claude 2>/dev/null | sort -V | tail -1)
[ -x "$claude_bin" ] || fail "找不到 claude 命令，请在 config.sh 里设置 LARKSPUR_CLAUDE_BIN"

# 1. 后台创建会话（-p 模式回复一句即退出；此时还没有同步记录，SessionEnd 钩子不会误关）
out=$(cd "$dir" && timeout 180 "$claude_bin" -p "这是 Larkspur 从飞书新建的会话。请只回复：已创建" \
        --output-format json 2>/dev/null) || fail "后台创建会话失败"
sid=$(printf '%s' "$out" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || fail "没有拿到会话 ID"

# 2. 建专属群并写同步记录
chat=$("$LARKSPUR_HOME/on.sh" "$sid" "$dir" "$title" 2>/dev/null) || fail "建群失败（会话 $sid 已创建）"

# 3. 导入桌面端
if command -v xdg-open >/dev/null; then opener=xdg-open; elif command -v open >/dev/null; then opener=open; else opener=""; fi
[ -n "$opener" ] && "$opener" "claude://resume?session=$sid" >/dev/null 2>&1 &

# 4. 要不要让总控切换权限模式：settings.json 的默认模式已经是 auto（导入后直接生效、不弹确认卡）
#    或已经等于目标模式时，就不切换。例外：默认模式设成 bypassPermissions 时，导入后只会是 acceptEdits，仍要切换。
mode="$SPAWN_MODE"
default_mode=$(jq -r '.permissions.defaultMode // ""' "$HOME/.claude/settings.json" 2>/dev/null)
if [ "$default_mode" = auto ] || { [ "$default_mode" = "$mode" ] && [ "$mode" != bypassPermissions ]; }; then mode=""; fi

fs_log "spawn sid=$sid chat=$chat switch=${mode:-none}"
name=$(jq -r '.group_name // ""' "$(state_file "$sid")" 2>/dev/null)
jq -cn --arg sid "$sid" --arg chat "$chat" --arg dir "$dir" --arg name "$name" --arg mode "$mode" \
  '{ok:true, session_id:$sid, desktop_id:("local_"+$sid), chat_id:$chat, group_name:$name, dir:$dir, permission_mode:$mode}'
