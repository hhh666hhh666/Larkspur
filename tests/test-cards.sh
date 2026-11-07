#!/usr/bin/env bash
# 离线测试 listen-cards.sh 的防重复提交：同一张卡片点两次只放行一次，并且放行前先把卡片改成「正在创建」。
# 用法：tests/test-cards.sh   （约 3 秒）
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cp "$ROOT"/lib/*.sh "$TMP/"
export LARKSPUR_HOME="$TMP" LARKSPUR_LARK_CLI="$ROOT/tests/fake-lark.sh" \
       LARKSPUR_OPEN_ID="ou_test" FAKE_LARK_CALLS="$TMP/calls"
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
exit $fail
