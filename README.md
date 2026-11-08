# Larkspur

**按会话把 Claude Code 接到飞书**：在任意一个 Claude Code 会话里执行 `/feishu on`，机器人就会为这个会话新建一个独立的飞书群。AI 的回复会发到群里，你在群里发的文字和图片也会回到这个会话，交给 Claude 处理。每个会话一个群，互不干扰。

> Larkspur（飞燕草）：名字里带着 Lark，也就是飞书的英文名。

[English summary](#english-summary)

## 特性

### 会话同步

- **按会话开启**：默认关闭，只对执行了 `/feishu on` 的会话生效，用 `/feishu off` 中途关闭。
- **一个会话一个群**：群名形如「Claude · 项目目录名 · 会话标题」，会话标题直接取自 Claude 桌面端。
- **双向**：AI 每轮的最终回复以 Markdown 富文本发到群里；你在群里发的消息会转给会话。
- **图片**：群里的图片会下载到本地，交给 Claude 看图。图片后几秒内跟上的文字会合并成一条消息（秒数可调）。
- **桌面端显示为消息气泡**：群里的消息由总控转发进对应会话，在桌面端显示成一条用户消息气泡（标着"来自 飞书总控"）。
- **已读回执**：收到你的飞书消息时，立刻给那条消息加一个表情（默认「了解」），表示已经收到。
- **只认你本人**：只放行你自己的 open_id、且发在该会话专属群里的消息。

### 总控

- **在飞书里新建会话**：把一个会话设为总控（`/feishu hub`），在和机器人的私聊里发 `新会话 <目录> [标题]`，或发 `新会话` 后在表单卡片里选目录，就会在该目录新建一个 Claude Code 会话、建好它的专属群，并导入桌面端侧边栏（桌面端没开时只建会话不导入，不会把桌面端拉起来）。
- **统一转发**：所有群的消息由一路监听收下，再由总控投进对应会话。**必须有总控**：普通会话不允许自己监听。
- **按需唤醒，空闲不花 token**：总控不挂 Monitor。每个回合结束时，Stop 钩子在后台等事件队列，有飞书消息、卡片提交、要转发的群消息时才唤醒总控处理；没有消息时不调用模型，也没有每半小时的续期回合（约 7 天续期一次）。
- **桌面端重启后自动恢复**：桌面端启动、总控会话被拉起时，SessionStart 钩子直接开始等事件，不调用模型；中断期间排队的事件立刻交给总控。总控会话没被拉起时，由一个开着同步的会话把它叫起来。

### 常驻服务 Larkspur 与本地网页控制台

- **飞书监听不依赖桌面端**：监听、网络检测和 IP 守卫都在常驻服务里（systemd 用户服务），桌面端重启、总控上下文压缩都不会断；这期间的事件排在队列里，总控回来后一次补上。监听意外退出会自动重启。
- **本地网页控制台**：`http://localhost:<随机高位端口>/`，端口第一次启动时随机挑选并记住。可以看状态、完整的网络检测、开关 IP 闸门和守卫、改期望 IP、关闭会话同步、改功能选项，以及启动 Claude 桌面端、**关闭 Larkspur**。
- **桌面图标**：双击桌面上的「Larkspur」启动服务并打开控制台；不设开机自启，在网页上关闭。
- **网页只给本机用**：只监听 127.0.0.1；写操作要带自定义请求头并校验 Host、Origin，别的网页没法让浏览器替它关软件或改设置。

### 飞书控制台卡片

- **置顶在总控私聊里**：状态、会话、网络检测、功能选项四个折叠面板，原地更新，不另发消息。点机器人菜单「控制台」或在私聊里发「控制台」「状态」「会话」「网络」「设置」打开。
- **卡片上直接操作**：进群、关闭同步、归档会话、新建会话、启动 Claude 桌面端、改设置，都由脚本处理，不唤醒 Claude，不花 token（只有归档要交给总控）。
- **自动刷新**：会话开关、新建时刷新；网络检测每分钟刷新一次。

### 网络检测（与 ip.net.coffee/claude 相同）

- **三个出口 IP**：中国出口 IPv4、Cloudflare 出口 IP、Claude AI 出口 IP，各带归属地。
- **风险**：Claude AI 信任评分、是否 Claude 支持的地区、住宅/机房、ASN 与运营商、VPN/代理/Tor/爬虫/滥用记录。
- **可用性**：claude.ai、anthropic.com、api.anthropic.com 延迟，Claude 服务状态，DNS 泄露。
- 每分钟自动检测，也可以随时点「重新检测」。

### 出口 IP 守卫

- **三个出口都要相符**：设了期望 IP 后，国内、Cloudflare、Claude 看到的出口 IP 都必须是它。
- **启动闸门**（先于一切）：每次启动 Claude 桌面端都先检查，三个都确认相符才启动；不符或查不到就不启动、不联网，并弹出通知、在飞书里提醒。
- **运行中守卫**：会话启动时和每次网络检测后检查，确认不符（连续两次现查）就提醒并运行守卫命令（例如结束所有 Claude 进程）。查不到 IP 不算不符，不会误杀。
- **桌面端只能手动启动**：Larkspur 从不自动启动或重启桌面端；桌面端退出后，只能自己打开，或在网页控制台、飞书控制台卡片上点「启动桌面端」（同样经过启动闸门）。
- 两个开关和期望 IP 都在网页控制台里设置。

### 可靠性

- **断线补发**：监听重启时，补发中断期间漏掉的消息（时长可调），按 message_id 去重。
- **不留孤儿进程**：监听脚本被强杀时，它的 lark-cli 几秒内自己退出；新监听启动时还会清掉上一轮留下的。关闭 Larkspur 时连同所有子进程一起结束。
- **会话 ID 变了也认得**：桌面端重启或压缩上下文后会话 ID 可能变化，按桌面端会话 ID 找回同步记录。
- **异常提醒**：发回失败、消息没能转发、Larkspur 没在运行时，在飞书里提醒（同一件事 10 分钟内只提醒一次）。

### 依赖

- 只用到官方的 [`lark-cli`](https://www.npmjs.com/package/@larksuite/cli)、Claude Code 自带的钩子与技能，以及系统自带的 bash、jq、curl、Python 3（标准库）。网络检测的数据来自 ip.net.coffee。

## 工作原理

**只有总控监听**，普通会话不允许自己挂监听（`lib/mode.sh` 输出 `router` 表示总控在工作，`none` 表示没有总控）：

- 总控用一路 lark-cli 监听自己的私聊和所有会话的专属群。收到你在某个会话专属群里的消息后，输出一行 `飞书转发` 事件，总控用桌面端的 `send_message` 把原文投进那个会话，显示为消息气泡。
- 普通会话即使执行了 `listen.sh` 也会直接退出；总控监听启动时，会把旧版本留下的会话监听全部停掉。
- 没有总控时，普通会话照常把 AI 回复发到群里，但收不到群消息，Stop 钩子会在群里提醒你开总控（10 分钟内最多一次）。总控开启后会补发中断期间的消息。

```
                     /feishu on
Claude Code 会话 ◄──────────────► on.sh：机器人建群，记录「会话 ID → 群 ID」
     ▲   │
     │   ├─ Stop 钩子（notify.sh）：本轮最终回复 ──────────────► 飞书群
     │   └─ Stop 钩子（ensure-listener.sh）：总控监听停了就提醒总控；没有总控就在群里提醒开总控
     │
     │ send_message（消息气泡）
     │
总控会话 ◄── 钩子在后台等事件，有事件才唤醒（listen-wait.sh 读事件队列）◄── 常驻服务 Larkspur（listen.sh --hub：一路 lark-cli 长连接，按发送者过滤，下载图片）◄── 飞书：私聊 + 各会话的群
                                                         └── 本地网页控制台 http://localhost:<随机端口>/、每分钟网络检测、IP 守卫
```

| 文件 | 作用 |
|---|---|
| `lib/on.sh` / `lib/off.sh` | 开启、关闭会话同步，建群或复用已有的群 |
| `lib/listen.sh` | 监听飞书消息（由常驻服务运行），每行输出一个事件；`--hub` 时同时监听卡片、转发其他会话的群消息 |
| `lib/hub-on.sh` | 把会话设为总控，同步对象是你和机器人的私聊 |
| `lib/spawn.sh` | 总控用：后台新建会话、建群，并用 `claude://resume?session=<id>` 导入桌面端 |
| `lib/card-new.sh` / `lib/card-update.sh` | 总控用：发「新建会话」表单卡片，并按结果更新卡片 |
| `lib/listen-cards.sh` | 总控用：监听卡片表单提交，由 `listen.sh --hub` 在后台拉起 |
| `lib/say.sh` | 总控用：以机器人身份发一条提醒 |
| `lib/console.sh` | 控制台卡片：渲染、置顶、原地更新，处理卡片上的点击 |
| `lib/netcheck.sh` | 检测本机访问 Claude 的出口 IP、信任评分和风险，结果缓存给控制台 |
| `lib/netwatch.sh` | 每分钟重做网络检测、刷新控制台、跑 IP 守卫，由常驻服务拉起 |
| `lib/exit-ips.sh` | 并发查三个出口 IP（国内网站、Cloudflare、Claude 看到的），可判断是否都等于期望 IP |
| `lib/ipguard.sh` | IP 守卫：出口 IP 不符时提醒并运行守卫命令（会话启动时、每次网络检测刷新后） |
| `lib/desktop-start.sh` | 手动启动桌面端（网页、飞书卡片上的按钮），经过启动闸门 |
| `lib/desktop-gate.sh` | 桌面端启动闸门，装为 `~/.local/bin/claude-desktop`：三个出口 IP 都相符才启动桌面端 |
| `hooks/session-start.sh` | SessionStart 钩子：会话启动时跑 IP 守卫；桌面端拉起总控会话时直接开始等飞书事件 |
| `hooks/hub-wait.sh` | Stop 钩子（后台）：总控每个回合结束时开始等飞书事件，有事件才唤醒总控 |
| `lib/larkspurd.py` | 常驻服务：飞书监听、每分钟网络检测与 IP 守卫、本地网页控制台（`lib/web/index.html`） |
| `lib/larkspurctl.sh` | 启动、关闭、查看常驻服务；`open` 启动并在浏览器打开控制台（桌面「Larkspur」图标） |
| `lib/listen-wait.sh` | 总控的钩子在后台运行：等常驻服务写下的事件队列，有事件就交给总控 |
| `lib/listen-inbox.sh` | 已停用（旧版总控的 Monitor）：只告诉还按老办法运行的总控停下 |
| `lib/listen-menu.sh` | 总控用：响应机器人菜单「控制台」 |
| `lib/mode.sh` | 输出当前有没有总控在转发（router / none） |
| `hooks/notify.sh` | Stop 钩子：只给开启了同步的会话，把最终回复发到对应的群 |
| `hooks/ensure-listener.sh` | Stop 钩子：普通会话发现总控没在接收事件就提醒总控；没有总控、Larkspur 没在运行时在群里提醒 |
| `hooks/session-end.sh` | SessionEnd 钩子：只在 `/clear`、登出时关闭同步，进程退出时保留 |
| `skill/SKILL.md` | `/feishu on \| off` 技能，告诉 Claude 如何处理飞书事件 |

## 前置条件

1. **Claude Code**，需要支持 `asyncRewake` 的钩子，最好是桌面端，这样能读到会话标题。
2. **jq**、**bash**。
3. **lark-cli** 已安装并登录：

   ```bash
   npm install -g @larksuite/cli
   lark-cli config init --new
   lark-cli auth login --recommend
   ```

4. **飞书自建应用**，也就是 `lark-cli config init` 用到的那个应用，需要：
   - 开启机器人能力；
   - 事件订阅使用**长连接**，并订阅 `im.message.receive_v1`（接收消息）；
   - 机器人能建群、改群名、在群里发消息、下载消息里的图片、给消息加表情回复（`im:message.reactions:write_only`）、置顶消息（`im:message.pins:write_only`，控制台用）；
   - 开通 `im:message.group_msg`（获取群组中所有消息）。不开的话，你在群里每条消息都要 @机器人。
   - 使用总控的卡片功能时，在「事件与回调 → 回调配置」里添加回调 `card.action.trigger`（卡片回传交互），订阅方式选长连接，然后**发布新版本**。不开的话监听照样能启动，但收不到任何卡片提交。

   权限名以飞书开放平台后台为准。缺权限时 `lark-cli` 会报出缺少的 scope，按提示补开即可。

## 安装

```bash
git clone https://github.com/hhh666hhh666/Larkspur.git
cd Larkspur
./install.sh
```

安装脚本会：

- 把脚本装到 `~/.claude/larkspur/`；
- 生成个人配置 `~/.claude/larkspur/config.sh`，open_id 从 `lark-cli auth status` 自动读取；
- 把技能装到 `~/.claude/skills/feishu/`；
- 把两个 Stop 钩子和一个 SessionEnd 钩子合并进 `~/.claude/settings.json`，改动前会先备份。

可以重复执行，不会产生重复的钩子。已经打开的会话可能要重开，才会加载新的钩子和技能。

## 使用

在 Claude Code 会话里：

| 命令 | 作用 |
|---|---|
| `/feishu on` | 为当前会话开启同步，群名用会话标题 |
| `/feishu on 修登录 bug` | 开启同步，并自定义群名标题 |
| `/feishu off` | 关闭同步，群保留，再次开启时复用同一个群 |
| `/feishu hub` | 把当前会话设为总控 |

桌面端重启、上下文压缩不会关闭同步：会话下一回合结束时会自动恢复监听，并补发中间漏掉的消息。`/clear` 和登出会关闭同步。

### 总控：在飞书里新建会话

1. 找一个常开的会话，执行 `/feishu hub`。机器人会在你们的私聊里发一条说明。
2. 两种方式新建会话：
   - **卡片**：在私聊里只发 `新会话`，机器人会发一张表单卡片。目录用下拉框选，下拉框列出 `LARKSPUR_PROJECTS_ROOT` 下最近修改的文件夹；群名标题和第一句话可以留空。点「创建会话」后，卡片约 1 秒内就会变成"正在创建"，表单随之消失，同一张卡片也只认第一次提交，不会重复建会话；建好后卡片变成"会话已创建"，并带有进群按钮。
   - **文字**：发 `新会话 <目录> [标题]`。目录可以是绝对路径，或 `LARKSPUR_PROJECTS_ROOT` 下的名字。
3. 总控会：
   1. 在该目录用 `claude -p` 后台新建一个会话；
   2. 为它建专属群；
   3. 通过 `claude://resume?session=<id>` 把它导入 Claude 桌面端；
   4. 如果 `~/.claude/settings.json` 的默认权限模式不是 `auto`，就在私聊里提醒你，然后把它切到「跳过权限确认」模式。桌面端会弹一张确认卡，要在电脑上点一下；
   5. 给它发一条消息，让它启动自己的监听。
4. 去新群里对话即可，桌面端侧边栏里也能看到这个会话。

### 控制台

总控私聊里置顶着一张「Larkspur 控制台」卡片，分四页：

- **状态**：接收方式、总控监听是否在跑、同步中的会话数、今天收到/转发/发回的条数、常驻内存、最近事件。
- **会话**：每个同步中的会话一行，带「进群」「关闭同步」「归档会话」按钮（后两个会先弹确认）。
- **网络检测**：前三行依次是中国出口 IPv4、Cloudflare 出口 IP、Claude AI 出口 IP（各带归属地），然后是信任评分、是否 Claude 支持的地区、住宅/机房、ASN 与运营商、VPN/代理/Tor/爬虫/滥用记录、claude.ai/anthropic.com/api.anthropic.com 延迟、Claude 服务状态、DNS 泄露。检测项与 [ip.net.coffee/claude](https://ip.net.coffee/claude/) 相同，数据也来自它（WebRTC 只存在于浏览器，不检测）。总控在跑时每分钟自动重测并刷新整张卡片（`LARKSPUR_NET_REFRESH`），也可以点「重新检测」现测，约 10 秒。
- **功能选项**：已读回执表情、图片等文字的秒数、断线补发时长、新会话权限模式、异常提醒、群名前缀、项目根目录。保存后立即生效，不用重启监听。

打开方式：点私聊输入框上方的机器人菜单「控制台」，或在私聊里发「控制台」「状态」「会话」「网络」「设置」。卡片不在了会重新发一张并置顶。

切页、刷新、关闭同步、改设置、发新建卡片、网络检测都由脚本直接完成，不唤醒 Claude，不花 token；只有「归档会话」要用到桌面端工具，会交给总控处理。会话开启、关闭或新建时，卡片也会自动刷新。

要用机器人菜单，需要在飞书开放平台：

1. 「机器人 → 机器人自定义菜单」里开启菜单，加一个「推送事件」类型的菜单项，名称「控制台」，事件 ID 填 `console`；
2. 「事件与回调 → 事件配置」里订阅 `application.bot.menu_v6`（机器人自定义菜单事件）；
3. 发布新版本。

不配菜单也能用，在私聊里发「控制台」即可。

### 常驻服务与本地控制台

不需要 Claude 的部分都在常驻服务 **Larkspur**（`larkspurd`，Python 标准库，systemd 用户服务）里运行，不依赖 Claude 桌面端：

- **飞书监听**：有总控时，服务运行 `listen.sh <总控私聊> --hub`（私聊、卡片、菜单、群消息转发），到时或意外退出后自动重启。每行事件写进队列 `run/hub-queue`，总控会话的钩子在后台运行 `listen-wait.sh` 等着，有事件就取走（队列随即清空）并唤醒总控。桌面端重启、总控上下文压缩时事件排在队列里，总控回来后一次补上。
- **每分钟网络检测、刷新飞书控制台、运行中 IP 守卫**。
- **本地网页控制台**：浏览器打开 `http://localhost:<端口>/`（随机高位端口，见下），可以看状态、网络检测、开关 IP 闸门、改期望 IP、关闭会话同步、改功能选项，以及**关闭 Larkspur**。只监听 127.0.0.1；写操作要带自定义请求头并校验 Host 和 Origin，别的网页没法让浏览器替它关软件或改设置。

打开与关闭：`install.sh` 在桌面放一个「Larkspur」图标（应用菜单里也有），双击启动服务并在浏览器里打开控制台；在网页上点「关闭 Larkspur」关闭。不设开机自启。命令行：`~/.claude/larkspur/larkspurctl.sh start|stop|status|open`。总控执行 `/feishu hub` 时也会顺手启动它。

**端口**：第一次启动时在 20000～60999 里随机挑一个高位端口，写进 `config.sh` 的 `LARKSPUR_WEB_PORT`，之后一直用它（网址不变，可以收藏）。这个端口被别的程序占了时会重新随机挑一个，页面顶部会提示。也可以在 `config.sh` 里改成指定端口（1024 以上）。用桌面的「Larkspur」图标打开时，总会打开当前的地址。

### 出口 IP 守卫与自动启动总控

设了 `LARKSPUR_EXPECTED_IP` 后，「出口 IP」指三个：国内网站（ipip.net）、Cloudflare（1.1.1.1）和 Claude（claude.ai）看到的 IP，三个都要等于它。

- **桌面端启动前**（先于一切）：`install.sh` 把闸门装成 `~/.local/bin/claude-desktop`。菜单、面板图标、`claude://` 链接都按 PATH 找 `claude-desktop`，而 `~/.local/bin` 排在最前，所以每次启动都先过闸门：三个 IP 都查到且相符才启动真正的桌面端；否则在 `LARKSPUR_DESKTOP_GATE_WAIT` 秒内重查，期满仍不通过就不启动——桌面端不运行，也就不会联网，同时弹出桌面通知并在飞书私聊里提醒。桌面端已在运行时（点 `claude://` 链接）直接放行。直接运行 `/usr/bin/claude-desktop` 会绕过闸门。
- **运行中**：每个会话启动时（SessionStart 钩子），以及控制台每次网络检测刷新之后，都跑一次 IP 守卫。有任何一个 IP 查到了且不符，就再现查两次确认，然后在飞书私聊里提醒，并运行 `LARKSPUR_IP_GUARD_CMD`（例如结束所有 Claude 进程的脚本）。查不到 IP（断网）不算不符。
- **桌面端只能手动启动**：Larkspur 从不自动启动或重启 Claude 桌面端（`desktop-start.sh` 是唯一的启动入口，只由按钮触发）。在网页控制台或飞书控制台卡片上点「启动桌面端」，同样先过启动闸门；启动的桌面端放在单独的 systemd scope 里，关闭 Larkspur 不会连带关掉它。总控新建会话时，桌面端没开就不导入（`claude://` 链接会把桌面端拉起来）。
- **开关**：在本地网页控制台的「IP 闸门」卡片里开关「启动闸门」和「运行中守卫」、改期望 IP，保存后立即生效。打开守卫或改期望 IP 会让守卫马上动手时，会先弹确认。
- **自动启动总控**：桌面端启动时会自动拉起之前打开的会话。总控会话被拉起时，SessionStart 钩子发现它的飞书监听没在跑，就唤醒它启动监听；万一总控会话没被拉起，30 秒后由一个开着同步的会话给总控发消息，把它拉起来。

注意：

- 导入时桌面端会切到新会话，可能打断你正在桌面端的操作。
- 新会话收到的是总控转述的开启指令，不是你亲手输入的。
- **权限模式**：桌面端导入的会话沿用 settings.json 里的 `permissions.defaultMode`，没设就是「手动」，每条命令都要在桌面端确认。设成 `bypassPermissions` 也只会降成「接受编辑」，运行命令仍要确认。
  - **推荐**：把默认模式设成 `auto`，导入后直接是 auto 模式，命令由系统自动判断放行或拦下，不弹窗，总控也就不用切换模式。
  - **否则**：总控会在导入后切换模式。桌面端规定升权限必须由你在电脑上点确认，没法只靠飞书完成。不点的话，新会话照样能用，只是每条命令都要在桌面端确认。
- 导入深链接是从桌面应用里观察到的行为，不是公开文档中的接口，以后的版本可能改变。

## 配置

在控制台的「功能选项」里改，或编辑 `~/.claude/larkspur/config.sh`：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `LARKSPUR_OPEN_ID` | 安装时自动获取 | 唯一被放行的发送者，也就是你自己 |
| `LARKSPUR_LARK_CLI` | 自动查找 | `lark-cli` 路径 |
| `LARKSPUR_INBOX` | `~/files/larkspur-inbox` | 图片下载目录，必须在 lark-cli 允许的根目录内 |
| `LARKSPUR_IMAGE_WAIT` | `3` | 图片后等待文字合并的秒数 |
| `LARKSPUR_GROUP_PREFIX` | `Claude` | 群名前缀 |
| `LARKSPUR_PROJECTS_ROOT` | `$HOME` | 总控「新会话 <名字>」时相对目录的根 |
| `LARKSPUR_CLAUDE_BIN` | 自动查找 | 总控新建会话时用的 `claude` 命令 |
| `LARKSPUR_SPAWN_PERMISSION_MODE` | `bypassPermissions` | 总控新建的会话导入后切到的权限模式，留空不切换；默认模式是 `auto` 时自动跳过 |
| `LARKSPUR_ALERTS` | `on` | 发回失败、消息没能转发时提醒你 |
| `LARKSPUR_ACK_EMOJI` | `Get` | 收到消息时加的表情回复（`Get` 即「了解」），留空不加 |
| `LARKSPUR_NET_REFRESH` | `60` | 总控在跑时每隔多少秒重做网络检测并刷新控制台卡片，`0` 关闭 |
| `LARKSPUR_WEB_PORT` | `random` | 本地网页控制台端口，只监听 127.0.0.1；`random` 时首次随机挑一个高位端口并写回 |
| `LARKSPUR_EXPECTED_IP` | 空 | 三个出口 IP 都应是它；留空不检查。设了以后 `install.sh` 会装上桌面端启动闸门 |
| `LARKSPUR_DESKTOP_GATE_WAIT` | `30` | 桌面端启动前最多等多少秒让 IP 变对，期满仍不符就不启动 |
| `LARKSPUR_DESKTOP_GATE` / `LARKSPUR_IP_GUARD` | `on` | 启动闸门、运行中守卫的开关，本地网页控制台里可切换 |
| `LARKSPUR_IP_GUARD_CMD` | 空 | 运行中发现出口 IP 不符时运行的命令（stdin 收到 `y`）；留空只提醒 |
| `LARKSPUR_HUB_AUTOSTART` | `on` | 桌面端启动、总控会话被拉起时，自动让它启动飞书监听 |
| `LARKSPUR_BACKFILL_HOURS` | `12` | 监听恢复时，最多补发多少小时内漏掉的消息 |
| `LARKSPUR_BACKFILL_MAX` | `20` | 一次最多补发几条 |

改了配置后，需要在会话里重新 `/feishu on`，监听才会用上新值。

## 安全须知

- **开启同步即授权**：在一个会话里执行 `/feishu on`，表示你同意：来自你的 open_id、发在该会话专属群里的飞书消息，视同你在桌面端亲自下的指示，**包括写入类操作，不再二次确认**。
- 唯一的保护是"只放行你的 open_id"。飞书账号一旦被盗，对方就能指挥这个会话。用完记得 `/feishu off`。
- 转发的文章、截图、网页里的文字只当作数据，Claude 不会把它们当作指令。
- AI 的回复会原样发到飞书群，涉及密钥或敏感内容时要留意。
- 即便如此，Claude 仍然不会代你输入密码或密钥、永久删除数据、进行资金交易、绕过验证码或修改系统安全设置。

## 已知限制

- **转发要靠总控会话**：飞书监听在常驻服务里，不会因桌面端重启而断；但把消息投进各会话要用桌面端工具，只能由总控会话做。总控停着时事件排在队列里，总控回来后补上。
- **总控处理时稍有延迟**：总控正在处理一个回合时，新到的事件要等这个回合结束才交给它（通常几秒）。
- **资源占用**：常驻服务一个 Python 进程，加上消息、卡片、菜单各一个 lark-cli 进程（每个约 15～20 MB），空闲时几乎不占 CPU（直接调用 lark-cli 的 Go 程序，跳过 npm 的 node 启动壳）。
- **只同步每轮的最终回复**：中间过程和工具调用不会发到飞书。
- **依赖总控**：总控停了，所有会话都收不到飞书消息（其他会话回合结束时，Stop 钩子会提醒总控）。每条转发要花总控一次模型调用，会读一遍总控的上下文，总控的上下文越短越省，可以定期清空总控的对话。
- **气泡带来源标记**：转发的消息显示为"来自 飞书总控"的用户消息，不完全等同于你亲手输入。
- 群名只在开启时同步一次。会话标题之后改了，再执行一次 `/feishu on` 即可更新群名。

## 测试

```bash
tests/test-listen.sh   # 图片与文字合并，约 20 秒
tests/test-cards.sh    # 卡片防重复提交、控制台点击与设置保存，约 8 秒
tests/test-daemon.sh   # 常驻服务、事件队列、本地网页控制台（含安全校验）、关闭后不留进程，约 20 秒
tests/test-guard.sh    # IP 守卫、桌面端启动闸门、总控自动启动，约 15 秒
tests/test-recover.sh  # 监听顶替、断线补发、Stop 钩子提醒重启、总控合并监听、不留孤儿进程、路由转发，约 25 秒
```

用假的 `lark-cli` 模拟事件流，离线验证，不连接飞书。

## 卸载

```bash
./uninstall.sh          # 移除钩子、技能和脚本，保留配置与会话记录
./uninstall.sh --purge  # 连同配置、会话记录和日志一起删除
```

飞书里已经建好的群不会被删除。

## English summary

Larkspur bridges individual Claude Code sessions to Feishu/Lark. Run `/feishu on` in a session and a bot creates a dedicated Feishu group for it. Claude's final reply each turn is posted to the group, and your messages and images in that group are relayed into the session by a hub session (`/feishu hub`), which runs the only listener; individual sessions never listen on their own. Each session gets its own group, so conversations never mix. It uses only the official `lark-cli`, Claude Code hooks and a skill. The hub is woken only when an event arrives, so an idle hub costs no model calls. Only messages from your own open_id in the session's group are accepted. Enabling it authorizes Claude to act on those messages as if you had typed them, so read the security notes above. Install with `./install.sh`, remove with `./uninstall.sh`.

## 许可证

[MIT](LICENSE)
