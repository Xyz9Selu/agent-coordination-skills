---
name: herdr-agents
description: Use when driving another coding agent (claude / agy / opencode) through herdr — starting it, confirming it is ready, getting an instruction delivered exactly once, reading it back, interrupting it, passing messages between agents, or telling stuck from finished from restarted. Also reached by the dispatch skill for every worker it launches.
---

# herdr-agents

**先读官方 `herdr` 技能**（通常在 `~/.agents/skills/herdr/SKILL.md`）。命令语法、ID、`agent start` /
`agent prompt` / `pane read` 的基本用法、名字的正则、安全规则都在那里，这里不重复。

本技能只写官方没写的东西：**实测出来的启动序列、送达确认、回读、打断、agent 之间通信，以及每一个
返回值不会告诉你的坑。** 官方的描述和这里带日期的实测冲突时，先核版本（见「版本绑定」），再以
这里的实测为准。

第一次在一台机器上用：跑一次 `scripts/check-env.sh`，它把本机 herdr 与各 agent CLI 的版本和本技能
标注的实测版本对一遍，不同就提醒（只读，不拦、不装任何东西）。

## 版本绑定

> **每条都绑在一个 herdr 版本上。** 下面「已知陷阱」多数条目实测于 **0.8.0**；陷阱 ① 已随 **0.9.0**
> 修复，其余条目**未在 0.9.1 上复测**。发现某条对不上时，先核 `herdr --version` 与
> `https://herdr.dev/latest.json` 的发布说明——上游可能已经修了，那就该升级，而不是在这里
> 加一条新的变通写法。

「已知陷阱」这一组条目最早是 2026-08-25 实测记下的，返回值都不会告诉你。下面按用途分节，
编号 ①–⑦ 保留原来的编号，方便和旧记录对照。

## 1 · 起 agent，确认它真的就绪

### 命令形式

`herdr agent start` 本身没有 `--model` 参数，agent 自己的参数靠 `--` 之后透传（已实测）：

    herdr agent start <名> --kind claude --pane <p> --timeout 90000 -- --model opus
    # 返回 argv: ['claude', '--model', 'opus']

**claude kind：herdr 起的独立 session 省略 `--model` 不会继承你的模型**，会去读
`~/.claude/settings.json`（写下时那台机器上是 `sonnet`）——该显式传的地方必须传，否则拿去做架构
判断的 agent 会悄悄落在低一档的模型上。（只有 Claude Code 自己的 Agent 工具省略 `model` 才继承
调用方。）

agy 的模型名：`gemini-3.8-flash-high` 是写下时（2026-09-17/18）最新的，**`3.1-pro` 更旧**（名字里的
"pro" 会骗人）。不传 `--model` 会落回会话默认。

### 名字

官方技能写了名字必须匹配 `[a-z][a-z0-9_-]{0,31}`。补两条实测：

- 违反时 `agent start` 返回 `invalid_agent_name`（这是工具直接吐出来的硬约束，不是观测）。`WORKER-476` 这种写法会被拒——曾经有一版说明只写了
  「只用连字符、不带空格」，不完整。
- `herdr worktree create --label` 与 `herdr tab rename` 的标签**可以**带空格、`#`、`·`、中文（2026-08-25
  实测通过）。所以**标签给人看、agent 名给命令用**。
- **`herdr agent rename <pane_id> <名字>` 可用**（2026-08-26 实测）。在 herdr 之外直接起的 agy 在
  `agent list` 里是 `name=None`，按名字发不了 prompt；用 pane id 当 target 补个名字就能寻址了。

### 陷阱 ① `agent start` 返回时 TUI 还没接管终端，此时发出的 prompt 会丢 —— 而 `--wait` 有四分之一的概率谎报成功

**`agent start` 返回的 `interactive_ready: true` 对 agy 是过早的。** 它说的是 pane 里的进程起来了，
不是 agy 的 TUI 已经接管终端。官方技能说 `agent start` 在 herdr「认为它可以交互」后才返回——对 agy
这条路径不成立。

实测（2026-09-22，herdr 0.9.1，每组 4 次）：`agent start` 后**立即发**，真执行 **0/4**（3 次报
`agent_prompt_stalled`，**1 次报 `OK` 却根本没执行**）；**轮询到 banner 出现再发**，**4/4**。完整对照
实验、banner 行号这条铁证、以及我在这个问题上连错的三次结论，见
[`startup-evidence.md`](startup-evidence.md)——**想改这一节的任何一句之前先读它。**

### 陷阱 ①a 新 worktree 先弹「是否信任此文件夹」，`recent --lines 20` 看不见它

agy 在没信任过的目录里启动（每个新建的 worktree 都是），先出一个「Do you trust the contents of this
project? > Yes, I trust this folder」对话框，**banner 要等按了 Enter 才出现**。用
`--source recent-unwrapped --lines 20` 轮询会在这个对话框上**读回全空**，循环空转到超时，prompt 随后
打进对话框里。原因、测量表、上游核查见 [`startup-evidence.md`](startup-evidence.md) §①a。

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
- 其它 kind 的 banner 特征字串不同，**自己回读一眼定**。claude kind 在新目录里有没有类似的信任
  对话框、`--lines 20` 读不读得到它，**没测过**。

**完成判据：** 循环是因为匹配到 banner 特征串而 `break` 的，不是因为跑满 60 次。跑满了就是没就绪，
先 `pane read --source visible` 看画面停在哪，别发。

**什么观测会推翻本节**：轮询到 banner 之后发出的 prompt 仍然丢；或者立即发能稳定成功；新 worktree 里
启动 agy 不再弹信任对话框；banner 不再带版本号。任一出现，按 `startup-evidence.md` 里对应的推翻条件
重做实验，并先核 `herdr --version`。

## 2 · 发指令，并确认它送达了、只送达了一次

```bash
herdr agent prompt <名> '<指令>' --wait --until working --timeout 12000
```

### `--wait` 的返回码不能当证据

实测 4 次立即发里有 1 次返回 `OK` 而指令其实丢了 —— **假阳性**。所以：

- `agent_prompt_stalled` ⇒ 确实没进去，可以信，重发一次。
- `OK` ⇒ **什么都不能证明**，必须回读画面确认（下一小节）。

这一条推翻了 2026-09-22 早些时候写过的「没报错就是已落地，不要补发」。那句话是错的。

### 回读确认 —— 唯一可信的判据，不是可选的补充

```bash
herdr pane read <pane_id> --source recent-unwrapped --lines 100
```

看两样：指令内容在不在、以及它落在 banner **之后**（落在 banner 之前 = 打进了裸终端，已丢）。

### 只送达了一次 —— 数 transcript 的内容，不是文件数

**回读和「占住已落地」都抓不住指令被重复投递。** 实测：`herdr agent prompt` 把同一份批次指令投递了
两次，第二次落进会话启动器，在**同一个 worktree 里**又生成了一个 session，两个 session 并行探查同一批
文件。回读只能证明「送达了」，不能证明「只送了一次」；占住记录是按任务记的，两个副本共用同一条分支、
同一个任务，只会出现一条，看不出重复。

最早的检查写的是「transcript 文件数增量必须为 1」：

```bash
ls ~/.claude/projects/<worktree-slug>/*.jsonl | wc -l   # 发之前、发之后各跑一次，增量必须为 1
```

**必须是增量，不能读绝对值** —— transcript 按路径归档，活得比 worktree 长，同一个 worktree 名字重发
一次时该目录已经存有旧 transcript，绝对值 == 1 会立刻误报。

2026-09-17/18 一轮八张牌跑下来发现，文件数增量只能抓到「多起了一个会话」，**抓不到同一会话里的重复
投递**——而重复投递正是那一轮多次发生的事（`agent prompt` 静默吞掉第一次是常态，回读看不到就容易
重发）。所以改成数内容，两种都能抓：

```bash
python3 -c "
import json
n=0
for line in open('<transcript.jsonl>',encoding='utf-8'):
    d=json.loads(line)
    if d.get('type')=='user':
        c=d.get('message',{}).get('content')
        t=c if isinstance(c,str) else ' '.join(x.get('text','') for x in c if isinstance(x,dict))
        if '<prompt 里一句独特的话>' in t: n+=1
print(n)"
```

`<worktree-slug>` = worktree 绝对路径把 `/` 换成 `-`，**`.` 也变 `-`**（`/home/<user>/.herdr/...` →
`-home-<user>--herdr-...`），少算一个横线会得到「0 个 transcript」的假读数。（这是 claude kind 的
transcript 位置；其它 kind 的对应物没有记录。）

**完成判据：** 回读看到指令落在 banner 之后，**并且**那句独特的话在 transcript 里恰好出现 1 次。

### 送达不等于被处理

回读证明的是「那一刻送到了」—— 一条已经躺在会话里、还没被消费的指令，遇上 `claude --resume` 会无声
蒸发，而画面上看不出区别（2026-08-27 06:18 实际发生过，见 §6「被重启过」）。**改变边界或叫停一类的
指令，验收要落在行为上**（分支基点变了、那个文件不再被动了），不是落在画面上。

### 斜杠命令这样打是有效的

2026-08-25 实测：经 `agent prompt` 打进输入框的 `/grill-with-docs` 会正常加载技能，即使它带
`disable-model-invocation: true`（那条只挡模型自行加载，不挡人敲，而打进输入框等同人敲）。

### 指令里要引用技能时，写清它能不能找到

各 harness 发现技能的位置不同，见 §8。**agy 不发现用户级技能**：给 agy 的指令里凡是要它读某个技能，
写**那个 `SKILL.md` 的绝对路径**，不要只写技能名。

### 一个尚未证伪也尚未确认的观测

对**已经在 working** 的 agent 发指令时，`--wait --until working` 返回 `timeout` 而不是
`agent_prompt_stalled`（它本来就在 working，观察不到状态变化），消息照样进队列。一次观测，只记不写死。

## 3 · 回读：用哪种读法，读到的状态能不能信

### 陷阱 ④ 两种读法的真实分工

**原文（2026-08-25/26，herdr 0.8.x）**：「`pane read --source visible` 读不到对话内容，会返回空白让你
误判『指令没送达』。一律用 `--source recent-unwrapped`。」

> **2026-09-28 在 herdr 0.9.1 上不再成立，原文保留。** 当时观测到 `visible` 读回空白；0.9.1 上逐个读了
> claude / opencode / agy 各 kind 的活跃 pane，`visible` 都返回了当前一屏的内容。当初为什么成立没能
> 复现，推测与 0.8.x 的读取实现有关（0.9.0 修过 #3444 一类读空问题），**未证实**。
>
> 现在两种读法的真实分工：
> - `visible` = **只有当前这一屏**，看不到滚上去的内容；不受光标位置影响。
> - `recent-unwrapped --lines N` = 从**光标所在行**往上数 N 行，能读到滚上去的历史；但画面只占屏幕
>   顶部、光标停在下方时（agy 的信任对话框），小的 N 会读回全空，见陷阱 ①a。
>
> 所以：**确认启动、看对话框用 `visible`；回读较长的对话历史、确认指令落在 banner 之后，用
> `recent-unwrapped` 并给足行数。** 推翻条件：`visible` 在某个 kind 上再次读回空白，而同一时刻
> `recent-unwrapped` 读得到——记下 `herdr --version` 与 kind。

### 陷阱 ③ `agent_status` 是刮终端画面得来的，会抖

`herdr agent explain` 显示判定规则是 `live_prompt_box`，证据就是终端里的 `"❯\n"`。同一个 agent 数秒内
可被读成 `blocked` / `done` / `idle`。而且**「闲着因为干完了」和「闲着因为卡在权限提示上」状态完全
相同** —— 必须读回滚或看提交/交付物才分得清。herdr 也把一个真死了 45 分钟的 agent 报成过 "done"。

**对每个活着的 agent 读回滚佐证，不能只信 `agent_status`。**

### `herdr agent list` 只看得见 herdr 自己起的 agent

agent 退出后会**从列表里消失**，pane 变 `unknown`，死活可判。但 herdr 只看得见它自己起的 pane ——
后台作业形态的 session 它看不见（实测 4 vs 12）。要知道这台机器上一共有哪些 agent 在跑，用 harness
自己的 peer 列表（Claude Code 是 `ListAgents`）和 `git worktree list` 交叉核对。**只看 herdr 会漏掉
一大半。**

## 4 · 打断与叫停

### 陷阱 ② `agent prompt` 是排队，不是打断

给正在干活的 agent 插指令，它会等当前这轮**完整跑完**才处理。改派时必须接受「对方会先把手上这轮
做完」。

### 陷阱 ⑥ 四条「叫停」路径，实测只有一部分能用（2026-08-26，2026-09-17 补）

| 路径 | 实测结果 |
|---|---|
| `herdr agent prompt` | 排队，不打断（同陷阱 ②） |
| `SendMessage`（Claude Code 跨 session 消息） | 会被接收方扣留等人工批准；`dialogExpiry` 默认 5 分钟，超时**静默丢弃并回拒绝** —— 发送方只看到「已扣留」，看不出是超时废弃 |
| `herdr pane send-keys <pane_id> Escape` | 仍未实测 |
| `herdr agent send-keys <agent> <键>` | **实测可用**（2026-09-17，替 agy 按权限提示的 `2`）。官方技能也给了 `agent send-keys <名> esc` 的写法；用它当急停**没单独测过** |
| `herdr agent <stop>` | **不存在这个子命令** |

唯一实测可用的急停手段：`kill <pid>`。pid 从该 agent 自报的地方取——例如它写下的占住记录里的进程号
字段，或 §6 的「进程 ↔ worktree」对照。**`SendMessage` 不是急停手段** —— 会排队、会被扣留、会静默超时
作废，指望它打断正在跑的 agent 会白等。

## 5 · agent 之间通信

### 陷阱 ⑦ Claude Code：`crossSessionInbound` 未设置时，跨 session 消息按权限模式对等投递（2026-08-26 实测）

主控 session 常是 `bypassPermissions`，herdr 起的 claude agent 是 `auto`（prompting 类）——每一对都
跨类，双向消息全部扣留等人工批准。后果不是「消息慢」，是**agent 看起来像卡死**：那一轮有个 worker
静默 31 分钟、零文件改动，被误判为进程冻结，实际是它在等一条消息的投递批准。修法：在
`~/.claude/settings.json` 顶层设 `"crossSessionInbound": "accept"`；对**已在跑的 session 立即生效，
无需重启**。

### agy 够不着 `SendMessage`

它不是 Claude session，没有 `cc-socks` socket，发过去直接 `No agent named ... is reachable`。只能
`herdr agent prompt <名> "<文本>"`（受陷阱 ② 约束：排队）。

## 6 · 判断死活、卡住、干完、还是被重启过

### 判定「停摆」前四个信号必须全部为真

不能只看 transcript 是否增长。transcript 冻结与「正在跑长命令」在这个指标下表现完全相同 —— 一个开 PR
前要跑约 8 分钟全量测试的项目就会触发这个假信号（实测：一个 worker 的 transcript 冻结 5.5 分钟，进程
核查显示它在正常跑测试脚本里的 `pytest`）。

**这个指标的另一侧一样会撞车：已经做完的 agent 也长这样。** transcript 停止是因为它交完活退场了，文件
mtime 静止是因为它提交了（工作区变干净）；一份纯文档任务本来就没有子进程可看。「跑长命令」和「已完工」
在这三个信号上完全重合，这正是陷阱 ③（闲着因为干完了 vs 闲着因为卡住，状态完全相同）在停摆判定里的
再现——按字面实现这条会重新推导出同一种误报。实测：一次巡检把一个文档任务的 worker 判成 `STALLED`
（transcript 135 行、文件 mtime 皆静止 10 分钟、无存活子进程），而当时的真实状态是已提交、已开 PR、
正常收工。

四个信号必须**全部**为真才成立，任一为假都不是停摆：

- transcript 静止；
- worktree 文件 mtime 静止；
- 该 worktree 路径下无存活子进程（`pytest`/`pnpm`/`node`/`tsc`/`uv` 这类）（或该 worktree 的解释器
  无活动的测试库连接）；
- 该分支相对主干**没有**未合并提交、且**没有**已开的交付物（合并请求）—— 用
  `git -C <worktree> log --oneline origin/main..HEAD` 查提交，交付物用你所用工作流的查法；不要信
  `agent_status`：herdr 把「做完退场」和「卡死」都报成 `idle`。

给巡检脚本作者的提醒：新增脚本写完先 `bash -n` 校验，不要用 zsh 语法（如 `$var[...]`）写 bash 脚本
—— 崩溃和真实告警在退出码上分不出来，有一轮已发生两次误报（一次数组下标语法崩溃、一次被自己的
`pkill` 误杀，都被当成告警上报）。

### 被 `claude --resume` 重启过：四个信号全正常，但事情没在推进

2026-08-27 06:18，一批任务的 claude 进程被 `claude --resume <sid>` 重新拉起。同一个 session id 续写
**同一个** transcript、提交都在、分支没变、占住记录原样躺着 —— **上面四个信号在重启前后全部读作健康，
没有一个会翻转**，当时的技能里对 resume 一个字都没有。主控完全没察觉，是用户问了一句「貌似有一个
worker 已经在工作很久了」才去跑 `ps` 发现的。

真正的代价不是进程中断（resume 恢复了上下文，活继续做完了），而是：**指令送达之后、被消费之前遇到
重启会无声蒸发，发送方看不出任何区别。** 那一轮给它排了四条指令，事后只能从行为反推出 rebase 那条
被消费了（分支基点变了）；若有一条没被消费，永远不会有人知道。

**检测：比 pid。** agent 自报的进程号（例如它的占住记录里的 `pid:`；Claude Code 的消息 socket 路径
`/run/user/<uid>/cc-socks/<pid>.sock` 里就是它），对上那个 worktree 里实际活着的进程：

```bash
for p in $(pgrep -x claude); do printf '%s\t%s\n' "$p" "$(readlink /proc/$p/cwd)"; done
```

两者不等 ⇒ 被重启过（resume 是新进程、新 pid，本次 boot 内 pid 不会重用）。

**不要改用启动时间比。** `ps -o lstart` 在 WSL2 上不可信：实测一个进程的 lstart 报 `Aug 28 03:35`，而
它 socket 文件的 mtime 与它自己写下的占住时间戳都指向 `Aug 27 15:28` —— 差 12 小时。时钟跳变会让启动
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

```
1. kill <pid>                             停 agent 进程
2. git worktree remove <path> --force     删 git worktree
3. herdr workspace close <ws_id>          关 herdr workspace   ← 必须显式做
```

**不要假设哪一步会替你做另一步。** 2026-09-17/18 那一轮我清掉四个 worker 的进程与 worktree 之后，前
三个的 workspace 从 `herdr workspace list` 里消失了，我据此推断「`worktree remove` 会连带关 workspace」
并当场写成经验——**用户指出那三个是他们手动关的**。`worktree remove` 到底会不会连带关，至今没有观测
过。第 4 个就留成了空壳，要显式 `workspace close` 才没了。

**完成判据**：收工后跑一次 `herdr workspace list`，还看得见那个标签就是没关干净。

（这一条本身就是「当一个解释让你当下的叙事变得完整时，那正是最该去核的时刻」的又一个实例——区别只是
这次的来源是我自己，不是同伴。）

## 8 · 各 harness 从哪里发现技能

| harness | 用户级（`~/.agents/skills/`、`~/.claude/skills/`） | 工作区级 | 怎么测的 |
|---|---|---|---|
| Claude Code | **发现** `~/.claude/skills/`。测的那台机器上 `~/.claude/skills` 整个是指向 `~/.agents/skills` 的软链；Claude Code 自己扫不扫 `~/.agents/skills/` **没单独测** | `.claude/skills/`；其中软链到别处的技能目录也会被发现 | 2026-09-28：session 的技能列表里出现用户级技能，也出现工作区里以软链存在的技能 |
| OpenCode 1.18.32 | **发现**，两个目录都扫 | 未测出结论 | 2026-09-28：在一个空目录里跑 `opencode debug skill`，列出的 `location` 全在 `~/.agents/skills/…` 下，日志里对 `~/.claude/skills/…` 报 `duplicate skill name`（说明两个都扫了） |
| agy 1.2.12 | **不发现** | `.agents/skills/` | 2026-09-28 实测：列技能时用户级技能不出现；用触发词问它，它是靠 `find ~` 搜到文件再读出来的，不是加载 |

推论：**派 agy 时，指令里写明要它读的技能的绝对路径**（§2）。

**什么观测会推翻本表**：agy 的技能列表里出现用户级技能 ⇒ agy 那行改成「发现」，§2 那条可删；
OpenCode 某版本的 `opencode debug skill` 不再列出 `~/.agents/skills/…` ⇒ 改 OpenCode 那行。

软链的**用户级**技能目录（`~/.agents/skills/<名> -> <别处>`）能不能被三者发现，**都没测过**——装好之后
用上表的方法各看一眼。
