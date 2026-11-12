# herdr-agents 的历史记录

`SKILL.md` 里「见 HISTORY #n」指到这里：何时观测、怎么测出来的、当时的数据，以及被推翻的旧说法的来龙去脉。只在需要查
来龙去脉时读，平时不加载。

## #1 · 陷阱 ④b：`visible` 跟着滚动位置走

**起因（2026-09-28 17:50 前后，coordinator 驱动 agy worker）：** `visible` 一直显示「输入框里还躺着刚发的指令、
上面是很早以前的输出」，于是以为没提交，多按了几次 Enter 又重发。同一时刻 `recent --lines 400` 显示指令早已提交、
agent 在干活；`herdr agent explain` 也报 working。

**第一次测（2026-09-29，herdr 0.9.1，新开 workspace 里一个普通 shell pane 和一个 agy 1.2.x）：**
1. 在底部时连续采样 10 次，`visible` 与 `recent` 的最后一行每次都一样——`visible` 本身没有延迟。
2. 用 socket API 的 `pane.scroll` 把 pane 往上滚 150 行：`visible` 立刻变成 S105–S151 那一段，`recent --lines 3`
   仍是最后几行，`detection` 仍是底部。
3. 滚着不动再打 50 行新输出：`offset_from_bottom` 从 150 自动涨到 201，`visible` 仍是 S105–S151。
4. 对 agy：滚上去 20 行后发一条新指令，agent 跑完，`visible` 连续 24 秒都是上一轮的输出；`recent` 读到了全部新
   输出。把偏移调到 76 行时，`visible` 底部正好是「上一轮输出 + 分隔线 + `> 指令原文`」——就是 17:50 那次的画面。
5. 滚回 0：`visible` 与 `recent --lines 47`（47 = viewport_rows）逐字相同。

上游（写下时）：0.9.1 是最新正式版，之后两个 preview（09-21、09-28）没有改 `visible` 语义的提交；issue 列表里没人
报过。文档对 `visible` 只写「Current rendered screen」，按字面不算 bug。

**复测（2026-10-21，herdr 0.9.5 + agy 1.4.2，一次性 workspace，测完关掉）：** 0.9.2–0.9.5 的发布说明里没有改
`visible` 语义的条目。
1. shell pane 打出 S1–S300，`pane.scroll` 滚到 150：`visible` = S99–S151，`recent` / `detection` 底部是 S300。
2. 再打 50 行：`offset_from_bottom` 150 → 201，`visible` 仍是 S99–S151，`recent` 底部 S350。
3. 滚回 0：`visible` 与 `recent --lines 53`（viewport_rows）`diff` 无差异。
4. agy：滚上去 30 行，发一条「输出 M1–M40」的指令，跑完后 `visible` 与发指令前**逐字相同**（0 行 M），
   `recent --lines 60` 有 40 行 M；`offset_from_bottom` 30 → 74。

**还没拆开的一次观测（2026-09-29 01:10 前后）：** 巡检脚本用 `visible | tail -4` 对 5 个 agy 连续报 working 超过
一小时，改成 `recent --lines 12` 才读对。那次同时把 agy 状态栏的「N task(s)」当成了在干活——在底部时 agy 的最后
4 行只有输入框和状态栏，看不出忙不忙，所以更像是「只看 4 行 + 判据错」，不一定是 `visible` 冻住了。那 5 个 pane
事后已关，没法再查滚动位置。

## #2 · 陷阱 ③a：agy 的 `agent_status`

**旧说法一（2026-09-29 写）：「后台 shell 在跑就算 working」。** 当时生效的 manifest `agy.toml` `2026.06.24.1`
有一条 `background_tasks_working`：底部出现 `· N task` 就判 working，而那个数字是后台 shell 个数，起着 dev server
就恒大于 0。2026-09-29 08:2x 三个停在输入框等人的 agy（底部 `2 task(s)`）`agent explain` 全报 working。
**推翻：** herdr 0.9.4 发布说明「Antigravity and Grok count as idle once they are back at their prompt, even if
their own background tasks or subagents are still running」（#3530），manifest `2026.10.05.1` 文件头「Once the agent
is back at its prompt they do not count as working」。

**旧说法二（2026-09-29 写，2026-10-21 合并 PR #2 时按 manifest 文本保留）：「接口报错停住仍读作 working」。** 依据是
09-28/29 当夜三次报错停住都被读成 working，以及 manifest 里没有认 `Internal error encountered` 的规则。当夜被读成
working，多半是上面那条后台任务规则顺带造成的；没有规则命中时的默认值其实是 `idle`。
**推翻（2026-10-21，herdr 0.9.5，remote manifest `2026.10.05.1`，没有本地覆盖）：** 用 `herdr agent explain --file
<屏> --agent agy` 测四张屏：

| 屏 | 结果 |
|---|---|
| 空闲（真实 agy 1.4.2 截屏） | `idle`，无规则命中 |
| 干活（真实截屏，`⣯ Generating...` + `esc to cancel`） | `working`，`esc_cancel_footer_working` |
| 信任框（真实截屏） | `blocked`，`trust_prompt` |
| 接口报错 | `idle`，无规则命中 |

报错屏**不是真实截屏**：是在真实空闲屏的输入框上边框之前插入 `⚠ Internal error encountered.` 和 `Error ID: …`
两行造出来的（形状照 2026-09-29 本地覆盖文件里那条正则，那条正则是照当夜真实屏幕写的）。真实报错屏如果多出别的
行，结论可能不同——这也是正文推翻条件里写「真实报错屏读成 working」的原因。

## #3 · 本地覆盖整份替换上游 manifest

herdr 0.9.5 文档（Agents · Detection manifests）：「Local overrides can replace a remote or bundled manifest」
「Local overrides always win」。为确认是整份替换而不是按规则合并，2026-10-21 用 #2 那四张屏在四种配置下跑
`agent explain --file`（每次改完 `herdr server reload-agent-manifests`）：

| 配置 | 空闲 | 干活 | 信任框 | 报错 |
|---|---|---|---|---|
| A 本机原覆盖 `2026.09.29.1` | idle | working | **idle** | blocked |
| B 无覆盖（remote `2026.10.05.1`） | idle | working | blocked | idle |
| C 覆盖里只放报错那一条规则 | idle | **idle** | **idle** | blocked |
| D remote `2026.10.05.1` 全文 + 报错那条规则 | idle | working | blocked | blocked |

C 里干活屏落成 idle：上游规则一条都没生效，所以是整份替换。A 的信任框读成 idle，是因为那份覆盖写于上游加
`trust_prompt` 之前——覆盖会把上游后来的修复一起挡住。D 是唯一四张都对的，代价是上游以后再更新，本机也看不到，
要手动再同步。

## #4 · 版本绑定：「陷阱 ① 已随 0.9.0 修复」（已推翻）

**原文：** 「版本绑定」曾写「陷阱 ① 已随 **0.9.0** 修复」。依据是 0.9.0 的发布说明（「`agent prompt` now reliably
sends the prompt and Enter before reporting successful submission」），0.8.2 也写了 `agent start` 不再过早报告就绪——
没有实测。

**推翻：** 2026-09-22 在 0.9.1 上对 agy 做的对照实验仍然复现（立即发 0/4，见 #5）。升级仍然是对的（0.8.0 上连等 30
秒都没用，0.9.1 上等 banner 就稳），只是发布说明说修了，不等于这条路径修了。2026-10-21 改正。

**其它版本信息（写下时）：** 「已知陷阱」多数条目最早实测于 2026-08-25、herdr 0.8.0，未在 0.9.x 上复测；陷阱 ① 的
现状实测于 0.9.1；带 2026-10-21 日期的 claude kind 条目实测于 0.9.5 + Claude Code 2.1.306。

## #5 · 陷阱 ① 对照实验（2026-09-22，herdr 0.9.1，每组 4 次）

原 `startup-evidence.md` §①。判据不是 `--wait` 的返回码，而是**画面上有没有出现 agy 的回答**（prompt 里要求只回
`PROBEOK`，数它出现几次：1 次 = 只有回显，2 次 = 真的执行了）。

| 条件 | 真的执行了 | 细节 |
|---|---|---|
| `agent start` 后**立即发** | **0 / 4** | 3 次报 `agent_prompt_stalled`，**1 次报 `OK` 却根本没执行** |
| **轮询到 banner 出现再发** | **4 / 4** | 全部真执行 |

铁证是 banner 的行号：立即发那 4 次**全是第 64 行**（3KB 文本占了 1–63 行，排在 banner 前面，说明击键落进了裸终端）；
等待那 4 次**全是第 4 行**（文本在 banner 之后，进了 TUI 的输入框）。

当时的轮询写法是 `--source recent-unwrapped --lines 20` 加 `grep "Antigravity CLI"`；2026-09-28 因为 #6 改成了
`--source visible` 加 `Antigravity CLI [0-9]`。4/4 这个结论本身没被推翻，只是当初没覆盖信任对话框。

同一实验推翻了 2026-09-22 早些时候写过的「没报错就是已落地，不要补发」：4 次立即发里有 1 次返回 `OK` 而指令其实丢了。

2026-11-11 在 herdr 0.9.5 + agy 1.5.5 上复测，0/4 不再复现，见 #26。

## #6 · 陷阱 ①a：新 worktree 先弹信任框，旧的轮询读法看不见它（2026-09-28，herdr 0.9.1 / agy 1.2.11–1.2.12）

原 `startup-evidence.md` §①a。

**现象：** 原先的轮询写 `--source recent-unwrapped --lines 20`，在信任对话框上读回全空，循环空转 60 秒超时，prompt
随后打进对话框里。2026-09-22 的对照实验没撞上它，推测那几次的目录已被信任过（`~/.gemini/antigravity-cli/settings.json`
的 `trustedWorkspaces` 是逐路径列表，父目录在列表里也不会让子目录免问——看到列表后推断的，没单独测）。

**为什么读回空：** 不是 herdr 的 bug，是文档写明的行为：`--lines N` 取「最后 N 行终端行」，从光标所在行往上数，空行
也算。对话框只画在屏幕顶部十来行，光标却停在下方很远处。`visible` 不受光标影响。

**怎么测出来的**（开一个空白 pane，统计各读法的非空行数）：

| 场景 | `recent-unwrapped --lines 20` | `--lines 80` | `visible` |
|---|---|---|---|
| 普通 shell，打几行字 | 读得到 | 读得到 | 读得到 |
| `less` 全屏（alternate screen） | 读得到 | 读得到 | 读得到 |
| agy 停在信任对话框 | **0 行** | 8 行 | 8 行 |
| agy 按 Enter 信任之后 | 10 行，含 banner | 10 行 | 10 行 |
| **不用 agy**：shell 打两行后 `tput cup 48 0` 把光标挪到下方 | **0 行** | 读得到 | 读得到 |

最后一行把 agy 排除掉了：只挪光标就能复现。第二行排除了「全屏程序就读空」的猜想。第四行说明信任之后 `--lines 20`
照常可用。

**旧判据串会误判：** 对话框里有一句「Antigravity CLI requires permission…」，`grep "Antigravity CLI"` 会在对话框阶段
就误以为 banner 到了。

**上游：** herdr 0.9.1 是写下时最新正式版；0.9.0 修过一个相似的 bug（#3444：内容没滚出一屏时 recent 读回空），在
0.9.1 上确认已修（上表第一行）。剩下的这个是文档写明的行为，升级不会变。agy 1.2.12 的 `--help` 里没有跳过信任的参数。

**推翻条件：** 新 worktree 里启动 agy 不再弹信任对话框 ⇒ 循环里那行 `trust` 分支可删；herdr 改了 `--lines` 的计数方式
（发布说明里提 `pane read` / `--lines`）⇒ 重做上表；banner 不再带版本号 ⇒ 判据串要改。

当时写「claude kind 在新目录里有没有类似的信任对话框、`--lines 20` 读不读得到它，没测过」。前半句 2026-10-21 测了（见
#10）；后半句仍然没测——`launch.sh` 轮询用的是 `visible`。

## #7 · 启动序列上连错的三次结论（刹车）

同一个问题连错三次，每次都是**少数观测 + 一个说得通的故事**：

| | 当时的结论 | 被什么推翻 |
|---|---|---|
| 1 | 「等稳再发」能解决 | 等 30 秒照样丢 |
| 2 | 「本会话第一条必被丢弃」，用 `--wait` 检测 | 是竞态不是「第一条」；且 `--wait` 会假阳性 |
| 3 | 「0.9.1 已修」 | 那次探针本身就是假阳性——prompt 出现在 banner 之前，看到 `OK-working` 就收了，从没确认 agy 真回答过 |

第 3 次尤其要记：当时手里已经有 banner 行号这个判据，但没去用。判据存在不等于判据被使用。

## #8 · 名字与标签的实测

- 2026-08-25：`herdr worktree create --label` 与 `herdr tab rename` 的标签带空格、`#`、`·`、中文都通过。
- 2026-08-26：`herdr agent rename <pane_id> <名字>` 可用。
- `--model` 不继承：写下时那台机器的 `~/.claude/settings.json` 是 `sonnet`，herdr 起的 claude 省略 `--model` 就落在它上。

## #9 · opencode 起在 worktree 里（2026-10-13）

**何时、怎么测的：** OpenCode 1.18.34 + herdr 0.9.3，作者一个私有项目的 Issue 里的执行者对比：OpenCode（deepseek v4.1 flash）
被起在 `<路径>/runner-compare/`，在 `<worktree 路径>/cmp-ds` 里跑 26 条 e2e 要点，弹了
7 次以上权限框（每次一个新子目录）；同时、同手册、同类目录布局的 Claude Code（Haiku，auto mode）0 次。前一天另外两个 Issue 里
的 OpenCode 执行者同样起在运行目录、同样逐目录弹框。

**细节：** `Allow always` 只放行**那一个子目录**的 pattern（例如 `…/cmp-ds/frontend/tests/e2e/*`），读到
`…/backend/app/services` 又问一遍；选 Allow always 后还会再弹一个「This will allow the following patterns until
OpenCode is restarted — Confirm / Cancel」，要再按一次 Enter 才放行。

**否掉的做法：** ① 在 `~/.config/opencode/opencode.json` 加 `"permission": {"external_directory": {"<路径>/**":
"allow"}}`——官方支持，但改的是全局配置，影响所有项目的 OpenCode；② `--auto`（「auto-approve permissions that are not
explicitly denied (dangerous!)」），放行范围太宽。

## #10 · claude kind 的信任框（2026-10-21）

**何时、怎么测的：** Claude Code 2.1.306 + herdr 0.9.5，三次：一个 job 临时目录、一个 `~/.cache` 下的新目录、一个从没
用过的仓库的新 herdr worktree，都弹了；一个信任过的仓库的 herdr worktree 没弹。第一次照 agy 的写法直接按 Enter，会话
退出了。

**原文（已推翻）：** 「claude kind 在新目录里有没有类似的信任对话框，**没测过**」——当时确实没测；`launch.sh` 的前身
照 agy 的写法「看到 trust this folder 就按 Enter」，按下去就退出了。

## #11 · 只送达了一次：从文件数到数内容

**重复投递的事故：** `herdr agent prompt` 把同一份批次指令投递了两次，第二次落进会话启动器，在同一个 worktree 里又生成
了一个 session，两个 session 并行探查同一批文件。

**原检查（已推翻）：** 「transcript 文件数增量必须为 1」：

```bash
ls ~/.claude/projects/<worktree-slug>/*.jsonl | wc -l   # 发之前、发之后各跑一次，增量必须为 1
```

（必须是增量：transcript 按路径归档，活得比 worktree 长，绝对值 == 1 会立刻误报。）2026-09-17/18 一轮八张牌跑下来
发现，文件数增量只能抓到「多起了一个会话」，抓不到同一会话里的重复投递——而那一轮重复投递多次发生（`agent prompt`
静默吞掉第一次是常态，回读看不到就容易重发）。所以改成数内容。

## #12 · 计数时排除 `isMeta`、计入 `queued_command`（2026-10-21，Claude Code 2.1.306）

**`isMeta`：** 在本机最近约 400 份 transcript 里找「命令行参数原样出现在某条 isMeta 记录里」的，找到 4 份。**原写法
（已推翻）：** SKILL.md §2 原先贴的计数代码没排除 `isMeta`，对斜杠命令起头的指令会数成 2，读成「重复送达」；dispatch
的 launch.sh 排除了；两份并存，现只留 `count-delivered.sh`。

**`queued_command`：** 同一个 worker 的 transcript：忙时排队的那条只有 `enqueue` / `remove` / `queued_command` 各一条、
`user` 为 0；空闲时发的几条各有一条 `user`。原来只数 `user`，对排队的那条读出 0，是假阴性。

## #13 · 别往有人在打字的输入框里发（2026-10-13 / 10-14）

- 2026-10-13：一条消息被接在用户在 grill pane 里没写完的回答后面一起发了出去。`pane send-text` 同样会接在后面——按机制
  推断，没单独测。
- 2026-10-14：一个 worker 的输入框里显示「合并 PR 1007」，按纯文本读，coordinator 好几次让用户「按一下 Enter」，用户
  指出那是 Claude Code 的灰字建议、他根本没打过。去掉暗色片段后，4 个显示着建议的 pane 都读成空。真有人打了字时应当
  读成非空——没测过。

## #14 · 斜杠命令经 herdr 打进去有效

- 2026-08-25：经 `agent prompt` 打进输入框的 `/grill-with-docs` 正常加载技能，即使它带 `disable-model-invocation: true`。
- 2026-10-21，Claude Code 2.1.306 + herdr 0.9.5：先在一个一次性 session 上测：空闲时发 `/rename`，立刻显示
  `Session renamed to: …`，peer 列表（`ListAgents`）马上变了；正在跑工具（`sleep 25`）时发，也是立刻生效，没有打断
  那一轮，也没有排到这一轮之后。再在一个 session 自己这一轮的工具调用里对自己的 pane 发，同样生效。

## #15 · 陷阱 ④：「`visible` 读不到对话内容」（已推翻）

**原文（2026-08-25/26，herdr 0.8.x）：** 「`pane read --source visible` 读不到对话内容，会返回空白让你误判『指令没
送达』。一律用 `--source recent-unwrapped`。」

**推翻（2026-09-28，herdr 0.9.1）：** 逐个读了 claude / opencode / agy 各 kind 的活跃 pane，`visible` 都返回了当前
一屏的内容。当初为什么成立没能复现，推测与 0.8.x 的读取实现有关（0.9.0 修过 #3444 一类读空问题），未证实。后来又
发现「`visible` = 当前这一屏」少说了一半：它是当前滚动位置那一屏（见 #1）。

## #16 · 叫停路径与跨 session 消息的实测（2026-08-26，2026-09-17 补）

- 2026-08-26：`agent prompt`、`SendMessage` 都不打断；`kill <pid>` 可用。
- 2026-09-17：`herdr agent send-keys <agent> 2` 替 agy 按了权限提示，可用。
- 陷阱 ⑦（2026-08-26）：那一轮有个 worker 静默 31 分钟、零文件改动，被误判为进程冻结，实际是它在等一条跨 session
  消息的投递批准。设 `"crossSessionInbound": "accept"` 后对已在跑的 session 立即生效。

## #17 · 停摆判定的两次误报

- 一个开 PR 前要跑约 8 分钟全量测试的项目：一个 worker 的 transcript 冻结 5.5 分钟，进程核查显示它在正常跑测试脚本里
  的 `pytest`。
- 一次巡检把一个文档任务的 worker 判成 `STALLED`（transcript 135 行、文件 mtime 皆静止 10 分钟、无存活子进程），而
  当时的真实状态是已提交、已开 PR、正常收工。

## #18 · 被 `claude --resume` 重启过（2026-08-27）

2026-08-27 06:18，一批任务的 claude 进程被 `claude --resume <sid>` 重新拉起。同一个 session id 续写同一个
transcript、提交都在、分支没变、占住记录原样躺着——四个停摆信号在重启前后全部读作健康，当时的技能里对 resume 一个字
都没有。主控完全没察觉，是用户问了一句「貌似有一个 worker 已经在工作很久了」才去跑 `ps` 发现的。那一轮给它排了四条
指令，事后只能从行为反推出 rebase 那条被消费了（分支基点变了）；若有一条没被消费，永远不会有人知道。

**`ps -o lstart` 在 WSL2 上不可信：** 一个进程的 lstart 报 `Aug 28 03:35`，而它 socket 文件的 mtime 与它自己写下的
占住时间戳都指向 `Aug 27 15:28`——差 12 小时。

## #19 · `/exit` 收工路径（2026-10-21，Claude Code 2.1.306 + herdr 0.9.5）

在一个一次性仓库的新 worktree 上跑了一遍 `launch.sh` → `deliver-when-idle.sh` → `retire.sh exit` → `retire.sh
remove`：空闲的 agent 收到 `/exit` 后约 3 秒离开列表，worktree 删掉，workspace 关掉，列表里不再有它。只测了空闲时
这一次。

## #20 · 「`worktree remove` 会连带关 workspace」（已推翻，2026-09-17/18）

那一轮清掉四个 worker 的进程与 worktree 之后，前三个的 workspace 从 `herdr workspace list` 里消失了，据此推断
「`worktree remove` 会连带关 workspace」并当场写成经验——用户指出那三个是他们手动关的。第 4 个就留成了空壳，要显式
`workspace close` 才没了。`worktree remove` 到底会不会连带关，至今没有观测过。

## #21 · 各 harness 从哪里发现技能（2026-09-28）

- Claude Code：session 的技能列表里出现用户级技能，也出现工作区里以软链存在的技能。测的那台机器上 `~/.claude/skills`
  整个是指向 `~/.agents/skills` 的软链。
- OpenCode 1.18.32：在一个空目录里跑 `opencode debug skill`，列出的 `location` 全在 `~/.agents/skills/…` 下，日志里对
  `~/.claude/skills/…` 报 `duplicate skill name`（说明两个都扫了）。
- agy 1.2.12：在 `~/.gemini/config/skills/<名>/SKILL.md` 放一个探针技能，在一个空目录里让 agy 列技能（明确要求不调用
  工具），列表里出现了它；换成指向别处的软链再测一次，照样出现。对照：同一个探针放在 `~/.agents/skills/` 时不出现——
  用触发词问它，它是靠 `find ~` 搜到文件再读出来的，不是加载。

**原文（已推翻）：** 同一天早些时候 agy 那一行写的是「agy **不发现**用户级技能」，推论是「派 agy 时，指令里写明要它读
的技能的绝对路径」。当时只测了 `~/.agents/skills/`——那一半是对的——就把「这个目录不扫」推广成了「用户级都不扫」，没去
查 agy 自己的全局技能目录。绝对路径那条变通因此作废：它会把一个装对位置就能消除的问题，固化成每条指令都要带的额外负担。

## #22 · OpenCode 两处都链同一技能会怎样（2026-10-22，OpenCode 1.18.34）

**对应正文：** SKILL.md §8「所以用户级安装按 harness 各链一处」。

**怎么测的：** 隔离 HOME（`env -i HOME=<临时目录>`），一个测试技能 `demo-skill`，在空目录里跑 `opencode debug skill`
看列出的 `location`；加 `--print-logs` 看日志。幕僚长 2026-10-22 08:54 SGT 测过一遍，worker 在临时 HOME 里复现，结果一致：

| 摆法 | 列出几份 | 备注 |
|---|---|---|
| 只链 `~/.agents/skills` | 1 | |
| 只链 `~/.claude/skills` | 1 | |
| 两处都链同一个源 | 1，取 `~/.agents/skills` 那份 | 日志 `WARN message="duplicate skill name"` |
| 两处放内容不同的两份 | 1，只出 `~/.agents/skills` 那份 | 另一份静默丢弃，只有那行 WARN |

**结论：** 两处都链无实害，只多一条警告；README 改成「按 harness 挑一行」，同时用 Claude Code 和 OpenCode 只链
`~/.claude/skills`，是为了干净，不是因为会出错。（「OpenCode 用户会看到每个技能两份」的担心不成立：列出来只有一份。）

**推翻条件：** OpenCode 改了重名处理（报错，或列出两份）。

**原文（已推翻）：** SKILL.md §8 曾写「用户级安装要链两处：`~/.agents/skills/<名>`（Claude Code 经 `~/.claude/skills`、
OpenCode）和 `~/.gemini/config/skills/<名>`（agy）」，已改，见本条。

## #23 · agent 名在整台机器上唯一；`launch.sh` 吞掉了报错（2026-10-23，herdr 0.9.5）

**观测：** 两个项目在同一台机器上各起 agent。按 Issue 号起的名字一重叠，`agent start` 就返回
`{"error":{"code":"agent_name_taken","message":"agent name <名> is already used; candidates: … cwd=<另一个项目> …"}}`，
退出码 1。名字超过 32 个字符时返回 `invalid_agent_name`。旧的 `launch.sh` 把 `agent start` 的输出丢进 `/dev/null`，
然后在就绪循环里空等 60 秒，只报 `NOT READY`，看不出真正的原因。

**上游：** 0.9.5 是当天最新的发布版。名字的格式和全机唯一都是有意做的校验（报错文案就写着规则），不是 bug，所以写成适应。

**改了什么：**

- `launch.sh` 在建 worktree 之前先查格式和重名，免得留下一个没人用的 worktree。`agent start` 失败时把 herdr 的报错原样
  打出来，并说明留下了哪个 worktree / pane。
- `retire.sh exit` 加了可选的 `REPO` 护栏：同名 agent 的 cwd 不在 `REPO` 那个 git 仓库里，就不发 `/exit`，退出码 3。
  只凭名字收工的话，自己的 agent 已经退出、别的项目又恰好有同名 agent 时，会收错人。
- `scripts/test-scripts.sh` 用假 herdr 覆盖上面几条。拿旧脚本跑是 6 败 5 过，新脚本 11 条全过。

**推翻条件：** herdr 改成按 workspace 或项目分开命名。

## #24 · 起 worker 顺带建出主 checkout workspace，收工没人收（2026-10-23，herdr 0.9.5）

**观测：** 幕僚长用 `launch.sh` 给一个作者此前没开过 workspace 的仓库起 worker，`herdr worktree create` 建了 worker 的
workspace，同时多出一个主 checkout 的 workspace（标签是仓库名、一个空闲 shell）。`retire.sh remove` 只关了 worker 的，
主 checkout 的留在侧栏里。作者本来就开着主 workspace 的仓库没有这个现象。

**上游：** 0.9.5 是当天最新的发布版。官方 CLI 文档写明 `worktree create`「groups it with the parent repo workspace」，是有意
的分组，不是 bug；`--help`、文档和配置参考里都没有不建它的参数。另测了两条绕路（用一个临时仓库）：`git worktree add` +
`herdr worktree open --path` 同样会建出主 workspace；`git worktree add` + `herdr workspace create --cwd <wt>` 不建，但
得到的 workspace 没有 worktree 关联（`workspace list` 里没有 `worktree` 字段），丢了分组，`retire.sh` 也找不到它。所以
在 herdr 一侧消除不了，写成适应。

**判据为什么是「launch 时记录」：** 光看状态（只有一个空闲 shell）分不出作者自己开着的主 workspace，会误关。launch 前
后对比 `workspace list`，才能确定「这个是我们引出来的」；收工时再叠加仍挂主 checkout、无别的 worker workspace、1 个
pane、无 agent 在跑，防的是作者在里面干了活，或另一个 worker 还在用它。拿不准就留着并报出来。

**改了什么：** 新增 `scripts/root-ws.sh`（find / record / reap）；`launch.sh` 建 worktree 前后调用 find / record；
`retire.sh remove` 收完 worker 的 workspace 后调用 reap；`test-scripts.sh` 用假 herdr 覆盖「引出来的会关」「作者自己的
不关」「还有别的 worker / 被加了 pane / agent 在跑 / id 指向别处则留着」。

**推翻条件：** herdr 提供了不建主 checkout workspace 的参数（那时 launch 直接传它，删掉 root-ws.sh）。

## #25 · 后台任务面板被读成「输入框非空」，消息排了 40 多分钟（2026-11-03，herdr 0.9.5）

**观测：** 幕僚长用 `deliver-when-idle.sh` 给一个空闲的 worker 送两条消息，日志一直是「input box not empty, waiting」，
排了 40 多分钟没送出去。worker 的 pane 开着 Claude Code 的后台任务面板（「Background · 2 active shells」，最晚
14:21 就在屏幕上；谁打开的不知道），面板盖住了输入框，最后一行带 `❯` 的是面板的选择光标 `❯ ● E=/tmp/…`。
按 Esc 关掉面板后，输入框里只剩灰字建议，直接 `agent prompt` 就送达了。幕僚长起初误报成「灰字建议被当成打了字」；
在三个带灰字建议的 pane 上实测那段判断，都读成空，下午另一次带灰字建议也照常送出，所以灰字那条不是原因。

**是不是我们的问题：** 是。面板是 Claude Code 正常的界面状态，是脚本只看「最后一行 `❯`」没想到面板。不涉及 herdr
或 Claude Code 版本。

**复现：** 想当场再开一次面板对照，没成——面板只在有后台任务时才能打开，当时任务已跑完。证据是当时截下的屏幕，
以及用那段屏幕文字跑旧判断得到 `● E=/tmp/x   running`（非空）。

**改了什么（John 选的做法 1）：** 先看整屏有没有「Esc to close」，有就报「panel open over the input box」并等，不按键。
没选「自动按 Esc」：识别错了时 Esc 会打断正在干活的 agent，代价不对称。`test-scripts.sh` 加了三条（灰字建议照发、
打了字要等、面板开着报面板），为此脚本的轮数和间隔可用 `DELIVER_ROUNDS` / `DELIVER_SLEEP` 改。旧脚本不认这两个
变量，拿它跑新测试会挂在 15 秒间隔上，所以红的一侧用上面那段屏幕直接对旧判断验。

**推翻条件：** 面板底部不再写「Esc to close」；或者出现别的盖住输入框、但不带这行字的界面。

## #26 · 0.9.1 那批 agy 结论在 0.9.5 上复测（2026-11-11，herdr 0.9.5，agy 1.4.4→1.5.5）

**为什么测：** 版本绑定里有几条写着「实测于 0.9.1」，本机已是 0.9.5，没人看过 0.9.2–0.9.5 的发布说明。按全局规矩先把
旧结论当成「可能已经不成立」去测。

**上游核查：** 0.9.5 是 `https://herdr.dev/latest.json` 上的最新版。0.9.2–0.9.5 的发布说明里**没有**提 `agent prompt` /
`agent start` 就绪判定或 `pane read --lines` 计数方式的条目；相关的只有 0.9.4「Antigravity permission, question and
workspace-trust dialogs show as blocked」。issue：#5888（open，0.9.5）首次启动/引导画面被报成 `idle` +
`interactive_ready: true`，`agent.prompt` 打进去文本丢失而本身返回成功；#4529（Windows 上刚起的 Claude Code 第一条
prompt 约 1/4 不提交）维护者复现不出，按过期关闭。agy 本地的 `~/.gemini/antigravity-cli/cache/CHANGELOG.md` 停在
1.2.14（9 月 30 日），查不到之后的说明。

**环境：** 一次性 workspace；一个已信任的空目录；每次新开一个 tab、新起一个 agy（默认模型 Gemini 3.8 Flash High）。
agy 在第一次和第二次启动之间自己从 1.4.4 升到了 1.5.5，后面全部在 1.5.5 上。测完 workspace、agent、进程都关掉。

**陷阱 ①（判据同 #5：画面上 `PROBEOK-xx` 出现 2 次 = 回显 + 真回答；再看 banner 与 prompt 的行号先后）：**

| 组 | 做法 | 真执行 | `--wait --until working` | banner 行 / prompt 行 |
|---|---|---|---|---|
| A | `agent start` 返回后立即发，约 70 字节 | 4/4 | 4 次 `agent_prompted` | 3 / 10 |
| C | 立即发，约 3.5KB（对照 #5 的 3KB） | 4/4 | 4 次 `agent_prompted` | 3 / 10，回答在 32 |
| B | 轮询到 banner 再发 | 4/4 | 4 次 `agent_prompted` | 第 1 次轮询就看到 banner |

12 次里没有一次「报 OK 却没执行」。B 组第一轮就看到 banner：`agent start` 返回时 agy 的 TUI 已经画好了。herdr 和 agy
两边都变了，发布说明里都找不到对应修复，**分不清是谁修好的**；降级 herdr 做对照要动全机共用的 server，没做。
正文保留「轮询到 banner 再发」，理由改成 #5888 那一类问题还没修。

**陷阱 ①a：**
- 纯 shell：顶部打两行，`tput cup 48 0` 把光标挪下去 → `--lines 20` 读不到那两行，`--lines 80`、`visible` 读得到。
- agy 1.5.5 在没信任过的目录里：`recent-unwrapped --lines 20` 0 行，`--lines 80` 8 行，`visible` 8 行，与 #6 的表一致。
- 新现象：`agent start` 直接返回 `agent_not_ready`（「is blocked during startup」），`agent explain` 命中 `trust_prompt`
  （remote manifest `2026.10.05.1`）。信任后 banner 仍是 `Antigravity CLI 1.5.5`，带版本号。

**陷阱 ② 与排队：**
- 一轮约 25 秒、不调工具的长输出中途 `agent prompt` 一条：画面显示 `▸ <消息> (alt+m to send immediately)` 和
  `Press up to edit queued messages`，**这一轮结束后**才回答。
- 让 agy 跑 `sleep 40` / `sleep 150` 时，它多次自己把命令放到后台并结束这一轮（「I have launched … as a background task」），
  排队的消息于是在命令跑完前就被回答。是这一轮结束了，不是插队。
- `herdr agent send-keys <名> alt+m` 试了两次，两次 agy 都已把命令放进后台，分不清是 alt+m 起的作用还是这一轮自己结束了。
  没测干净。本机 agy `settings.json` 没设 `queuedMessages`（默认 `Queue`）。

**陷阱 ⑥ 的 Escape：** agy 前台跑 `sleep 150` 时，`herdr pane send-keys <p> Escape` → 4 秒内出现
`⎿ Interrupted · What should Antigravity CLI do instead?`，状态变 `done`，`sleep 150` 进程不在了；排队的那条消息被放回
输入框。之后 `pane send-keys <p> ctrl+u` 和 `agent send-keys <名> ctrl+u` 各一次，都把输入框清空了。只测了 agy。

**`--wait` 对已在 working 的 agent：** 3 次对 working 的 agy 发 `--wait --until working --timeout 5000`，3 次都返回
`agent_prompted`。原先「返回 timeout」那一次观测的说法删掉。

**推翻条件：** 见正文各节。陷阱 ① 那一句的翻案条件是：`agent start` 返回后立即发的 prompt 落在 banner 之前，或回读
不到回答——那时回到 #5 的结论，先核两边版本。

## #27 · 有后台任务时 `/exit` 先弹确认框（2026-11-12，Claude Code 2.1.322，herdr 0.9.5）

**起因：** 幕僚长按用户要求停掉旧幕僚长 Nora：交接后发 `/exit`，它没退出，屏幕上是
`❯ 1. Exit and stop tasks / 2. Move to background and exit / 3. Stay`，上方列着它的后台 shell 任务。按 Enter 才退出。
`retire.sh exit` 只等 15 秒看它从列表消失，碰到这个框会报 ⚠、退 1。

**上游：** 本机 2.1.322 是 npm 上的最新版（11-10 发布）。CHANGELOG 里没有这个框的条目；它是有意的交互，不是 bug，升级
解决不了，所以写成适应。

**对照实验（同一时间、同一目录、都是 haiku，各一次）：**

- 没有后台任务的 agent：`/exit` 后 15 秒内从 `herdr agent list` 消失。
- 先让它用 Bash `run_in_background` 跑 `sleep 900` 的 agent：`/exit` 后 15 秒仍在列表里，屏幕停在上面那个框，默认光标在
  第 1 项。按 Enter 后 6 秒内从列表消失，`sleep 900` 进程也没了（第 1 项会停掉后台任务）。
- 改过的 `retire.sh exit` 在真的 herdr 上各跑一次：有后台任务（`sleep 901`）的打出 ℹ、退 0、后台进程停掉；没有的照旧退 0。

**做法：** 只在光标确实停在「Exit and stop tasks」那一行时按一次 Enter，文案或顺序一变就不按，退回原来的「报 ⚠」。没选
第 2 项「Move to background and exit」：收工就是要停干净，留个没人管的后台进程正是 §7 要防的「留壳」。Monitor 算不算后台
任务**没单独测**（Nora 那次框里列的是 shell 任务）。

**测试：** `scripts/test-scripts.sh` 加了两条（光标在第 1 项：按 Enter、照常收；不在：不按、报还在）。改之前 2 败，改之后
34 条全过。

**原文（已改）：** 「`/exit` 这条路径只在空闲时测过一次（见 HISTORY #19）。」

**推翻条件：** Claude Code 的确认框文案或默认项变了；或出了能跳过这个框的设置（那时改用设置，删掉按键）。
