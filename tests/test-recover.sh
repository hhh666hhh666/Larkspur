#!/usr/bin/env bash
# 离线测试断线恢复：同一个群只留一个监听（新的顶替旧的，连同 lark-cli 子进程）、
# 新监听补发漏掉的消息并按 message_id 去重、监听停了时 Stop 钩子提醒重启且只提醒一次。
# 另测：连上时不输出「就绪」、总控 --with-cards 一路同时输出卡片提交、被杀后不留孤儿进程。
# 用法：tests/test-recover.sh   （约 15 秒）
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
cp "$ROOT"/lib/*.sh "$TMP/"; mkdir -p "$TMP/hooks"; cp "$ROOT"/hooks/*.sh "$TMP/hooks/"
export LARKSPUR_HOME="$TMP" LARKSPUR_LARK_CLI="$ROOT/tests/fake-lark.sh" LARKSPUR_OPEN_ID="ou_test" \
       LARKSPUR_INBOX="$TMP/inbox" LARKSPUR_IMAGE_WAIT=1 FAKE_LARK_MODE=recover
chmod +x "$ROOT/tests/fake-lark.sh"
. "$TMP/common.sh"
cleanup() { for p in "${A:-}" "${B:-}" "${H:-}"; do [ -n "$p" ] && kill_tree "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
waitfor() { local i; for i in $(seq 1 30); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.2; done; return 1; }
tree() { local c; echo "$1"; for c in $(pgrep -P "$1"); do tree "$c"; done; }
hook() { printf '{"session_id":"s1","stop_hook_active":%s}' "${1:-false}" | bash "$TMP/hooks/ensure-listener.sh"; }

jq -n '{session_id:"s1", chat_id:"oc_t", active:true, role:""}' > "$TMP/sessions/s1.json"

bash "$TMP/listen.sh" oc_t > "$TMP/a.out" 2>&1 & A=$!
waitfor "$TMP/a.out" "实时消息"
check "首次启动不补发" '! grep -q "补发" "$TMP/a.out"'
check "连上时不输出就绪" '! grep -q "就绪" "$TMP/a.out"'
check "监听登记了 pid" '[ "$(cat "$TMP/run/oc_t.msg.pid")" = "$A" ]'
check "监听活着时钩子放行" '[ -z "$(hook)" ]'
a_kids=$(tree "$A" | tail -n +2 | tr '\n' ' ')

bash "$TMP/listen.sh" oc_t > "$TMP/b.out" 2>&1 & B=$!
waitfor "$TMP/b.out" "飞书图片"; sleep 1.5
check "旧监听被顶替" '! kill -0 "$A" 2>/dev/null'
check "旧监听的所有子孙进程都被清理（含占 stdin 的进程）" 'for k in $a_kids; do kill -0 $k 2>/dev/null && exit 1; done; true'
check "补发提示为 2 条" 'grep -q "收到 2 条消息" "$TMP/b.out"'
check "补发了中断时的文字和图片" 'grep -q "中断时发的文字" "$TMP/b.out" && grep -q "飞书图片:" "$TMP/b.out"'
check "机器人的消息不补发" '! grep -q "机器人回复" "$TMP/b.out"'
check "已处理的实时消息不重复" '! grep -q "实时消息" "$TMP/b.out"'

kill_tree "$B"; sleep 0.3
out=$(hook)
check "监听停了时钩子拦下并给出重启命令" 'printf "%s" "$out" | jq -e ".decision==\"block\" and (.reason|contains(\"listen.sh oc_t\"))" >/dev/null'
check "第二次（stop_hook_active）放行" '[ -z "$(hook true)" ]'
jq '.role="hub"' "$TMP/sessions/s1.json" > "$TMP/x" && mv "$TMP/x" "$TMP/sessions/s1.json"
check "总控提醒用 --with-cards 重启" 'hook | jq -e ".reason|contains(\"listen.sh oc_t --with-cards\")" >/dev/null'
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
exit $fail
