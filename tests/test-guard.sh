#!/usr/bin/env bash
# 离线测试 IP 守卫、桌面端启动闸门和总控自动启动：用假的 curl 返回指定的出口 IP，不联网。
# 用法：tests/test-guard.sh   （约 15 秒）
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d); trap 'pkill -f "$TMP/" 2>/dev/null; rm -rf "$TMP"' EXIT
cp "$ROOT"/lib/*.sh "$ROOT"/hooks/*.sh "$TMP/"; chmod +x "$TMP"/*.sh
mkdir -p "$TMP/bin" "$TMP/realbin"
# 假 curl：按网址返回 FAKE_CN / FAKE_CF / FAKE_CLAUDE（为空表示查不到），每次调用记一行
cat > "$TMP/bin/curl" <<'C'
#!/usr/bin/env bash
echo "$*" >> "$LARKSPUR_HOME/curl-calls"
for a in "$@"; do case "$a" in
  *myip.ipip.net*) [ -n "${FAKE_CN:-}" ] && printf '{"ret":"ok","data":{"ip":"%s"}}' "$FAKE_CN"; exit 0 ;;
  *1.1.1.1*)       [ -n "${FAKE_CF:-}" ] && printf 'fl=1\nip=%s\nloc=US\n' "$FAKE_CF"; exit 0 ;;
  *claude.ai*)     [ -n "${FAKE_CLAUDE:-}" ] && printf 'fl=1\nip=%s\nloc=US\n' "$FAKE_CLAUDE"; exit 0 ;;
esac; done
exit 7
C
# 假的守卫命令：记下收到的 stdin；假的桌面端：记下参数
printf '#!/usr/bin/env bash\nread -r a; echo "ran:$a" >> "%s/guard-ran"\n' "$TMP" > "$TMP/guard.sh"
printf '#!/usr/bin/env bash\necho "desktop:$*" >> "%s/desktop-ran"\n' "$TMP" > "$TMP/realbin/claude-desktop"
cp "$TMP/desktop-gate.sh" "$TMP/bin/claude-desktop"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/notify-send"   # 不弹真的桌面通知
chmod +x "$TMP/bin/"* "$TMP/guard.sh" "$TMP/realbin/claude-desktop"
export PATH="$TMP/bin:$TMP/realbin:$PATH" LARKSPUR_HOME="$TMP" LARKSPUR_LARK_CLI="$ROOT/tests/fake-lark.sh" \
       LARKSPUR_OPEN_ID=ou_test LARKSPUR_NET_REFRESH=0 FAKE_LARK_CALLS="$TMP/calls"
E=203.0.113.7   # 文档保留地址，测试用
printf 'LARKSPUR_EXPECTED_IP="%s"\nLARKSPUR_IP_GUARD_CMD="%s"\nLARKSPUR_DESKTOP_GATE_WAIT="0"\n' "$E" "$TMP/guard.sh" > "$TMP/config.sh"
fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
ok() { export FAKE_CN=$E FAKE_CF=$E FAKE_CLAUDE=$E; }
reset() { rm -f "$TMP/guard-ran" "$TMP/desktop-ran" "$TMP/run/ipguard.fired" "$TMP/curl-calls"; ok; }

reset; bash "$TMP/exit-ips.sh" $E >/dev/null; r=$?
check "三个出口都相符时通过" '[ $r = 0 ]'
reset; FAKE_CF=1.2.3.4 bash "$TMP/exit-ips.sh" $E >/dev/null; r=$?
check "Cloudflare 出口不符时判为不符" '[ $r = 1 ]'
reset; FAKE_CN="" bash "$TMP/exit-ips.sh" $E >/dev/null; r=$?
check "国内出口查不到时判为无法确定" '[ $r = 2 ]'

reset; bash "$TMP/ipguard.sh"; r=$?
check "IP 相符时守卫不动手" '[ $r = 0 ] && [ ! -f "$TMP/guard-ran" ]'
reset; FAKE_CN=9.9.9.9 bash "$TMP/ipguard.sh"; r=$?; sleep 1
check "国内出口不符时运行守卫命令，并给它回答 y" '[ $r = 3 ] && grep -q "^ran:y$" "$TMP/guard-ran"'
check "动手前在总控私聊提醒、并记日志" 'grep -q "ipguard-mismatch" "$TMP/larkspur.log"'
reset; FAKE_CLAUDE="" FAKE_CF="" FAKE_CN="" bash "$TMP/ipguard.sh"; r=$?
check "查不到 IP（断网）时守卫不动手" '[ $r = 0 ] && [ ! -f "$TMP/guard-ran" ]'
reset; mkdir -p "$TMP/run"
echo '{"at":1,"cn":{"ip":"'$E'"},"cloudflare":{"ip":"'$E'"},"claude":{"ip":"'$E'"}}' > "$TMP/run/netcheck.json"
bash "$TMP/ipguard.sh" --cached; r=$?
check "面板刷新后的检查：检测结果都相符时不再联网" '[ $r = 0 ] && [ ! -s "$TMP/curl-calls" ]'
echo '{"at":1,"cn":{"ip":"'$E'"},"cloudflare":{"ip":"5.5.5.5"},"claude":{"ip":"'$E'"}}' > "$TMP/run/netcheck.json"
FAKE_CF=5.5.5.5 bash "$TMP/ipguard.sh" --cached; r=$?; sleep 1
check "面板刷新后的检查：检测结果不符且现查确认后动手" '[ $r = 3 ] && [ -f "$TMP/guard-ran" ]'
reset; echo '{"at":1,"cn":{"ip":"'$E'"},"cloudflare":{"ip":"5.5.5.5"},"claude":{"ip":"'$E'"}}' > "$TMP/run/netcheck.json"
bash "$TMP/ipguard.sh" --cached; r=$?
check "检测结果不符但现查已恢复时不动手" '[ $r = 0 ] && [ ! -f "$TMP/guard-ran" ]'

reset; claude-desktop "claude://x"; r=$?
check "闸门：三个出口都相符才启动桌面端，参数原样传过去" '[ $r = 0 ] && grep -q "^desktop:claude://x$" "$TMP/desktop-ran"'
reset; FAKE_CLAUDE=7.7.7.7 claude-desktop 2>/dev/null; r=$?
check "闸门：Claude 出口不符时不启动桌面端" '[ $r = 1 ] && [ ! -f "$TMP/desktop-ran" ]'
check "闸门：拒绝时记日志并说明哪个出口不符" 'grep -q "desktop-gate refused.*claude=7.7.7.7" "$TMP/larkspur.log"'
reset; FAKE_CN="" claude-desktop 2>/dev/null; r=$?
check "闸门：有出口查不到时也不启动" '[ $r = 1 ] && [ ! -f "$TMP/desktop-ran" ]'
reset; LARKSPUR_HOME="$TMP/none" FAKE_CLAUDE=7.7.7.7 claude-desktop; r=$?
check "闸门：没有配置期望 IP 时直接放行" '[ $r = 0 ] && [ -f "$TMP/desktop-ran" ]'

# 总控自动启动
reset
jq -n '{session_id:"hubsid", desktop_id:"local_hub", chat_id:"oc_hub", active:true, role:"hub"}' > "$TMP/sessions/hubsid.json"
jq -n '{session_id:"g", desktop_id:"local_g", chat_id:"oc_g", active:true}' > "$TMP/sessions/g.json"
err=$(echo '{"session_id":"hubsid"}' | CLAUDE_CODE_HOST_SESSION_ID=local_hub bash "$TMP/session-start.sh" 2>&1 >/dev/null); r=$?
check "桌面端拉起总控会话、监听没在跑时唤醒它启动监听" '[ $r = 2 ] && printf "%s" "$err" | grep -q "listen.sh oc_hub --hub"'
err=$(echo '{"session_id":"newsid"}' | CLAUDE_CODE_HOST_SESSION_ID=local_hub bash "$TMP/session-start.sh" 2>&1 >/dev/null); r=$?
check "总控换了会话 ID 也能按桌面端会话 ID 认出来" '[ $r = 2 ]'
bash -c 'exec -a listen-fake sleep 300' & lp=$!; echo "$lp" > "$TMP/run/oc_hub.msg.pid"   # 让监听看起来活着
err=$(echo '{"session_id":"hubsid"}' | CLAUDE_CODE_HOST_SESSION_ID=local_hub bash "$TMP/session-start.sh" 2>&1 >/dev/null); r=$?
check "总控监听已在跑时不唤醒" '[ $r = 0 ]'
kill "$lp" 2>/dev/null; rm -f "$TMP/run/oc_hub.msg.pid"
err=$(echo '{"session_id":"g"}' | LARKSPUR_HUB_RELAY_DELAY=0 CLAUDE_CODE_HOST_SESSION_ID=local_g bash "$TMP/session-start.sh" 2>&1 >/dev/null); r=$?
check "总控没被拉起时，由开着同步的会话转告总控" '[ $r = 2 ] && printf "%s" "$err" | grep -q "local_hub"'
err=$(echo '{"session_id":"g"}' | LARKSPUR_HUB_RELAY_DELAY=0 CLAUDE_CODE_HOST_SESSION_ID=local_g bash "$TMP/session-start.sh" 2>&1 >/dev/null); r=$?
check "5 分钟内只转告一次" '[ $r = 0 ]'
err=$(echo '{"session_id":"hubsid"}' | FAKE_CLAUDE=7.7.7.7 CLAUDE_CODE_HOST_SESSION_ID=local_hub bash "$TMP/session-start.sh" 2>&1 >/dev/null); r=$?; sleep 1
check "会话启动时 IP 不符：先运行守卫命令，不再唤醒总控" '[ $r = 0 ] && [ -f "$TMP/guard-ran" ]'
# 开关
reset; printf 'LARKSPUR_DESKTOP_GATE="off"\n' >> "$TMP/config.sh"
FAKE_CLAUDE=7.7.7.7 claude-desktop; r=$?
check "启动闸门关闭时不检查直接启动" '[ $r = 0 ] && [ -f "$TMP/desktop-ran" ]'
printf 'LARKSPUR_IP_GUARD="off"\n' >> "$TMP/config.sh"
reset; FAKE_CN=9.9.9.9 bash "$TMP/ipguard.sh"; r=$?
check "运行中守卫关闭时不动手" '[ $r = 0 ] && [ ! -f "$TMP/guard-ran" ]'
# 设置程序：假 zenity 按 FAKE_Z_LIST 回答勾选框，其余对话框直接确定
cat > "$TMP/bin/zenity" <<'Z'
#!/usr/bin/env bash
echo "$*" >> "$LARKSPUR_HOME/zenity-calls"
case "$*" in
  *--progress*) cat >/dev/null ;;
  *--checklist*) printf '%s\n' "$FAKE_Z_LIST"; exit "${FAKE_Z_RC:-0}" ;;
  *--entry*) printf '%s\n' "$FAKE_Z_ENTRY" ;;
esac
exit 0
Z
chmod +x "$TMP/bin/zenity"; ok
FAKE_Z_LIST="gate guard" bash "$TMP/ip-gate-ui.sh"
check "设置程序：勾选两项后写回 on" 'grep -q "^LARKSPUR_DESKTOP_GATE=\"on\"" "$TMP/config.sh" && grep -q "^LARKSPUR_IP_GUARD=\"on\"" "$TMP/config.sh"'
check "设置程序：先现查并显示三个出口 IP" 'grep -q "Cloudflare $E" "$TMP/zenity-calls"'
FAKE_Z_LIST="guard" bash "$TMP/ip-gate-ui.sh"
check "设置程序：取消勾选启动闸门后写回 off" 'grep -q "^LARKSPUR_DESKTOP_GATE=\"off\"" "$TMP/config.sh" && grep -q "^LARKSPUR_IP_GUARD=\"on\"" "$TMP/config.sh"'
FAKE_Z_LIST="" FAKE_Z_RC=1 bash "$TMP/ip-gate-ui.sh"
check "设置程序：点取消不改配置" 'grep -q "^LARKSPUR_DESKTOP_GATE=\"off\"" "$TMP/config.sh"'
exit $fail
