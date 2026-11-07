#!/usr/bin/env bash
# 用法：listen-menu.sh [父进程 pid]
# 总控用：监听机器人自定义菜单的点击。事件键为 console 的菜单项会打开（必要时重发并置顶）控制台卡片。
# 由 listen.sh <chat_id> --hub 在后台拉起，父进程退出时跟着退出；不输出任何事件，不唤醒 Claude。
# lark-cli 中途断开（例如刚在后台订阅事件、版本还没生效）时，每分钟重试一次。
# 需要在飞书开放平台的「机器人 → 机器人自定义菜单」里添加一个「推送事件」类型的菜单项，事件 ID 填 console，
# 并在「事件与回调」里订阅 application.bot.menu_v6，然后发布版本。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"
require_open_id

parent="${1:-}"
claim_listener "menu"
end=$(( $(date +%s) + 29 * 60 ))
alive() { [ "$(date +%s)" -lt "$end" ] && { [ -z "$parent" ] || kill -0 "$parent" 2>/dev/null; }; }

while alive; do
  started=$(date +%s)
  "$LARK" event consume application.bot.menu_v6 --as bot --timeout "$(( (end - started) / 60 + 1 ))m" \
    --jq "select((.operator_open_id // .operator_id) == \"$OPEN_ID\") | {key: .event_key}" \
    < <(hold_stdin $$) 2>&1 |
  while IFS= read -r line; do
    case "$line" in
      \{\"key\"*) key=$(printf '%s' "$line" | jq -r '.key // ""'); fs_log "menu key=$key"
           case "$key" in console|控制台) "$LARKSPUR_HOME/console.sh" show none >/dev/null 2>&1 ;; esac ;;
      *exited*|*\"ok\":false*|*error*|*ERROR*) is_normal_exit "$line" || fs_log "menu-listener ${line:0:120}" ;;
    esac
  done
  [ $(( $(date +%s) - started )) -lt 60 ] && alive && sleep 60
done
