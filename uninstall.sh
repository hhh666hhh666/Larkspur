#!/usr/bin/env bash
# Larkspur 卸载脚本：移除钩子、技能和脚本。
# 默认保留个人配置与会话记录；加 --purge 一并删除。飞书里的群不会被删除。
set -euo pipefail

DEST="${LARKSPUR_HOME:-$HOME/.claude/larkspur}"
SKILL_DIR="$HOME/.claude/skills/feishu"
SETTINGS="$HOME/.claude/settings.json"
say() { printf '[larkspur] %s\n' "$*"; }

if [ -f "$SETTINGS" ] && command -v jq >/dev/null; then
  cp "$SETTINGS" "$SETTINGS.larkspur-bak.$(date +%Y%m%d%H%M%S)"
  tmp=$(mktemp)
  jq --arg stop "$DEST/hooks/notify.sh" --arg end "$DEST/hooks/session-end.sh" --arg ensure "$DEST/hooks/ensure-listener.sh" \
     --arg start "$DEST/hooks/session-start.sh" --arg wait "$DEST/hooks/hub-wait.sh" '
    def strip($c): map(select(([.hooks[]?.command] | index($c)) | not));
    if .hooks then
      .hooks.Stop       = ((.hooks.Stop // [])       | strip($stop) | strip($ensure) | strip($wait))
      | .hooks.SessionEnd = ((.hooks.SessionEnd // []) | strip($end))
      | .hooks.SessionStart = ((.hooks.SessionStart // []) | strip($start))
      | .hooks |= with_entries(select(.value | length > 0))
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
  ' "$SETTINGS" > "$tmp" && jq -e . "$tmp" >/dev/null && mv "$tmp" "$SETTINGS"
  say "已从 $SETTINGS 移除钩子（原文件已备份）"
fi

[ -f "$SKILL_DIR/SKILL.md" ] && grep -q 'Larkspur' "$SKILL_DIR/SKILL.md" && rm -rf "$SKILL_DIR" && say "已移除技能 $SKILL_DIR"

rm -f "$DEST"/common.sh "$DEST"/on.sh "$DEST"/off.sh "$DEST"/listen.sh "$DEST"/hub-on.sh "$DEST"/spawn.sh \
      "$DEST"/card-new.sh "$DEST"/card-update.sh "$DEST"/listen-cards.sh "$DEST"/say.sh "$DEST"/mode.sh "$DEST"/console.sh "$DEST"/listen-menu.sh \
      "$DEST"/netcheck.sh "$DEST"/netwatch.sh "$DEST"/exit-ips.sh "$DEST"/ipguard.sh "$DEST"/desktop-gate.sh
gate="$HOME/.local/bin/claude-desktop"
[ -f "$gate" ] && grep -q 'Claude 桌面端的启动闸门' "$gate" && rm -f "$gate" && say "已移除桌面端启动闸门 $gate"
desk=$(xdg-user-dir DESKTOP 2>/dev/null || true)
rm -f "$HOME/.local/bin/larkspur-ip-gate" "$HOME/.local/share/applications/larkspur-ip-gate.desktop" ${desk:+"$desk/IP闸门.desktop"}
if command -v systemctl >/dev/null; then
  systemctl --user stop larkspur.service 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/larkspur.service"; systemctl --user daemon-reload 2>/dev/null || true
fi
[ -f "$DEST/run/daemon.json" ] && kill "$(jq -r '.pid // empty' "$DEST/run/daemon.json" 2>/dev/null)" 2>/dev/null || true
rm -f "$DEST/larkspurd.py" "$DEST/larkspurctl.sh" "$DEST/listen-inbox.sh" "$DEST/listen-wait.sh" "$DEST/hub-revive.sh" "$HOME/.local/share/applications/larkspur.desktop" ${desk:+"$desk/Larkspur.desktop"}
rm -rf "$DEST/web"
say "已移除常驻服务"
rm -rf "$DEST/hooks" "$DEST/run"
say "已移除脚本"

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$DEST"
  say "已删除 $DEST（配置、会话记录、日志）"
else
  say "保留 $DEST 中的配置与会话记录；需要彻底删除请加 --purge"
fi
