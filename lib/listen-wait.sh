#!/usr/bin/env bash
# 用法：listen-wait.sh <总控的 session_id> [桌面端会话 ID]
# 总控按需唤醒：由总控会话的钩子在后台运行（Stop 钩子 hub-wait.sh、SessionStart 钩子，都是 asyncRewake），不要放进 Monitor。
# 常驻服务 larkspurd 把飞书事件追加到 run/hub-queue；这里每秒看一次，空闲时什么都不做（不调用模型）。
# 一有事件就把它们写到 stderr、以退出码 2 结束，Claude Code 随即唤醒总控处理；总控回合结束时 Stop 钩子再起下一个。
#   - 同一时间只留一个（新的顶替旧的）；被顶替、Claude 进程退出、本会话不再是总控时安静退出，事件留在队列里；
#   - 事件先挪进 run/hub-taken.<pid> 再交出，中途被杀也不丢，下一个等待进程会补上；
#   - 等了 LARKSPUR_WAIT_SECONDS（默认 7 天，略短于钩子的超时）都没有事件，就唤醒总控一次续期。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"
hsid="${1:?缺少 session_id}"; hdesk="${2:-}"
Q="$RUN_DIR/hub-queue"; MINE="$RUN_DIR/hub-taken.$$"

still_hub() {   # 会话 ID 变了（桌面端重启后迁移记录）时按桌面端会话 ID 认
  local hf; hf=$(hub_state) || return 1
  [ "$(jq -r '.session_id' "$hf")" = "$hsid" ] || { [ -n "$hdesk" ] && [ "$(jq -r '.desktop_id // ""' "$hf")" = "$hdesk" ]; }
}
take() {   # 把队列、以及死掉的旧等待进程没交出去的事件挪到自己名下
  local f p
  {
    flock 9
    for f in "$RUN_DIR"/hub-taken.*; do
      [ -f "$f" ] || continue
      p=${f##*.}; [ "$p" = "$$" ] && continue
      kill -0 "$p" 2>/dev/null && continue
      cat "$f" >> "$MINE"; rm -f "$f"
    done
    if [ -s "$Q" ]; then cat "$Q" >> "$MINE"; : > "$Q"; fi
  } 9>>"$Q.lock"
  [ -s "$MINE" ]
}
handoff() { date +%s > "$RUN_DIR/inbox.handoff"; }

still_hub || exit 0
claude="${LARKSPUR_WAIT_PARENT:-$(claude_ancestor)}"   # 测试时可指定
claim_listener inbox
rm -f "$RUN_DIR/inbox.handoff"
end=$(( $(date +%s) + ${LARKSPUR_WAIT_SECONDS:-604500} ))
i=0
while :; do
  kill -0 "$claude" 2>/dev/null || exit 0
  if take; then
    sleep 0.3; take   # 同一批里紧跟着的事件（图片和文字）一起交
    n=$(wc -l < "$MINE")
    { echo "【Larkspur】飞书事件（$n 条，总控按需唤醒；照常逐条处理，处理完结束回合即可，不用启动 Monitor）："; cat "$MINE"; } >&2
    rm -f "$MINE"; handoff
    fs_log "hub-wake events=$n"
    exit 2
  fi
  if [ "$(date +%s)" -ge "$end" ]; then
    echo "【Larkspur】总控的事件等待到期续期，没有新事件。不要输出任何文字，直接结束本回合。" >&2
    handoff; fs_log "hub-wake renew"
    exit 2
  fi
  i=$((i+1)); [ $((i % ${LARKSPUR_WAIT_CHECK:-10})) -eq 0 ] && { still_hub || exit 0; }
  sleep 1
done
