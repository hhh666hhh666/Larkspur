#!/usr/bin/env bash
# 离线测试常驻服务 larkspurd 和本地网页控制台：用假 lark-cli，网页端口由系统随机分配，不碰真的服务。
# 用法：tests/test-daemon.sh   （约 20 秒）
set -u
unset LARKSPUR_DAEMON   # 测试在服务拉起的桌面端里运行时会带着它
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
cp "$ROOT"/lib/*.sh "$ROOT"/lib/larkspurd.py "$TMP/"; mkdir -p "$TMP/web" "$TMP/sessions"; cp "$ROOT"/lib/web/index.html "$TMP/web/"
chmod +x "$TMP"/*.sh "$ROOT/tests/fake-lark.sh"
export LARKSPUR_HOME="$TMP" LARKSPUR_LARK_CLI="$ROOT/tests/fake-lark.sh" LARKSPUR_OPEN_ID=ou_test LARKSPUR_NO_SYSTEMD=1 \
       LARKSPUR_INBOX="$TMP/inbox" LARKSPUR_IMAGE_WAIT=1 FAKE_LARK_MODE=router FAKE_LARK_CALLS="$TMP/calls" LARKSPUR_HOLD_POLL=1
printf 'LARKSPUR_WEB_PORT="0"\nLARKSPUR_NET_REFRESH="0"\n' > "$TMP/config.sh"
# 服务会尝试拉起停着的总控：换成假的桌面端进程名和假的链接打开程序，绝不碰真的桌面端
mkdir -p "$TMP/bin"; printf '#!/bin/sh\necho "$*" >> "%s/opened"\n' "$TMP" > "$TMP/bin/opener"; chmod +x "$TMP/bin/opener"
export LARKSPUR_DESKTOP_COMM=fakedesk LARKSPUR_OPENER="$TMP/bin/opener"
. "$TMP/common.sh"
cleanup() { "$TMP/larkspurctl.sh" stop >/dev/null 2>&1; pkill -f "$TMP/" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
waitfor() { local i; for i in $(seq 1 50); do eval "$1" && return 0; sleep 0.2; done; return 1; }
jq -n '{session_id:"h", desktop_id:"local_h", chat_id:"oc_h", active:true, role:"hub"}' > "$TMP/sessions/h.json"
jq -n '{session_id:"0123456789ab", desktop_id:"local_g", chat_id:"oc_g", group_name:"G", cwd:"/x", active:true}' > "$TMP/sessions/0123456789ab.json"

out=$("$TMP/larkspurctl.sh" start)
P=$(jq -r .port "$TMP/run/daemon.json" 2>/dev/null)
U="http://localhost:$P"
check "larkspurctl start 启动服务并报告网页地址" 'daemon_alive && printf "%s" "$out" | grep -q "http://localhost:$P/"'
out2=$(python3 "$TMP/larkspurd.py")
check "同时只运行一个：再启动一次直接说已在运行" 'printf "%s" "$out2" | grep -q "已在运行"'
waitfor 'grep -q "只发了图片" "$TMP/run/hub-queue" 2>/dev/null'
waitfor 'grep -q "hub-revive-skipped reason=desktop-not-running" "$TMP/larkspur.log"'
check "总控停着而队列里有事件时，服务尝试拉起总控（桌面端没开就不做，不会把它启动起来）" 'grep -q "hub-revive-skipped reason=desktop-not-running" "$TMP/larkspur.log" && [ ! -f "$TMP/opened" ]'
check "飞书事件写进给总控的队列（私聊消息、卡片提交、群消息转发）" 'grep -q "^飞书消息（用户，text）: 私聊里的话" "$TMP/run/hub-queue" && grep -q "^飞书卡片提交: " "$TMP/run/hub-queue" && [ "$(grep -c "^飞书转发: " "$TMP/run/hub-queue")" = 3 ]'
in=$(LARKSPUR_WAIT_SECONDS=3 bash "$TMP/listen-wait.sh" h local_h 2>&1 >/dev/null); r=$?
check "总控按需唤醒：以退出码 2 原样交出全部事件后清空队列" '[ $r = 2 ] && [ "$(printf "%s\n" "$in" | grep -c "^飞书转发: ")" = 3 ] && [ ! -s "$TMP/run/hub-queue" ]'
in=$(LARKSPUR_WAIT_SECONDS=2 bash "$TMP/listen-wait.sh" h local_h 2>&1 >/dev/null)
check "交过的事件不会再交一次" '! printf "%s" "$in" | grep -q "^飞书"'

st=$(curl -s "$U/api/state")
check "网页：状态接口有服务、监听和会话信息" 'printf "%s" "$st" | jq -e ".daemon.listener == true and .daemon.hub_chat == \"oc_h\" and (.sessions | length) == 2" >/dev/null'
check "网页：首页能打开" '[ "$(curl -s -o /dev/null -w "%{http_code}" "$U/")" = 200 ] && curl -s "$U/" | grep -q "Larkspur 控制台"'
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
check "安全：不带 X-Larkspur 头的写请求被拒绝（防别的网页偷偷关软件）" '[ "$(code -X POST "$U/api/stop" -d "{}")" = 403 ]'
check "安全：Origin 是别的网站时被拒绝" '[ "$(code -X POST -H "X-Larkspur: 1" -H "Origin: http://evil.example" "$U/api/stop" -d "{}")" = 403 ]'
check "安全：Host 不是 localhost 时被拒绝（防 DNS 重绑定）" '[ "$(code -H "Host: evil.example" "$U/api/state")" = 403 ]'
check "安全：只监听 127.0.0.1" 'ss -ltn 2>/dev/null | grep -q "127.0.0.1:$P " && ! ss -ltn 2>/dev/null | grep -q "0.0.0.0:$P "'
post() { curl -s -X POST -H "X-Larkspur: 1" -H "Content-Type: application/json" "$U$1" -d "$2"; }
r=$(post /api/config '{"key":"gate","value":"off"}')
check "网页：开关启动闸门写进 config.sh" 'printf "%s" "$r" | jq -e .ok >/dev/null && grep -q "^LARKSPUR_DESKTOP_GATE=\"off\"" "$TMP/config.sh"'
r=$(post /api/config '{"key":"expip","value":"1.2.3"}')
check "网页：无效的期望 IP 不保存，并说明原因" 'printf "%s" "$r" | jq -e ".ok == false and (.error | contains(\"IPv4\"))" >/dev/null && ! grep -q "1.2.3\"" "$TMP/config.sh"'
r=$(post /api/config '{"key":"open_id","value":"x"}')
check "网页：不在白名单里的配置项不能改" 'printf "%s" "$r" | jq -e ".ok == false" >/dev/null'
r=$(post /api/session/off '{"sid":"0123456789ab"}')
check "网页：关闭会话同步" 'printf "%s" "$r" | jq -e .ok >/dev/null && [ "$(jq -r .active "$TMP/sessions/0123456789ab.json")" = false ]'

lp=$(cat "$TMP/run/oc_h.msg.pid"); kill -9 "$lp"
waitfor '[ "$(cat "$TMP/run/oc_h.msg.pid" 2>/dev/null)" != "$lp" ] && listener_alive oc_h.msg'
check "飞书监听意外退出后服务自动重启它" 'listener_alive oc_h.msg && [ "$(curl -s "$U/api/state" | jq .daemon.listener_restarts)" -ge 1 ]'
jq '.active=false' "$TMP/sessions/h.json" > "$TMP/x" && mv "$TMP/x" "$TMP/sessions/h.json"
waitfor '! listener_alive oc_h.msg'
check "总控关闭后服务停掉飞书监听" '! listener_alive oc_h.msg'
jq '.active=true' "$TMP/sessions/h.json" > "$TMP/x" && mv "$TMP/x" "$TMP/sessions/h.json"
waitfor 'listener_alive oc_h.msg'

# 桌面端只能手动启动：按钮经过启动器启动它；已在运行时不重复启动；关掉 Larkspur 不连带关掉它
mkdir -p "$TMP/bin"; cp "$(command -v bash)" "$TMP/bin/fakedesk"   # 假桌面端：进程名为 fakedesk（sleep 可能是 coreutils 多合一程序，改名后不能运行）
printf '#!/usr/bin/env bash\necho "$*" >> "%s/desk-launched"\necho "daemon-env:${LARKSPUR_DAEMON:-none}" >> "%s/desk-launched"\nexec "%s/bin/fakedesk" -c "sleep 120; true"\n' "$TMP" "$TMP" "$TMP" > "$TMP/bin/launcher"; chmod +x "$TMP/bin/launcher"
export LARKSPUR_DESKTOP_COMM=fakedesk LARKSPUR_DESKTOP_LAUNCHER="$TMP/bin/launcher"
"$TMP/larkspurctl.sh" restart >/dev/null; P=$(jq -r .port "$TMP/run/daemon.json"); U="http://localhost:$P"
check "桌面端没在运行时状态显示没在运行，飞书卡片上有「启动桌面端」按钮" '[ "$(curl -s "$U/api/state" | jq -r .desktop)" = stopped ] && bash "$TMP/console.sh" render status | grep -q "启动桌面端"'
r=$(post /api/desktop/start '{}')
waitfor '[ "$(desktop_state)" = running ]'
check "网页：点「启动桌面端」后桌面端启动" 'printf "%s" "$r" | jq -e .ok >/dev/null && [ "$(desktop_state)" = running ] && grep -q "desktop-start source=web" "$TMP/larkspur.log"'
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Larkspur: 1" "$U/api/desktop/start" -d '{}')
check "已在运行时不会再启动一个" '[ "$code" = 409 ] && [ "$(grep -c "^daemon-env:" "$TMP/desk-launched")" = 1 ]'
check "桌面端在运行时飞书卡片上没有启动按钮" '! bash "$TMP/console.sh" render status | grep -q "启动桌面端"'
dk=$(pgrep -x fakedesk | head -1)
"$TMP/larkspurctl.sh" restart >/dev/null; P=$(jq -r .port "$TMP/run/daemon.json"); U="http://localhost:$P"
check "关掉或重启 Larkspur 不会连带关掉桌面端" 'kill -0 "$dk" 2>/dev/null'
kill "$dk"; waitfor '[ "$(desktop_state)" = stopped ]'
sleep 3
check "桌面端退出后不会被自动拉起" '[ "$(desktop_state)" = stopped ] && [ "$(grep -c "^daemon-env:" "$TMP/desk-launched")" = 1 ]'
: > "$TMP/calls"; bash "$TMP/console.sh" action '{"lk":"c","op":"desktop"}' >/dev/null 2>&1
waitfor '[ "$(desktop_state)" = running ]'
check "飞书卡片：点「启动桌面端」后桌面端启动，卡片提示正在启动" '[ "$(desktop_state)" = running ] && grep -q "desktop-start source=feishu" "$TMP/larkspur.log" && grep -qE "api PATCH|messages-send" "$TMP/calls"'
check "从飞书卡片启动的桌面端不继承服务监听进程的 LARKSPUR_DAEMON" '! grep -q "daemon-env:1" "$TMP/desk-launched" && grep -q "daemon-env:none" "$TMP/desk-launched"'
pkill -x fakedesk
lp=$(cat "$TMP/run/oc_h.msg.pid")
out=$(timeout 5 bash "$TMP/listen.sh" oc_h --hub)
check "服务在跑时，总控旧的 Monitor 再起 listen.sh 不会顶替服务的监听，并告诉总控不再需要 Monitor" 'printf "%s" "$out" | grep -q "按需唤醒" && [ "$(cat "$TMP/run/oc_h.msg.pid")" = "$lp" ] && listener_alive oc_h.msg'
dp=$(jq -r .pid "$TMP/run/daemon.json")
r=$(post /api/stop '{}')
waitfor '! kill -0 "$dp" 2>/dev/null'
sleep 1.5
check "网页：关闭 Larkspur 后服务退出" 'printf "%s" "$r" | jq -e .ok >/dev/null && ! kill -0 "$dp" 2>/dev/null && ! daemon_alive'
left=$(ps -eo args | grep -E "$TMP/|fake-lark.sh event" | grep -v grep | grep -c . )
check "关闭后不留任何子进程（监听、lark-cli、网络检测）" '[ "$left" = 0 ]'
check "日志记下了启动和关闭" 'grep -q "daemon-start" "$TMP/larkspur.log" && grep -q "daemon-stop source=web" "$TMP/larkspur.log"'
out=$("$TMP/larkspurctl.sh" status); rc=$?
check "larkspurctl status：没在运行" '[ $rc = 3 ] && printf "%s" "$out" | grep -q "没在运行"'
# 随机高位端口：第一次随机挑一个并记进 config.sh，重启后还用它；被占用时重新挑
sed -i '/^LARKSPUR_WEB_PORT=/d' "$TMP/config.sh"
"$TMP/larkspurctl.sh" start >/dev/null; P1=$(jq -r .port "$TMP/run/daemon.json")
check "没设端口时随机挑一个 20000～60999 的高位端口" '[ "$P1" -ge 20000 ] && [ "$P1" -le 60999 ] && [ "$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$P1/")" = 200 ]'
check "随机端口记进了 config.sh" 'grep -q "^LARKSPUR_WEB_PORT=\"$P1\"" "$TMP/config.sh"'
"$TMP/larkspurctl.sh" restart >/dev/null; P2=$(jq -r .port "$TMP/run/daemon.json")
check "重启后还用同一个端口（网址不变）" '[ "$P2" = "$P1" ]'
"$TMP/larkspurctl.sh" stop >/dev/null
python3 -c "import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind((\"127.0.0.1\", $P1)); s.listen(); time.sleep(8)" & BLK=$!; sleep 0.5
"$TMP/larkspurctl.sh" start >/dev/null; P3=$(jq -r .port "$TMP/run/daemon.json")
check "记住的端口被占用时换一个新的随机端口、记下并提示" '[ "$P3" != "$P1" ] && grep -q "^LARKSPUR_WEB_PORT=\"$P3\"" "$TMP/config.sh" && curl -s "http://localhost:$P3/api/state" | jq -e ".daemon.port_note | contains(\"$P1\")" >/dev/null'
"$TMP/larkspurctl.sh" stop >/dev/null; kill "$BLK" 2>/dev/null
exit $fail
