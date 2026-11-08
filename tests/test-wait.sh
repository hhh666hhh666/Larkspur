#!/usr/bin/env bash
# 离线测试总控按需唤醒：后台等待进程（listen-wait.sh）有事件才以退出码 2 交出、空闲时到期续期、
# 新的顶替旧的、Claude 进程没了或不再是总控时安静退出、中途被杀的事件不丢；以及 hub-wait.sh 钩子只管总控。
# 用法：tests/test-wait.sh   （约 20 秒）
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
cp "$ROOT"/lib/*.sh "$TMP/"; mkdir -p "$TMP/hooks" "$TMP/sessions" "$TMP/run"; cp "$ROOT"/hooks/*.sh "$TMP/hooks/"
chmod +x "$TMP"/*.sh "$TMP"/hooks/*.sh
export LARKSPUR_HOME="$TMP" LARKSPUR_LARK_CLI="$ROOT/tests/fake-lark.sh" LARKSPUR_OPEN_ID=ou_test LARKSPUR_WAIT_CHECK=1
. "$TMP/common.sh"
cleanup() { pkill -f "$TMP/" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
waitfor() { local i; for i in $(seq 1 50); do eval "$1" && return 0; sleep 0.2; done; return 1; }
Q="$TMP/run/hub-queue"
W="$TMP/listen-wait.sh"
jq -n '{session_id:"h", desktop_id:"local_h", chat_id:"oc_h", active:true, role:"hub"}' > "$TMP/sessions/h.json"
jq -n '{session_id:"g", desktop_id:"local_g", chat_id:"oc_g", active:true}' > "$TMP/sessions/g.json"

timeout 5 bash "$W" g local_g 2>/dev/null; r=$?
check "不是总控的会话：直接退出，不登记" '[ $r = 0 ] && [ ! -f "$TMP/run/inbox.pid" ]'

printf '飞书消息（用户，text）: 第一条\n飞书转发: {"to":"local_g"}\n' > "$Q"
err=$(timeout 10 bash "$W" h local_h 2>&1 >/dev/null); r=$?
check "有事件：以退出码 2 一次交出全部事件" '[ $r = 2 ] && printf "%s\n" "$err" | grep -q "^【Larkspur】飞书事件（2 条" && printf "%s\n" "$err" | grep -q "^飞书消息（用户，text）: 第一条$" && printf "%s\n" "$err" | grep -q "^飞书转发: "'
check "交出后队列清空，不留 hub-taken 文件" '[ ! -s "$Q" ] && ! ls "$TMP/run"/hub-taken.* >/dev/null 2>&1'
check "交出后总控处理期间仍算在接收（不会被普通会话误报停了）" '[ ! -f "$TMP/run/inbox.pid" ] && hub_reader_ok'
check "交出超过宽限时间还没回来就算停了" '! LARKSPUR_HANDOFF_GRACE=0 hub_reader_ok'
check "交出时记下了总控的 Claude 进程，状态为处理中" '[ "$(hub_reader_state)" = busy ] && [ "$(wc -w < "$TMP/run/inbox.handoff")" = 2 ]'
dead=$(bash -c 'echo $$'); echo "$(date +%s) $dead" > "$TMP/run/inbox.handoff"
check "总控的 Claude 进程没了（桌面端关了）就算停了，不用等宽限时间" '[ "$(hub_reader_state)" = stopped ]'
export LARKSPUR_DESKTOP_COMM=no-such-desktop
check "飞书卡片：停了且桌面端没开时提示启动桌面端" 'bash "$TMP/console.sh" render status | grep -q "已停止.*启动后总控会自动恢复"'

start=$(date +%s)
err=$(LARKSPUR_WAIT_SECONDS=2 timeout 10 bash "$W" h local_h 2>&1 >/dev/null); r=$?
check "没有事件时一直等着（不调用模型），到期才唤醒一次续期" '[ $r = 2 ] && [ $(( $(date +%s) - start )) -ge 2 ] && printf "%s" "$err" | grep -q "到期续期" && ! printf "%s" "$err" | grep -q "飞书事件"'

bash "$W" h local_h 2> "$TMP/a.err" & A=$!
waitfor '[ "$(cat "$TMP/run/inbox.pid" 2>/dev/null)" = "$A" ]'
check "等待进程登记为总控的事件读取，状态为等待中" 'listener_alive inbox && [ "$(hub_reader_state)" = waiting ]'
check "飞书卡片：总控显示等待中" 'bash "$TMP/console.sh" render status | grep -q "等待中（有消息才唤醒）"'
bash "$W" h local_h 2> "$TMP/b.err" & B=$!
wait "$A"; ra=$?   # A 是本脚本的子进程：先收掉它，B 才看得到它已退出、登记自己
waitfor '[ "$(cat "$TMP/run/inbox.pid" 2>/dev/null)" = "$B" ]'
check "新的等待进程顶替旧的，旧的不唤醒总控" '[ "$ra" != 2 ] && [ "$(cat "$TMP/run/inbox.pid")" = "$B" ] && ! grep -q "飞书事件" "$TMP/a.err"'
echo '飞书消息（用户，text）: 顶替后来的' >> "$Q"
wait "$B"; rb=$?
check "顶替后的那个收到事件并唤醒总控" '[ "$rb" = 2 ] && grep -q "顶替后来的" "$TMP/b.err"'

sleep 300 & SP=$!
LARKSPUR_WAIT_PARENT=$SP bash "$W" h local_h 2>/dev/null & C=$!
waitfor '[ "$(cat "$TMP/run/inbox.pid" 2>/dev/null)" = "$C" ]'
kill "$SP"; wait "$C"; rc=$?
echo '飞书消息（用户，text）: Claude 不在时来的' >> "$Q"; sleep 1.2
check "Claude 进程没了：安静退出，事件留在队列里" '[ $rc = 0 ] && grep -q "Claude 不在时来的" "$Q" && [ ! -f "$TMP/run/inbox.pid" ]'
: > "$Q"

bash "$W" h local_h 2>/dev/null & D=$!
waitfor '[ "$(cat "$TMP/run/inbox.pid" 2>/dev/null)" = "$D" ]'
jq '.active=false' "$TMP/sessions/h.json" > "$TMP/x" && mv "$TMP/x" "$TMP/sessions/h.json"
waitfor '! kill -0 "$D" 2>/dev/null'; wait "$D"; rd=$?
check "总控关闭后等待进程自己退出" '[ $rd = 0 ]'
jq '.active=true' "$TMP/sessions/h.json" > "$TMP/x" && mv "$TMP/x" "$TMP/sessions/h.json"

jq '.session_id="h2"' "$TMP/sessions/h.json" > "$TMP/sessions/h2.json" && rm "$TMP/sessions/h.json"
echo '飞书消息（用户，text）: 换了 ID' >> "$Q"
err=$(timeout 10 bash "$W" h local_h 2>&1 >/dev/null); r=$?
check "总控的会话 ID 变了，按桌面端会话 ID 仍认得" '[ $r = 2 ] && printf "%s" "$err" | grep -q "换了 ID"'
mv "$TMP/sessions/h2.json" "$TMP/sessions/h.json"; jq '.session_id="h"' "$TMP/sessions/h.json" > "$TMP/x" && mv "$TMP/x" "$TMP/sessions/h.json"

dead=$(bash -c 'echo $$'); echo '飞书消息（用户，text）: 被杀前取走的' > "$TMP/run/hub-taken.$dead"
err=$(timeout 10 bash "$W" h local_h 2>&1 >/dev/null); r=$?
check "旧等待进程取走后没交出就被杀：下一个补交，不丢" '[ $r = 2 ] && printf "%s" "$err" | grep -q "被杀前取走的" && [ ! -f "$TMP/run/hub-taken.$dead" ]'

# hub-wait.sh 钩子
rm -f "$TMP/run/inbox.handoff"
timeout 5 bash "$TMP/hooks/hub-wait.sh" <<< '{"session_id":"g"}' 2>/dev/null; r=$?
check "Stop 钩子：普通会话直接退出" '[ $r = 0 ] && [ ! -f "$TMP/run/inbox.pid" ]'
echo '飞书消息（用户，text）: 钩子交的' >> "$Q"
err=$(timeout 10 bash "$TMP/hooks/hub-wait.sh" <<< '{"session_id":"h"}' 2>&1 >/dev/null); r=$?
check "Stop 钩子：总控会话等到事件后唤醒它" '[ $r = 2 ] && printf "%s" "$err" | grep -q "钩子交的"'
echo '飞书消息（用户，text）: 新 ID' >> "$Q"
err=$(CLAUDE_CODE_HOST_SESSION_ID=local_h timeout 10 bash "$TMP/hooks/hub-wait.sh" <<< '{"session_id":"brandnew"}' 2>&1 >/dev/null); r=$?
check "Stop 钩子：总控换了会话 ID 也认得" '[ $r = 2 ] && printf "%s" "$err" | grep -q "新 ID"'

# 普通会话的 Stop 钩子：总控正在处理（刚交出事件）时不误报
bash -c 'exec -a larkspurd-fake sleep 300' & DPID=$!; echo "{\"pid\":$DPID,\"port\":1}" > "$TMP/run/daemon.json"
out=$(printf '{"session_id":"g","stop_hook_active":false}' | bash "$TMP/hooks/ensure-listener.sh")
check "总控刚被唤醒、正在处理时，普通会话不提醒总控" '[ -z "$out" ] && [ ! -f "$TMP/run/hub-nag" ]'
out=$(printf '{"session_id":"h","stop_hook_active":false}' | bash "$TMP/hooks/ensure-listener.sh")
check "总控自己的同步 Stop 钩子不再拦下（接收交给 hub-wait.sh）" '[ -z "$out" ]'
kill "$DPID" 2>/dev/null

# 总控停着时由服务拉起：打开桌面端里的总控会话
mkdir -p "$TMP/bin"; printf '#!/bin/sh\necho "$*" >> "%s/opened"\n' "$TMP" > "$TMP/bin/opener"; chmod +x "$TMP/bin/opener"
cp "$(command -v bash)" "$TMP/bin/fakedesk"; cp "$(command -v bash)" "$TMP/bin/fakeclaude"
export LARKSPUR_OPENER="$TMP/bin/opener" LARKSPUR_DESKTOP_COMM=fakedesk LARKSPUR_CLAUDE_COMM=fakeclaude
rm -f "$TMP/run/inbox.handoff" "$TMP/opened"; : > "$Q"
bash "$TMP/hub-revive.sh"; r=$?
check "拉起总控：队列是空的就不做" '[ $r = 1 ] && [ ! -f "$TMP/opened" ]'
echo '飞书消息（用户，text）: 桌面端重启后发到群里的' >> "$Q"
bash "$TMP/hub-revive.sh"; r=$?
check "拉起总控：桌面端没开时不做（链接会把桌面端启动起来）" '[ $r = 2 ] && [ ! -f "$TMP/opened" ] && grep -q "hub-revive-skipped reason=desktop-not-running" "$TMP/larkspur.log"'
"$TMP/bin/fakedesk" -c "sleep 60; true" & FD=$!; sleep 0.3
LARKSPUR_REVIVE_INTERVAL=0 bash "$TMP/hub-revive.sh" test; r=$?; sleep 0.3
check "拉起总控：桌面端开着就打开总控会话的链接" '[ $r = 0 ] && grep -qx "claude://claude.ai/epitaxy/local_h" "$TMP/opened"'
check "飞书卡片：桌面端开着、总控会话没在运行时，提示会自动拉起" 'bash "$TMP/console.sh" render status | grep -q "已停止.*飞书一来消息就会自动打开总控会话"'
bash "$TMP/hub-revive.sh"; r=$?
check "拉起总控：2 分钟内不重复" '[ $r = 3 ] && [ "$(wc -l < "$TMP/opened")" = 1 ]'
CLAUDE_CODE_HOST_SESSION_ID=local_h "$TMP/bin/fakeclaude" -c "sleep 60; true" & FC=$!; sleep 0.3
LARKSPUR_REVIVE_INTERVAL=0 bash "$TMP/hub-revive.sh"; r=$?
check "拉起总控：总控的 Claude 进程已经在跑时不开链接，只记日志" '[ $r = 2 ] && [ "$(wc -l < "$TMP/opened")" = 1 ] && grep -q "hub-revive-skipped reason=process-running" "$TMP/larkspur.log"'
check "飞书卡片：总控会话开着却没在等事件时，提示去里面发句话" 'bash "$TMP/console.sh" render status | grep -q "已停止.*在它里面随便发一句话即可恢复"'
kill "$FC"
echo "$(date +%s) $$" > "$TMP/run/inbox.handoff"
LARKSPUR_REVIVE_INTERVAL=0 bash "$TMP/hub-revive.sh"; r=$?
check "拉起总控：总控正在处理时不需要" '[ $r = 1 ] && [ "$(wc -l < "$TMP/opened")" = 1 ]'
kill "$FD" 2>/dev/null; rm -f "$TMP/run/inbox.handoff"

out=$(bash "$TMP/listen-inbox.sh"); r=$?
check "旧的 listen-inbox.sh 只说明已改为按需唤醒，不登记、不读队列" '[ $r = 0 ] && printf "%s" "$out" | grep -q "按需唤醒" && [ ! -f "$TMP/run/inbox.pid" ]'
exit $fail
