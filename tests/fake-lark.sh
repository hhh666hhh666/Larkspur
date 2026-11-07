#!/usr/bin/env bash
# Larkspur 离线测试用的假 lark-cli：模拟事件流与图片下载
case "$1 $2" in
  "event consume")
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
esac
