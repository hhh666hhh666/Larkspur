#!/usr/bin/env bash
# 离线测试 listen-cards.sh 的防重复提交：同一张卡片点两次只放行一次，并且放行前先把卡片改成「正在创建」。
# 另测控制台：点击由脚本处理、归档转给总控、三页都能渲染、保存设置。
# 用法：tests/test-cards.sh   （约 8 秒）
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d); trap 'pkill -f "$TMP/" 2>/dev/null; rm -rf "$TMP"' EXIT
cp "$ROOT"/lib/*.sh "$TMP/"
export LARKSPUR_HOME="$TMP" LARKSPUR_LARK_CLI="$ROOT/tests/fake-lark.sh" \
       LARKSPUR_OPEN_ID="ou_test" LARKSPUR_NET_REFRESH=0 FAKE_LARK_CALLS="$TMP/calls"
chmod +x "$ROOT/tests/fake-lark.sh"
out=$(timeout 20 bash "$TMP/listen-cards.sh" oc_test)
printf '%s\n' "$out"
fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
n=$(printf '%s\n' "$out" | grep -c '^飞书卡片提交:')
check "放行 2 次提交（重复点击被丢弃）" '[ "$n" = 2 ]'
check "第一张卡片用的是第一次点击的 token" 'printf "%s\n" "$out" | grep -q "\"token\":\"tok1\".*\"card\":\"creating\""'
check "重复点击的 token 没有放行" '! printf "%s\n" "$out" | grep -q "\"token\":\"tok2\""'
check "两张卡片各更新一次为正在创建" '[ "$(grep -c "card/update" "$TMP/calls")" = 2 ]'
check "日志记录了重复点击" 'grep -q "card-dup mid=om_card1" "$TMP/larkspur.log"'
# 控制台：点击由脚本处理，不交给 Claude；归档请求转给总控
jq -n '{session_id:"h", desktop_id:"local_h", chat_id:"oc_test", active:true, role:"hub"}' > "$TMP/sessions/h.json"
jq -n '{session_id:"g", desktop_id:"local_g", chat_id:"oc_g", group_name:"G", cwd:"/x", active:true}' > "$TMP/sessions/g.json"
: > "$TMP/calls"
out=$(FAKE_CONSOLE=1 timeout 30 bash "$TMP/listen-cards.sh" oc_test)
check "控制台切页由脚本原地更新卡片" 'grep -q "api PATCH /open-apis/im/v1/messages/om_console" "$TMP/calls" || grep -q "im +messages-send" "$TMP/calls"'
check "控制台点击不会作为卡片提交交给总控" '[ "$(printf "%s\n" "$out" | grep -c "^飞书卡片提交:")" = 2 ]'
check "归档请求转给总控" 'printf "%s\n" "$out" | grep "^飞书控制台请求: " | sed "s/^飞书控制台请求: //" | jq -e ".op==\"archive\" and .desktop_id==\"local_g\"" >/dev/null'
for pg in status sessions net options; do
  check "控制台 $pg 页能渲染" 'bash "$TMP/console.sh" render '"$pg"' | jq -e ".schema==\"2.0\" and (.body.elements|length) > 2" >/dev/null'
done
# 设置保存：写入 config.sh 并校验
echo 'LARKSPUR_ACK_EMOJI="Get"' > "$TMP/config.sh"
bash "$TMP/console.sh" action '{"lk":"c","op":"save"}' '{"ack":"off","wait":"5","backfill":"6","spawn":"none","alerts":"off","prefix":"Bot","root":"/nonexistent"}' >/dev/null 2>&1
check "保存设置写入 config.sh" 'grep -q "^LARKSPUR_ACK_EMOJI=\"\"" "$TMP/config.sh" && grep -q "^LARKSPUR_IMAGE_WAIT=\"5\"" "$TMP/config.sh" && grep -q "^LARKSPUR_GROUP_PREFIX=\"Bot\"" "$TMP/config.sh"'
check "不存在的目录不写入" '! grep -q "nonexistent" "$TMP/config.sh"'
: > "$TMP/calls"
bash "$TMP/console.sh" action '{"lk":"c","op":"set","key":"wait"}' "10" >/dev/null 2>&1
check "单项设置立即写入且不刷新卡片" 'grep -q "^LARKSPUR_IMAGE_WAIT=\"10\"" "$TMP/config.sh" && ! grep -q "api PATCH" "$TMP/calls"'
bash "$TMP/console.sh" action '{"lk":"c","op":"set","key":"root"}' "/nonexistent" >/dev/null 2>&1
check "无效设置不写入，并刷新卡片提示原因" '! grep -q nonexistent "$TMP/config.sh" && grep -q "api PATCH" "$TMP/calls"'
check "控制台四块都是折叠面板，功能选项在面板里" 'bash "$TMP/console.sh" render options | jq -e "[.body.elements[] | select(.tag==\"collapsible_panel\")] | length == 4 and (.[3].expanded == true) and (.[0].expanded == false) and ([.[3].elements[] | select(.tag==\"select_static\")] | length == 5)" >/dev/null'
# 网络检测：用假的检测结果渲染，不联网
cat > "$TMP/run/netcheck.json" <<'J'
{"at":1,"claude":{"ip":"1.2.3.4","cc":"HK","country":"Hong Kong"},"cloudflare":{"ip":"1.2.3.4","cc":"HK"},"cn":{"ip":"5.6.7.8"},
 "restricted":"香港","risk":{"score":90,"residential":false,"asn":1,"vpn":true},"latency":[{"name":"claude.ai","ms":-1}],
 "status":{"indicator":"minor","down":["Claude Code"]},"dns":{"servers":[{"ip":"9.9.9.9","cc":"cn","isp":"X"}],"leak":true}}
J
net=$(bash "$TMP/console.sh" render net | jq -r '.body.elements[] | select(.tag=="collapsible_panel") | select(.expanded) | .header.title.content, (.elements[] | .content // empty)')
check "网络页显示出口 IP、受限地区按 0 分、泄露和故障" 'printf "%s" "$net" | grep -q "1.2.3.4" && printf "%s" "$net" | grep -q "不可访问" && printf "%s" "$net" | grep -q "可能泄露" && printf "%s" "$net" | grep -q "轻微故障" && printf "%s" "$net" | grep -q "<font color=\"red\">0</font>"'
check "没有检测结果时网络页也能渲染" 'rm -f "$TMP/run/netcheck.json"; bash "$TMP/console.sh" render net | jq -e "[.body.elements[] | select(.tag==\"collapsible_panel\")] | length == 4" >/dev/null'
# 定时网络检测：用假的 netcheck.sh 计数，不联网；间隔最短 5 秒；父进程退出后跟着退出
printf '#!/usr/bin/env bash\necho x >> "$LARKSPUR_HOME/nc-calls"\n' > "$TMP/netcheck.sh"; chmod +x "$TMP/netcheck.sh"
rm -f "$TMP/run/console.json"   # 没有控制台卡片时只检测、不刷新，计时不受假接口影响
sleep 8 & ppid_=$!
LARKSPUR_NET_REFRESH=1 bash "$TMP/netwatch.sh" "$ppid_" & wpid=$!
wait "$ppid_"; sleep 5.5
check "每轮都做网络检测（8 秒内 2 次）" '[ "$(wc -l < "$TMP/nc-calls")" = 2 ]'
check "父进程退出后定时检测跟着退出" '! kill -0 "$wpid" 2>/dev/null'
exit $fail
