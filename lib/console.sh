#!/usr/bin/env bash
# 用法：
#   console.sh show [页面]                      确保私聊里有一张置顶的控制台卡片，并刷新到指定页面
#   console.sh refresh                          控制台卡片已存在时，按当前页面重新渲染（状态变化时顺手调用）
#   console.sh action <action_value> [form_value]  处理控制台卡片上的点击（由 listen-cards.sh 调用）
# 页面：status（状态）、sessions（会话）、net（网络检测）、options（功能选项）。
# 控制台是总控私聊里的一张置顶卡片，所有操作都原地更新这张卡片，不另发消息。
# 能用脚本完成的操作（切页、刷新、关闭同步、改设置、发新建卡片、网络检测）都在这里直接做，不唤醒 Claude；
# 需要桌面端工具的操作（归档会话）输出一行「飞书控制台请求: {...}」交给总控。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"
require_open_id

CF="$RUN_DIR/console.json"     # {message_id, page}
CONFIG="$LARKSPUR_HOME/config.sh"

hub_chat() { local f; f=$(hub_state) && jq -r '.chat_id // empty' "$f"; }
cget() { jq -r --arg k "$1" '.[$k] // empty' "$CF" 2>/dev/null; }
cset() { local tmp; tmp=$(mktemp); { [ -f "$CF" ] && cat "$CF" || echo '{}'; } | jq --arg k "$1" --arg v "$2" '.[$k]=$v' > "$tmp" && mv "$tmp" "$CF"; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

set_config() {   # 改写 config.sh 里的一项（没有就追加）
  local k="$1" esc
  esc=$(printf '%s' "$2" | sed 's/[\\"$`]/\\&/g')
  touch "$CONFIG"
  if grep -q "^$k=" "$CONFIG"; then
    LINE="$k=\"$esc\"" KEY="$k" awk 'index($0, ENVIRON["KEY"] "=") == 1 { print ENVIRON["LINE"]; next } { print }' \
      "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  else
    printf '%s="%s"\n' "$k" "$esc" >> "$CONFIG"
  fi
  chmod 600 "$CONFIG"
}

ago() {   # 秒数 → 「N 分钟前」
  local s=$1
  if [ "$s" -lt 60 ]; then echo "刚刚"
  elif [ "$s" -lt 3600 ]; then echo "$((s/60)) 分钟前"
  elif [ "$s" -lt 86400 ]; then echo "$((s/3600)) 小时前"
  else echo "$((s/86400)) 天前"; fi
}

collect() {   # 把渲染需要的数据收集成一个 JSON
  local now hc started up="" sessions today mem events
  now=$(date +%s)
  hc=$(hub_chat || true)
  # 飞书监听由常驻服务 larkspurd 负责，总控会话只读它写的事件队列
  local dalive=false reader=false rstate=stopped hubproc=false pending=0 web="" hfile=""
  if daemon_alive; then
    dalive=true
    started=$(jq -r '.started // empty' "$RUN_DIR/daemon.json" 2>/dev/null); started=${started:-$now}
    web=$(jq -r 'if .port then "http://localhost:\(.port)/" else "" end' "$RUN_DIR/daemon.json" 2>/dev/null)
    if [ -z "$hc" ]; then up="运行中（没有总控，不收飞书消息）"
    elif listener_alive "$hc.msg"; then up="运行中（已运行 $(( (now - started) / 60 )) 分钟）"
    else up="运行中，飞书监听正在重连"; fi
  else up="<font color=\"red\">没在运行</font>（在电脑桌面点「Larkspur」打开）"; fi
  rstate=$(hub_reader_state); [ "$rstate" != stopped ] && reader=true
  # 总控停着时，它的会话进程还在不在：不在的话飞书一来消息服务就会把它拉起来（hub-revive.sh），在的话要主人去它里面发句话
  hfile=$(hub_state) && hub_process "$(jq -r '.desktop_id // ""' "$hfile")" >/dev/null && hubproc=true
  local dstate gatelast; dstate=$(desktop_state); gatelast=$(desktop_gate_last)
  pending=$(grep -c '' "$RUN_DIR/hub-queue" 2>/dev/null); pending=${pending:-0}

  sessions=$(for f in "$STATE_DIR"/*.json; do [ -f "$f" ] || continue
      sid=$(jq -r '.session_id' "$f"); t=$(ls "$HOME"/.claude/projects/*/"$sid.jsonl" 2>/dev/null | head -1)
      last=""; title=""
      if [ -n "$t" ]; then
        last=$(ago $(( now - $(mtime "$t") )))
        # 会话名：桌面端的会话标题（记录里最后一条 custom-title）
        title=$(grep -a '"type":"custom-title"' -- "$t" 2>/dev/null | tail -n 1 | jq -r '.customTitle // empty' 2>/dev/null)
      fi
      jq -c --arg last "$last" --arg title "$title" '{sid:.session_id, desk:(.desktop_id // ("local_" + .session_id)), chat:.chat_id,
         group:(.group_name // ""),
         name:(if $title != "" then $title
               elif .role == "hub" then "飞书总控"
               elif (.group_name // "") != "" then (.group_name | split(" · ") | last)
               else ((.cwd // "") | split("/") | last) end),
         cwd:(.cwd // ""), active:(.active == true), hub:(.role == "hub"), last:$last}' "$f"
    done | jq -sc '.')

  # 「今天」按显示时区（默认 UTC+8）的零点算；日志里是本机时间，先把那个零点换算成本机时间再比较
  day0=$(date -d "$(TZ="$DISPLAY_TZ" date +%F) 00:00:00 $(TZ="$DISPLAY_TZ" date +%z)" '+%F %T' 2>/dev/null || date +%F)
  today=$(awk -v d="$day0" 'substr($0, 1, 19) >= d { print $3 }' "$LOG" 2>/dev/null | sort | uniq -c | awk '{printf "%s %s\n",$2,$1}' \
          | jq -Rsc 'split("\n") | map(select(length>0) | split(" ") | {(.[0]): (.[1]|tonumber)}) | add // {}')

  mem=0
  for p in $(pgrep -f 'lark-cli event|/listen(-cards|-menu|-inbox|-wait)?\.sh|/netwatch\.sh|larkspurd' 2>/dev/null); do
    k=$(awk '/^Pss:/{print $2}' "/proc/$p/smaps_rollup" 2>/dev/null)
    [ -n "$k" ] || k=$(ps -p "$p" -o rss= 2>/dev/null | tr -d ' ')
    mem=$((mem + ${k:-0}))
  done

  events=$(tail -n 200 "$LOG" 2>/dev/null | grep -E ' (inbound|route|outbound|outbound-failed|backfill|listener-takeover|listener-missing|hub-listener-missing|spawn|on|off|hub-on|route-skip|daemon-start|daemon-stop) ' \
           | tail -n 8 | while IFS= read -r l; do   # 时间换成显示时区
               e=$(date -d "${l:0:19}" +%s 2>/dev/null) && hm=$(TZ="$DISPLAY_TZ" date -d "@$e" +%H:%M) || hm="${l:11:5}"
               printf '%s %s\n' "$hm" "${l:20}"
             done | jq -Rsc 'split("\n") | map(select(length>0)) | reverse')   # 新的在上

  net=$("$LARKSPUR_HOME/netcheck.sh" --cached 2>/dev/null | jq -c . 2>/dev/null)
  at=$(printf '%s' "$net" | jq -r '.at // empty' 2>/dev/null)
  if [ -n "$at" ]; then   # 检测时间按显示时区
    at=$(TZ="$DISPLAY_TZ" date -d "@$at" +%H:%M:%S 2>/dev/null || TZ="$DISPLAY_TZ" date -r "$at" +%H:%M:%S)
    net=$(printf '%s' "$net" | jq -c --arg t "$at" '.at_text = $t')
  fi

  [ -n "$today" ] || today='{}'; [ -n "$events" ] || events='[]'; [ -n "$net" ] || net='{}'
  jq -cn --argjson net "$net" --arg now "$now" --argjson dalive "$dalive" --argjson reader "$reader" --arg rstate "$rstate" --argjson hubproc "$hubproc" --arg dstate "$dstate" --arg gatelast "$gatelast" --arg pending "$pending" --arg web "$web" --arg netint "$NET_REFRESH" --arg expip "$EXPECTED_IP" --arg guard "$IP_GUARD_CMD" --arg guardon "$IP_GUARD" --arg gateon "$DESKTOP_GATE" --arg mode "$(router_active && echo router || echo none)" --arg up "$up" --argjson s "$sessions" \
     --argjson today "$today" --arg mem "$(( mem / 1024 ))" --argjson ev "$events" \
     --arg ack "$ACK_EMOJI" --arg wait "$IMAGE_WAIT" --arg bf "$BACKFILL_HOURS" --arg sm "$SPAWN_MODE" \
     --arg alerts "$ALERTS" --arg prefix "$GROUP_PREFIX" --arg root "$PROJECTS_ROOT" --arg time "$(TZ="$DISPLAY_TZ" date +%H:%M:%S)" \
     '{mode:$mode, up:$up, sessions:$s, today:$today, mem:$mem, events:$ev, time:$time, net:$net, now:($now|tonumber), daemon:$dalive, reader:$reader, rstate:$rstate, hubproc:$hubproc, desktop:$dstate,
       gatelast:(if $gatelast == "" then null else ($gatelast | capture("^(?<t>\\S+ \\S+) desktop-gate (?<r>\\S+)(?<rest>.*)$")) end), pending:($pending|tonumber? // 0), web:$web, netint:($netint|tonumber? // 0), expip:$expip, guard:$guard, guardon:$guardon, gateon:$gateon,
       opt:{ack:$ack, wait:$wait, backfill:$bf, spawn:$sm, alerts:$alerts, prefix:$prefix, root:$root}}'
}

render() {   # <page> [提示] → 卡片 JSON
  collect | jq -c --arg page "$1" --arg notice "${2:-}" '. as $d |
    def pt($t): {tag:"plain_text", content:$t};
    def cb($v): [{type:"callback", value:($v + {lk:"c"})}];
    def btn($t; $v; $kind): {tag:"button", text:pt($t), type:$kind, size:"small", behaviors:cb($v)};
    def row($bs): {tag:"column_set", flex_mode:"flow", horizontal_spacing:"small",
                   columns:[$bs[] | {tag:"column", width:"auto", elements:[.]}]};
    def md($t): {tag:"markdown", content:$t};
    def panel($title; $open; $els): {tag:"collapsible_panel", expanded:$open, vertical_spacing:"8px", padding:"4px 8px 8px 8px",
        header:{title:{tag:"markdown", content:$title}, vertical_align:"center", padding:"4px 0px 4px 8px",
                icon:{tag:"standard_icon", token:"down-small-ccm_outlined", size:"16px 16px"},
                icon_position:"right", icon_expanded_angle:-180},
        border:{color:"grey", corner_radius:"6px"}, elements:$els};
    def opt($t; $v): {text:pt($t), value:$v};
    def setsel($k; $cur; $opts): {tag:"select_static", name:$k, width:"fill", initial_option:$cur, options:$opts,
        behaviors:cb({op:"set", key:$k})};
    def setinput($k; $cur; $ph): {tag:"input", name:$k, width:"fill", max_length:200, default_value:$cur, placeholder:pt($ph),
        behaviors:cb({op:"set", key:$k})};
    {inbound:"收到", route:"转发", outbound:"发回飞书", "outbound-failed":"发回失败", backfill:"补发",
                "listener-takeover":"监听接替", "listener-missing":"监听停止", "hub-listener-missing":"总控监听停止",
                spawn:"新建会话", on:"开启同步", off:"关闭同步", "hub-on":"开启总控", "route-skip":"未转发", "daemon-start":"启动 Larkspur", "daemon-stop":"关闭 Larkspur"} as $labels
    | $d
    | ([ $d.sessions[] | {key:.chat, value:.name}, {key:.sid, value:.name}, {key:.desk, value:.name} ] | from_entries) as $names
    | (([ $d.sessions[] | select(.active) ] | sort_by(.hub | not)) as $act
        | [ md("**同步中的会话**　\($act | length) 个　·　已关闭 \([$d.sessions[] | select(.active | not)] | length) 个") ]
          + [ $act[] |
              md("**\(.name)**\n<font color=\"grey\">\(if .group != "" then "群：" + .group + "\n" else "" end)\(.cwd)\(if .last != "" then "　·　最后活动 " + .last else "" end)</font>"),
              (if .hub then md("<font color=\"grey\">这是总控本身，在总控里执行 /feishu off 关闭</font>")
               else row([
                 {tag:"button", text:pt("进群"), type:"default", size:"small",
                  behaviors:[{type:"open_url", default_url:("https://applink.feishu.cn/client/chat/open?openChatId=" + .chat)}]},
                 (btn("关闭同步"; {op:"off", sid:.sid}; "default")
                   + {confirm:{title:pt("关闭这个会话的飞书同步？"), text:pt("群会保留，之后在会话里 /feishu on 可以重新开启。")}}),
                 (btn("归档会话"; {op:"archive", sid:.sid}; "danger")
                   + {confirm:{title:pt("归档这个 Claude 会话？"), text:pt("会话会停止并移到桌面端的已归档列表，可以恢复。同时关闭它的飞书同步。")}})
               ]) end) ]
          + [ row([btn("新建会话"; {op:"new"}; "primary"), btn("刷新"; {op:"refresh", page:"sessions"}; "default")]) ]) as $sess
    | ([ md("选完立即保存并生效，不用重启。"),
            md("**已读回执表情**　收到飞书消息时加在那条消息上"),
            setsel("ack"; (if $d.opt.ack == "" then "off" else $d.opt.ack end);
                [opt("了解";"Get"), opt("OK";"OK"), opt("赞";"THUMBSUP"), opt("完成";"DONE"), opt("不加";"off")]),
            md("**图片等文字的秒数**　发图后这么多秒内跟上的文字会合成一条"),
            setsel("wait"; $d.opt.wait; [opt("0 秒（不等）";"0"), opt("3 秒";"3"), opt("5 秒";"5"), opt("10 秒";"10")]),
            md("**断线补发**　监听恢复时，最多补发多久之内漏掉的消息"),
            setsel("backfill"; $d.opt.backfill; [opt("不补发";"0"), opt("1 小时";"1"), opt("6 小时";"6"), opt("12 小时";"12"), opt("24 小时";"24")]),
            md("**新会话权限模式**　总控新建的会话导入后切到的模式（默认模式是 auto 时不切换）"),
            setsel("spawn"; (if $d.opt.spawn == "" then "none" else $d.opt.spawn end);
                [opt("不切换";"none"), opt("接受编辑";"acceptEdits"), opt("跳过权限确认（要在桌面端点确认）";"bypassPermissions")]),
            md("**异常提醒**　转发或发回失败时在这里提醒你"),
            setsel("alerts"; $d.opt.alerts; [opt("开";"on"), opt("关";"off")]),
            md("**群名前缀**　改完按回车保存"),
            setinput("prefix"; $d.opt.prefix; "例如 Claude"),
            md("**项目根目录**　新建会话卡片里列出的目录，改完按回车保存"),
            setinput("root"; $d.opt.root; "绝对路径"),
          md("<font color=\"grey\">接收方式：只由总控统一监听并转发，不允许各会话自己监听。没有总控时各会话收不到飞书消息，在一个常开的会话里执行 /feishu hub 即可。</font>") ]) as $opts
    | ([ md("**接收方式**　\(if $d.mode == "router" then "总控统一转发" else "<font color=\"red\">没有总控，各会话收不到消息</font>" end)\n**Larkspur 服务**　\($d.up)\n**总控会话**　\(if $d.rstate == "waiting" then "等待中（有消息才唤醒）" elif $d.rstate == "busy" then "处理中" else "<font color=\"red\">已停止</font>" end)\(if $d.pending > 0 then "　<font color=\"grey\">\($d.pending) 条事件排队中</font>" else "" end)\(if $d.rstate == "stopped" and $d.mode == "router" then "\n<font color=\"grey\">\(if $d.desktop != "running" then "Claude 桌面端没在运行，启动后总控会自动恢复" elif $d.hubproc then "总控会话开着却没在等事件，在它里面随便发一句话即可恢复" else "飞书一来消息就会自动打开总控会话把它拉起来" end)，期间的消息排在队列里</font>" else "" end)\n**Claude 桌面端**　\(if $d.desktop == "running" then "运行中" elif $d.desktop == "starting" then "正在启动（检查出口 IP 中）" else "<font color=\"grey\">没在运行（只能手动启动）</font>" end)\(if $d.desktop != "running" and ($d.gatelast.r // "") == "refused" then "\n<font color=\"red\">上次启动被闸门拦下（\($d.gatelast.t[11:16])）：出口 IP 不符</font>" else "" end)\(if $d.web != "" then "\n**本地控制台**　" + $d.web else "" end)\n**同步中的会话**　\([$d.sessions[] | select(.active and (.hub | not))] | length) 个\n**今天**　收到 \($d.today.inbound // 0) 条 · 转发 \($d.today.route // 0) 条 · 发回 \($d.today.outbound // 0) 条\(if ($d.today["outbound-failed"] // 0) > 0 then " · <font color=\"red\">发回失败 \($d.today["outbound-failed"]) 次</font>" else "" end)\n**常驻内存**　\($d.mem) MB"),
          (if $d.desktop == "stopped" then row([btn("启动桌面端"; {op:"desktop"}; "primary")
             + {confirm:{title:pt("启动 Claude 桌面端？"), text:pt("会先检查三个出口 IP，相符才启动。")}}]) else empty end),
          md("**最近事件**\n" + (if ($d.events | length) == 0 then "<font color=\"grey\">暂无</font>" else
             ($d.events | map(split(" ") as $w
               | ($w[1]) as $t
               | ([ $w[2:][] | select(startswith("chat=") or startswith("to=") or startswith("desktop=")) | sub("^[a-z]+="; "") ] | map($names[.] // empty) | first) as $nm1
               | ([ $w[2:][] | select(startswith("sid=")) | sub("^sid="; "") ] | map($names[.] // empty) | first) as $nm2
               | ($nm1 // $nm2) as $nm
               | "<font color=\"grey\">\($w[0])</font>　\($labels[$t] // $t)\(if $nm then "　" + $nm else "" end)")
              | join("\n")) end))
          ]) as $stat
    | ($d.net) as $n
    | def tag($t; $c): "<text_tag color=\"\($c)\">\($t)</text_tag>";
      def flag($cc): if ($cc | test("^[A-Za-z]{2}$")) then ($cc | ascii_upcase | explode | map(. + 127397) | implode) + " " else "" end;
      def yn($v; $yes; $no): if $v == true then tag($yes; "red") elif $v == false then tag($no; "green") else tag("未知"; "neutral") end;
      ($n.risk.score // null) as $score
    | (if $n.restricted then {t:"不可访问", c:"red"}
       elif $score == null then {t:"无数据", c:"neutral"}
       elif $score >= 95 then {t:"极度纯净", c:"green"} elif $score >= 80 then {t:"纯净", c:"green"}
       elif $score >= 50 then {t:"良好", c:"turquoise"} elif $score >= 25 then {t:"中性", c:"orange"}
       else {t:"可疑", c:"red"} end) as $lv
    | (if ($n.claude.ip // "") == "" then "" else "　\(if $n.restricted then 0 else $score // "—" end) \($lv.t)" end) as $netsum
    | (if ($n.at // null) == null then
         [ md("<font color=\"grey\">还没有检测过。点「重新检测」查看本机访问 Claude 的出口 IP 和风险，约 10 秒。</font>") ]
       else
         ($n.claude) as $c
         | def exit_ip($t; $x; $bold): "**\($t)**　" + (if ($x.ip // "") == "" then "<font color=\"red\">获取失败</font>"
             else flag($x.cc // "") + (if $bold then "**" + $x.ip + "**" else $x.ip end)
                  + (if ($x.where // "") != "" then "\n<font color=\"grey\">" + $x.where + "</font>" else "" end) end);
           [ md(exit_ip("中国出口 IPv4"; $n.cn // {}; false) + "\n" + exit_ip("Cloudflare 出口 IP"; $n.cloudflare // {}; false)
                + "\n" + exit_ip("Claude AI 出口 IP"; $c; true)),
             md("**信任评分**　\(if $n.restricted then "<font color=\"red\">0</font>" elif $score == null then "—" else "**\($score)**" end) \(tag($lv.t; $lv.c))"
               + (if $n.restricted then "\n<font color=\"red\">出口 IP 位于\($n.restricted)，Claude 会严格风控，不建议登录</font>"
                  elif $score == null then "" else "　<font color=\"grey\">\(if $score >= 95 then "该 IP 信誉极好" elif $score >= 80 then "该 IP 信誉优异" elif $score >= 50 then "该 IP 存在轻微风险" elif $score >= 25 then "该 IP 存在一定风险" else "该 IP 风险极高" end)</font>" end)
               + "\n**Claude 支持地区**　\(if $n.restricted then tag("不支持"; "red") elif ($c.cc // "") == "" then tag("未知"; "neutral") else tag("正常"; "green") end)"),
             md("**IP 属性**　\(if $n.risk.residential == true then tag("家庭住宅 IP"; "green") elif $n.risk.residential == false then tag("机房 IP"; "orange") else tag("未知"; "neutral") end)\(if ($n.risk.company_type // "") != "" then "（" + ({hosting:"Hosting", isp:"ISP", business:"Business", education:"Education"}[$n.risk.company_type] // $n.risk.company_type) + "）" else "" end)"
               + "\n**ASN**　\(if $n.risk.asn then "AS\($n.risk.asn)" else "未知" end)　\($n.risk.org // "")"),
             md("**安全检测**　VPN \(yn($n.risk.vpn; "VPN"; "未检测到"))　代理 \(yn($n.risk.proxy; "代理"; "未检测到"))　Tor \(yn($n.risk.tor; "Tor"; "未检测到"))"
               + "\n机器人 \(yn($n.risk.crawler; "是"; "否"))　滥用记录 \(yn($n.risk.abuser; "有记录"; "无记录"))"),
             md("**可用性**　" + ([ ($n.latency // [])[] | "\(.name) " + (if $n.restricted or .ms < 0 then tag("不可访问"; "red")
                   elif .ms < 250 then tag("正常"; "green") elif .ms < 500 then tag("良好"; "turquoise") else tag("较慢"; "orange") end)
                   + (if .ms >= 0 then " <font color=\"grey\">\(.ms)ms</font>" else "" end) ] | join("　"))
               + "\n**Claude 服务状态**　" + (if $n.status == null then tag("未知"; "neutral")
                   else ({none:["全部服务正常","green"], minor:["轻微故障","orange"], major:["重大故障","red"], critical:["严重故障","red"], maintenance:["维护中","orange"]}[$n.status.indicator] // ["服务异常","orange"]) as $st
                   | tag($st[0]; $st[1]) + (if ($n.status.down | length) > 0 then "\n<font color=\"grey\">受影响：\($n.status.down | join("、"))</font>" else "" end) end)),
             md("**DNS 泄露**　" + (if ($n.dns.servers | length) == 0 then tag("DNS 加密或未暴露出口"; "green")
                   elif $n.dns.leak then tag("可能泄露"; "orange") else tag("未检测到泄露"; "green") end)
               + (([ $n.dns.servers[] | select(.cc == "cn") ] + $n.dns.servers) | first // null | if . then
                   "\n**DNS 出口**　\(flag(.cc))\(.ip)\(if .isp != "" then "　<font color=\"grey\">" + .isp + "</font>" else "" end)" else "" end)),
             (if $d.expip == "" then empty else
               ([$n.cn.ip?, $n.cloudflare.ip?, $n.claude.ip?] | map(. // "")) as $ips
               | md("**IP 守卫**　三个出口都应为 \($d.expip)　"
                   + (if any($ips[]; . != "" and . != $d.expip) then tag("不符"; "red")
                      elif all($ips[]; . == $d.expip) then tag("一致"; "green") else tag("未查全"; "neutral") end)
                   + "\n**启动闸门** \(if $d.gateon == "off" then tag("已关闭"; "neutral") else tag("开"; "green") end)　桌面端启动前检查，不通过不启动"
                   + "\n**运行中守卫** \(if $d.guardon == "off" then tag("已关闭"; "neutral") else tag("开"; "green") end)　每次刷新后检查，不符时\(if $d.guard != "" then "运行 " + ($d.guard | split("/") | last) else "只提醒（没有配置守卫命令）" end)"
                   + "\n<font color=\"grey\">在本地网页控制台里开关（电脑桌面「Larkspur」图标）</font>") end),
             md("<font color=\"grey\">检测于 \($n.at_text // "")　·　\(if $d.netint > 0 then "每 \($d.netint) 秒自动检测" else "自动检测已关闭" end)　·　数据来自 ip.net.coffee　·　WebRTC 只存在于浏览器，不检测</font>") ]
       end
       + [ row([btn("重新检测"; {op:"netcheck"}; "primary"),
                {tag:"button", text:pt("打开网页版"), type:"default", size:"small",
                 behaviors:[{type:"open_url", default_url:"https://ip.net.coffee/claude/"}]}]) ]) as $netels
    | ([ $d.sessions[] | select(.active and (.hub | not)) ] | length) as $nact
    | ([ row([btn("刷新"; {op:"refresh", page:$page}; "default"), btn("新建会话"; {op:"new"}; "primary")]),
         panel("**状态**"; ($page == "status"); $stat),
         panel("**会话**　\($nact) 个同步中"; ($page == "sessions"); $sess),
         panel("**网络检测**\($netsum)"; ($page == "net"); $netels),
           panel("**功能选项**"; ($page == "options"); $opts) ])

    as $content
    | {schema:"2.0", config:{update_multi:true},
       header:{title:pt("Larkspur 控制台"), subtitle:pt("更新于 \($d.time)"), template:"indigo"},
       body:{elements:(
         (if $notice != "" then [md("<font color=\"green\">\($notice)</font>")] else [] end)
         + $content)}}'
}

patch() {   # <message_id> <card> → 成功与否
  "$LARK" api PATCH "/open-apis/im/v1/messages/$1" --as bot \
     --data "$(jq -cn --arg c "$2" '{content:$c}')" 2>/dev/null | jq -e '.ok == true or .code == 0' >/dev/null 2>&1
}

publish() {   # <page> [提示] [force_new]：原地更新；失败或没有卡片时新发一张并置顶
  local page="$1" notice="${2:-}" card mid hc out
  card=$(render "$page" "$notice") || { echo "渲染控制台失败" >&2; return 1; }
  mid=$(cget message_id)
  if [ -n "$mid" ] && patch "$mid" "$card"; then cset page "$page"; return 0; fi
  hc=$(hub_chat) || { echo "没有活动的总控，控制台需要发在总控私聊里" >&2; return 1; }
  out=$("$LARK" im +messages-send --as bot --chat-id "$hc" --msg-type interactive --content "$card" 2>&1)
  mid=$(printf '%s' "$out" | jq -r '.data.message_id // empty' 2>/dev/null)
  [ -n "$mid" ] || { echo "发送控制台失败：$out" >&2; return 1; }
  "$LARK" im pins create --as bot --data "{\"message_id\":\"$mid\"}" >/dev/null 2>&1 || fs_log "console-pin-failed mid=$mid"
  cset message_id "$mid"; cset page "$page"
  fs_log "console-new mid=$mid"
}

do_set() {   # <键> <值>：校验并写入 config.sh，出错时把原因放进 err（飞书卡片和本地网页控制台共用）
  local k="$1" x="$2"; err=""
  case "$k" in
    ack)      case "$x" in Get|OK|THUMBSUP|DONE) set_config LARKSPUR_ACK_EMOJI "$x" ;; off) set_config LARKSPUR_ACK_EMOJI "" ;; *) err="无效的表情" ;; esac ;;
    wait)     case "$x" in 0|3|5|10) set_config LARKSPUR_IMAGE_WAIT "$x" ;; *) err="无效的秒数" ;; esac ;;
    backfill) case "$x" in 0|1|6|12|24) set_config LARKSPUR_BACKFILL_HOURS "$x" ;; *) err="无效的时长" ;; esac ;;
    spawn)    case "$x" in none) set_config LARKSPUR_SPAWN_PERMISSION_MODE "" ;; acceptEdits|bypassPermissions) set_config LARKSPUR_SPAWN_PERMISSION_MODE "$x" ;; *) err="无效的模式" ;; esac ;;
    alerts)   case "$x" in on|off) set_config LARKSPUR_ALERTS "$x" ;; *) err="无效的选项" ;; esac ;;
    prefix)   x=$(printf '%s' "$x" | tr -d '\n\r')
              if [ -n "$x" ] && [ "${#x}" -le 20 ]; then set_config LARKSPUR_GROUP_PREFIX "$x"; else err="群名前缀要在 1～20 个字之间"; fi ;;
    root)     x=$(printf '%s' "$x" | tr -d '\n\r'); x="${x/#\~/$HOME}"
              if [ -d "$x" ]; then set_config LARKSPUR_PROJECTS_ROOT "$x"; else err="目录不存在：$x"; fi ;;
    gate)     case "$x" in on|off) set_config LARKSPUR_DESKTOP_GATE "$x" ;; *) err="无效的选项" ;; esac ;;
    guard)    case "$x" in on|off) set_config LARKSPUR_IP_GUARD "$x" ;; *) err="无效的选项" ;; esac ;;
    webport)  if [[ "$x" =~ ^[0-9]+$ ]] && [ "$x" -ge 1024 ] && [ "$x" -le 65535 ]; then set_config LARKSPUR_WEB_PORT "$x"; else err="端口要在 1024～65535 之间"; fi ;;
    expip)    x=$(printf '%s' "$x" | tr -d '[:space:]')
              if printf '%s' "$x" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then set_config LARKSPUR_EXPECTED_IP "$x"; else err="不是有效的 IPv4 地址"; fi ;;
    *)        err="未知设置：$k" ;;
  esac
}

case "${1:-show}" in
  show)    publish "${2:-$(cget page)}" "${3:-}"   # 页面：none（全部收起）、status、sessions、net、options
           # 网络检测结果超过 30 分钟（或要看的就是网络页且超过 5 分钟）时，在后台重新检测，完成后再刷新一次
           at=$("$LARKSPUR_HOME/netcheck.sh" --cached | jq -r '.at // 0'); age=$(( $(date +%s) - ${at:-0} ))
           if [ "$age" -gt 1800 ] || { [ "${2:-}" = net ] && [ "$age" -gt 300 ]; }; then
             ( "$LARKSPUR_HOME/netcheck.sh" >/dev/null 2>&1 && "$0" refresh >/dev/null 2>&1; "$LARKSPUR_HOME/ipguard.sh" --cached >/dev/null 2>&1 & )
           fi ;;
  refresh) [ -n "$(cget message_id)" ] && publish "$(cget page)" ;;
  render)  render "${2:-status}" "${3:-}" ;;   # 只输出卡片 JSON，测试用
  data)    collect ;;                          # 渲染用的原始数据（JSON），本地网页控制台用
  set)     do_set "${2:-}" "${3:-}"; fs_log "console-set key=${2:-} ok=$([ -z "$err" ] && echo 1 || echo 0) via=cli"
           [ -z "$err" ] || { echo "$err" >&2; exit 1; } ;;
  action)
    v="${2:-}"; [ -n "$v" ] || v='{}'; fv="${3:-}"; op=$(printf '%s' "$v" | jq -r '.op // ""'); page=$(cget page); page=${page:-status}
    case "$op" in
      page|refresh) publish "$(printf '%s' "$v" | jq -r '.page // "status"')" ;;
      desktop)   # 手动启动桌面端（经过启动闸门）；结果过几秒才知道，先提示，稍后刷新一次
        msg=$("$LARKSPUR_HOME/desktop-start.sh" feishu 2>&1); publish status "$msg"
        ( sleep 15; "$LARKSPUR_HOME/console.sh" refresh >/dev/null 2>&1 & ) ;;
      netcheck)   # 先给个「检测中」，检测完再原地更新
        publish net "正在检测，约 10 秒…"
        if "$LARKSPUR_HOME/netcheck.sh" >/dev/null 2>&1; then publish net; else publish net "检测失败，请稍后再试"; fi
        "$LARKSPUR_HOME/ipguard.sh" --cached >/dev/null 2>&1 ;;
      new)   # 新卡片出现本身就是反馈，不再刷新控制台；失败时才提示
        "$LARKSPUR_HOME/card-new.sh" >/dev/null 2>&1 || publish "$page" "发出新建会话卡片失败，请看日志" ;;
      off)   # 先改状态、刷新卡片，给群里发「已关闭」的那条消息放到后台，少等一次接口调用
        sid=$(printf '%s' "$v" | jq -r '.sid // ""'); f=$(state_file "$sid")
        LARKSPUR_NO_CONSOLE_REFRESH=1 "$LARKSPUR_HOME/off.sh" "$sid" "在控制台关闭" >/dev/null 2>&1 &
        for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(jq -r '.active' "$f" 2>/dev/null)" = true ] || break; sleep 0.1; done
        publish sessions "已关闭同步，群保留" ;;
      archive)
        sid=$(printf '%s' "$v" | jq -r '.sid // ""'); f=$(state_file "$sid")
        [ -f "$f" ] || { publish sessions "找不到这个会话"; exit 0; }
        printf '飞书控制台请求: %s\n' "$(jq -c '{op:"archive", session_id:.session_id, desktop_id:(.desktop_id // ("local_" + .session_id)), group:(.group_name // "")}' "$f")"
        publish sessions "已请总控归档，稍等片刻后点「刷新」" ;;
      set)   # 单项设置：保存即可，客户端已经显示了新值，成功时不必刷新卡片（省一次接口调用）
        k=$(printf '%s' "$v" | jq -r '.key // ""'); x="${3:-}"; err=""
        do_set "$k" "$x"
        fs_log "console-set key=$k ok=$([ -z "$err" ] && echo 1 || echo 0)"
        if [ -n "$err" ]; then . "$CONFIG"; . "$LARKSPUR_HOME/common.sh"; publish options "没有保存：$err"; fi ;;
      save)
        [ -n "$fv" ] || { publish options "没有收到表单内容"; exit 0; }
        g() { printf '%s' "$fv" | jq -r --arg k "$1" '.[$k] // empty'; }
        errs=""
        ack=$(g ack); case "$ack" in Get|OK|THUMBSUP|DONE) set_config LARKSPUR_ACK_EMOJI "$ack" ;; off) set_config LARKSPUR_ACK_EMOJI "" ;; esac
        w=$(g wait); case "$w" in 0|3|5|10) set_config LARKSPUR_IMAGE_WAIT "$w" ;; esac
        b=$(g backfill); case "$b" in 0|1|6|12|24) set_config LARKSPUR_BACKFILL_HOURS "$b" ;; esac
        sm=$(g spawn); case "$sm" in none) set_config LARKSPUR_SPAWN_PERMISSION_MODE "" ;; acceptEdits|bypassPermissions) set_config LARKSPUR_SPAWN_PERMISSION_MODE "$sm" ;; esac
        a=$(g alerts); case "$a" in on|off) set_config LARKSPUR_ALERTS "$a" ;; esac
        p=$(g prefix | tr -d '\n\r'); [ -n "$p" ] && { [ "${#p}" -le 20 ] && set_config LARKSPUR_GROUP_PREFIX "$p" || errs="$errs 群名前缀太长"; }
        r=$(g root | tr -d '\n\r'); r="${r/#\~/$HOME}"
        [ -n "$r" ] && { [ -d "$r" ] && set_config LARKSPUR_PROJECTS_ROOT "$r" || errs="$errs 目录不存在：$r"; }
        fs_log "console-save"
        . "$CONFIG"; . "$LARKSPUR_HOME/common.sh"   # 让本次渲染用上新值
        if [ -n "$errs" ]; then publish options "已保存其余设置；未保存：$errs"; else publish options "已保存，立即生效"; fi ;;
      *) publish "$page" ;;
    esac ;;
  *) echo "用法：console.sh show [status|sessions|net|options] | refresh | action <value> [form] | data | set <键> <值>" >&2; exit 1 ;;
esac
