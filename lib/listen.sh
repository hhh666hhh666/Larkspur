#!/usr/bin/env bash
# 用法：listen.sh <chat_id>
# 只放行「这个群里、用户本人」发的消息。每条消息输出一行，图片先下载再输出本地路径。
# 图片合并：收到图片后最多等 WAIT 秒，期间到达的文字与图片合成一批一起输出；
# 超时仍无文字，则输出图片并附一行「飞书提示: 仅收到图片」。纯文字消息立即输出。
# 供 Claude Code 的 Monitor 使用：stdout 每行是一个事件（200ms 内的多行会合并为一条通知）。
# 同一个群只留一个监听：新启动的会顶替旧的。
# 断线补取：监听连上后，会从上一个监听的启动时间起查一遍群消息，把中间漏掉的（进程重启、
# Monitor 续期的空档）按顺序补发，已处理过的消息按 message_id 去重。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"
require_open_id

chat="${1:?缺少 chat_id}"
WAIT="$IMAGE_WAIT"
claim_listener "$chat.msg"
seen_f="$RUN_DIR/$chat.seen"; started_f="$RUN_DIR/$chat.started"
prev_start=$(cat "$started_f" 2>/dev/null || true)
date +%s > "$started_f"

buf=()          # 等待合并的图片行
deadline=0

flush() {       # 输出缓冲区，可附加一行
  local extra="${1:-}" l
  for l in "${buf[@]}"; do printf '%s\n' "$l"; done
  [ -n "$extra" ] && printf '%s\n' "$extra"
  buf=(); deadline=0
}

handle_msg() {  # 处理一条 JSON 消息事件
  local line="$1" mid mtype text key n=0 out got
  mid=$(printf '%s' "$line" | jq -r '.message_id')
  if [ -f "$seen_f" ] && grep -qxF "$mid" "$seen_f"; then return; fi
  printf '%s\n' "$mid" >> "$seen_f"
  mtype=$(printf '%s' "$line" | jq -r '.message_type')
  text=$(printf '%s' "$line" | jq -r '(.content // "") | gsub("\r?\n"; " ⏎ ")')

  local imgs=()
  for key in $(printf '%s' "$line" | grep -oE 'img_[A-Za-z0-9_-]+' | sort -u); do
    n=$((n+1))
    out="$INBOX/$(date +%Y%m%d-%H%M%S)-${mid: -8}-$n"
    if "$LARK" im +messages-resources-download --as bot --message-id "$mid" \
         --file-key "$key" --type image --output "$out" >/dev/null 2>&1; then
      got=$(ls -1 "$out"* 2>/dev/null | head -1)
      imgs+=("飞书图片: ${got:-$out}")
    else
      imgs+=("飞书图片下载失败: $key")
    fi
  done
  fs_log "inbound chat=$chat mid=$mid type=$mtype images=$n"

  if [ "$mtype" = "image" ]; then
    # 纯图片：进入缓冲，等待后续文字
    buf+=("飞书消息（用户，image）: $text" "${imgs[@]}")
    deadline=$((SECONDS + WAIT))
  else
    # 文字（或富文本）：连同缓冲中的图片一起立即输出
    buf+=("飞书消息（用户，$mtype）: $text" "${imgs[@]}")
    flush
  fi
}

backfill() {    # 补发上一个监听启动以来漏掉的消息（第一次启动时没有记录，不补）
  [ -n "$prev_start" ] || return 0
  local since=$((prev_start - 60)) floor=$(( $(date +%s) - BACKFILL_HOURS * 3600 )) rows n l
  [ "$since" -lt "$floor" ] && since=$floor
  rows=$("$LARK" im +chat-messages-list --as bot --chat-id "$chat" --start "$(iso_time "$since")" \
          --order asc --page-size 50 --no-reactions \
          --jq ".data.messages[] | select(.sender.id == \"$OPEN_ID\" and (.deleted | not)) | {message_id, message_type: .msg_type, content}" \
          2>/dev/null | jq -c . 2>/dev/null) || return 0
  [ -n "$rows" ] || return 0
  [ -f "$seen_f" ] && rows=$(printf '%s\n' "$rows" | while IFS= read -r l; do
      grep -qxF "$(printf '%s' "$l" | jq -r .message_id)" "$seen_f" || printf '%s\n' "$l"; done)
  [ -n "$rows" ] || return 0
  rows=$(printf '%s\n' "$rows" | tail -n "$BACKFILL_MAX"); n=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
  fs_log "backfill chat=$chat count=$n"
  printf '飞书提示: 监听中断期间收到 %s 条消息，下面按顺序补发\n' "$n"
  while IFS= read -r l; do handle_msg "$l"; done <<< "$rows"
}

"$LARK" event consume im.message.receive_v1 --as bot --timeout 29m \
  --jq "select(.chat_id == \"$chat\" and .sender_id == \"$OPEN_ID\") | {message_id, message_type, content}" \
  < <(tail -f /dev/null) 2>&1 |
while :; do
  if [ "$deadline" -gt 0 ]; then
    remain=$((deadline - SECONDS)); [ "$remain" -lt 1 ] && remain=1
    IFS= read -r -t "$remain" line; rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -gt 128 ]; then          # 读超时：等待结束，仍无文字
        flush "飞书提示: 仅收到图片，${WAIT} 秒内没有附带文字"
        continue
      fi
      flush; break                          # 上游结束
    fi
  else
    IFS= read -r line || break
  fi

  case "$line" in
    \{*) handle_msg "$line" ;;
    *ready\ event_key*) printf '飞书监听已就绪\n'; backfill
                        [ -f "$seen_f" ] && tail -n 500 "$seen_f" > "$seen_f.tmp" && mv "$seen_f.tmp" "$seen_f" ;;
    *exited*|*\"ok\":false*|*error*|*ERROR*) flush; printf '飞书监听状态: %s\n' "$line" ;;
  esac
done
