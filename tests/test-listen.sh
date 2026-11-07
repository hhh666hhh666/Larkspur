#!/usr/bin/env bash
# 离线测试 listen.sh 的图片合并逻辑：用假 lark-cli 模拟事件流，不连接飞书。
# 用法：tests/test-listen.sh   （约 20 秒）
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d); trap 'pkill -f "$TMP/" 2>/dev/null; rm -rf "$TMP"' EXIT
cp "$ROOT"/lib/*.sh "$TMP/"
export LARKSPUR_HOME="$TMP" LARKSPUR_LARK_CLI="$ROOT/tests/fake-lark.sh" \
       LARKSPUR_OPEN_ID="ou_test" LARKSPUR_INBOX="$TMP/inbox" LARKSPUR_IMAGE_WAIT=10
chmod +x "$ROOT/tests/fake-lark.sh"
start=$(date +%s)
timeout 40 bash "$TMP/listen.sh" oc_test | while IFS= read -r l; do
  printf '[+%2ss] %s\n' $(( $(date +%s) - start )) "$l"
done
