# herdr-agents 的历史记录

`SKILL.md` 里「见历史 #n」指到这里：何时观测、怎么测出来的、当时的数据，以及被推翻的旧说法的来龙去脉。只在需要查
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
