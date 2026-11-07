#!/usr/bin/env bash
# Larkspur · Claude Code Stop 钩子：只对开启了飞书同步（/feishu on）的会话生效，
# 把本回合最后一条回复发到该会话自己的飞书群。未开启的会话什么都不做。
# 失败时静默退出，绝不影响 Claude Code 本身。

. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh" 2>/dev/null || exit 0
MAX=20000   # 保护上限，正常回复不会触及

[ -x "$LARK" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
[ -n "$sid" ] || exit 0
f=$(state_file "$sid")
[ -f "$f" ] || exit 0
[ "$(jq -r '.active' "$f")" = "true" ] || exit 0
chat_id=$(jq -r '.chat_id' "$f")

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
msg=$(printf '%s' "$input" | jq -r '.last_assistant_message // empty')
if [ -z "$msg" ] && [ -f "$transcript" ]; then
  msg=$(jq -rs '[ .[] | select(.type == "assistant")
      | .message.content[]? | select(.type == "text") | .text ] | last // empty' "$transcript" 2>/dev/null)
fi
[ -n "$msg" ] || exit 0          # 无文本（例如只是续期监听的回合）不发

# 去掉回复开头对飞书原话的引用块（「> 📨 飞书：…」及其后续 > 行和空行），只发正文
msg=$(printf '%s\n' "$msg" | awk '
  !started && /^> 📨 飞书：/ { inq=1; next }
  !started && inq && /^>/     { next }
  !started && /^[[:space:]]*$/ { next }
  { started=1; print }')
[ -n "$msg" ] || exit 0
# 总控转发消息后的占位回复（「—」）不发
case "$(printf '%s' "$msg" | tr -d '[:space:]')" in —|-|"") exit 0 ;; esac

# 去重：与上次发出的内容相同则不发
hash=$(printf '%s' "$msg" | sha256sum | cut -c1-16)
[ "$hash" = "$(jq -r '.last_sent_hash // ""' "$f")" ] && exit 0

[ "${#msg}" -gt "$MAX" ] && msg="${msg:0:$MAX}…（内容过长已截断）"

if "$LARK" im +messages-send --as bot --chat-id "$chat_id" --markdown "$msg" >/dev/null 2>&1; then
  tmp=$(mktemp) && jq --arg h "$hash" '.last_sent_hash=$h' "$f" > "$tmp" && mv "$tmp" "$f"
  fs_log "outbound sid=$sid chat=$chat_id"
else
  fs_log "outbound-failed sid=$sid chat=$chat_id"
fi
exit 0
