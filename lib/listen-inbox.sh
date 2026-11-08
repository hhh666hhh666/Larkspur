#!/usr/bin/env bash
# 用法：listen-inbox.sh
# 总控会话用 Monitor 运行（description「飞书私聊（总控）」，timeout_ms 1800000）。
# 飞书监听由常驻服务 larkspurd 负责，它把每行事件（私聊消息、卡片提交、要转发的群消息、控制台请求……）
# 追加到 run/hub-queue；这里每秒看一次，把新事件原样输出给总控，然后清空队列（消息内容不长期留在磁盘上）。
# 总控会话停着时（桌面端重启、上下文压缩）事件留在队列里，Monitor 重新启动后一次性补上，不丢。
# 29 分钟后自己正常退出，总控按惯例续期。Larkspur 没在运行时输出一行提示（每次启动最多一次）。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"
require_open_id

claim_listener inbox
Q="$RUN_DIR/hub-queue"
end=$(( $(date +%s) + ${LARKSPUR_INBOX_SECONDS:-1740} ))
warned=""
while [ "$(date +%s)" -lt "$end" ]; do
  if [ -s "$Q" ]; then
    {
      flock 9
      cat "$Q"; : > "$Q"
    } 9>>"$Q.lock"
  fi
  if [ -z "$warned" ] && ! daemon_alive; then
    printf '飞书监听状态: Larkspur 没在运行，飞书消息暂时收不到。主人可以在电脑桌面点「Larkspur」打开它（或运行 %s start）。\n' "$LARKSPUR_HOME/larkspurctl.sh"
    warned=1
  fi
  daemon_alive && warned=""
  sleep 1
done
