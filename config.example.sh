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
