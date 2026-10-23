---
name: herdr-agents
description: Use when driving another coding agent (claude / agy / opencode) through herdr — starting it, confirming it is ready, getting an instruction delivered exactly once, reading it back, interrupting it, passing messages between agents, or telling stuck from finished from restarted. Also reached by the chief-of-staff skill for every worker it launches.
---

# herdr-agents

**先读官方 `herdr` 技能**（通常在 `~/.agents/skills/herdr/SKILL.md`）。命令语法、ID、`agent start` /
`agent prompt` / `pane read` 的基本用法、名字的正则、安全规则都在那里，这里不重复。

本技能只写官方没写的东西：**实测出来的启动序列、送达确认、回读、打断、agent 之间通信，以及每一个
返回值不会告诉你的坑。** 官方的描述和这里的实测冲突时，先核版本（见「版本绑定」），再以这里的实测为准。

第一次在一台机器上用：跑一次 `scripts/check-env.sh`，它把本机 herdr 与各 agent CLI 的版本和本技能
标注的实测版本对一遍，不同就提醒（只读，不拦、不装任何东西）。

## 版本绑定

> **每条都绑在一个 herdr 版本上。** 下面「已知陷阱」多数条目实测于 **0.8.0**，**未在 0.9.x 上复测**；
> 陷阱 ① 的现状实测于 **0.9.1**；claude kind 的条目实测于 **0.9.5 + Claude Code 2.1.306**。发现某条对不上时，
> 先核 `herdr --version` 与 `https://herdr.dev/latest.json` 的发布说明——上游可能已经修了，那就该升级，而不是
> 在这里加一条新的变通写法。但发布说明说修了，不等于这条路径修了：要实测。
>
> 曾是「陷阱 ① 已随 0.9.0 修复」（只凭发布说明），已推翻，见 HISTORY #4。

下面按用途分节，陷阱编号 ①–⑦ 保留原来的编号，方便和旧记录对照。

## 1 · 起 agent，确认它真的就绪

### 命令形式

`herdr agent start` 本身没有 `--model` 参数，agent 自己的参数靠 `--` 之后透传（已实测）：

    herdr agent start <名> --kind claude --pane <p> --timeout 90000 -- --model opus
    # 返回 argv: ['claude', '--model', 'opus']

**claude kind：herdr 起的独立 session 省略 `--model` 不会继承你的模型**，会去读
`~/.claude/settings.json`（见 HISTORY #8）——该显式传的地方必须传，否则拿去做架构
判断的 agent 会悄悄落在低一档的模型上。（只有 Claude Code 自己的 Agent 工具省略 `model` 才继承
调用方。）

agy 的模型名：`gemini-3.8-flash-high` 是写下时（2026-09-17/18）最新的，**`3.1-pro` 更旧**（名字里的
"pro" 会骗人）。不传 `--model` 会落回会话默认。

### 名字

官方技能写了名字必须匹配 `[a-z][a-z0-9_-]{0,31}`。补两条实测：

- 违反时 `agent start` 返回 `invalid_agent_name`（这是工具直接吐出来的硬约束，不是观测）。`WORKER-476` 这种写法会被拒：
  大写也不行，不只是空格。
- `herdr worktree create --label` 与 `herdr tab rename` 的标签**可以**带空格、`#`、`·`、中文（实测，见 HISTORY #8）。
  所以**标签给人看、agent 名给命令用**。
- **名字在整台机器上唯一**，不分 workspace，也不分项目（实测，herdr 0.9.5）。撞名时 `agent start` 返回
  `agent_name_taken`，并列出占着这个名字的 agent 的 pane 和 cwd。所以不同项目起的 agent 要在名字里带上能区分项目的
  部分。`scripts/launch.sh` 在建 worktree 之前先查格式和重名；`agent start` 失败时，它把 herdr 的报错原样打出来。
  推翻条件：herdr 改成按 workspace 或项目分开命名。来历见 HISTORY #23。
- **`herdr agent rename <pane_id> <名字>` 可用**（实测）。在 herdr 之外直接起的 agy 在
  `agent list` 里是 `name=None`，按名字发不了 prompt；用 pane id 当 target 补个名字就能寻址了。

### opencode kind：启动目录就是它的项目根，要把 worktree 路径直接传给它

    herdr agent start <名> --kind opencode --pane <p> --timeout 90000 -- \
        --model opencode-go/deepseek-v4.1-flash <worktree 的绝对路径>

`opencode [project]` 的位置参数就是项目目录（`opencode --help`：「project  path to start opencode in」）。
**先建好 worktree，再用它的路径起 OpenCode**；手册、结果文件放在别处（如 `~/.cache/<运行目录>/…`）照常用
绝对路径读写，那一处会弹一次权限框，可以接受。

**为什么。** OpenCode 把「启动目录以外」的路径一律走 `external_directory` 权限，每碰一个新子目录弹一次框，
`Allow always` 只放行那一个子目录，OpenCode 重启后全部失效。**启动之后改不了项目目录**：TUI 里没有 `/cd` 一类
命令，让它在 bash 里 `cd` 只改那条命令的 shell，权限检查仍按启动目录算。不用全局 `permission` 配置或 `--auto`：
放行范围太宽（实测与否掉的做法见 HISTORY #9）。

**什么观测会推翻本节：** OpenCode 新版本有了会话内切换项目目录的命令；`Allow always` 改成放行整棵目录树；
或者按本节起在 worktree 里，读写 worktree 仍然弹 `external_directory` 框。任一出现，记下
`opencode --version` 重测。

### 陷阱 ① `agent start` 返回时 TUI 还没接管终端，此时发出的 prompt 会丢 —— 而 `--wait` 有四分之一的概率谎报成功

**`agent start` 返回的 `interactive_ready: true` 对 agy 是过早的。** 它说的是 pane 里的进程起来了，
不是 agy 的 TUI 已经接管终端。官方技能说 `agent start` 在 herdr「认为它可以交互」后才返回——对 agy
这条路径不成立。

实测（herdr 0.9.1）：`agent start` 后**立即发**，真执行 **0/4**（**1 次报 `OK` 却根本没执行**）；**轮询到 banner
出现再发**，**4/4**。对照实验见 HISTORY #5；这个问题上连错过三次结论，见 HISTORY #7——**想改这一节的任何一句
之前先读那两条。**

### 陷阱 ①a 新 worktree 先弹「是否信任此文件夹」，`recent --lines 20` 看不见它

agy 在没信任过的目录里启动（每个新建的 worktree 都是），先出一个「Do you trust the contents of this
project? > Yes, I trust this folder」对话框，**banner 要等按了 Enter 才出现**。用
`--source recent-unwrapped --lines 20` 轮询会在这个对话框上**读回全空**，循环空转到超时，prompt 随后
打进对话框里。原因、测量表、上游核查见 HISTORY #6。

### 怎么做（步骤）

```bash
herdr agent start <名> --kind agy --pane <p> --timeout 90000 -- --model <m>

# 【必须】轮询到 TUI 真的渲染出来，再发 —— 实测 4/4 可靠
# 新 worktree 会先弹「是否信任此文件夹」（①a）；这个循环替你按掉它
for i in $(seq 1 60); do
  scr=$(herdr pane read <p> --source visible)
  echo "$scr" | grep -q "trust this folder" && { herdr pane send-keys <p> Enter; sleep 1; continue; }
  echo "$scr" | grep -q "Antigravity CLI [0-9]" && break
  sleep 1
done
```

- 判据串是 `Antigravity CLI [0-9]`，**不是** `Antigravity CLI`：信任对话框里有一句「Antigravity CLI
  requires permission…」，不带版本号的串会在对话框阶段就误判 banner 到了。banner 是
  「Antigravity CLI 1.2.12」这种带版本号的写法。
- 其它 kind 的 banner 特征字串不同，**自己回读一眼定**（claude 见下一小节）。

**完成判据：** 循环是因为匹配到 banner 特征串而 `break` 的，不是因为跑满 60 次。跑满了就是没就绪，
先 `pane read --source visible` 看画面停在哪，别发——看之前先确认这个 pane 没被滚上去（陷阱 ④b）。

**什么观测会推翻本节**：轮询到 banner 之后发出的 prompt 仍然丢；或者立即发能稳定成功；新 worktree 里
启动 agy 不再弹信任对话框；banner 不再带版本号。任一出现，按 HISTORY #5、#6 重做实验，并先核 `herdr --version`。

### claude kind：特征串、信任框，以及一条命令做完 §1–§2

**`scripts/launch.sh`** 把 claude kind 的整套序列串成一条命令：建 worktree（`herdr worktree create`，先 fetch
基点）→ 起 claude → 轮询就绪并按掉信任框 → 发一次指令 → 用 `scripts/count-delivered.sh` 数送达次数。用法见
文件头；`DRY_RUN=1` 只打印命令。它替你做的每一步，判据都在本节和 §2：

- **就绪特征串是 `Claude Code v`**（banner 里带版本号的那一行），用 `pane read --source visible` 轮询。
- **信任框默认选中的是「No, exit」**。Claude Code 在没信任过的目录里起（新 worktree 常常是），先出：

      ❯ No, exit
        Yes, I trust this folder

  直接按 Enter 会让会话退出，后面发的 prompt 打进裸 shell。**不要假设默认项**：读 `❯` 那一行，不在「Yes」上就
  按 `down`，在了才按 Enter。框出现时 `agent start` 立刻返回 `agent_not_ready`（它看得出被挡住了）。
  **推翻条件**：Claude Code 改了默认选项或文案（那时 `launch.sh` 的就绪循环会跑满 60 次、报 `NOT READY`，
  不会误按）；新目录不再弹框。实测见 HISTORY #10。
  曾是「claude kind 有没有信任框没测过」，照 agy 写法直接按 Enter，已推翻（会话会退出），见 HISTORY #10。

## 2 · 发指令，并确认它送达了、只送达了一次

```bash
herdr agent prompt <名> '<指令>' --wait --until working --timeout 12000
```

### `--wait` 的返回码不能当证据

实测 4 次立即发里有 1 次返回 `OK` 而指令其实丢了 —— **假阳性**（HISTORY #5）。所以：

- `agent_prompt_stalled` ⇒ 确实没进去，可以信，重发一次。
- `OK` ⇒ **什么都不能证明**，必须回读画面确认（下一小节）。

曾是「没报错就是已落地，不要补发」，已推翻，见 HISTORY #5。

### 回读确认 —— 唯一可信的判据，不是可选的补充

```bash
herdr pane read <pane_id> --source recent-unwrapped --lines 100
```

看两样：指令内容在不在、以及它落在 banner **之后**（落在 banner 之前 = 打进了裸终端，已丢）。

### 只送达了一次 —— 数 transcript 的内容，不是文件数

**回读和「占住已落地」都抓不住指令被重复投递**（发生过，见 HISTORY #11）。回读只能证明「送达了」，不能证明
「只送了一次」；占住记录是按任务记的，两个副本共用同一条分支、同一个任务，只会出现一条，看不出重复。

曾是「transcript 文件数增量必须为 1」，已推翻（抓不到同一会话里的重复投递），见 HISTORY #11。数内容，两种都能抓：

```bash
scripts/count-delivered.sh <worktree 路径 | transcript.jsonl> '<prompt 里一句独特的话>'   # 输出次数
```

计数代码只有这一份（`launch.sh` 也调它）。它数两种记录、排除两种，下面两段是为什么。

**斜杠命令展开出的 `isMeta` 记录不数**：经 `agent prompt` 打进去的 `/某技能 <参数>`，除了一条普通的 `user`
记录，技能正文会作为一条 `isMeta: true` 的 `user` 记录进对话，参数在里面再出现一次。**推翻条件**：Claude Code
改了斜杠命令展开的记法。曾是不排除 `isMeta` 的计数代码，已推翻（会数成 2），见 HISTORY #12。

**对方正忙时发的指令不记成 `user`**：先记一条 `queue-operation`（`operation: enqueue`），被取出时再记一条
`remove`，真正进入对话的是一条 `type: attachment`、`attachment.type: queued_command`（文本在 `attachment.prompt`），
整个过程**没有 `user` 记录**。所以上面连 `queued_command` 一起数；`queue-operation` 那两条不要数，否则一次投递
会数成两三次。对方空闲时发的才记成 `user`（实测见 HISTORY #12）。**推翻条件**：Claude Code 改了排队消息的记法。

`<worktree-slug>` = worktree 绝对路径把 `/` 换成 `-`，**`.` 也变 `-`**（`/home/<user>/.herdr/...` →
`-home-<user>--herdr-...`），少算一个横线会得到「0 个 transcript」的假读数。（这是 claude kind 的
transcript 位置；其它 kind 的对应物没有记录。）

**完成判据：** 回读看到指令落在 banner 之后，**并且**那句独特的话在 transcript 里恰好出现 1 次。

### 送达不等于被处理

回读证明的是「那一刻送到了」—— 一条已经躺在会话里、还没被消费的指令，遇上 `claude --resume` 会无声
蒸发，而画面上看不出区别（见 §6「被重启过」）。**改变边界或叫停一类的
指令，验收要落在行为上**（分支基点变了、那个文件不再被动了），不是落在画面上。

### 别往有人在打字的输入框里发

`agent prompt` 是往对方输入框里打字再按 Enter。**输入框里已经有人打了一半的字，你的消息会接在后面、和它一起
提交**（发生过，见 HISTORY #13）。`pane send-text` 同样会接在后面（按机制推断，没单独测）。

所以给可能有人在用的 pane 发消息前，先看输入框是不是空的：取 `pane read --source visible --format ansi` 里最后一行
带 `❯` 的，**去掉暗色（`ESC[2m … ESC[0m`）片段**再看剩下的有没有字。暗色那段是 Claude Code 的灰字输入建议，不是
谁打的字（误读过，见 HISTORY #13）。**还没见过的一侧**：真有人打了字时应当读成非空——没测过。**推翻条件**：Claude Code 改了建议的显示方式（不再
用暗色），或真打的字也被读成空。

`scripts/deliver-when-idle.sh "<消息>" <agent>...` 就是这么做的：等 agent 不在 working、输入框为空才发，每 15
秒看一次，最多一小时。它的 `rc=0` 也只说明 `--wait` 看到了 working，送达仍按上面回读。

### 斜杠命令这样打是有效的

经 `agent prompt` 打进输入框的 `/grill-with-docs` 会正常加载技能，即使它带 `disable-model-invocation: true`
（那条只挡模型自行加载，不挡人敲，而打进输入框等同人敲）。实测见 HISTORY #14。

**内置命令也一样，包括给自己打。** 模型自己调不了 `/rename` 这类内置命令，但经 herdr 往一个 claude 的输入框里打
（`pane send-text <pane> "/rename <名>"` 再 `send-keys Enter`），效果等于人敲，对自己的 pane 也行；忙时发也立刻
生效，不打断、不排队（实测见 HISTORY #14）。**推翻条件**：发出去之后画面上没有 `Session renamed to`、peer 列表里名字不变；忙时发的进了排队、等这一轮结束
才执行。受上面「别往有人在打字的输入框里发」约束。

### 指令里要引用技能时，先确认对方的 harness 找得到它

各 harness 发现用户级技能的目录不同，见 §8。装对了位置，指令里只写技能名就行；没把握时，在一个空目录里
让那个 agent 列一次技能。

### 一个尚未证伪也尚未确认的观测

对**已经在 working** 的 agent 发指令时，`--wait --until working` 返回 `timeout` 而不是
`agent_prompt_stalled`（它本来就在 working，观察不到状态变化），消息照样进队列。一次观测，只记不写死。

## 3 · 回读：用哪种读法，读到的状态能不能信

### 陷阱 ④ 两种读法的真实分工

曾是「`visible` 读不到对话内容，一律用 `recent-unwrapped`」（herdr 0.8.x），已推翻，见 HISTORY #15。

两种读法的真实分工：
- `visible` = **当前滚动位置那一屏**，看不到滚上去的内容；不受光标位置影响（滚动见下面 ④b）。
- `recent-unwrapped --lines N` = 从**光标所在行**往上数 N 行，能读到滚上去的历史；但画面只占屏幕
  顶部、光标停在下方时（agy 的信任对话框），小的 N 会读回全空，见陷阱 ①a。

所以：**确认启动、看对话框用 `visible`（只在 pane 停在底部时成立）；回读较长的对话历史、确认指令落在 banner
之后，用 `recent-unwrapped` 并给足行数。** 推翻条件：`visible` 在某个 kind 上再次读回空白，而同一时刻
`recent-unwrapped` 读得到——记下 `herdr --version` 与 kind。

### 陷阱 ④b `visible` 跟着 pane 的滚动位置走，滚上去就冻成旧画面

`visible` 读的是 pane **当前滚动位置**那一屏，不是底部。有人把 pane 往上滚了（滚轮、copy mode）又没滚回去，
`visible` 就一直返回那个位置的旧内容：新输出进来时 herdr 加大偏移量把那一屏钉在原处，发指令、按 Enter 都不会
把它拉回底部。agy 把已提交的指令回显成「分隔线 + `> 指令原文`」，冻在这里时和「指令还在输入框里没发」一模一样，
于是会重发。`recent` / `recent-unwrapped` / `detection`（`agent_status` 用的就是它）都从底部读，不受影响。

**怎么判断：** `herdr pane get <p>` 的 `scroll.offset_from_bottom`。`0` = 在底部，此时 `visible` 与
`recent --lines <viewport_rows>` 逐字相同；不为 `0` = `visible` 是旧画面。

```bash
off=$(herdr pane get <p> | jq '.result.pane.scroll.offset_from_bottom')
[ "$off" = 0 ] || echo "pane 被滚上去了 ($off 行)，visible 是旧画面，改读 recent"
```

**怎么做：**
- 判断「送到了没 / 在不在干活 / 停在哪」一律读 `recent`（或 `recent-unwrapped`）并给足行数，不用
  `visible`。巡检也一样。
- 只有要看「画在屏幕顶部、光标在下方」的东西（信任对话框，陷阱 ①a）才用 `visible`，并且先确认
  `offset_from_bottom` 为 0；或者改用 `recent --lines <viewport_rows>`（不受滚动影响，会多带进一两行上一屏）。
- 不要替人把 pane 滚回底部：那会改掉人正在看的界面。

实测于 herdr 0.9.5 + agy 1.4.2（0.9.1 上同样成立），见 HISTORY #1。
**推翻条件**：pane 滚上去时 `visible` 返回底部内容，或 `offset_from_bottom` 为 0 时 `visible` 比 `recent` 旧。

### 陷阱 ③ `agent_status` 是刮终端画面得来的，会抖

`herdr agent explain` 显示判定规则是 `live_prompt_box`，证据就是终端里的 `"❯\n"`。同一个 agent 数秒内
可被读成 `blocked` / `done` / `idle`。而且**「闲着因为干完了」和「闲着因为卡在权限提示上」状态完全
相同** —— 必须读回滚或看提交/交付物才分得清。herdr 也把一个真死了 45 分钟的 agent 报成过 "done"。

**对每个活着的 agent 读回滚佐证，不能只信 `agent_status`。**

### 陷阱 ③a agy 接口报错停住读作 `idle`，和「做完在等」分不出

herdr 对 agy 没有生命周期 hook，状态只靠屏幕 manifest。agy 遇到 `⚠ Internal error encountered`（或
`The request contains invalid parameters`）会停住等人叫醒，而 remote manifest `2026.10.05.1` 里没有规则认这行，
落到默认的 `idle`——不是 `blocked`。所以 agy 的 working→idle（`agent_status`、`agent wait`、
`pane.agent_status_changed`、chief-of-staff 的 `AGENT-STATUS`）每次都要读 `recent` 的底部，看输入框上方有没有那行报错。
herdr 0.9.5 + manifest `2026.10.05.1` 下用 `agent explain --file` 测过（HISTORY #2）。
**推翻条件**：`herdr agent explain --file <报错屏> --agent agy` 给出 `blocked`，或真实报错屏读成 `working`。

曾是「接口报错停住读作 working」「后台 shell 在跑就算 working」，已推翻，见 HISTORY #2。

**本地覆盖是整份替换，不是按规则合并。** `~/.config/herdr/agent-detection/agy.toml` 存在时，上游 manifest
整个不生效：覆盖文件里只放一条规则，agy 的 working、信任框、权限框就全落成 `idle`（HISTORY #3）。
`herdr server agent-manifests` 对 agy 报 `local override shadows cached remote rules` 时，去比两份规则。
**推翻条件**：同一组 `explain --file` 在只含一条规则的覆盖下，其余屏幕仍按上游规则判。

### `herdr agent list` 只看得见 herdr 自己起的 agent

agent 退出后会**从列表里消失**，pane 变 `unknown`，死活可判。但 herdr 只看得见它自己起的 pane ——
后台作业形态的 session 它看不见（实测 4 vs 12）。要知道这台机器上一共有哪些 agent 在跑，用 harness
自己的 peer 列表（Claude Code 是 `ListAgents`）和 `git worktree list` 交叉核对。**只看 herdr 会漏掉
一大半。**

## 4 · 打断与叫停

### 陷阱 ② `agent prompt` 是排队，不是打断

给正在干活的 agent 插指令，它会等当前这轮**完整跑完**才处理。改派时必须接受「对方会先把手上这轮
做完」。

### 陷阱 ⑥ 四条「叫停」路径，实测只有一部分能用（见 HISTORY #16）

| 路径 | 实测结果 |
|---|---|
| `herdr agent prompt` | 排队，不打断（同陷阱 ②） |
| `SendMessage`（Claude Code 跨 session 消息） | 会被接收方扣留等人工批准；`dialogExpiry` 默认 5 分钟，超时**静默丢弃并回拒绝** —— 发送方只看到「已扣留」，看不出是超时废弃 |
| `herdr pane send-keys <pane_id> Escape` | 仍未实测 |
| `herdr agent send-keys <agent> <键>` | **实测可用**（替 agy 按权限提示的 `2`）。官方技能也给了 `agent send-keys <名> esc` 的写法；用它当急停**没单独测过** |
| `herdr agent <stop>` | **不存在这个子命令** |

唯一实测可用的急停手段：`kill <pid>`。pid 从该 agent 自报的地方取——例如它写下的占住记录里的进程号
字段，或 §6 的「进程 ↔ worktree」对照。**`SendMessage` 不是急停手段** —— 会排队、会被扣留、会静默超时
作废，指望它打断正在跑的 agent 会白等。

## 5 · agent 之间通信

### 陷阱 ⑦ Claude Code：`crossSessionInbound` 未设置时，跨 session 消息按权限模式对等投递

主控 session 常是 `bypassPermissions`，herdr 起的 claude agent 是 `auto`（prompting 类）——每一对都
跨类，双向消息全部扣留等人工批准。后果不是「消息慢」，是**agent 看起来像卡死**（误判过，见 HISTORY #16）。修法：在
`~/.claude/settings.json` 顶层设 `"crossSessionInbound": "accept"`；对**已在跑的 session 立即生效，
无需重启**。

### agy 够不着 `SendMessage`

它不是 Claude session，没有 `cc-socks` socket，发过去直接 `No agent named ... is reachable`。只能
`herdr agent prompt <名> "<文本>"`（受陷阱 ② 约束：排队）。

## 6 · 判断死活、卡住、干完、还是被重启过

### 判定「停摆」前四个信号必须全部为真

不能只看 transcript 是否增长。transcript 冻结与「正在跑长命令」（例如开 PR 前的全量测试）在这个指标下表现完全
相同。

**这个指标的另一侧一样会撞车：已经做完的 agent 也长这样。** transcript 停止是因为它交完活退场了，文件
mtime 静止是因为它提交了（工作区变干净）；一份纯文档任务本来就没有子进程可看。「跑长命令」和「已完工」
在这三个信号上完全重合，这正是陷阱 ③（闲着因为干完了 vs 闲着因为卡住，状态完全相同）在停摆判定里的
再现——按字面实现这条会重新推导出同一种误报。两种误报都发生过，见 HISTORY #17。

四个信号必须**全部**为真才成立，任一为假都不是停摆：

- transcript 静止；
- worktree 文件 mtime 静止；
- 该 worktree 路径下无存活子进程（`pytest`/`pnpm`/`node`/`tsc`/`uv` 这类）（或该 worktree 的解释器
  无活动的测试库连接）；
- 该分支相对主干**没有**未合并提交、且**没有**已开的交付物（合并请求）—— 用
  `git -C <worktree> log --oneline origin/main..HEAD` 查提交，交付物用你所用工作流的查法；不要信
  `agent_status`：herdr 把「做完退场」和「卡死」都报成 `idle`。

### 被 `claude --resume` 重启过：四个信号全正常，但事情没在推进

`claude --resume <sid>` 重新拉起的进程续写**同一个** transcript、提交都在、分支没变、占住记录原样躺着 ——
**上面四个信号在重启前后全部读作健康，没有一个会翻转**（发生过，见 HISTORY #18）。

真正的代价不是进程中断（resume 恢复了上下文），而是：**指令送达之后、被消费之前遇到重启会无声蒸发，发送方看不出
任何区别**，只能从行为反推哪条被消费了。

**检测：比 pid。** agent 自报的进程号（例如它的占住记录里的 `pid:`；Claude Code 的消息 socket 路径
`/run/user/<uid>/cc-socks/<pid>.sock` 里就是它），对上那个 worktree 里实际活着的进程：

```bash
for p in $(pgrep -x claude); do printf '%s\t%s\n' "$p" "$(readlink /proc/$p/cwd)"; done
```

两者不等 ⇒ 被重启过（resume 是新进程、新 pid，本次 boot 内 pid 不会重用）。

**不要改用启动时间比。** `ps -o lstart` 在 WSL2 上不可信（实测差 12 小时，见 HISTORY #18）：时钟跳变会让启动
时间凭空「变化」，pid 不会。

**连带一条回收保护**：socket 路径按旧 pid 命名，重启后指向一个已不存在的进程，所以按 socket 判活的
检查对一个刚 resume 过的 agent 只会给出「大概死了」（socket 没了）或「活着」（旧 socket 恰好还在）——
它没有「重启过」这个读数。**读到「大概死了」而那个 worktree 里明明有活着的 claude 进程，那是重启不是
死亡，别回收。**

发现重启之后**不要把那一轮指令整批重发** —— 重复投递炸过一次（见 §2「只送达了一次」）。逐条回读画面
与提交，只补发**在行为上找不到任何痕迹**的那几条，措辞写成重复执行也无害，补完照走回读 + 内容计数。

### agy 的活性

agy 没有消息 socket，按 socket 判活的检查对它恒报「未知」，这是设计如此。活性判定用 `pgrep -x agy`
加 cwd 比对——**不能用 `pgrep -af agy`**，`-f` 匹配整条命令行，会把主控自己那条含 "agy" 字样的巡检
脚本捞出来读成「它还活着」。

```bash
for p in $(pgrep -x agy); do printf '%s\t%s\n' "$p" "$(readlink /proc/$p/cwd)"; done
```

## 7 · 收工是三步，缺一步留壳

三步是：停 agent 进程 → 删 git worktree → 关 herdr workspace（**必须显式做**）。第一步有两种做法，按情况选：

| 情况 | 第一步 | 后两步 |
|---|---|---|
| **正常收工**：claude kind，活干完了、agent 空闲（例如它的 PR 已合并） | `scripts/retire.sh exit <名>`：发 `/exit`，等它从 `herdr agent list` 消失（最多 15 秒），没消失就退非零、别往下做。带上 `REPO=<仓库>` 时，同名 agent 不在这个仓库里就不碰它，退 3（名字全机唯一，只凭名字会收到别的项目的 agent） | `scripts/retire.sh remove <worktree>` |
| **急停 / 卡住 / 非 claude kind / `/exit` 后还在列表里** | `kill <pid>`（§4：唯一实测可用的急停） | 同上，或手动 `git worktree remove --force` + `herdr workspace close` |

为什么正常收工不直接 kill：`/exit` 让 Claude Code 自己退出、收好 transcript，退出之后它从 `herdr agent list`
消失，这本身就是「进程停了」的判据，不用去找 pid。为什么急停不用 `/exit`：它是一条普通 prompt，对方正忙时会
**排队**到这一轮跑完（陷阱 ②），打断不了任何东西。
`/exit` 这条路径只在空闲时测过一次（见 HISTORY #19）。**推翻条件**：`/exit` 之后 agent 留在列表里
（`retire.sh exit` 会报 ⚠）；或 herdr 改成 agent 退出后仍保留在列表里。

`retire.sh remove` 按 `herdr workspace list` 里每个 workspace 的 `worktree.checkout_path` 找挂着这个 worktree 的那个
（workspace 的标签是给人看的，可能被改过；`checkout_path` 是 herdr 自己记的路径），删 worktree，关 workspace，
最后再看一遍列表。herdr 0.9.5 有 `herdr worktree remove`，它会不会连带关 workspace **没测过**，所以这里不用它。

**不要假设哪一步会替你做另一步。** 曾是「`worktree remove` 会连带关 workspace」，已推翻（那几个是用户手动关的），
见 HISTORY #20。`worktree remove` 到底会不会连带关，至今没有观测过。

**完成判据**：收工后跑一次 `herdr workspace list`，还看得见那个标签就是没关干净。

## 8 · 各 harness 从哪里发现技能

| harness | 用户级 | 工作区级 |
|---|---|---|
| Claude Code | **发现** `~/.claude/skills/`。测的那台机器上 `~/.claude/skills` 整个是指向 `~/.agents/skills` 的软链；Claude Code 自己扫不扫 `~/.agents/skills/` **没单独测** | `.claude/skills/`；其中软链到别处的技能目录也会被发现 |
| OpenCode 1.18.32 | **发现** `~/.agents/skills/` 与 `~/.claude/skills/`，两个都扫 | 未测出结论 |
| agy 1.2.12 | **发现 `~/.gemini/config/skills/<名>/SKILL.md`**（软链也行）；**不扫 `~/.agents/skills/`** | `.agents/skills/` |

怎么测的见 HISTORY #21。

**所以用户级安装按 harness 各链一处**：Claude Code 链 `~/.claude/skills/<名>`，OpenCode 链 `~/.agents/skills/<名>`
（或 `~/.claude/skills/<名>`，两个它都扫），agy 链 `~/.gemini/config/skills/<名>`。**同时用 Claude Code 和 OpenCode
时只链 `~/.claude/skills`**。`scripts/check-env.sh` 会列出五份技能在各处在不在。

两处都链对 OpenCode 无实害，只多一条 `duplicate skill name` 警告，见 HISTORY #22；只链一处是为了干净。

曾是「用户级安装要链两处：`~/.agents/skills` 与 `~/.gemini/config/skills`」，已改，见 HISTORY #22。

曾是「agy 不发现用户级技能，派 agy 时指令里写技能的绝对路径」，已推翻，见 HISTORY #21。下一个看到「agy 找不到
技能」的人，先查它是不是装进了 `~/.gemini/config/skills/`，别把绝对路径加回来。

**什么观测会推翻本表**：
- agy 改了全局技能目录，或开始扫 `~/.agents/skills/` ⇒ 改 agy 那行和安装步骤。复核方法：安装后在空目录里让
  agy 列一次技能。
- OpenCode 某版本的 `opencode debug skill` 不再列出 `~/.agents/skills/…` ⇒ 改 OpenCode 那行。
- OpenCode 改了扫描目录或重名处理（报错、或同名列两份）⇒ 重测，并改上面「只链一处」的说法（HISTORY #22）。

软链的用户级技能目录：agy 在 `~/.gemini/config/skills/` 下已测过软链可用；Claude Code、OpenCode 在
`~/.agents/skills/<名> -> <别处>` 这种形状下**没测过**——装好之后用上表的方法各看一眼。
