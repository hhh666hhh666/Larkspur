#!/usr/bin/env bash
# 用法：
#   console.sh show [页面]                      确保私聊里有一张置顶的控制台卡片，并刷新到指定页面
#   console.sh refresh                          控制台卡片已存在时，按当前页面重新渲染（状态变化时顺手调用）
#   console.sh action <action_value> [form_value]  处理控制台卡片上的点击（由 listen-cards.sh 调用）
# 页面：status（状态）、sessions（会话）、options（功能选项）。
# 控制台是总控私聊里的一张置顶卡片，所有操作都原地更新这张卡片，不另发消息。
# 能用脚本完成的操作（切页、刷新、关闭同步、改设置、发新建卡片）都在这里直接做，不唤醒 Claude；
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
  if [ -n "$hc" ] && listener_alive "$hc.msg"; then
    started=$(cat "$RUN_DIR/$hc.started" 2>/dev/null || echo "$now"); up="运行中（已运行 $(( (now - started) / 60 )) 分钟）"
  elif [ -n "$hc" ]; then up="已停止"; else up="没有总控"; fi

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
  for p in $(pgrep -f 'lark-cli event|/listen(-cards|-menu)?\.sh' 2>/dev/null); do
    k=$(awk '/^Pss:/{print $2}' "/proc/$p/smaps_rollup" 2>/dev/null)
    [ -n "$k" ] || k=$(ps -p "$p" -o rss= 2>/dev/null | tr -d ' ')
    mem=$((mem + ${k:-0}))
  done

  events=$(tail -n 200 "$LOG" 2>/dev/null | grep -E ' (inbound|route|outbound|outbound-failed|backfill|listener-takeover|listener-missing|hub-listener-missing|spawn|on|off|hub-on|route-skip) ' \
           | tail -n 8 | while IFS= read -r l; do   # 时间换成显示时区
               e=$(date -d "${l:0:19}" +%s 2>/dev/null) && hm=$(TZ="$DISPLAY_TZ" date -d "@$e" +%H:%M) || hm="${l:11:5}"
               printf '%s %s\n' "$hm" "${l:20}"
             done | jq -Rsc 'split("\n") | map(select(length>0)) | reverse')   # 新的在上

  [ -n "$today" ] || today='{}'; [ -n "$events" ] || events='[]'
  jq -cn --arg mode "$(router_active && echo router || echo direct)" --arg up "$up" --argjson s "$sessions" \
     --argjson today "$today" --arg mem "$(( mem / 1024 ))" --argjson ev "$events" \
     --arg ack "$ACK_EMOJI" --arg wait "$IMAGE_WAIT" --arg bf "$BACKFILL_HOURS" --arg sm "$SPAWN_MODE" \
     --arg alerts "$ALERTS" --arg prefix "$GROUP_PREFIX" --arg root "$PROJECTS_ROOT" --arg time "$(TZ="$DISPLAY_TZ" date +%H:%M:%S)" \
     '{mode:$mode, up:$up, sessions:$s, today:$today, mem:$mem, events:$ev, time:$time,
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
                spawn:"新建会话", on:"开启同步", off:"关闭同步", "hub-on":"开启总控", "route-skip":"未转发"} as $labels
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
          md("<font color=\"grey\">接收方式：\(if $d.mode == "router" then "总控统一转发" else "各会话自己监听" end)。切换方法：在总控里执行 /feishu off（改回各自监听）或 /feishu hub（开启转发）。</font>") ]) as $opts
    | ([ md("**接收方式**　\(if $d.mode == "router" then "总控统一转发" else "各会话自己监听" end)\n**总控监听**　\($d.up)\n**同步中的会话**　\([$d.sessions[] | select(.active and (.hub | not))] | length) 个\n**今天**　收到 \($d.today.inbound // 0) 条 · 转发 \($d.today.route // 0) 条 · 发回 \($d.today.outbound // 0) 条\(if ($d.today["outbound-failed"] // 0) > 0 then " · <font color=\"red\">发回失败 \($d.today["outbound-failed"]) 次</font>" else "" end)\n**常驻内存**　\($d.mem) MB"),
          md("**最近事件**\n" + (if ($d.events | length) == 0 then "<font color=\"grey\">暂无</font>" else
             ($d.events | map(split(" ") as $w
               | ($w[1]) as $t
               | ([ $w[2:][] | select(startswith("chat=") or startswith("to=") or startswith("desktop=")) | sub("^[a-z]+="; "") ] | map($names[.] // empty) | first) as $nm1
               | ([ $w[2:][] | select(startswith("sid=")) | sub("^sid="; "") ] | map($names[.] // empty) | first) as $nm2
               | ($nm1 // $nm2) as $nm
               | "<font color=\"grey\">\($w[0])</font>　\($labels[$t] // $t)\(if $nm then "　" + $nm else "" end)")
              | join("\n")) end))
          ]) as $stat
    | ([ $d.sessions[] | select(.active and (.hub | not)) ] | length) as $nact
    | ([ row([btn("刷新"; {op:"refresh", page:$page}; "default"), btn("新建会话"; {op:"new"}; "primary")]),
         panel("**状态**"; ($page == "status"); $stat),
         panel("**会话**　\($nact) 个同步中"; ($page == "sessions"); $sess),
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

case "${1:-show}" in
  show)    publish "${2:-$(cget page)}" "${3:-}" ;;   # 页面：none（全部收起）、status、sessions、options
  refresh) [ -n "$(cget message_id)" ] && publish "$(cget page)" ;;
  render)  render "${2:-status}" "${3:-}" ;;   # 只输出卡片 JSON，测试用
  action)
    v="${2:-}"; [ -n "$v" ] || v='{}'; fv="${3:-}"; op=$(printf '%s' "$v" | jq -r '.op // ""'); page=$(cget page); page=${page:-status}
    case "$op" in
      page|refresh) publish "$(printf '%s' "$v" | jq -r '.page // "status"')" ;;
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
          *)        err="未知设置：$k" ;;
        esac
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
  *) echo "用法：console.sh show [status|sessions|options] | refresh | action <value> [form]" >&2; exit 1 ;;
esac
