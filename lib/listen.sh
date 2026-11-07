#!/usr/bin/env bash
# 用法：listen.sh <chat_id> [--hub]
# 供 Claude Code 的 Monitor 使用：stdout 每行是一个事件（200ms 内的多行会合并为一条通知）。
#
# 两种模式：
# - 普通会话（不带参数）：只放行「这个群里、用户本人」发的消息。有活动的总控时，消息改由总控转发，
#   这里输出一行「飞书监听状态: 总控已接管…」后直接退出。
# - 总控（--hub，旧写法 --with-cards 等同）：
#   1. 自己私聊里的消息照常输出；
#   2. 后台跑 listen-cards.sh，卡片提交也从这里输出；
#   3. 其他开着同步的会话的群里，用户发的消息输出成一行「飞书转发: {"to","chat","group","message"}」，
#      （另有 chat 字段）由总控用 send_message 投进对应会话，在桌面端显示为消息气泡。
#
# 回执：每条放行的消息都会被加上 ACK_EMOJI 表情（默认「了解」），表示 Claude 已收到。
# 图片合并：收到图片后最多等 WAIT 秒，期间同一个群里到达的文字与图片合成一条；超时仍无文字则单独送出。
# 同一个群只留一个监听：新启动的会顶替旧的。连上时不输出「就绪」，正常到时退出也不输出。
# 断线补取：连上后从上一个监听的启动时间起查一遍消息，把漏掉的按顺序补发，已处理过的按 message_id 去重。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"
require_open_id

chat="${1:?缺少 chat_id}"
hub=""; case "${2:-}" in --hub|--with-cards) hub=1 ;; esac
WAIT="$IMAGE_WAIT"

if [ -z "$hub" ] && router_active; then
  printf '飞书监听状态: 总控已接管本会话的飞书消息转发，消息会以气泡形式直接出现在本会话里，本会话不需要自己的监听，不要重启这个 Monitor\n'
  exit 0
fi

claim_listener "$chat.msg"
cards_pid=""
if [ -n "$hub" ]; then
  "$LARKSPUR_HOME/listen-cards.sh" "$chat" & cards_pid=$!
  trap 'release_listener "$chat.msg"; kill_tree "$cards_pid"' EXIT
fi
seen_f="$RUN_DIR/$chat.seen"; started_f="$RUN_DIR/$chat.started"
prev_start=$(cat "$started_f" 2>/dev/null || true)
date +%s > "$started_f"

# 合并缓冲：同一时间只缓冲一个群的消息
buf_chat=""; buf_to=""; buf_group=""; buf_tag=""
buf=()          # 自己群的事件行
r_texts=()      # 转发群的文字
r_imgs=()       # 转发群的图片行
deadline=0

flush() {       # 送出缓冲区；参数 timeout 表示等图片后的文字超时
  local why="${1:-}" l msg
  if [ "$buf_chat" = "$chat" ]; then
    for l in "${buf[@]}"; do printf '%s\n' "$l"; done
    [ "$why" = timeout ] && printf '飞书提示: 仅收到图片，%s 秒内没有附带文字\n' "$WAIT"
  elif [ -n "$buf_chat" ]; then
    if [ "${#r_texts[@]}" -gt 0 ]; then msg=$(printf '%s\n' "${r_texts[@]}"); else msg="（只发了图片，没有附文字）"; fi
    msg="【飞书${buf_tag}】${msg}"
    for l in "${r_imgs[@]}"; do msg="$msg
$l"; done
    printf '飞书转发: %s\n' "$(jq -cn --arg to "$buf_to" --arg c "$buf_chat" --arg g "$buf_group" --arg m "$msg" '{to:$to, chat:$c, group:$g, message:$m}')"
    fs_log "route chat=$buf_chat to=$buf_to"
  fi
  buf_chat=""; buf_to=""; buf_group=""; buf_tag=""; buf=(); r_texts=(); r_imgs=(); deadline=0
}

handle_msg() {  # 处理一条 JSON 消息：{chat_id, message_id, message_type, content}；第二个参数为补发标记
  local line="$1" tag="${2:-}" c mid mtype raw key n=0 out got target to="" group=""
  c=$(printf '%s' "$line" | jq -r ".chat_id // \"$chat\"")
  mid=$(printf '%s' "$line" | jq -r '.message_id')
  if [ -f "$seen_f" ] && grep -qxF "$mid" "$seen_f"; then return; fi
  printf '%s\n' "$mid" >> "$seen_f"
  if [ "$c" != "$chat" ]; then
    target=$(route_target "$c")
    [ -n "$target" ] || { fs_log "route-skip chat=$c mid=$mid"; return; }
    to=${target%%$'\t'*}; group=${target#*$'\t'}
  fi
  # 回执：给这条飞书消息加个表情（默认「了解」），后台进行，不耽误转发
  [ -n "$ACK_EMOJI" ] && "$LARK" im reactions create --as bot --params "{\"message_id\":\"$mid\"}" \
      --data "{\"reaction_type\":{\"emoji_type\":\"$ACK_EMOJI\"}}" >/dev/null 2>&1 &
  [ -n "$buf_chat" ] && [ "$buf_chat" != "$c" ] && flush
  mtype=$(printf '%s' "$line" | jq -r '.message_type')
  raw=$(printf '%s' "$line" | jq -r '.content // ""')

  local imgs=()
  for key in $(printf '%s' "$raw" | grep -oE 'img_[A-Za-z0-9_-]+' | sort -u); do
    n=$((n+1))
    out="$INBOX/$(date +%Y%m%d-%H%M%S)-${mid: -8}-$n"
    if "$LARK" im +messages-resources-download --as bot --message-id "$mid" \
         --file-key "$key" --type image --output "$out" >/dev/null 2>&1; then
      got=$(ls -1 "$out"* 2>/dev/null | head -1); imgs+=("${got:-$out}")
    else
      imgs+=("下载失败:$key")
    fi
  done
  fs_log "inbound chat=$c mid=$mid type=$mtype images=$n"

  buf_chat="$c"; buf_to="$to"; buf_group="$group"; [ -n "$tag" ] && buf_tag="$tag"
  local p
  if [ "$c" = "$chat" ]; then
    buf+=("飞书消息（用户，$mtype）: ${raw//$'\n'/ ⏎ }")
    for p in "${imgs[@]}"; do case "$p" in 下载失败:*) buf+=("飞书图片下载失败: ${p#下载失败:}") ;; *) buf+=("飞书图片: $p") ;; esac; done
  else
    [ "$mtype" = image ] || r_texts+=("$raw")
    for p in "${imgs[@]}"; do case "$p" in 下载失败:*) r_imgs+=("[图片下载失败] ${p#下载失败:}") ;; *) r_imgs+=("[图片] $p") ;; esac; done
  fi
  if [ "$mtype" = image ]; then deadline=$((SECONDS + WAIT)); else flush; fi
}

backfill() {    # 补发上一个监听启动以来漏掉的消息（第一次启动时没有记录，不补）
  [ -n "$prev_start" ] || return 0
  local since=$((prev_start - 60)) floor=$(( $(date +%s) - BACKFILL_HOURS * 3600 )) c rows n l chats
  [ "$since" -lt "$floor" ] && since=$floor
  chats="$chat"; [ -n "$hub" ] && chats=$(printf '%s\n%s\n' "$chat" "$(routed_chats)")
  for c in $chats; do
    rows=$("$LARK" im +chat-messages-list --as bot --chat-id "$c" --start "$(iso_time "$since")" \
            --order asc --page-size 50 --no-reactions \
            --jq ".data.messages[] | select(.sender.id == \"$OPEN_ID\" and (.deleted | not)) | {chat_id: \"$c\", message_id, message_type: .msg_type, content}" \
            2>/dev/null | jq -c . 2>/dev/null) || continue
    [ -n "$rows" ] || continue
    [ -f "$seen_f" ] && rows=$(printf '%s\n' "$rows" | while IFS= read -r l; do
        grep -qxF "$(printf '%s' "$l" | jq -r .message_id)" "$seen_f" || printf '%s\n' "$l"; done)
    [ -n "$rows" ] || continue
    rows=$(printf '%s\n' "$rows" | tail -n "$BACKFILL_MAX"); n=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
    fs_log "backfill chat=$c count=$n"
    [ "$c" = "$chat" ] && printf '飞书提示: 监听中断期间收到 %s 条消息，下面按顺序补发\n' "$n"
    while IFS= read -r l; do handle_msg "$l" "·中断期间补发"; done <<< "$rows"
    flush
  done
}

if [ -n "$hub" ]; then filter="select(.sender_id == \"$OPEN_ID\")"
else filter="select(.chat_id == \"$chat\" and .sender_id == \"$OPEN_ID\")"; fi

"$LARK" event consume im.message.receive_v1 --as bot --timeout 29m \
  --jq "$filter | {chat_id, message_id, message_type, content}" \
  < <(hold_stdin $$) 2>&1 |
while :; do
  if [ "$deadline" -gt 0 ]; then
    remain=$((deadline - SECONDS)); [ "$remain" -lt 1 ] && remain=1
    IFS= read -r -t "$remain" line; rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -gt 128 ]; then flush timeout; continue; fi   # 读超时：等图片后的文字超时
      flush; break                                            # 上游结束
    fi
  else
    IFS= read -r line || break
  fi

  case "$line" in
    \{*) handle_msg "$line" ;;
    *ready\ event_key*) backfill
                        [ -f "$seen_f" ] && tail -n 500 "$seen_f" > "$seen_f.tmp" && mv "$seen_f.tmp" "$seen_f" ;;
    *exited*|*\"ok\":false*|*error*|*ERROR*) flush; is_normal_exit "$line" || printf '飞书监听状态: %s\n' "$line" ;;
  esac
done
