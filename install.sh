#!/usr/bin/env bash
# Larkspur 安装脚本：把脚本装到 ~/.claude/larkspur，技能装到 ~/.claude/skills/feishu，
# 并把 Stop / SessionEnd 钩子合并进 ~/.claude/settings.json（会先备份）。可重复执行。
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
DEST="${LARKSPUR_HOME:-$HOME/.claude/larkspur}"
SKILL_DIR="$HOME/.claude/skills/feishu"
SETTINGS="$HOME/.claude/settings.json"

say() { printf '[larkspur] %s\n' "$*"; }
die() { printf '[larkspur] 错误：%s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || die "需要 jq"
LARK=$(command -v lark-cli 2>/dev/null || true)
[ -n "$LARK" ] || { [ -x "$HOME/.local/bin/lark-cli" ] && LARK="$HOME/.local/bin/lark-cli"; }
[ -n "$LARK" ] || die "找不到 lark-cli，请先安装并登录：npm install -g @larksuite/cli"

# 1. 脚本
mkdir -p "$DEST/hooks" "$DEST/sessions"
cp "$SRC"/lib/*.sh "$DEST/"
cp "$SRC"/hooks/*.sh "$DEST/hooks/"
chmod +x "$DEST"/*.sh "$DEST"/hooks/*.sh
say "脚本已安装到 $DEST"

# 2. 个人配置（已存在则保留）
if [ ! -f "$DEST/config.sh" ]; then
  open_id="${LARKSPUR_OPEN_ID:-}"
  [ -n "$open_id" ] || open_id=$("$LARK" auth status 2>/dev/null | jq -r '.identities.user.openId // empty' 2>/dev/null || true)
  sed -e "s#^LARKSPUR_OPEN_ID=\"\"#LARKSPUR_OPEN_ID=\"$open_id\"#" \
      -e "s#^LARKSPUR_LARK_CLI=\"\"#LARKSPUR_LARK_CLI=\"$LARK\"#" \
      "$SRC/config.example.sh" > "$DEST/config.sh"
  chmod 600 "$DEST/config.sh"
  if [ -n "$open_id" ]; then
    say "已生成配置 $DEST/config.sh（open_id 取自 lark-cli 登录状态）"
  else
    say "已生成配置 $DEST/config.sh，但没能自动获取 open_id，请手动填写 LARKSPUR_OPEN_ID"
  fi
else
  say "保留已有配置 $DEST/config.sh"
fi

# 3. 技能
mkdir -p "$SKILL_DIR"
cp "$SRC/skill/SKILL.md" "$SKILL_DIR/SKILL.md"
say "技能已安装到 $SKILL_DIR（命令：/feishu on | off）"

# 4. 钩子（先删掉旧的同名条目再追加，保证幂等）
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.larkspur-bak.$(date +%Y%m%d%H%M%S)"
stop_cmd="$DEST/hooks/notify.sh"
end_cmd="$DEST/hooks/session-end.sh"
tmp=$(mktemp)
jq --arg stop "$stop_cmd" --arg end "$end_cmd" '
  def strip($c): map(select(([.hooks[]?.command] | index($c)) | not));
  .hooks //= {}
  | .hooks.Stop       = ((.hooks.Stop // [])       | strip($stop)) + [{hooks:[{type:"command", command:$stop, async:true, timeout:30}]}]
  | .hooks.SessionEnd = ((.hooks.SessionEnd // []) | strip($end))  + [{hooks:[{type:"command", command:$end, timeout:15}]}]
' "$SETTINGS" > "$tmp"
jq -e . "$tmp" >/dev/null && mv "$tmp" "$SETTINGS"
say "钩子已写入 $SETTINGS（原文件已备份）"

say "完成。已打开的会话可能需要重开才会加载新钩子与技能。"
