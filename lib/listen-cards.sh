#!/usr/bin/env bash
# 用法：listen-cards.sh <chat_id>
# 总控用：监听「新建会话」卡片的表单提交，只放行这个私聊里、你本人的提交。
# 每次提交输出一行：飞书卡片提交: {"dir","title","prompt","token","message_id","card"}
# 防重复提交：收到提交后，这里立刻用 token 把卡片改成「正在创建」（表单随之消失，约 1 秒），
# 并且同一张卡片（message_id）只放行第一次提交。card 字段是这次更新的结果：creating 或 update-failed。
# token 最多用 2 次，这里用掉第 1 次，总控只需在结束时再用 1 次（done 或 failed）。
# 需要在飞书开放平台「事件与回调 → 回调配置」里开启卡片回调（长连接），否则收不到任何事件。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"
require_open_id

chat="${1:?缺少 chat_id}"
claim_listener "$chat.cards"

"$LARK" event consume card.action.trigger --as bot --timeout 29m \
  --jq "select(.chat_id == \"$chat\" and .operator_id == \"$OPEN_ID\" and .action_tag == \"button\" and (.form_value // \"\") != \"\")
        | (.form_value | fromjson) as \$f
        | {dir: (\$f.dir // \"\"), title: (\$f.title // \"\"), prompt: (\$f.prompt // \"\"), token, message_id}" \
  < <(tail -f /dev/null) 2>&1 |
{
declare -A seen=()
while IFS= read -r line; do
  case "$line" in
    \{*)
      mid=$(printf '%s' "$line" | jq -r '.message_id // ""')
      if [ -n "$mid" ] && [ -n "${seen[$mid]:-}" ]; then fs_log "card-dup mid=$mid"; continue; fi
      [ -n "$mid" ] && seen[$mid]=1
      token=$(printf '%s' "$line" | jq -r '.token // ""'); dir=$(printf '%s' "$line" | jq -r '.dir // ""')
      state=creating
      "$LARKSPUR_HOME/card-update.sh" "$token" creating "$dir" >/dev/null 2>&1 || state=update-failed
      printf '飞书卡片提交: %s\n' "$(printf '%s' "$line" | jq -c --arg s "$state" '. + {card:$s}')"
      fs_log "card-submit chat=$chat mid=$mid card=$state" ;;
    *ready\ event_key*) printf '飞书卡片监听已就绪\n' ;;
    *exited*|*\"ok\":false*|*error*|*ERROR*) printf '飞书卡片监听状态: %s\n' "$line" ;;
  esac
done
}
