#!/usr/bin/env bash
# 用法：exit-ips.sh [期望 IP]
# 并发查三个出口 IP（和控制台网络检测的前三行同源）：
#   cn      国内网站看到的 IP（myip.ipip.net）
#   cf      Cloudflare 看到的 IP（1.1.1.1/cdn-cgi/trace）
#   claude  Claude 看到的 IP（claude.ai/cdn-cgi/trace）
# 输出一行 JSON：{"cn","cf","claude"}，查不到的为空字符串。约 1～2 秒，最多 6 秒。
# 给了期望 IP 时，退出码表示判断结果：
#   0  三个都查到且都等于期望 IP（通过）
#   1  至少一个查到了、但不等于期望 IP（确定不符）
#   2  查到的都相符，但有查不到的（无法确定）
set -u
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ua='Larkspur-exit-ips'
curl -s -m 6 -A "$ua" https://myip.ipip.net/json 2>/dev/null | jq -r 'select(.ret == "ok") | .data.ip // empty' 2>/dev/null > "$T/cn" &
curl -s -m 6 -A "$ua" https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' > "$T/cf" &
curl -s -m 6 -A "$ua" https://claude.ai/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' > "$T/claude" &
wait
cn=$(head -1 "$T/cn"); cf=$(head -1 "$T/cf"); cl=$(head -1 "$T/claude")
jq -cn --arg cn "$cn" --arg cf "$cf" --arg claude "$cl" '{cn:$cn, cf:$cf, claude:$claude}'
exp="${1:-}"; [ -n "$exp" ] || exit 0
missing=0
for ip in "$cn" "$cf" "$cl"; do
  if [ -z "$ip" ]; then missing=1; elif [ "$ip" != "$exp" ]; then exit 1; fi
done
exit $((missing * 2))
