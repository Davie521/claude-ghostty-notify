# claude-ghostty-notify

> 为 macOS 上跑在 [Ghostty](https://ghostty.org) 里的 [Claude Code](https://github.com/anthropics/claude-code) 提供 **精准到 tab** 的点击跳转通知。

**[English version here](./README.md)**

---

长任务跑完后，macOS 弹出系统通知。点 **Go to tab**，Ghostty 直接跳到跑 Claude 的**那个** tab —— 不是最前面那个、不只是激活 Ghostty，是**精确的源 tab**。多个 Claude 会话同时跑、同一项目开好几个 tab 都能区分。

## 你会看到什么

三级通知策略，防止短任务刷屏：

| 任务耗时 | 行为 |
|---|---|
| `< 45 秒` | **完全静默** — 不弹通知 |
| `45 秒 – 10 分钟` | **弹通知，无声** — 走神回来扫一眼通知中心就行 |
| `≥ 10 分钟` | **弹通知 + Glass 提示音** — 你肯定走远了，得叫你 |

阈值都可自定义。

## 为什么要用这个

现有的 Claude Code 通知工具（[code-notify](https://github.com/mylee04/code-notify)、[claude-code-notifier](https://github.com/kovoor/claude-code-notifier)、[claude-notifications-go](https://github.com/777genius/claude-notifications-go)）都有各自的问题：

- **不做 tab 级跳转**（只把 app 拉到前台，你还得自己找 tab），或
- **不过滤短任务噪音**（每次 2 秒的 `ls` 都弹通知），或
- **升级 Claude Code / plugin 就坏**。

本项目：

- **精准定位 tab** —— 往终端 TTY 发 OSC 2 转义序列写入独特 marker，再通过 AppleScript 查 Ghostty 哪个 tab 的标题等于 marker，然后恢复原标题。即使同一项目目录开了几个 Claude session 也能区分。
- **三级耗时门槛** —— 静默 / 静默通知 / 响铃通知，阈值可配置。
- **不需要辅助功能权限** —— 用 Ghostty 原生 AppleScript `select tab` 命令，不靠按键模拟。
- **免疫 Claude Code 和 plugin 升级** —— 纯 bash hook，你自己完全掌握，不依赖 `terminal-notifier -execute`（Banner 样式下经常静默失败）。
- **多会话感知** —— 按 Claude 的 `session_id` 做 key，多个并发会话互不干扰。

## 安装

### 1. 装依赖

```bash
brew install jq alerter
```

- **jq** —— 解析 Claude Code 喂给 hook 的 JSON
- **alerter** —— 显示可点击 action 按钮的 persistent 样式通知（原生 `terminal-notifier` 在 Banner 样式下 click 不稳定）

### 2. 装 hook 脚本

**一行装：**

```bash
curl -fsSL https://raw.githubusercontent.com/Davie521/claude-ghostty-notify/main/install.sh | bash
```

**或者克隆再装：**

```bash
git clone https://github.com/Davie521/claude-ghostty-notify.git
cd claude-ghostty-notify
./install.sh
```

安装器会把 3 个脚本拷到 `~/.claude/hooks/`，然后把你需要合并到 settings.json 的片段打印出来。

### 3. 在 `~/.claude/settings.json` 注册 hook

把下面这段合到你现有的 `settings.json`（把 `YOUR_USERNAME` 换成你的 macOS 用户名）：

```json
{
  "env": {
    "GHOSTTY_NOTIFY_MIN_ELAPSED": "45",
    "GHOSTTY_NOTIFY_SOUND_ELAPSED": "600",
    "GHOSTTY_NOTIFY_TIMEOUT": "1200"
  },
  "hooks": {
    "Notification": [{
      "matcher": "idle_prompt|permission_prompt",
      "hooks": [{"type": "command", "command": "/Users/YOUR_USERNAME/.claude/hooks/ghostty-notify.sh"}]
    }],
    "PreToolUse": [{
      "matcher": "",
      "hooks": [{"type": "command", "command": "/Users/YOUR_USERNAME/.claude/hooks/ghostty-tab-save.sh"}]
    }],
    "Stop": [{
      "matcher": "",
      "hooks": [{"type": "command", "command": "/Users/YOUR_USERNAME/.claude/hooks/ghostty-notify.sh"}]
    }]
  }
}
```

完整示例见 [example-settings.json](./example-settings.json)。

### 4. 改一个 macOS 系统设置

**系统设置 → 通知 → Script Editor → 提醒样式 → 提醒 (Persistent)**

> 为什么是 Script Editor？`alerter` 默认挂在 Script Editor 这个 bundle 下发通知。**提醒 (Persistent)** 样式会让通知留在屏幕上、直接显示 **Go to tab** 按钮。**横幅 (Banner)** 样式通知一闪即逝，按钮会藏在 "Show" 折叠菜单里，点击不稳定。

### 5. 重启 Claude Code

`settings.json` 里的 env 变量只在启动时读。退出 Claude Code 再打开，三个阈值才生效。

搞定。

## 配置

三个阈值都是 `settings.json` `env` 块里的环境变量。**改完要重启 Claude Code 才生效。**

| 变量 | 默认值 | 含义 |
|---|---:|---|
| `GHOSTTY_NOTIFY_MIN_ELAPSED`   | `60`  | 低于这个秒数：**静默** —— 完全不弹通知 |
| `GHOSTTY_NOTIFY_SOUND_ELAPSED` | `300` | 低于这个（高于 MIN）：**弹通知但无声** |
| `GHOSTTY_NOTIFY_TIMEOUT`       | `120` | 通知在屏幕上保留多久（秒），到时自动消失 |

**例子**：我想让超过 30 秒的任务都弹通知，但只有超过 5 分钟的才响铃，通知一直挂 20 分钟才消失：

```json
"env": {
  "GHOSTTY_NOTIFY_MIN_ELAPSED": "30",
  "GHOSTTY_NOTIFY_SOUND_ELAPSED": "300",
  "GHOSTTY_NOTIFY_TIMEOUT": "1200"
}
```

## 常见问题排查

### 完全看不到通知

1. Script Editor 的 **Alert Style** 改成 **Persistent** 了吗？（第 4 步）
2. 改完 env 有没有**重启** Claude Code？（第 5 步）
3. macOS 的**勿扰 / 专注模式**开了吗？关掉再试。
4. 检查 hook 跑过没：`ls ~/.claude/notifications/ghostty-sessions/`，应该能看到当前 session 的 `<session_id>.json` 和 `.start` 文件。

### 同时弹两条通知，其中一条是 Script Editor 图标、内容是我的 assistant 回复文字

那是 [everything-claude-code](https://github.com/affaan-m/everything-claude-code)（ECC）plugin 自带的 `stop:desktop-notify` hook，每次 Stop 都发它自己的通知。它跟本项目撞了。只关掉它这一个 hook（ECC 的其他功能保留）：

```json
"env": {
  "ECC_DISABLED_HOOKS": "stop:desktop-notify"
}
```

### 点通知跳出 Script Editor 的"新建文档"对话框，而不是跳回 Ghostty

说明你点的是通知**主体**（title/message 区域），不是 **Go to tab** 按钮。`alerter` 默认把 body 点击路由到 `--sender` 对应的 app，而 Script Editor 被激活时默认行为就是弹新建文档框。处理方式二选一：

- 总是点 **Go to tab** 按钮（推荐），或
- 打开 Ghostty 的通知权限，我们可以加 `--sender com.mitchellh.ghostty` —— 但 Ghostty 开了权限后会发自己的 `notify-on-command-finish-after` 通知，可能反而更吵。

### 跳错 tab 了

两个常见原因：

1. 你用 `--resume` 在**新 tab** 里恢复了旧 session，原来保存的 tab ID 失效。解决：`rm ~/.claude/notifications/ghostty-sessions/<session_id>.json`，随便跑一条命令让 hook 重新识别当前 tab。
2. 跑 Claude 的原 tab 被你关了。点通知只会 activate Ghostty，跳不过去。

### alerter 进程还挂着没退

正常。`alerter` 会阻塞等到你点按钮或超时（`GHOSTTY_NOTIFY_TIMEOUT` 秒）。想手动清：`pkill -f 'alerter.*ghostty-notify'`。

## 原理（技术细节）

**Hook 1 —— `ghostty-tab-save.sh`（每次 `PreToolUse` 触发）：**

1. 读 Claude Code 从 stdin 喂来的 JSON，提取 `session_id` 和 `cwd`。
2. 首次工具调用时记录时间戳。
3. 从 hook shell 的 PID 往上走进程树（`ps -o ppid= / command=`）直到找到 `claude` 进程 —— 它的 controlling TTY 就是用户看得见的终端。
4. 往那个 TTY 发 OSC 2 转义序列，把 tab 标题临时改成含 session ID 的独特 marker。
5. 通过 AppleScript 查 Ghostty：哪个 tab 的标题等于这个 marker？找到的就是**我们**所在的 tab。
6. 恢复原标题（`trap EXIT` 保底，出任何错都能恢复）。
7. 把 `{tab_id, cwd}` 保存到 `~/.claude/notifications/ghostty-sessions/<session_id>.json`。

这套"marker 舞"每个 session 只跑一次（保存文件在就不重跑）。

**Hook 2 —— `ghostty-notify.sh`（`Stop` 和 `Notification` 触发）：**

1. 读 `PreToolUse` 写的时间戳，算出任务耗时。
2. 低于 `MIN_ELAPSED` 直接静默退出。
3. 以后台子 shell 启动 `alerter`，带一个显式的 `Go to tab` action 按钮。耗时低于 `SOUND_ELAPSED` 时不传 `--sound`。
4. 子 shell 捕获 `alerter` 的 stdout：`@CLOSED` / `@TIMEOUT` → 啥也不做；其他值 → 调 focus 脚本。
5. Stop 事件清除时间戳，下一轮任务重新计时。

**Hook 3 —— `ghostty-tab-focus.sh`（用户点 Go to tab 时跑）：**

1. 激活 Ghostty (`tell application "Ghostty" to activate`)。
2. 从 session 保存文件读 `tab_id`。
3. 用 Ghostty 原生 AppleScript `select tab` 命令切过去。这是 sdef 里定义的 command（不是属性写入），所以**不需要辅助功能权限**。

### 设计决策说明

- **为什么用 `session_id` 而不是 `$PPID`？** Claude Code 每次 hook 触发会 fork 中间 shell，PID 不固定。`session_id`（从 hook stdin JSON 读）在整个会话（包括 `--resume` 后）都稳定。
- **为什么用 OSC 2 marker 而不是按 `cwd` 匹配？** 同一个项目目录下开两个 Claude session 时 `cwd` 一样，没法区分。marker 给了每个 session 独特的信号，无论多少 tab 在同一个目录都能精确命中。
- **为什么用 `alerter` 而不是 `terminal-notifier`？** 新版 macOS 在 Banner 样式下会静默丢掉 `terminal-notifier -execute` 的点击事件。`alerter` 本身就是 alert 样式 + 明确的 action 按钮，点击可靠。

## 卸载

```bash
rm -f ~/.claude/hooks/ghostty-tab-save.sh \
      ~/.claude/hooks/ghostty-tab-focus.sh \
      ~/.claude/hooks/ghostty-notify.sh
rm -rf ~/.claude/notifications/ghostty-sessions
```

然后把 `~/.claude/settings.json` 里相关的 `env` 和 `hooks` 条目删掉。

## 局限

- **仅 macOS**。依赖 Ghostty 的 AppleScript 字典 + macOS 通知 API。
- **仅 Ghostty**。tab 识别技巧是 Ghostty 独有的。
- **Session 必须在 Ghostty 里启动**。如果 Claude 的 controlling TTY 不是 Ghostty surface，hook 静默退出。
- **关 tab 后跳不过去**。跑 Claude 的原 tab 被关掉，点通知只 activate Ghostty，无法跳转。

## 致谢

灵感来自现有的 Claude Code 通知生态，尤其是 [kovoor/claude-code-notifier](https://github.com/kovoor/claude-code-notifier) 讨论过的 TTY marker 技巧。

## 许可证

[MIT](./LICENSE)。
