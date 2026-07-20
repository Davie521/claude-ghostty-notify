# claude-ghostty-notify

[![CI](https://github.com/Davie521/claude-ghostty-notify/actions/workflows/ci.yml/badge.svg)](https://github.com/Davie521/claude-ghostty-notify/actions/workflows/ci.yml)

> **长任务一跑完,就把你精准拉回运行它的那个 Ghostty tab —— 不是把 app 拉到前台、不是最前面那个 tab,是_那一个_ tab。**

**[English version here](./README.md)**

---

## 它解决什么问题

你启动一个长时间的 Claude Code 任务 —— 一次大规模重构、一整套测试、一次数据库迁移 —— 然后切到浏览器等它跑。十分钟后切回 Ghostty,结果:你开着八个 tab,三个在跑 Claude,完全不知道刚才是哪个跑完了。你挨个瞄 buffer、往上翻找、丢了手头的思路。再乘以一天十几次。

`claude-ghostty-notify` 把这个循环闭上。任务完成时 macOS 弹出通知,点 **Go to tab**,Ghostty 直接跳到跑它的那个 surface —— 哪怕同一个项目目录下还开着另外五个 Claude 会话。你再也不用找 tab。

整个东西就是几个依赖极少的小 bash 脚本,你能从头读到尾。没有常驻进程、没有 Node 进程、没有遥测、不需要任何辅助功能权限。

## 它凭什么不一样

任务跑完弹个通知的工具一抓一大把。这个项目专攻别的工具都做砸的那几处。

### 每一次都落在正确的 tab

大多数通知工具只能把 Ghostty 拉到前台,tab 还得你自己找。这个能定位到**精确的 surface**。在一个 session 的首次工具调用时,它用 OSC 2 转义序列往 tab 标题里写一个独特 marker,通过 AppleScript 问 Ghostty 现在哪个 tab 带着这个 marker,记下答案,再把原标题恢复回去 —— 全程不到一秒,而且每个 session 只做一次。

同一个目录下的两个 Claude 会话共用一个 `cwd`,所以靠目录匹配的通知工具根本分不清它们。这里每个 session 拿到的是自己的 marker,跳转永远不含糊。

### 三档策略,短任务永不刷屏

| 任务耗时 | 行为 |
|---|---|
| `< 3 分钟` | **完全静默** —— 不弹通知 |
| `3 – 10 分钟` | **弹通知,无声** —— 走神回来扫一眼通知中心就行 |
| `≥ 10 分钟` | **弹通知 + Glass 提示音** —— 你肯定走远了,得叫你 |

一次 2 秒的 `ls` 保持静默。一次 3 分钟的构建给你一条安静、瞄一眼就懂的通知。一次 10 分钟的迁移用提示音把你叫回来。每个阈值都是环境变量 —— 按你自己的节奏调。

通知在任务完成(`Stop`)时弹。权限 / 输入提示(`Notification` 事件)默认静默 —— bypass-permissions 模式下它们很少出现,终端铃声也已经够提示了。你跑的是默认权限模式?设 `GHOSTTY_NOTIFY_ON_PROMPT=1`,当 Claude 卡在后台 tab 的提示上时你会立刻收到提醒,卡住的任务再也不会伪装成还在跑的样子。

### 点击是真能用的

新版 macOS 会静默丢掉横幅样式通知上的 action 按钮点击 —— 这正是很多通知工具用起来「总觉得哪里坏了」的原因。本插件优先用 `alerter`,它的提醒样式通知带一个真正可靠触发的 **Go to tab** 按钮;alerter 不可用时降级到 `terminal-notifier`。

### 永远不需要辅助功能权限

切 tab 用的是 Ghostty 原生的 AppleScript `select tab` 命令 —— 这是 Ghostty 字典里真实存在的脚本动词,不是模拟按键。你不用授予辅助功能权限,macOS 升级也没法悄悄把它弄坏。

### 多会话感知,resume 无碍

状态按 Claude 的 `session_id` 做 key,绝不用 PID 或工作目录。想开多少并发会话都行,每个都记得自己的 tab;因为 session id 在整个会话里都稳定,这套映射连 `--resume` 之后都不会失效。

### 为混乱的真实世界做了加固

方便的部分谁都会写;通知工具烂掉的地方永远在边界情况。这个项目的设计目标是「保持安静」,而不是给你添新麻烦:

- **用 Esc 中断了一轮,或者会话崩了?** 计时器在你下一次输入时重新武装,你绝不会因为一个 10 秒的追问收到一条响亮的「finished after 20m」。
- **Ghostty 版本太老没法脚本化、自动化权限被拒、或跑在 tmux 里?** 它探测一次、退避、降级为只 activate Ghostty —— tab 标题不会卡在 marker 字符串上,也不会每次工具调用都白付延迟。
- **并发工具调用在抢同一个 tab?** marker 往返是串行化的,并发的 hook 没法把你的 tab 名字改走。
- **配置写错了,或者遇到构造过的状态文件?** 非整数阈值 fail-closed 回落到默认值,tab id 以数据形式送进 AppleScript(绝不拼进脚本源码),所以不是你亲手输入的东西一律跑不起来。

以上每一条路径都有自动化回归测试,CI 在每次改动时都会在 macOS 上跑完整套件。

## 横向对比

| | `claude-ghostty-notify` | 一般的 Claude 通知工具 |
|---|---|---|
| 跳到**精确的** tab | 能 | 把 app 拉到前台,tab 你自己找 |
| 压制短任务噪音 | 三档耗时门槛 | 每次 `ls` 都弹 |
| 同目录两个会话 | 用 marker 区分 | 被共用的 `cwd` 搞混 |
| 辅助功能权限 | 不需要 | 有时需要(模拟按键) |
| 扛得住 Claude Code / 插件升级 | 你自己掌控的纯 bash | 升级常坏 |

同类项目值得一看 —— [code-notify](https://github.com/mylee04/code-notify)、[claude-code-notifier](https://github.com/kovoor/claude-code-notifier)、[claude-notifications-go](https://github.com/777genius/claude-notifications-go) —— 它们各自解决了问题的一部分;上面这张表就是本项目更进一步的地方。

## 安装

### 1. 装依赖

```bash
brew install jq alerter
```

- **jq** —— 解析 Claude Code 喂给 hook 的 JSON
- **alerter** —— 显示可点击 action 按钮的 persistent 样式通知(原生 `terminal-notifier` 在 Banner 样式下 click 不稳定)

### 2. 装插件

在 Claude Code 里跑:

```
/plugin marketplace add Davie521/claude-ghostty-notify
/plugin install claude-ghostty-notify
```

完事 —— hook 通过插件 manifest 自动注册,**不需要手动改 `settings.json`**。

### 3. 改一个 macOS 系统设置

**系统设置 → 通知 → 提醒样式 → 提醒 (Persistent)**,**Script Editor 和 Terminal 两个条目都设**(机器上有哪个设哪个)。

> 通知挂在哪个 bundle 下取决于 alerter 版本:老版 alerter(≤1.x,ObjC 构建)借用 Script Editor 的 bundle,而 alerter 26.x(Swift 重写版)默认是 `com.apple.Terminal`(它的 `--help` 写着 `--sender ... (default: com.apple.Terminal)`)。两个都设没有副作用,能覆盖任一版本。**提醒 (Persistent)** 样式会让通知留在屏幕上、直接显示 **Go to tab** 按钮。**横幅 (Banner)** 样式通知一闪即逝,按钮会藏在 "Show" 折叠菜单里,点击不稳定。

### 4. 重启 Claude Code

退出 Claude Code 再打开,新 hook 才会被加载。

搞定。默认阈值(3 分钟 / 10 分钟 / 20 分钟超时)开箱即用,想调见 [配置](#配置)。

---

### 手动安装(不用插件系统)

不想走 plugin marketplace 也行,老的安装器还在:

```bash
git clone https://github.com/Davie521/claude-ghostty-notify.git
cd claude-ghostty-notify
./install.sh
```

它会把 hook 拷到 `~/.claude/hooks/`,并打印需要手动合并到 `settings.json` 的片段。完整示例见 [example-settings.json](./example-settings.json)。

## 配置

所有阈值都是 `settings.json` `env` 块里的环境变量。**改完要重启 Claude Code 才生效。** 默认值针对「大部分任务在 3 分钟内完成」的工作流调过,只有更长的任务才会弹通知。

| 变量 | 默认值 | 含义 |
|---|---:|---|
| `GHOSTTY_NOTIFY_MIN_ELAPSED`   | `180`  | 低于这个秒数(3 分钟):**静默** —— 完全不弹通知 |
| `GHOSTTY_NOTIFY_SOUND_ELAPSED` | `600`  | 低于这个(10 分钟)但高于 MIN:**弹通知但无声** |
| `GHOSTTY_NOTIFY_TIMEOUT`       | `1200` | 通知在屏幕上保留多久(20 分钟),到时自动消失 |
| `GHOSTTY_NOTIFY_BACKEND`       | `auto` | `auto`(先 alerter,没有再 fallback 到 terminal-notifier)/ `terminal-notifier`(强制)。如果 alerter 弹不出通知,设成 `terminal-notifier` —— 见排查那节。注意 terminal-notifier 后端不接点击跳转(它的 `-execute` 连 dismiss 都会触发);强制 alerter 但二进制缺失时会降级到 terminal-notifier,而不是静默吞掉通知 |
| `GHOSTTY_NOTIFY_ON_PROMPT`     | `0`    | 设成 `1` 后,`Notification` 事件(权限/输入提示)也会立即弹通知 + Ping 音。不跑 bypass-permissions 模式的话推荐打开 |

值必须是纯整数(秒),否则回落到默认值。

**例子** —— 超过 30 秒的任务就弹通知,但只有超过 5 分钟的才响铃,通知挂 20 分钟才消失:

```json
"env": {
  "GHOSTTY_NOTIFY_MIN_ELAPSED": "30",
  "GHOSTTY_NOTIFY_SOUND_ELAPSED": "300",
  "GHOSTTY_NOTIFY_TIMEOUT": "1200"
}
```

## 常见问题排查

### 完全看不到通知

1. Script Editor **和 Terminal** 的 **Alert Style** 都改成 **Persistent** 了吗?(第 3 步 —— 通知挂在哪个 bundle 下取决于 alerter 版本)
2. 改完 env 有没有**重启** Claude Code?(第 4 步)
3. macOS 的**勿扰 / 专注模式**开了吗?关掉再试。
4. 检查 hook 跑过没:`ls ~/.claude/notifications/ghostty-sessions/`,应该能看到当前 session 的 `<session_id>.json` 和 `.start` 文件。
5. **alerter 跑了但通知就是不显示** —— 通常是因为负责投递的 bundle 在系统设置里**从来没被授权过通知**。`alerter` 能正常跑完,但 macOS 静默丢了显示。解决:强制走 terminal-notifier 后端(它有自己独立的通知授权):

   ```json
   "env": {
     "GHOSTTY_NOTIFY_BACKEND": "terminal-notifier"
   }
   ```

### 同时弹两条通知,其中一条是 Script Editor 图标、内容是我的 assistant 回复文字

那是 [everything-claude-code](https://github.com/affaan-m/everything-claude-code)(ECC)plugin 自带的 `stop:desktop-notify` hook,每次 Stop 都发它自己的通知。它跟本项目撞了。只关掉它这一个 hook(ECC 的其他功能保留):

```json
"env": {
  "ECC_DISABLED_HOOKS": "stop:desktop-notify"
}
```

### 点通知跳出 Script Editor 的「新建文档」对话框,而不是跳回 Ghostty

说明你点的是通知**主体**(title/message 区域),不是 **Go to tab** 按钮。`alerter` 默认把 body 点击路由到 `--sender` 对应的 app,而 Script Editor 被激活时默认行为就是弹新建文档框。处理方式二选一:

- 总是点 **Go to tab** 按钮(推荐),或
- 打开 Ghostty 的通知权限,我们可以加 `--sender com.mitchellh.ghostty` —— 但 Ghostty 开了权限后会发自己的 `notify-on-command-finish-after` 通知,可能反而更吵。

### 跳错 tab 了

两个常见原因:

1. 你用 `--resume` 在**新 tab** 里恢复了旧 session,原来保存的 tab ID 失效。解决:`rm ~/.claude/notifications/ghostty-sessions/<session_id>.json`,随便跑一条命令让 hook 重新识别当前 tab。
2. 跑 Claude 的原 tab 被你关了。点通知只会 activate Ghostty,跳不过去。

### alerter 进程还挂着没退

正常。`alerter` 会阻塞等到你点按钮或超时(`GHOSTTY_NOTIFY_TIMEOUT` 秒)。想手动清:`pkill -f 'alerter.*ghostty-notify'`。

## 原理(技术细节)

**Hook 1 —— `ghostty-tab-save.sh`(每次 `PreToolUse` 触发):**

1. 读 Claude Code 从 stdin 喂来的 JSON,提取 `session_id` 和 `cwd`。
2. 首次工具调用时记录时间戳。
3. 从 hook shell 的 PID 往上走进程树(`ps -o ppid= / command=`)直到找到 `claude` 进程 —— 它的 controlling TTY 就是用户看得见的终端。
4. 先确认 Ghostty 可被 AppleScript 控制,再往那个 TTY 发 OSC 2 转义序列,把 tab 标题临时改成含 session ID 的独特 marker。
5. 通过 AppleScript 查 Ghostty:哪个 tab 的标题等于这个 marker?找到的就是**我们**所在的 tab。
6. 恢复原标题(`trap EXIT` 保底,出任何错都能恢复)。
7. 把 `{tab_id, cwd}` 保存到 `~/.claude/notifications/ghostty-sessions/<session_id>.json`。

这套开销较大的「marker 舞」每个 session 只跑一次,并且在锁的保护下串行执行,并发工具调用没法互相抢。如果 Ghostty 没法被脚本化(或 marker 无法往返,比如在 tmux 里),它会退避,该 session 降级为只 activate。

**Hook 2 —— `ghostty-notify.sh`(`Stop` 触发;开启后也在 `Notification` 触发):**

1. 读 `PreToolUse` 写的时间戳,算出任务耗时。
2. 低于 `MIN_ELAPSED` 直接静默退出。
3. 以后台子 shell 启动 `alerter`,带一个显式的 `Go to tab` action 按钮。耗时低于 `SOUND_ELAPSED` 时不加提示音。
4. 子 shell 捕获 `alerter` 的 stdout:只有 `Go to tab` 按钮或通知主体点击(`@CONTENTCLICKED`)才调 focus 脚本;dismiss / 超时啥也不做。
5. Stop 事件清除时间戳,下一轮任务重新计时。

**Hook 2b —— `ghostty-round-reset.sh`(`UserPromptSubmit` 触发):**

清除本轮开始时间戳。用户中断(Esc/Ctrl-C)或进程崩溃时 Stop 不会触发,没有这个兜底的话,残留的旧时间戳会把下一轮的耗时算得离谱 —— 10 秒的小任务弹出带响铃的「Finished after 20m」假通知。

**Hook 3 —— `ghostty-tab-focus.sh`(用户点 Go to tab 时跑):**

1. 激活 Ghostty (`tell application "Ghostty" to activate`)。
2. 从 session 保存文件读 `tab_id`。
3. 用 Ghostty 原生 AppleScript `select tab` 命令切过去。这是 sdef 里定义的 command(不是属性写入),所以**不需要辅助功能权限**。

### 设计决策说明

- **为什么用 `session_id` 而不是 `$PPID`?** Claude Code 每次 hook 触发会 fork 中间 shell,PID 不固定。`session_id`(从 hook stdin JSON 读)在整个会话(包括 `--resume` 后)都稳定。
- **为什么用 OSC 2 marker 而不是按 `cwd` 匹配?** 同一个项目目录下开两个 Claude session 时 `cwd` 一样,没法区分。marker 给了每个 session 独特的信号,无论多少 tab 在同一个目录都能精确命中。
- **为什么用 `alerter` 而不是 `terminal-notifier`?** 新版 macOS 在 Banner 样式下会静默丢掉 `terminal-notifier -execute` 的点击事件。`alerter` 本身就是 alert 样式 + 明确的 action 按钮,点击可靠。

## 卸载

**插件方式安装的:**

```
/plugin uninstall claude-ghostty-notify
```

完事 —— hook 自动注销。

**手动安装的:**

```bash
rm -f ~/.claude/hooks/ghostty-tab-save.sh \
      ~/.claude/hooks/ghostty-tab-focus.sh \
      ~/.claude/hooks/ghostty-notify.sh \
      ~/.claude/hooks/ghostty-round-reset.sh
rm -rf ~/.claude/notifications/ghostty-sessions
rm -f ~/.claude/notifications/state/ghostty-notify-*
```

然后把 `~/.claude/settings.json` 里相关的 `env` 和 `hooks` 条目删掉。

## 局限

- **仅 macOS**。依赖 Ghostty 的 AppleScript 字典 + macOS 通知 API。
- **仅 Ghostty**。tab 识别技巧是 Ghostty 独有的。
- **Session 必须在 Ghostty 里启动**。如果 Claude 的 controlling TTY 不是 Ghostty surface,hook 静默退出。
- **关 tab 后跳不过去**。跑 Claude 的原 tab 被关掉,点通知只 activate Ghostty,无法跳转。
- **Ghostty 必须可被 AppleScript 控制**。tab 识别需要 Ghostty ≥ 1.3(AppleScript 支持)+ macOS 自动化权限。缺任一个时 hook 会探测一次然后退避一天,通知降级为只 activate。`claude` 跑在 tmux 里同理(OSC 2 改的是 tmux pane 标题,不是 Ghostty tab):失败 3 次后该 session 降级为只 activate。

## 致谢

灵感来自现有的 Claude Code 通知生态,尤其是 [kovoor/claude-code-notifier](https://github.com/kovoor/claude-code-notifier) 讨论过的 TTY marker 技巧。

## 许可证

[MIT](./LICENSE)。
