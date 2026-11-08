#!/usr/bin/env bash
# 用法：listen-cards.sh <chat_id> [总控监听的 pid]（给了 pid 时，它退出后这里也跟着退出）
# 总控用：监听这个私聊里、你本人在卡片上的操作，只放行你本人。两类卡片：
#   1. 「新建会话」表单卡片：提交时输出下面这行事件，交给总控；
#   2. 控制台卡片（按钮带 {"lk":"c"}）：交给 console.sh 直接处理，不唤醒 Claude；
#      console.sh 需要总控出手时（例如归档会话）会输出一行「飞书控制台请求: {...}」，原样转给总控。
# 通常不单独启动，而是由 listen.sh <chat_id> --hub 在后台拉起，共用一个 Monitor。
# 每次提交输出一行：飞书卡片提交: {"dir","title","prompt","token","message_id","card"}
# 防重复提交：收到提交后，这里立刻用 token 把卡片改成「正在创建」（表单随之消失，约 1 秒），
# 并且同一张卡片（message_id）只放行第一次提交。card 字段是这次更新的结果：creating 或 update-failed。
# token 最多用 2 次，这里用掉第 1 次，总控只需在结束时再用 1 次（done 或 failed）。
# 需要在飞书开放平台「事件与回调 → 回调配置」里开启卡片回调（长连接），否则收不到任何事件。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"
require_open_id

chat="${1:?缺少 chat_id}"; parent="${2:-}"
claim_listener "$chat.cards"

reap_orphan_consumers card.action.trigger
"$LARK" event consume card.action.trigger --as bot \
  --jq "select(.operator_id == \"$OPEN_ID\" and ((.chat_id // \"\") == \"$chat\" or (.chat_id // \"\") == \"\"))
        | {tag: (.action_tag // \"\"), value: (.action_value // \"\"), form: (.form_value // \"\"),
           input: ((.option // \"\") + (.input_value // \"\")), token, message_id}" \
  < <(hold_stdin $$ $((29 * 60)) $parent) 2>&1 |
{
declare -A seen=()
while IFS= read -r line; do
  case "$line" in
    \{*)
      value=$(printf '%s' "$line" | jq -r '.value')
      if printf '%s' "$value" | jq -e '.lk == "c"' >/dev/null 2>&1; then   # 控制台
        fs_log "console-click op=$(printf '%s' "$value" | jq -r '.op // ""')"
        extra=$(printf '%s' "$line" | jq -r 'if .form != "" then .form else .input end')
        # 后台处理，后面的点击不用排队等前一次的接口调用
        { "$LARKSPUR_HOME/console.sh" action "$value" "$extra" 2>/dev/null | grep '^飞书控制台请求: '; } &
        continue
      fi
      form=$(printf '%s' "$line" | jq -r '.form')
      [ "$(printf '%s' "$line" | jq -r '.tag')" = button ] && [ -n "$form" ] || continue
      line=$(printf '%s' "$line" | jq -c '(.form | fromjson) as $f
             | {dir: ($f.dir // ""), title: ($f.title // ""), prompt: ($f.prompt // ""), token, message_id}')
      mid=$(printf '%s' "$line" | jq -r '.message_id // ""')
      if [ -n "$mid" ] && [ -n "${seen[$mid]:-}" ]; then fs_log "card-dup mid=$mid"; continue; fi
      [ -n "$mid" ] && seen[$mid]=1
      token=$(printf '%s' "$line" | jq -r '.token // ""'); dir=$(printf '%s' "$line" | jq -r '.dir // ""')
      state=creating
      "$LARKSPUR_HOME/card-update.sh" "$token" creating "$dir" >/dev/null 2>&1 || state=update-failed
      printf '飞书卡片提交: %s\n' "$(printf '%s' "$line" | jq -c --arg s "$state" '. + {card:$s}')"
      fs_log "card-submit chat=$chat mid=$mid card=$state" ;;
    *ready\ event_key*) ;;
    *exited*|*\"ok\":false*|*error*|*ERROR*) is_normal_exit "$line" || printf '飞书卡片监听状态: %s\n' "$line" ;;
  esac
done
}
