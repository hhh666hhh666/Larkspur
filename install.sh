#!/usr/bin/env bash
# Larkspur 安装脚本：把脚本装到 ~/.claude/larkspur，技能装到 ~/.claude/skills/feishu，
# 并把 SessionStart / Stop / SessionEnd 钩子合并进 ~/.claude/settings.json（会先备份）。可重复执行。
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
# 先写临时文件再 mv 替换：正在运行的监听脚本仍读旧文件，不会被就地改写打乱
put() { cp "$1" "$2.new.$$" && mv -f "$2.new.$$" "$2"; }
for f in "$SRC"/lib/*.sh;   do put "$f" "$DEST/$(basename "$f")"; done
for f in "$SRC"/hooks/*.sh; do put "$f" "$DEST/hooks/$(basename "$f")"; done
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
say "技能已安装到 $SKILL_DIR（命令：/feishu on | off | hub）"

# 4. 钩子（先删掉旧的同名条目再追加，保证幂等）
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.larkspur-bak.$(date +%Y%m%d%H%M%S)"
stop_cmd="$DEST/hooks/notify.sh"
end_cmd="$DEST/hooks/session-end.sh"
ensure_cmd="$DEST/hooks/ensure-listener.sh"
start_cmd="$DEST/hooks/session-start.sh"
tmp=$(mktemp)
jq --arg stop "$stop_cmd" --arg end "$end_cmd" --arg ensure "$ensure_cmd" --arg start "$start_cmd" '
  def strip($c): map(select(([.hooks[]?.command] | index($c)) | not));
  .hooks //= {}
  | .hooks.Stop       = ((.hooks.Stop // [])       | strip($stop) | strip($ensure))
                        + [{hooks:[{type:"command", command:$stop, async:true, timeout:30}]},
                           {hooks:[{type:"command", command:$ensure, timeout:10}]}]
  | .hooks.SessionEnd = ((.hooks.SessionEnd // []) | strip($end))  + [{hooks:[{type:"command", command:$end, timeout:15}]}]
  | .hooks.SessionStart = ((.hooks.SessionStart // []) | strip($start))
                        + [{hooks:[{type:"command", command:$start, asyncRewake:true, timeout:90}]}]
' "$SETTINGS" > "$tmp"
jq -e . "$tmp" >/dev/null && mv "$tmp" "$SETTINGS"
say "钩子已写入 $SETTINGS（原文件已备份）"

# 5. 桌面端启动闸门：配置了 LARKSPUR_EXPECTED_IP 时装为 ~/.local/bin/claude-desktop（PATH 里排在系统的前面）
gate="$HOME/.local/bin/claude-desktop"
if ( . "$DEST/config.sh"; [ -n "${LARKSPUR_EXPECTED_IP:-}" ] ); then
  mkdir -p "$HOME/.local/bin"
  [ ! -e "$gate" ] || grep -q 'Claude 桌面端的启动闸门' "$gate" || die "$gate 已存在且不是 Larkspur 的闸门，请先移走"
  put "$SRC/lib/desktop-gate.sh" "$gate"; chmod +x "$gate"
  say "桌面端启动闸门已装到 $gate：三个出口 IP 都是 $( . "$DEST/config.sh"; echo "$LARKSPUR_EXPECTED_IP") 才启动桌面端"
elif [ -f "$gate" ] && grep -q 'Claude 桌面端的启动闸门' "$gate"; then
  rm -f "$gate"; say "没有配置 LARKSPUR_EXPECTED_IP，已移除桌面端启动闸门"
fi

# 6. 「IP 闸门」设置程序：~/.local/bin/larkspur-ip-gate，桌面图标和应用菜单里各放一个
ui="$HOME/.local/bin/larkspur-ip-gate"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
put "$SRC/lib/ip-gate-ui.sh" "$ui"; chmod +x "$ui"
entry="[Desktop Entry]
Type=Application
Name=IP 闸门
Comment=设置是否启用出口 IP 检查（Larkspur）
Exec=$ui
Icon=preferences-system-network-proxy
Terminal=false
Categories=Utility;Network;"
printf '%s\n' "$entry" > "$HOME/.local/share/applications/larkspur-ip-gate.desktop"
desk=$(xdg-user-dir DESKTOP 2>/dev/null || true)
if [ -n "$desk" ] && [ -d "$desk" ] && [ "$desk" != "$HOME" ]; then
  printf '%s\n' "$entry" > "$desk/IP闸门.desktop"; chmod +x "$desk/IP闸门.desktop"
  # XFCE 只直接运行被标记为可信的桌面启动器
  command -v gio >/dev/null && gio set -t string "$desk/IP闸门.desktop" metadata::xfce-exe-checksum \
    "$(sha256sum "$desk/IP闸门.desktop" | cut -d' ' -f1)" 2>/dev/null || true
  say "「IP 闸门」设置程序已放到桌面：$desk/IP闸门.desktop"
fi

say "完成。已打开的会话可能需要重开才会加载新钩子与技能。"
