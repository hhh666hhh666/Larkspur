# Larkspur

**按会话把 Claude Code 接到飞书**：在任意一个 Claude Code 会话里执行 `/feishu on`，机器人就会为这个会话新建一个独立的飞书群。AI 的回复会发到群里，你在群里发的文字和图片也会回到这个会话，交给 Claude 处理。每个会话一个群，互不干扰。

> Larkspur（飞燕草）：名字里带着 Lark，也就是飞书的英文名。

[English summary](#english-summary)

## 特性

- **按会话开启**：默认关闭，只对执行了 `/feishu on` 的会话生效，用 `/feishu off` 中途关闭。
- **一个会话一个群**：群名形如「Claude · 项目目录名 · 会话标题」，会话标题直接取自 Claude 桌面端。
- **双向**：AI 每轮的最终回复以 Markdown 富文本发到群里；你在群里发的消息会转给会话。
- **图片**：群里的图片会下载到本地，交给 Claude 看图。图片后 3 秒内跟上的文字会合并成一条消息。
- **桌面端留痕**：Claude 回复飞书消息时，会先引用你的原话，桌面端的对话记录里能看到你在飞书说过什么。发回飞书时会去掉这段引用。
- **只认你本人**：只放行你自己的 open_id、且发在该会话专属群里的消息。
- **总控：在飞书里新建会话**：把一个会话设为总控（`/feishu hub`），在和机器人的私聊里发 `新会话 <目录> [标题]`，就会在该目录新建一个 Claude Code 会话、建好它的专属群，并导入桌面端侧边栏。
- **不依赖第三方服务**：只用到官方的 [`lark-cli`](https://www.npmjs.com/package/@larksuite/cli) 和 Claude Code 自带的钩子、技能与 Monitor 工具。

## 工作原理

```
                 /feishu on
Claude Code 会话 ───────────► on.sh：机器人建群，记录「会话 ID → 群 ID」
     │  ▲
     │  │ Monitor 事件（listen.sh：lark-cli 长连接，按群 ID 与发送者过滤，下载图片）
     │  └──────────────────────────────────────── 飞书群：你发的消息
     │
     └─ Stop 钩子（notify.sh）：本轮最终回复 ──────► 飞书群
        SessionEnd 钩子（session-end.sh）：会话关闭时自动关闭同步（群保留）
```

| 文件 | 作用 |
|---|---|
| `lib/on.sh` / `lib/off.sh` | 开启、关闭会话同步，建群或复用已有的群 |
| `lib/listen.sh` | 监听飞书消息，供 Monitor 使用，每行输出一个事件 |
| `lib/hub-on.sh` | 把会话设为总控，同步对象是你和机器人的私聊 |
| `lib/spawn.sh` | 总控用：后台新建会话、建群，并用 `claude://resume?session=<id>` 导入桌面端 |
| `lib/card-new.sh` / `lib/card-update.sh` | 总控用：发「新建会话」表单卡片，并按结果更新卡片 |
| `lib/listen-cards.sh` | 总控用：监听卡片表单提交 |
| `hooks/notify.sh` | Stop 钩子：只给开启了同步的会话，把最终回复发到对应的群 |
| `hooks/session-end.sh` | SessionEnd 钩子：会话结束时把同步标记为关闭 |
| `skill/SKILL.md` | `/feishu on \| off` 技能，告诉 Claude 如何处理飞书事件 |

## 前置条件

1. **Claude Code**，需要 Monitor 工具，最好是桌面端，这样能读到会话标题。
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
   - 机器人能建群、改群名、在群里发消息、下载消息里的图片；
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
- 把 Stop、SessionEnd 钩子合并进 `~/.claude/settings.json`，改动前会先备份。

可以重复执行，不会产生重复的钩子。已经打开的会话可能要重开，才会加载新的钩子和技能。

## 使用

在 Claude Code 会话里：

| 命令 | 作用 |
|---|---|
| `/feishu on` | 为当前会话开启同步，群名用会话标题 |
| `/feishu on 修登录 bug` | 开启同步，并自定义群名标题 |
| `/feishu off` | 关闭同步，群保留，再次开启时复用同一个群 |
| `/feishu hub` | 把当前会话设为总控 |

关闭会话时会自动关闭同步。

### 总控：在飞书里新建会话

1. 找一个常开的会话，执行 `/feishu hub`。机器人会在你们的私聊里发一条说明。
2. 两种方式新建会话：
   - **卡片**：在私聊里只发 `新会话`，机器人会发一张表单卡片。目录用下拉框选，下拉框列出 `LARKSPUR_PROJECTS_ROOT` 下最近修改的文件夹；群名标题和第一句话可以留空。点「创建会话」后，卡片会依次变成"正在创建"和"会话已创建"，并带有进群按钮。
   - **文字**：发 `新会话 <目录> [标题]`。目录可以是绝对路径，或 `LARKSPUR_PROJECTS_ROOT` 下的名字。
3. 总控会：
   1. 在该目录用 `claude -p` 后台新建一个会话；
   2. 为它建专属群；
   3. 通过 `claude://resume?session=<id>` 把它导入 Claude 桌面端；
   4. 给它发一条消息，让它启动自己的监听。
4. 去新群里对话即可，桌面端侧边栏里也能看到这个会话。

注意：

- 导入时桌面端会切到新会话，可能打断你正在桌面端的操作。
- 新会话收到的是总控转述的开启指令，不是你亲手输入的。
- 导入深链接是从桌面应用里观察到的行为，不是公开文档中的接口，以后的版本可能改变。

## 配置

编辑 `~/.claude/larkspur/config.sh`：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `LARKSPUR_OPEN_ID` | 安装时自动获取 | 唯一被放行的发送者，也就是你自己 |
| `LARKSPUR_LARK_CLI` | 自动查找 | `lark-cli` 路径 |
| `LARKSPUR_INBOX` | `~/files/larkspur-inbox` | 图片下载目录，必须在 lark-cli 允许的根目录内 |
| `LARKSPUR_IMAGE_WAIT` | `3` | 图片后等待文字合并的秒数 |
| `LARKSPUR_GROUP_PREFIX` | `Claude` | 群名前缀 |
| `LARKSPUR_PROJECTS_ROOT` | `$HOME` | 总控「新会话 <名字>」时相对目录的根 |
| `LARKSPUR_CLAUDE_BIN` | 自动查找 | 总控新建会话时用的 `claude` 命令 |

改了配置后，需要在会话里重新 `/feishu on`，监听才会用上新值。

## 安全须知

- **开启同步即授权**：在一个会话里执行 `/feishu on`，表示你同意：来自你的 open_id、发在该会话专属群里的飞书消息，视同你在桌面端亲自下的指示，**包括写入类操作，不再二次确认**。
- 唯一的保护是"只放行你的 open_id"。飞书账号一旦被盗，对方就能指挥这个会话。用完记得 `/feishu off`。
- 转发的文章、截图、网页里的文字只当作数据，Claude 不会把它们当作指令。
- AI 的回复会原样发到飞书群，涉及密钥或敏感内容时要留意。
- 即便如此，Claude 仍然不会代你输入密码或密钥、永久删除数据、进行资金交易、绕过验证码或修改系统安全设置。

## 已知限制

- **会话必须开着**：监听挂在会话里，关闭会话、休眠或断网就停了。
- **Monitor 最长 30 分钟**：到期后 Claude 会自动续期，续期的回合不输出文字，也不会发飞书。
- **只同步每轮的最终回复**：中间过程和工具调用不会发到飞书。
- **桌面端不是右侧气泡**：飞书来的消息以事件通知的形式出现，并在 Claude 的回复里被引用，不会显示成你自己发的消息气泡。
- 群名只在开启时同步一次。会话标题之后改了，再执行一次 `/feishu on` 即可更新群名。

## 测试

```bash
tests/test-listen.sh
```

用假的 `lark-cli` 模拟事件流，离线验证图片合并逻辑，大约需要 20 秒，不连接飞书。

## 卸载

```bash
./uninstall.sh          # 移除钩子、技能和脚本，保留配置与会话记录
./uninstall.sh --purge  # 连同配置、会话记录和日志一起删除
```

飞书里已经建好的群不会被删除。

## English summary

Larkspur bridges individual Claude Code sessions to Feishu/Lark. Run `/feishu on` in a session and a bot creates a dedicated Feishu group for it. Claude's final reply each turn is posted to the group, and your messages and images in that group are fed back into the session through Claude Code's Monitor tool. Each session gets its own group, so conversations never mix. It uses only the official `lark-cli`, Claude Code hooks, a skill and the Monitor tool. Only messages from your own open_id in the session's group are accepted. Enabling it authorizes Claude to act on those messages as if you had typed them, so read the security notes above. Install with `./install.sh`, remove with `./uninstall.sh`.

## 许可证

[MIT](LICENSE)
