#!/usr/bin/env bash
# 用法：netcheck.sh            检测本机访问 Claude 的出口 IP，结果写入 $RUN_DIR/netcheck.json 并输出
#       netcheck.sh --cached   只输出上次的结果（没有时输出 {}）
# 检测项与 https://ip.net.coffee/claude/ 一致（WebRTC 只存在于浏览器，不检测）：
#   出口 IP：国内网站（ipip.net）、Cloudflare（1.1.1.1）、claude.ai 各自看到的 IP 及归属地；
#   风险：信任评分、住宅/机房、ASN、运营商、VPN/代理/Tor/爬虫/滥用记录（ip.net.coffee 的 iprisk 接口）；
#   可用性：claude.ai、anthropic.com、api.anthropic.com 的延迟（复用连接后的第二次请求，与浏览器里测的口径相同）；
#   Claude 服务状态；DNS 泄露（解析一个一次性子域名，再查权威 DNS 看到的解析器 IP）。
# 所有请求并发进行，约 5 秒；同时只跑一个，后来的等前一个跑完直接用它的结果。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"

OUT="$RUN_DIR/netcheck.json"
API="${LARKSPUR_NETCHECK_API:-https://ip.net.coffee}"
[ "${1:-}" = --cached ] && { cat "$OUT" 2>/dev/null || echo '{}'; exit 0; }

LOCK="$RUN_DIR/netcheck.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  # 锁超过 60 秒视为上次异常退出留下的
  if [ $(( $(date +%s) - $(file_mtime "$LOCK" || echo 0) )) -gt 60 ]; then rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 1
  else
    for _ in $(seq 1 30); do [ -d "$LOCK" ] || break; sleep 0.5; done
    cat "$OUT" 2>/dev/null || echo '{}'; exit 0
  fi
fi
T=$(mktemp -d); trap 'rm -rf "$T" "$LOCK"' EXIT

get() { curl -sS -m "${2:-8}" -A 'Larkspur-netcheck' "$1" 2>/dev/null; }
trace() { get "$1" | awk -F= '$1=="ip"{ip=$2} $1=="loc"{loc=$2} END{printf "%s\t%s\n", ip, loc}'; }   # → "ip<TAB>loc"
latency() {   # <name> <url> → {"name","ms"}，不通时 ms 为 -1
  local s; s=$(curl -s -m 8 -A 'Larkspur-netcheck' -o /dev/null -o /dev/null -w '%{http_code} %{time_total}\n' "$2" "$2" 2>/dev/null | tail -n 1)
  case "$s" in 000*|"") jq -cn --arg n "$1" '{name:$n, ms:-1}' ;;
    *) jq -cn --arg n "$1" --arg t "${s#* }" '{name:$n, ms:(($t|tonumber)*1000|round)}' ;; esac
}

# 第一批：各出口 IP、延迟、服务状态、DNS 泄露，全部并发
trace https://claude.ai/cdn-cgi/trace > "$T/claude" & cpid=$!
trace https://1.1.1.1/cdn-cgi/trace > "$T/cf" &
get https://myip.ipip.net/json 6 > "$T/cn" &
{ latency claude.ai https://claude.ai/cdn-cgi/trace; latency anthropic.com https://www.anthropic.com/cdn-cgi/trace; } > "$T/lat1" &
latency api.anthropic.com https://api.anthropic.com/ > "$T/lat2" &
get "$API/claude/status.json" 6 > "$T/status" &
{ tok="lk$(date +%s)$RANDOM$RANDOM"
  for i in 1 2; do   # 只需要触发一次本机的 DNS 解析
    if command -v getent >/dev/null; then timeout 3 getent ahosts "$tok-$i.d.ip.net.coffee" >/dev/null 2>&1
    else curl -s -m 2 -o /dev/null "https://$tok-$i.d.ip.net.coffee/" 2>/dev/null; fi
  done
  sleep 1
  for _ in 1 2; do
    r=$(get "$API/api/dns/result/$tok" 4 | jq -c '.dns_servers // []' 2>/dev/null)
    [ -n "$r" ] && [ "$r" != "[]" ] && break; sleep 1.5
  done
  printf '%s' "${r:-[]}" > "$T/dns"
} &

# Claude 出口 IP 一拿到就查风险和归属地，不等其他项
wait "$cpid"
IFS=$'\t' read -r cip cloc < "$T/claude" 2>/dev/null || { cip=""; cloc=""; }
if [ -n "$cip" ]; then
  get "$API/api/iprisk/$cip" 10 > "$T/risk" &
  get "$API/api/geoip/$cip" 6 > "$T/geo" &
fi
wait

js() { local v; v=$(jq -c . "$1" 2>/dev/null) && [ -n "$v" ] && printf '%s' "$v" || printf 'null'; }
IFS=$'\t' read -r cfip cfloc < "$T/cf" 2>/dev/null || { cfip=""; cfloc=""; }
cnip=$(jq -r 'select(.ret == "ok") | .data.ip // empty' "$T/cn" 2>/dev/null)

# 第二批并发：另两个出口 IP 的归属地（和 Claude 出口相同时不重复查），DNS 解析器的归属地
# （最多查 3 个，有一个在中国就够判断泄露）
[ -n "$cfip" ] && [ "$cfip" != "$cip" ] && { get "$API/api/geoip/$cfip" 6 > "$T/cfgeo" & }
[ -n "$cnip" ] && [ "$cnip" != "$cip" ] && [ "$cnip" != "$cfip" ] && { get "$API/api/geoip/$cnip" 6 > "$T/cngeo" & }
dns=$(cat "$T/dns" 2>/dev/null); [ -n "$dns" ] || dns='[]'
n=0; for d in $(printf '%s' "$dns" | jq -r '.[:3][]' 2>/dev/null); do
  n=$((n+1)); { get "$API/api/geoip/$d" 4 | jq -c --arg ip "$d" '{ip:$ip, cc:(.country_code // ""), isp:(.isp // ""), country:(.country // "")}' 2>/dev/null > "$T/dg$n"; } &
done; wait
dnsgeo=$(cat "$T"/dg* 2>/dev/null | jq -sc '.')
[ -n "$dnsgeo" ] || dnsgeo='[]'
[ "$cfip" = "$cip" ] && cp "$T/geo" "$T/cfgeo" 2>/dev/null
if [ "$cnip" = "$cip" ]; then cp "$T/geo" "$T/cngeo" 2>/dev/null; elif [ "$cnip" = "$cfip" ]; then cp "$T/cfgeo" "$T/cngeo" 2>/dev/null; fi
result=$(jq -cn --arg cip "$cip" --arg cloc "$cloc" --arg cfip "$cfip" --arg cfloc "$cfloc" \
  --argjson cn "$(js "$T/cn")" --argjson risk "$(js "$T/risk")" --argjson geo "$(js "$T/geo")" \
  --argjson status "$(js "$T/status")" --argjson lat "$(cat "$T/lat1" "$T/lat2" 2>/dev/null | jq -sc '.')" \
  --argjson cfgeo "$(js "$T/cfgeo")" --argjson cngeo "$(js "$T/cngeo")" \
  --argjson dns "$dnsgeo" --arg at "$(date +%s)" '
  {"CN":"中国大陆","HK":"香港","MO":"澳门","RU":"俄罗斯","KP":"朝鲜","IR":"伊朗","SY":"叙利亚","CU":"古巴","BY":"白俄罗斯","VE":"委内瑞拉"} as $restricted
  | def place($g): [$g.country, $g.region, $g.city, $g.isp] | map(select(. != null and . != "")) | join(" ");   # 与网页相同的写法
    (($risk.countryCode // $geo.country_code // $cloc) | ascii_upcase) as $cc
  | {at:($at|tonumber),
     claude:{ip:$cip, cc:$cc, where:(if $geo.country then place($geo) else ([$risk.country, $risk.region, $risk.city] | map(select(. != null and . != "")) | join(" ")) end)},
     cloudflare:{ip:$cfip, cc:(($cfgeo.country_code // $cfloc) | ascii_upcase), where:(if $cfgeo.country then place($cfgeo) else "" end)},
     cn:(if ($cn.ret // "") == "ok" then {ip:$cn.data.ip, cc:(($cngeo.country_code // "") | ascii_upcase),
           where:(if $cngeo.country then place($cngeo) else [$cn.data.location[:3][]? | select(. != "")] | join(" ") end)} else null end),
     restricted:($restricted[$cc] // null),
     risk:(if $risk then {score:$risk.trust_score, residential:$risk.isResidential, company_type:($risk.company_type // ""),
             asn:$risk.asn, org:($risk.asOrganization // ""), vpn:$risk.is_vpn, proxy:$risk.is_proxy, tor:$risk.is_tor,
             crawler:$risk.is_crawler, abuser:$risk.is_abuser, timezone:($risk.timezone // "")} else null end),
     latency:$lat,
     status:(if $status then {indicator:($status.overall_indicator // ""),
             down:[$status.components[]? | select(.status != "operational") | .name]} else null end),
     dns:{servers:$dns,
          leak:(($cc != "CN") and ([$dns[] | select(.cc == "cn")] | length > 0))}}')
[ -n "$result" ] || { echo "网络检测失败" >&2; exit 1; }
# 每分钟都会检测，日志只记出口 IP 或评分变了的时候，免得把控制台的「最近事件」挤掉
key=$(printf '%s' "$result" | jq -r '"ip=\(.claude.ip | if . == "" then "none" else . end) score=\(.risk.score // "none")"')
old=$(jq -r '"ip=\(.claude.ip | if . == "" then "none" else . end) score=\(.risk.score // "none")"' "$OUT" 2>/dev/null)
printf '%s\n' "$result" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
[ "$key" = "$old" ] || fs_log "netcheck $key"
printf '%s\n' "$result"
