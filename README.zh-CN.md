# claude-ghostty-notify

[![CI](https://github.com/Davie521/claude-ghostty-notify/actions/workflows/ci.yml/badge.svg)](https://github.com/Davie521/claude-ghostty-notify/actions/workflows/ci.yml)

**语言 / Language** → [English](README.md) · [中文](README.zh-CN.md)

> **长任务一跑完,就把你精准拉回运行它的那个 Ghostty tab —— 不是把 app 拉到前台、不是最前面那个 tab,是_那一个_ tab。**

长任务跑完,macOS 弹出通知,点 **Go to tab**,Ghostty 直接跳到运行它的那个 surface —— 哪怕同一个项目目录下还开着另外五个 Claude 会话。就是几个依赖极少的小 bash hook;没有常驻进程、没有 Node、没有遥测、不需要任何辅助功能权限。

```
10:32   你在 8 个 tab 里的第 3 个开始一次 12 分钟的重构,然后切去浏览器
          ...
10:44   ┌──────────────────────────┐
        │ Claude ✅  Task Complete │   ← macOS 通知
        │ Finished after 12m 3s    │
        │            [ Go to tab ] │
        └──────────────────────────┘
        点一下  →  Ghostty 直接跳到第 3 个 tab
```

Repo: https://github.com/Davie521/claude-ghostty-notify

---

## 为什么要有它

Claude Code 自带的「任务完成」信号,是在你当前正看着的那个 tab 里响一声终端铃 —— 一旦你切了 app、或者同时开着好几个会话,它就没用了。社区里的通知工具有帮助,但每个都在某处止步:

- 大多数只把 Ghostty 拉到前台 —— 正确的 tab 还得你自己找;
- 很多每次 2 秒的命令都弹,弹到你学会无视;
- 有些靠模拟按键切 tab,既要辅助功能权限、又会在 macOS 升级后失效;
- 大多数分不清同一目录下开着的两个 Claude 会话,因为它们靠工作目录匹配。

`claude-ghostty-notify` 就是奔着补上这四个缺口去的。同类项目值得一看:[code-notify](https://github.com/mylee04/code-notify)、[claude-code-notifier](https://github.com/kovoor/claude-code-notifier)、[claude-notifications-go](https://github.com/777genius/claude-notifications-go)。

---

## 亮点

| 任务耗时 | 行为 |
|---|---|
| `< 3 分钟` | **完全静默** —— 不弹通知 |
| `3 – 10 分钟` | **弹通知,无声** —— 走神回来扫一眼就行 |
| `≥ 10 分钟` | **弹通知 + Glass 提示音** —— 你肯定走远了 |

- **落在精确的那个 tab。** 一个 OSC 2 marker + 一次 AppleScript 查询,每个 session 只做一次就锁定精确的 surface,同一目录的两个会话永不混淆。
- **短任务不刷屏。** 上面三档全是环境变量 —— 按你自己的节奏调。
- **点击是真能用的。** 优先用 `alerter` 的提醒样式 **Go to tab** 按钮(新版 macOS 会静默丢掉横幅样式通知上的 action 点击);缺失时降级到 `terminal-notifier`。
- **永远不需要辅助功能权限。** 用 Ghostty 原生 AppleScript `select tab`,不是模拟按键。
- **多会话、resume 无碍。** 状态按 `session_id` 做 key,`--resume` 之后依然稳定。
- **为真实使用做了加固。** 中断/崩溃重新计时、Ghostty 不可脚本化及 tmux 降级、marker 往返串行化、配置 fail-closed、AppleScript 防注入 —— 每条都有回归测试、都受 CI 把关。
- **完全归你掌控。** 就是几个小 bash hook —— 没有常驻进程、没有 Node、没有遥测 —— 不受 Claude Code 和插件升级影响。

通知在任务完成(`Stop`)时弹。权限/输入提示默认静默;设 `GHOSTTY_NOTIFY_ON_PROMPT=1` 可在 Claude 卡在后台 tab 的提示上时立刻收到提醒(不跑 bypass-permissions 模式的话推荐打开)。

---

## 安装

### 1. 依赖

```bash
brew install jq alerter
```

- **jq** —— 解析 Claude Code 喂给 hook 的 JSON
- **alerter** —— 带 action 按钮的 persistent 样式通知(原生 `terminal-notifier` 在 Banner 样式下点击不稳定)

### 2. 插件

在 Claude Code 里:

```
/plugin marketplace add Davie521/claude-ghostty-notify
/plugin install claude-ghostty-notify
```

hook 通过插件 manifest 自动注册 —— **不需要手动改 `settings.json`。**

### 3. 一个 macOS 系统设置

**系统设置 → 通知 → 提醒样式 → 提醒 (Persistent)**,**Script Editor 和 Terminal 两个条目都设**(机器上有哪个设哪个)。

> 通知挂在哪个 bundle 下取决于 alerter 版本:老版 alerter(≤1.x,ObjC)借用 Script Editor 的 bundle,而 alerter 26.x(Swift 重写版)默认是 `com.apple.Terminal`(它的 `--help` 写着 `--sender ... (default: com.apple.Terminal)`)。两个都设没有副作用,能覆盖任一版本。**提醒 (Persistent)** 样式会让通知留在屏幕上、直接显示 **Go to tab** 按钮;**横幅 (Banner)** 样式一闪即逝,按钮藏在 "Show" 折叠菜单里,点击不稳定。

### 4. 重启 Claude Code

退出再打开,新 hook 才会被加载。默认阈值(3 分钟 / 10 分钟 / 20 分钟超时)开箱即用,想调见 [配置](#配置)。

### 手动安装(不用插件系统)

```bash
git clone https://github.com/Davie521/claude-ghostty-notify.git
cd claude-ghostty-notify
./install.sh
```

它会把 hook 拷到 `~/.claude/hooks/`,并打印需要合并进 `settings.json` 的片段。完整示例见 [example-settings.json](./example-settings.json)。

## 配置

所有阈值都是 `settings.json` `env` 块里的环境变量。**改完要重启 Claude Code 才生效。**

| 变量 | 默认值 | 含义 |
|---|---:|---|
| `GHOSTTY_NOTIFY_MIN_ELAPSED`   | `180`  | 低于这个秒数(3 分钟):**静默** —— 完全不弹通知 |
| `GHOSTTY_NOTIFY_SOUND_ELAPSED` | `600`  | 低于这个(10 分钟)但高于 MIN:**弹通知但无声** |
| `GHOSTTY_NOTIFY_TIMEOUT`       | `1200` | 通知在屏幕上保留多久(20 分钟),到时自动消失 |
| `GHOSTTY_NOTIFY_BACKEND`       | `auto` | `auto`(先 alerter,没有再 fallback 到 terminal-notifier)/ `terminal-notifier`(强制)。alerter 弹不出通知时设成 `terminal-notifier` —— 见排查那节。terminal-notifier 后端不接点击跳转(它的 `-execute` 连 dismiss 都会触发);强制 alerter 但二进制缺失时会降级到 terminal-notifier,而不是静默吞掉通知 |
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
4. 检查 hook 跑过没:`ls ~/.claude/notifications/ghostty-sessions/`,应能看到当前 session 的 `<session_id>.json` 和 `.start` 文件。
5. **alerter 跑了但通知就是不显示** —— 负责投递的 bundle 在系统设置里从来没被授权过通知。`alerter` 能跑完、正常退出,但 macOS 静默丢了显示。解决:强制走 terminal-notifier 后端(它有自己独立的通知授权):

   ```json
   "env": {
     "GHOSTTY_NOTIFY_BACKEND": "terminal-notifier"
   }
   ```

### 同时弹两条通知,其中一条是 Script Editor 图标、内容是我的 assistant 回复文字

那是 [everything-claude-code](https://github.com/affaan-m/everything-claude-code)(ECC)plugin 自带的 `stop:desktop-notify` hook,每次 Stop 都发它自己的通知,跟本项目撞了。只关掉它这一个 hook(ECC 其他功能保留):

```json
"env": {
  "ECC_DISABLED_HOOKS": "stop:desktop-notify"
}
```

### 点通知跳出 Script Editor 的「新建文档」对话框,而不是跳回 Ghostty

说明你点的是通知**主体**,不是 **Go to tab** 按钮。`alerter` 默认把 body 点击路由到 `--sender` 对应的 app,而 Script Editor 被激活时默认就是弹新建文档框。要么总是点 **Go to tab**(推荐),要么打开 Ghostty 的通知权限、给脚本加 `--sender com.mitchellh.ghostty`(但 Ghostty 之后会发自己的 `notify-on-command-finish-after` 通知,可能更吵)。

### 跳错 tab 了

1. 你用 `--resume` 在**新 tab** 里恢复了旧 session,保存的 tab ID 失效。解决:`rm ~/.claude/notifications/ghostty-sessions/<session_id>.json`,随便跑一条命令让它重新识别。
2. 跑 Claude 的原 tab 被关了。点通知只会 activate Ghostty,跳不过去。

### alerter 进程还挂着没退

正常。`alerter` 会阻塞到你点按钮或超时(`GHOSTTY_NOTIFY_TIMEOUT` 秒)。想手动清:`pkill -f 'alerter.*ghostty-notify'`。

## 原理

```
┌─────────────────────────────────────────────────────────┐
│ PreToolUse → ghostty-tab-save.sh          (每会话一次)  │
│   往 tab 标题写 OSC 2 marker → AppleScript 找到这个 tab │
│   → 把 {tab_id} 存到 per-session 文件                   │
└─────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────┐
│ UserPromptSubmit → ghostty-round-reset.sh               │
│   重新武装本轮计时器(扛得住 Esc / 崩溃)                 │
└─────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────┐
│ Stop → ghostty-notify.sh                                │
│   耗时 ≥ MIN?→ 弹 alerter,带一个 "Go to tab" 按钮       │
└─────────────────────────────────────────────────────────┘
                          │  点 "Go to tab"
                          ▼
┌─────────────────────────────────────────────────────────┐
│ ghostty-tab-focus.sh                                    │
│   读 {tab_id} → AppleScript select tab → 跳到那个 tab   │
└─────────────────────────────────────────────────────────┘
```

**`ghostty-tab-save.sh`(每次 `PreToolUse`):** 从 stdin 读 `session_id` / `cwd`;记录开始时间戳;沿进程树找到 Claude 的 controlling TTY;先确认 Ghostty 可脚本化,再往 tab 标题写一个含 session ID 的独特 OSC 2 marker;通过 AppleScript 查现在哪个 tab 带着这个 marker;恢复原标题(`trap EXIT` 保底);保存 `{tab_id, cwd}`。这套 marker 舞每 session 只跑一次,并在锁的保护下串行执行,并发工具调用没法互相抢。Ghostty 没法被脚本化、或 marker 无法往返(比如在 tmux 里)时,它会退避,该 session 降级为只 activate。

**`ghostty-notify.sh`(`Stop` 触发;开启后也在 `Notification` 触发):** 算出耗时,低于 `MIN_ELAPSED` 直接静默退出;否则在后台子 shell 里启动 `alerter`,带一个显式 **Go to tab** 按钮(低于 `SOUND_ELAPSED` 时无声)。子 shell 只有在点了按钮或点了通知主体(`@CONTENTCLICKED`)时才调 focus 脚本 —— dismiss / 超时啥也不做。Stop 时清时间戳,下一轮重新计时。

**`ghostty-round-reset.sh`(`UserPromptSubmit` 触发):** 清除本轮开始时间戳。用户中断(Esc/Ctrl-C)或崩溃时 Stop 不触发,没有它的话,残留的旧时间戳会把下一轮耗时算得离谱 —— 10 秒的小任务弹出带响铃的「Finished after 20m」假通知。

**`ghostty-tab-focus.sh`(点击时):** 激活 Ghostty,从 session 文件读 `tab_id`,用 Ghostty 原生 AppleScript `select tab` 命令切过去 —— 这是 sdef 里真实的 command(不是属性写入),所以**不需要辅助功能权限**。

### 设计决策说明

- **为什么用 `session_id` 而不是 `$PPID`?** Claude Code 每次 hook 触发会 fork 中间 shell,PID 不固定。`session_id`(从 hook stdin JSON 读)在整个会话(含 `--resume` 后)都稳定。
- **为什么用 OSC 2 marker 而不是按 `cwd` 匹配?** 同一目录下开两个 session 时 `cwd` 一样,分不清。marker 给每个 session 独特信号,无论多少 tab 在同一目录都能精确命中。
- **为什么用 `alerter` 而不是 `terminal-notifier`?** 新版 macOS 在 Banner 样式下会静默丢掉 `terminal-notifier -execute` 的点击。`alerter` 本身就是 alert 样式 + 明确的 action 按钮,点击可靠。

## 卸载

**插件方式:** `/plugin uninstall claude-ghostty-notify` —— hook 自动注销。

**手动安装:**

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

- **仅 macOS** —— 依赖 Ghostty 的 AppleScript 字典 + macOS 通知 API。
- **仅 Ghostty** —— tab 识别技巧是 Ghostty 独有的。
- **Session 必须在 Ghostty 里启动** —— Claude 的 controlling TTY 不是 Ghostty surface 时,hook 静默退出。
- **关 tab 后跳不过去** —— 点通知只 activate Ghostty,无法跳转。
- **Ghostty 必须可被 AppleScript 控制** —— 需要 Ghostty ≥ 1.3(AppleScript 支持)+ macOS 自动化权限。缺任一个时 hook 探测一次、退避一天、降级为只 activate。`claude` 跑在 tmux 里同理(OSC 2 改的是 tmux pane 标题,不是 Ghostty tab):失败 3 次后该 session 降级为只 activate。

## 致谢

灵感来自现有的 Claude Code 通知生态,尤其是 [kovoor/claude-code-notifier](https://github.com/kovoor/claude-code-notifier) 讨论过的 TTY marker 技巧。

## 许可证

[MIT](./LICENSE)。
