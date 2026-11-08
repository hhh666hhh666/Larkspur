#!/usr/bin/env bash
# 用法：listen-inbox.sh（已停用）
# 以前总控用 Monitor 运行它读事件队列，每 29 分钟要模型续期一次。现在改为按需唤醒：
# 总控的钩子（hub-wait.sh、session-start.sh）在后台运行 listen-wait.sh，有飞书事件才唤醒总控。
# 留着这个文件，是为了让还按老办法启动 Monitor 的总控收到一句说明后停下，而不是和等待进程互相顶替。
printf '飞书监听状态: 总控已改为按需唤醒，飞书事件会在有消息时自动送进本会话，不再需要 Monitor。不要再启动或续期这个 Monitor，不要输出任何文字，直接结束本回合。\n'
