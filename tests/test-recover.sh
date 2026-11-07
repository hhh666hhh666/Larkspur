#!/usr/bin/env bash
# 离线测试断线恢复：同一个群只留一个监听（新的顶替旧的，连同 lark-cli 子进程）、
# 新监听补发漏掉的消息并按 message_id 去重、监听停了时 Stop 钩子提醒重启且只提醒一次。
# 用法：tests/test-recover.sh   （约 10 秒）
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
cp "$ROOT"/lib/*.sh "$TMP/"; mkdir -p "$TMP/hooks"; cp "$ROOT"/hooks/*.sh "$TMP/hooks/"
export LARKSPUR_HOME="$TMP" LARKSPUR_LARK_CLI="$ROOT/tests/fake-lark.sh" LARKSPUR_OPEN_ID="ou_test" \
       LARKSPUR_INBOX="$TMP/inbox" LARKSPUR_IMAGE_WAIT=1 FAKE_LARK_MODE=recover
chmod +x "$ROOT/tests/fake-lark.sh"
. "$TMP/common.sh"
cleanup() { for p in "${A:-}" "${B:-}"; do [ -n "$p" ] && kill_tree "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
waitfor() { local i; for i in $(seq 1 30); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.2; done; return 1; }
hook() { printf '{"session_id":"s1","stop_hook_active":%s}' "${1:-false}" | bash "$TMP/hooks/ensure-listener.sh"; }

jq -n '{session_id:"s1", chat_id:"oc_t", active:true, role:""}' > "$TMP/sessions/s1.json"

bash "$TMP/listen.sh" oc_t > "$TMP/a.out" 2>&1 & A=$!
waitfor "$TMP/a.out" "实时消息"
check "首次启动不补发" '! grep -q "补发" "$TMP/a.out"'
check "监听登记了 pid" '[ "$(cat "$TMP/run/oc_t.msg.pid")" = "$A" ]'
check "监听活着时钩子放行" '[ -z "$(hook)" ]'
a_kids=$(pgrep -P "$A" | tr '\n' ' ')

bash "$TMP/listen.sh" oc_t > "$TMP/b.out" 2>&1 & B=$!
waitfor "$TMP/b.out" "飞书图片"; sleep 1.5
check "旧监听被顶替" '! kill -0 "$A" 2>/dev/null'
check "旧监听的子进程也被清理" 'for k in $a_kids; do kill -0 $k 2>/dev/null && exit 1; done; true'
check "补发提示为 2 条" 'grep -q "收到 2 条消息" "$TMP/b.out"'
check "补发了中断时的文字和图片" 'grep -q "中断时发的文字" "$TMP/b.out" && grep -q "飞书图片:" "$TMP/b.out"'
check "机器人的消息不补发" '! grep -q "机器人回复" "$TMP/b.out"'
check "已处理的实时消息不重复" '! grep -q "实时消息" "$TMP/b.out"'

kill_tree "$B"; sleep 0.3
out=$(hook)
check "监听停了时钩子拦下并给出重启命令" 'printf "%s" "$out" | jq -e ".decision==\"block\" and (.reason|contains(\"listen.sh oc_t\"))" >/dev/null'
check "第二次（stop_hook_active）放行" '[ -z "$(hook true)" ]'
jq '.role="hub"' "$TMP/sessions/s1.json" > "$TMP/x" && mv "$TMP/x" "$TMP/sessions/s1.json"
check "总控同时提醒卡片监听" 'hook | jq -e ".reason|contains(\"listen-cards.sh oc_t\")" >/dev/null'
jq '.active=false' "$TMP/sessions/s1.json" > "$TMP/x" && mv "$TMP/x" "$TMP/sessions/s1.json"
check "同步关闭后钩子放行" '[ -z "$(hook)" ]'
printf '{"session_id":"s1","reason":"other"}' > "$TMP/se"
jq '.active=true' "$TMP/sessions/s1.json" > "$TMP/x" && mv "$TMP/x" "$TMP/sessions/s1.json"
bash "$TMP/hooks/session-end.sh" < "$TMP/se"
check "进程退出时保留同步" '[ "$(jq -r .active "$TMP/sessions/s1.json")" = "true" ]'
exit $fail
