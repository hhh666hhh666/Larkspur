#!/usr/bin/env bash
# 用法：card-new.sh
# 由总控调用：在你和机器人的私聊里发一张「新建会话」表单卡片（Card 2.0）。
# 目录下拉框列出 $PROJECTS_ROOT 下的文件夹（最近修改的在前，最多 50 个）。
# 成功时 stdout 输出卡片消息的 message_id。
set -u
. "${LARKSPUR_HOME:-$HOME/.claude/larkspur}/common.sh"
require_open_id

opts=$(find "$PROJECTS_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@\t%f\n' 2>/dev/null \
       | sort -rn | head -50 | cut -f2 \
       | jq -R . | jq -sc 'map({text:{tag:"plain_text", content:.}, value:.})')
[ "$opts" != "[]" ] || { echo "在 $PROJECTS_ROOT 下没有找到任何文件夹" >&2; exit 1; }

card=$(jq -cn --argjson opts "$opts" --arg root "$PROJECTS_ROOT" '{
  schema: "2.0",
  header: {
    title:    {tag:"plain_text", content:"新建 Claude 会话"},
    subtitle: {tag:"plain_text", content:"Larkspur 总控"},
    template: "blue"
  },
  body: {
    direction: "vertical",
    padding: "12px 12px 16px 12px",
    elements: [
      { tag:"markdown",
        content: ("<font color=\"grey\">目录来自 `" + $root + "`，最近修改的在前。新会话会有自己的飞书群，并出现在桌面端侧边栏。</font>") },
      { tag:"form", name:"new_session", vertical_spacing:"medium", elements: [
          { tag:"select_static", name:"dir", required:true, width:"fill",
            placeholder:{tag:"plain_text", content:"选择项目目录"}, options:$opts },
          { tag:"input", name:"title", width:"fill", max_length:40,
            label:{tag:"plain_text", content:"群名标题"},
            placeholder:{tag:"plain_text", content:"可留空，自动取名"} },
          { tag:"input", name:"prompt", width:"fill", input_type:"multiline_text", rows:3,
            label:{tag:"plain_text", content:"第一句话"},
            placeholder:{tag:"plain_text", content:"可留空；填了会作为你在新群里的第一条消息"} },
          { tag:"button", name:"submit", form_action_type:"submit",
            type:"primary_filled", width:"fill",
            text:{tag:"plain_text", content:"创建会话"} }
      ]}
    ]
  }
}')

out=$("$LARK" im +messages-send --as bot --user-id "$OPEN_ID" --msg-type interactive --content "$card" 2>&1)
mid=$(printf '%s' "$out" | jq -r '.data.message_id // empty' 2>/dev/null)
[ -n "$mid" ] || { echo "发送卡片失败：" >&2; printf '%s\n' "$out" >&2; exit 1; }
fs_log "card-new mid=$mid"
echo "$mid"
