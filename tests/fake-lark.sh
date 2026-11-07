#!/usr/bin/env bash
# Larkspur 离线测试用的假 lark-cli：模拟事件流、图片下载和卡片更新
case "$1 $2" in
  "event consume")
    if [ "$3" = "application.bot.menu_v6" ]; then sleep 300; exit 0; fi
    if [ "$3" = "card.action.trigger" ]; then
      echo "[event] ready event_key=card.action.trigger" >&2
      c() { jq -cn --arg d "$1" --arg t "tok$2" --arg m "$3" \
              '{tag:"button", value:"", form:({dir:$d, title:"", prompt:""} | tojson), token:$t, message_id:$m}'; }
      v() { jq -cn --arg v "$1" '{tag:"button", value:$v, form:"", token:"tokc", message_id:"om_console"}'; }
      c proj-a 1 om_card1; sleep 1
      c proj-a 2 om_card1; sleep 1   # 同一张卡片的第二次点击，应被丢弃
      c proj-b 3 om_card2            # 另一张卡片，应放行
      if [ -n "${FAKE_CONSOLE:-}" ]; then   # 控制台：切到会话页、点归档
        sleep 0.5; v '{"lk":"c","op":"page","page":"sessions"}'
        sleep 1; v '{"lk":"c","op":"archive","sid":"g"}'; sleep 1.5
      fi
      echo "[event] exited — received 3 event(s) (reason: timeout)" >&2
      exit 0
    fi
    if [ "${FAKE_LARK_MODE:-}" = "router" ]; then    # 总控视角：私聊、两个群、一个不认识的群
      echo "[event] ready event_key=im.message.receive_v1" >&2
      m() { printf '{"chat_id":"%s","message_id":"%s","message_type":"%s","content":"%s"}\n' "$1" "$2" "$3" "$4"; }
      m oc_h om_r1 text "私聊里的话";                       sleep 0.3
      m oc_g om_r2 text "群里第一行\\n第二行";              sleep 0.3
      m oc_g om_r3 image "[Image: img_v3_r3]";              sleep 0.3
      m oc_g om_r4 text "这张图是什么";                     sleep 0.3
      m oc_x om_r5 text "不认识的群";                       sleep 0.3
      m oc_g om_r6 image "[Image: img_v3_r6]"
      sleep 300; exit 0
    fi
    if [ "${FAKE_LARK_MODE:-}" = "recover" ]; then   # 连上后收到一条实时消息，然后一直挂着
      echo "[event] ready event_key=im.message.receive_v1" >&2
      printf '{"message_id":"om_live1","message_type":"text","content":"实时消息"}\n'
      sleep 300; exit 0
    fi
    echo "[event] ready event_key=im.message.receive_v1" >&2
    j() { printf '{"message_id":"om_test%s","message_type":"%s","content":"%s"}\n' "$1" "$2" "$3"; }
    j 0001 text "纯文字，应立即输出";                      sleep 1
    j 0002 image "[Image: img_v3_aaa]";                     sleep 3
    j 0003 text "图后 3 秒的文字，应与图合并";             sleep 1
    j 0004 image "[Image: img_v3_bbb]";                     sleep 12
    j 0005 text "图后 12 秒的文字，应单独输出";            sleep 1
    echo "[event] exited — received 5 event(s) (reason: timeout)" >&2
    ;;
  "im +messages-resources-download")
    out=""; while [ $# -gt 0 ]; do [ "$1" = "--output" ] && out="$2"; shift; done
    : > "$out.jpg" ;;
  "im +chat-messages-list")   # 群历史：实时消息、两条漏掉的、一条机器人的
    q=""; while [ $# -gt 0 ]; do [ "$1" = "--jq" ] && q="$2"; shift; done
    printf '%s' '{"data":{"messages":[
      {"message_id":"om_live1","msg_type":"text","content":"实时消息","deleted":false,"sender":{"id":"ou_test"}},
      {"message_id":"om_gap1","msg_type":"text","content":"中断时发的文字","deleted":false,"sender":{"id":"ou_test"}},
      {"message_id":"om_botx","msg_type":"text","content":"机器人回复","deleted":false,"sender":{"id":"cli_app"}},
      {"message_id":"om_gap2","msg_type":"image","content":"[Image: img_v3_gap]","deleted":false,"sender":{"id":"ou_test"}}]}}' \
      | jq "$q" ;;
  "im reactions")
    [ -n "${FAKE_LARK_CALLS:-}" ] && printf '%s\n' "$*" >> "$FAKE_LARK_CALLS" ;;
  "api PATCH"|"im pins")
    [ -n "${FAKE_LARK_CALLS:-}" ] && printf '%s\n' "$*" >> "$FAKE_LARK_CALLS"
    echo '{"ok":true,"code":0}' ;;
  "im +messages-send")
    [ -n "${FAKE_LARK_CALLS:-}" ] && printf '%s\n' "$*" >> "$FAKE_LARK_CALLS"
    echo '{"ok":true,"data":{"message_id":"om_console","chat_id":"oc_test"}}' ;;
  "api POST")
    [ -n "${FAKE_LARK_CALLS:-}" ] && printf '%s\n' "$*" >> "$FAKE_LARK_CALLS"
    echo '{"code":0}' ;;
esac
