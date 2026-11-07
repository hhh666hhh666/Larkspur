#!/usr/bin/env bash
# 用法：listen-cards.sh <chat_id>
# 总控用：监听「新建会话」卡片的表单提交，只放行这个私聊里、你本人的提交。
# 每次提交输出一行：飞书卡片提交: {"dir","title","prompt","token","message_id"}
# 需要在飞书开放平台「事件与回调 → 回调配置」里开启卡片回调（长连接），否则收不到任何事件。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"
require_open_id

chat="${1:?缺少 chat_id}"

"$LARK" event consume card.action.trigger --as bot --timeout 29m \
  --jq "select(.chat_id == \"$chat\" and .operator_id == \"$OPEN_ID\" and .action_tag == \"button\" and (.form_value // \"\") != \"\")
        | (.form_value | fromjson) as \$f
        | {dir: (\$f.dir // \"\"), title: (\$f.title // \"\"), prompt: (\$f.prompt // \"\"), token, message_id}" \
  < <(tail -f /dev/null) 2>&1 |
while IFS= read -r line; do
  case "$line" in
    \{*) printf '飞书卡片提交: %s\n' "$(printf '%s' "$line" | jq -c .)"; fs_log "card-submit chat=$chat" ;;
    *ready\ event_key*) printf '飞书卡片监听已就绪\n' ;;
    *exited*|*\"ok\":false*|*error*|*ERROR*) printf '飞书卡片监听状态: %s\n' "$line" ;;
  esac
done
