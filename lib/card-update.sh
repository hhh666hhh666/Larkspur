#!/usr/bin/env bash
# 用法：
#   card-update.sh <token> creating <目录>
#   card-update.sh <token> done     <目录> <chat_id> <群名>
#   card-update.sh <token> failed   <错误信息>
# 用卡片回调里的 token 把「新建会话」卡片更新为对应状态（token 30 分钟内有效、最多用 2 次）。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"

token="${1:?缺少 token}"; state="${2:?缺少状态}"; shift 2

hdr() { jq -cn --arg t "$1" --arg c "$2" '{title:{tag:"plain_text", content:$t}, subtitle:{tag:"plain_text", content:"Larkspur 总控"}, template:$c}'; }

case "$state" in
  creating)
    dir="${1:-}"
    card=$(jq -cn --argjson h "$(hdr '正在创建会话…' 'wathet')" --arg d "$dir" '{schema:"2.0", header:$h, body:{elements:[
      {tag:"markdown", content:("**目录**　" + $d + "\n<font color=\"grey\">正在后台新建会话、建群并导入桌面端，约需半分钟。</font>")}
    ]}}') ;;
  done)
    dir="${1:-}"; chat="${2:-}"; name="${3:-}"
    url="https://applink.feishu.cn/client/chat/open?openChatId=$chat"
    card=$(jq -cn --argjson h "$(hdr '会话已创建' 'green')" --arg d "$dir" --arg n "$name" --arg u "$url" '{schema:"2.0", header:$h, body:{elements:[
      {tag:"markdown", content:("**群名**　" + $n + "\n**目录**　" + $d + "\n<font color=\"grey\">桌面端侧边栏里也能看到这个会话。</font>")},
      {tag:"button", type:"primary_filled", width:"fill", text:{tag:"plain_text", content:"进入群聊"},
       behaviors:[{type:"open_url", default_url:$u}]}
    ]}}') ;;
  failed)
    err="${1:-未知错误}"
    card=$(jq -cn --argjson h "$(hdr '创建失败' 'red')" --arg e "$err" '{schema:"2.0", header:$h, body:{elements:[
      {tag:"markdown", content:($e + "\n<font color=\"grey\">可以在私聊里重新发「新会话」再试一次。</font>")}
    ]}}') ;;
  *) echo "未知状态：$state" >&2; exit 1 ;;
esac

out=$("$LARK" api POST /open-apis/interactive/v1/card/update --as bot \
        --data "$(jq -cn --arg t "$token" --argjson c "$card" '{token:$t, card:$c}')" 2>&1)
if printf '%s' "$out" | jq -e '.ok == true or .code == 0' >/dev/null 2>&1; then
  fs_log "card-update state=$state"; echo "ok"
else
  fs_log "card-update-failed state=$state"; printf '%s\n' "$out" >&2; exit 1
fi
