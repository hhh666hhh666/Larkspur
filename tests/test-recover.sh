#!/usr/bin/env bash
# 离线测试断线恢复：同一个群只留一个监听（新的顶替旧的，连同 lark-cli 子进程）、
# 新监听补发漏掉的消息并按 message_id 去重、监听停了时 Stop 钩子提醒重启且只提醒一次。
# 另测：连上时不输出「就绪」、总控 --with-cards 一路同时输出卡片提交、被杀后不留孤儿进程。
# 另测路由模式：总控按群转发、合并图片、不认识的群不转发、总控停了时提醒。
# 用法：tests/test-recover.sh   （约 25 秒）
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
cp "$ROOT"/lib/*.sh "$TMP/"; mkdir -p "$TMP/hooks"; cp "$ROOT"/hooks/*.sh "$TMP/hooks/"
export LARKSPUR_HOME="$TMP" LARKSPUR_LARK_CLI="$ROOT/tests/fake-lark.sh" LARKSPUR_OPEN_ID="ou_test" LARKSPUR_NET_REFRESH=0 LARKSPUR_HOLD_POLL=1 \
       LARKSPUR_INBOX="$TMP/inbox" LARKSPUR_IMAGE_WAIT=1 FAKE_LARK_MODE=recover
chmod +x "$ROOT/tests/fake-lark.sh"
. "$TMP/common.sh"
cleanup() { for p in "${A:-}" "${B:-}" "${H:-}" "${R:-}"; do [ -n "$p" ] && kill_tree "$p" 2>/dev/null; done; pkill -f "$TMP/" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
waitfor() { local i; for i in $(seq 1 30); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.2; done; return 1; }
tree() { local c; echo "$1"; for c in $(pgrep -P "$1"); do tree "$c"; done; }
hook() { printf '{"session_id":"s1","stop_hook_active":%s}' "${1:-false}" | bash "$TMP/hooks/ensure-listener.sh"; }

jq -n '{session_id:"s1", chat_id:"oc_t", active:true, role:"hub"}' > "$TMP/sessions/s1.json"

bash "$TMP/listen.sh" oc_t --hub > "$TMP/a.out" 2>&1 & A=$!
waitfor "$TMP/a.out" "实时消息"
check "首次启动不补发" '! grep -q "补发" "$TMP/a.out"'
check "连上时不输出就绪" '! grep -q "就绪" "$TMP/a.out"'
check "监听登记了 pid" '[ "$(cat "$TMP/run/oc_t.msg.pid")" = "$A" ]'
check "监听活着时钩子放行" '[ -z "$(hook)" ]'
a_kids=$(tree "$A" | tail -n +2 | tr '\n' ' ')

bash "$TMP/listen.sh" oc_t --hub > "$TMP/b.out" 2>&1 & B=$!
waitfor "$TMP/b.out" "飞书图片"; sleep 1.5
check "旧监听被顶替" '! kill -0 "$A" 2>/dev/null'
check "旧监听的所有子孙进程都被清理（含占 stdin 的进程）" 'for k in $a_kids; do kill -0 $k 2>/dev/null && exit 1; done; true'
check "补发提示为 2 条" 'grep -q "收到 2 条消息" "$TMP/b.out"'
check "补发了中断时的文字和图片" 'grep -q "中断时发的文字" "$TMP/b.out" && grep -q "飞书图片:" "$TMP/b.out"'
check "机器人的消息不补发" '! grep -q "机器人回复" "$TMP/b.out"'
check "已处理的实时消息不重复" '! grep -q "实时消息" "$TMP/b.out"'

kill_tree "$B"; sleep 0.3
out=$(hook)
check "总控监听停了时钩子拦下并给出 --hub 重启命令" 'printf "%s" "$out" | jq -e ".decision==\"block\" and (.reason|contains(\"listen.sh oc_t --hub\"))" >/dev/null'
check "第二次（stop_hook_active）放行" '[ -z "$(hook true)" ]'
# 没有总控时：普通会话不被要求自己监听，只在群里提醒开总控
jq '.role=""' "$TMP/sessions/s1.json" > "$TMP/x" && mv "$TMP/x" "$TMP/sessions/s1.json"
export FAKE_LARK_CALLS="$TMP/calls0"; : > "$TMP/calls0"
check "没有总控时普通会话的钩子不拦" '[ -z "$(hook)" ]'
sleep 0.5
check "没有总控时在群里提醒开总控" 'grep -q "messages-send.*oc_t.*feishu hub" "$TMP/calls0"'
out=$(timeout 5 bash "$TMP/listen.sh" oc_t)
check "没有总控时普通会话的监听也拒绝启动" 'printf "%s" "$out" | grep -q "普通会话不能自己监听" && ! listener_alive oc_t.msg'
unset FAKE_LARK_CALLS
jq '.role="hub"' "$TMP/sessions/s1.json" > "$TMP/x" && mv "$TMP/x" "$TMP/sessions/s1.json"
jq '.active=false' "$TMP/sessions/s1.json" > "$TMP/x" && mv "$TMP/x" "$TMP/sessions/s1.json"
check "同步关闭后钩子放行" '[ -z "$(hook)" ]'
printf '{"session_id":"s1","reason":"other"}' > "$TMP/se"
jq '.active=true' "$TMP/sessions/s1.json" > "$TMP/x" && mv "$TMP/x" "$TMP/sessions/s1.json"
bash "$TMP/hooks/session-end.sh" < "$TMP/se"
check "进程退出时保留同步" '[ "$(jq -r .active "$TMP/sessions/s1.json")" = "true" ]'
# 总控：一路监听同时输出私聊消息和卡片提交
bash "$TMP/listen.sh" oc_h --with-cards > "$TMP/h.out" 2>&1 & H=$!
waitfor "$TMP/h.out" "om_card2"; waitfor "$TMP/h.out" "实时消息"
check "--with-cards 同时输出私聊消息和卡片提交" 'grep -q "实时消息" "$TMP/h.out" && [ "$(grep -c "飞书卡片提交" "$TMP/h.out")" = 2 ]'
check "卡片正常到时退出不打扰" '! grep -q "状态" "$TMP/h.out"'
h_all=$(tree "$H" | tr '\n' ' ')
kill_tree "$H"; sleep 0.5
check "总控监听被杀后不留孤儿进程" 'for k in $h_all; do kill -0 $k 2>/dev/null && exit 1; done; true'
# 桌面端重启：只有监听脚本本身被杀（kill -9），lark-cli 不能变成孤儿继续占着事件
bash "$TMP/listen.sh" oc_k --hub > "$TMP/k.out" 2>&1 & K=$!
waitfor "$TMP/k.out" "实时消息"; sleep 1
k_lark=$(pgrep -f "fake-lark.sh event consume" | while read -r p; do tree "$K" | grep -qx "$p" && echo "$p"; done | tr '\n' ' ')
kill -9 "$K"; sleep 4
check "监听脚本被强杀后，它的 lark-cli 几秒内自己退出（不成孤儿）" '[ -n "$k_lark" ] && ( for k in $k_lark; do kill -0 $k 2>/dev/null && exit 1; done; true )'
pkill -f "$TMP/" 2>/dev/null; sleep 0.3
# 兜底：已经存在的孤儿 lark-cli（就是 $LARK、父进程不是监听脚本、带本人 open_id）在新监听启动时被清掉
orphan() { ( "$ROOT/tests/fake-lark.sh" event consume application.bot.menu_v6 --as bot --timeout 29m \
             --jq "select(.operator_id == \"$1\")" </dev/null >/dev/null 2>&1 & echo $! > "$TMP/$1.pid" ); }
orphan ou_test; orphan ou_other
( bash -c 'sleep 30 # event consume application.bot.menu_v6 ou_test' & echo $! > "$TMP/decoy.pid" )
sleep 0.3; op=$(cat "$TMP/ou_test.pid"); xp=$(cat "$TMP/ou_other.pid"); dp=$(cat "$TMP/decoy.pid")
timeout 3 bash "$TMP/listen-menu.sh" >/dev/null 2>&1
check "新监听启动时清掉上一轮的孤儿 lark-cli" '! kill -0 "$op" 2>/dev/null && grep -q "orphan-reaped key=application.bot.menu_v6" "$TMP/larkspur.log"'
check "不动别人的 lark-cli，也不动只是命令行里提到它的进程" 'kill -0 "$xp" 2>/dev/null && kill -0 "$dp" 2>/dev/null'
kill "$xp" "$dp" 2>/dev/null
# ---- 会话换了新 ID：按桌面端会话 ID 找回记录并迁移 ----
jq -n '{session_id:"old1", desktop_id:"local_d1", chat_id:"oc_m", active:true}' > "$TMP/sessions/old1.json"
f=$(CLAUDE_CODE_SESSION_ID=new1 CLAUDE_CODE_HOST_SESSION_ID=local_d1 bash -c '. "$LARKSPUR_HOME/common.sh"; resolve_state new1')
check "换了会话 ID 后按桌面端 ID 迁移记录" '[ -f "$TMP/sessions/new1.json" ] && [ ! -f "$TMP/sessions/old1.json" ] && [ "$(jq -r .session_id "$TMP/sessions/new1.json")" = new1 ]'
f=$(CLAUDE_CODE_SESSION_ID=hubsid CLAUDE_CODE_HOST_SESSION_ID=local_d1 bash -c '. "$LARKSPUR_HOME/common.sh"; resolve_state other')
check "查的不是当前会话时不迁移" '[ -f "$TMP/sessions/new1.json" ] && [ ! -f "$TMP/sessions/other.json" ]'
rm -f "$TMP/sessions/new1.json"
# 总控用 claude -p 新建会话：子会话继承了总控的桌面端 ID，它的钩子不能把总控的记录迁走
jq -n '{session_id:"hubsid", desktop_id:"local_hub", chat_id:"oc_dm", active:true, role:"hub"}' > "$TMP/sessions/hubsid.json"
# 用 exec -a claude 模拟「在总控 shell 里启动的 claude 进程」，它的环境带着总控的会话 ID
CLAUDE_CODE_SESSION_ID=hubsid CLAUDE_CODE_HOST_SESSION_ID=local_hub bash -c \
  'exec -a claude bash -c "CLAUDE_CODE_SESSION_ID=child1 bash -c \". \\\"\$LARKSPUR_HOME/common.sh\\\"; resolve_state child1\" >/dev/null; true"'
check "嵌在总控里的子会话不迁走总控记录" '[ -f "$TMP/sessions/hubsid.json" ] && [ ! -f "$TMP/sessions/child1.json" ] && grep -q "state-migrate-skipped.*reason=nested" "$TMP/larkspur.log"'
# 同时触发的两个钩子只迁一次，记录完好
jq -n '{session_id:"old2", desktop_id:"local_d2", chat_id:"oc_m2", active:true}' > "$TMP/sessions/old2.json"
for i in 1 2 3; do CLAUDE_CODE_SESSION_ID=new2 CLAUDE_CODE_HOST_SESSION_ID=local_d2 bash -c '. "$LARKSPUR_HOME/common.sh"; resolve_state new2' >/dev/null & done; wait
check "并发迁移只迁一次且记录完好" '[ "$(grep -c "state-migrated old=old2" "$TMP/larkspur.log")" = 1 ] && [ "$(jq -r .chat_id "$TMP/sessions/new2.json")" = oc_m2 ] && ! ls "$TMP"/sessions/*.claim.* "$TMP"/sessions/*.tmp.* 2>/dev/null | grep -q .'
rm -f "$TMP/sessions/hubsid.json" "$TMP/sessions/new2.json"

# ---- 路由模式 ----
rm -f "$TMP"/sessions/*.json "$TMP"/run/*
jq -n '{session_id:"h", desktop_id:"local_h", chat_id:"oc_h", active:true, role:"hub"}' > "$TMP/sessions/h.json"
jq -n '{session_id:"g", desktop_id:"local_g", chat_id:"oc_g", group_name:"G", active:true}' > "$TMP/sessions/g.json"
out=$(timeout 5 bash "$TMP/listen.sh" oc_g)
check "有总控时普通会话的监听直接退出" 'printf "%s" "$out" | grep -q "总控已接管"'
bash -c 'exec -a listen-old-session sleep 300' & OLD=$!; echo "$OLD" > "$TMP/run/oc_g.msg.pid"
export FAKE_LARK_CALLS="$TMP/calls"; : > "$TMP/calls"
FAKE_LARK_MODE=router bash "$TMP/listen.sh" oc_h --hub > "$TMP/r.out" 2>&1 & R=$!
waitfor "$TMP/r.out" "只发了图片"
r() { grep '^飞书转发: ' "$TMP/r.out" | sed 's/^飞书转发: //' | sed -n "${1}p"; }
check "总控启动时停掉会话自己的旧监听" '! kill -0 "$OLD" 2>/dev/null && [ ! -f "$TMP/run/oc_g.msg.pid" ]'
check "私聊消息照常输出给总控" 'grep -q "^飞书消息（用户，text）: 私聊里的话" "$TMP/r.out"'
check "群消息转发给对应会话" '[ "$(r 1 | jq -r .to)" = local_g ] && [ "$(r 1 | jq -r .chat)" = oc_g ]'
check "转发保留原文换行并带【飞书】前缀" '[ "$(r 1 | jq -r .message)" = "$(printf "【飞书】群里第一行\n第二行")" ]'
check "图片和随后的文字合成一条转发" 'r 2 | jq -e ".message | startswith(\"【飞书】这张图是什么\") and contains(\"[图片] \")" >/dev/null'
check "不认识的群不转发" '! grep -q "不认识的群" "$TMP/r.out"'
check "只发图片时超时后单独转发" 'r 3 | jq -e ".message | contains(\"只发了图片\") and contains(\"[图片] \")" >/dev/null'
check "一共转发 3 条" '[ "$(grep -c "^飞书转发: " "$TMP/r.out")" = 3 ]'
check "放行的 5 条消息都加了「了解」表情，不认识的群不加" '[ "$(grep -c "reactions create.*emoji_type\\\":\\\"Get" "$TMP/calls")" = 5 ] && ! grep -q om_r5 "$TMP/calls"'
kill_tree "$R"; sleep 0.3
hk() { printf '{"session_id":"g","stop_hook_active":false}' | bash "$TMP/hooks/ensure-listener.sh"; }
out=$(hk)
check "总控监听停了时，普通会话被要求提醒总控" 'printf "%s" "$out" | jq -e ".decision==\"block\" and (.reason|contains(\"local_h\"))" >/dev/null'
check "5 分钟内不重复提醒" '[ -z "$(hk)" ]'
exit $fail
