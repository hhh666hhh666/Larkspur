# Larkspur 个人配置。install.sh 会复制到 ~/.claude/larkspur/config.sh 并尽量自动填好。
# 这个文件只在本机，不要提交到版本库。

# 你自己的飞书 open_id（ou_ 开头）。只有这个发送者的消息会被转给 Claude。
# 查看方法：lark-cli auth status 输出里的 identities.user.openId
LARKSPUR_OPEN_ID=""

# lark-cli 的路径。留空则自动查找（PATH 中的 lark-cli，或 ~/.local/bin/lark-cli）。
LARKSPUR_LARK_CLI=""

# 飞书图片下载目录。必须位于 lark-cli 允许的根目录内（当前目录、/tmp 或 ~/files）。
LARKSPUR_INBOX="$HOME/files/larkspur-inbox"

# 收到图片后等待文字的秒数：期间到达的文字会和图片合并成一条消息。
LARKSPUR_IMAGE_WAIT=3

# 飞书群名前缀，群名形如「Claude · 项目目录名 · 会话标题」。
LARKSPUR_GROUP_PREFIX="Claude"

# 总控模式：「新会话 <名字>」里不是绝对路径的目录，相对于这个根目录查找。
LARKSPUR_PROJECTS_ROOT="$HOME"

# 总控模式新建会话时用的 claude 命令。留空则自动查找（PATH 中的 claude，或桌面端自带的那份）。
LARKSPUR_CLAUDE_BIN=""

# 总控新建的会话导入桌面端后，切换到哪个权限模式：default、acceptEdits、auto、bypassPermissions。
# 桌面端导入的会话一律是「手动」，从飞书发的指令会卡在确认弹窗上。切换时桌面端会弹一张确认卡，要在电脑上点一次。
# 设为空字符串则不切换。
LARKSPUR_SPAWN_PERMISSION_MODE="bypassPermissions"

# 收到你的飞书消息时，给那条消息加的表情回复，表示 Claude 已收到。Get 显示为「了解」；留空则不加。
LARKSPUR_ACK_EMOJI="Get"

# 发回飞书失败、或某个群的消息因会话已关闭同步而没有转发时，在飞书里提醒你：on 或 off。
LARKSPUR_ALERTS="on"

# 总控在跑时，每隔多少秒重新做一次网络检测（出口 IP、信任评分等）并刷新控制台卡片；0 关闭。
LARKSPUR_NET_REFRESH="60"

# 本地网页控制台端口（只监听 127.0.0.1）。random：第一次启动时在 20000～60999 里随机挑一个，写回这里，之后固定不变。
LARKSPUR_WEB_PORT="random"

# IP 守卫：三个出口 IP（国内网站、Cloudflare、Claude 看到的）都应是这个 IP；留空不检查。
# 设了以后，install.sh 会装上桌面端启动闸门（~/.local/bin/claude-desktop）：三个都确认相符才启动桌面端，否则不启动、不联网。
LARKSPUR_EXPECTED_IP=""
# 桌面端启动前最多等多少秒让 IP 变对（开机时代理可能还没起来），期满仍不符就不启动。
LARKSPUR_DESKTOP_GATE_WAIT="30"
# 开关（也可以在本地网页控制台里切换）：桌面端启动闸门、运行中的 IP 守卫，on 或 off。
LARKSPUR_DESKTOP_GATE="on"
LARKSPUR_IP_GUARD="on"
# 运行中（会话启动时、每次网络检测刷新后）发现出口 IP 不符时运行的命令，stdin 会收到 "y"；留空只提醒。
LARKSPUR_IP_GUARD_CMD=""
# 桌面端启动、总控会话被拉起时，自动让它启动飞书监听：on 或 off。
LARKSPUR_HUB_AUTOSTART="on"
