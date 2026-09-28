# 启动序列的实测证据

[`SKILL.md`](SKILL.md) §1 的规则（轮询到 banner 再发、按掉信任对话框、判据串带版本号）都从这里来。
**想改那一节的任何一句之前，先读完这一页**——这个问题我连错过三次，每次都是少数观测加一个说得通的故事。

## ① 对照实验（2026-09-22，herdr 0.9.1，每组 4 次）

判据不是 `--wait` 的返回码，而是**画面上有没有出现 agy 的回答**（prompt 里要求只回 `PROBEOK`，
数它出现几次：1 次 = 只有回显，2 次 = 真的执行了）。

| 条件 | 真的执行了 | 细节 |
|---|---|---|
| `agent start` 后**立即发** | **0 / 4** | 3 次报 `agent_prompt_stalled`，**1 次报 `OK` 却根本没执行** |
| **轮询到 banner 出现再发** | **4 / 4** | 全部真执行 |

铁证是 banner 的行号：立即发那 4 次**全是第 64 行**（3KB 文本占了 1–63 行，排在 banner 前面，说明
击键落进了裸终端）；等待那 4 次**全是第 4 行**（文本在 banner 之后，进了 TUI 的输入框）。

**`agent start` 返回的 `interactive_ready: true` 对 agy 是过早的。** 它说的是 pane 里的进程起来了，
不是 agy 的 TUI 已经接管终端。

当时（2026-09-22）的轮询写法是 `--source recent-unwrapped --lines 20` 加 `grep "Antigravity CLI"`；
2026-09-28 因为下面 ①a 改成了 `--source visible` 加 `Antigravity CLI [0-9]`。4/4 这个结论本身没被
推翻，只是当初没覆盖信任对话框。

## ①a 新 worktree 先弹「是否信任此文件夹」，旧的轮询读法看不见它（2026-09-28，herdr 0.9.1 / agy 1.2.11–1.2.12）

**现象。** agy 在没信任过的目录里启动（每个新建的 worktree 都是），先出一个「Do you trust the
contents of this project? > Yes, I trust this folder」对话框，**banner 要等按了 Enter 才出现**。
原先的轮询写 `--source recent-unwrapped --lines 20`，在这个对话框上**读回全空**，于是循环空转
60 秒超时，prompt 随后打进对话框里。2026-09-22 的对照实验没撞上它，推测那几次的目录已被信任过
（`~/.gemini/antigravity-cli/settings.json` 的 `trustedWorkspaces` 是逐路径列表，父目录（家目录）
在列表里也不会让子目录免问——这一点是看到列表后推断的，没单独测）。

**为什么读回空。** 不是 herdr 的 bug，是文档写明的行为：`recent` / `recent-unwrapped` 的
`--lines N` 取的是「最后 N 行终端行」，从**光标所在行**往上数，空行也算。对话框只画在屏幕顶部
十来行，光标却停在下方很远处，最后 20 行全是空行。`visible` 不受光标影响，返回整屏。

**怎么测出来的**（开一个空白 pane，统计各读法的非空行数）：

| 场景 | `recent-unwrapped --lines 20` | `--lines 80` | `visible` |
|---|---|---|---|
| 普通 shell，打几行字 | 读得到 | 读得到 | 读得到 |
| `less` 全屏（alternate screen） | 读得到 | 读得到 | 读得到 |
| agy 停在信任对话框 | **0 行** | 8 行 | 8 行 |
| agy 按 Enter 信任之后 | 10 行，含 banner | 10 行 | 10 行 |
| **不用 agy**：shell 打两行后 `tput cup 48 0` 把光标挪到下方 | **0 行** | 读得到 | 读得到 |

最后一行把 agy 排除掉了：只挪光标就能复现。第二行排除了「全屏程序就读空」的猜想。第四行说明
**信任之后** `--lines 20` 照常可用，所以 2026-09-22 的 4/4 结论本身没错，只是没覆盖信任对话框。

**另一个坑：旧的判据串会误判。** 对话框里有一句「Antigravity CLI requires permission…」，用
`grep "Antigravity CLI"` 去匹配 `visible` 会在对话框阶段就误以为 banner 到了。所以判据改成
`Antigravity CLI [0-9]`（banner 是「Antigravity CLI 1.2.12」这种带版本号的写法）。

**上游。** herdr 0.9.1 是写下时最新正式版；0.9.0 修过一个相似的 bug（#3444：内容没滚出一屏时
recent 读回空），那个在 0.9.1 上确认已修（上表第一行）。剩下的这个是文档写明的行为，升级不会变。
agy 1.2.12 的 `--help` 里没有跳过信任的参数。

**什么观测会推翻本条**：
- 新 worktree 里启动 agy 不再弹信任对话框（agy 改了行为，或加了跳过参数）⇒ 循环里那行 `trust` 分支可删；
- herdr 改了 `--lines` 的计数方式（发布说明里提 `pane read` / `--lines`）⇒ 重做上表；
- banner 不再带版本号 ⇒ 判据串要改。

claude kind 在新目录里有没有类似的信任对话框、`--lines 20` 读不读得到它，**没测过**。

## 三次错误结论，留在这里当刹车

同一个问题我连错三次，每次都是**少数观测 + 一个说得通的故事**：

| | 当时的结论 | 被什么推翻 |
|---|---|---|
| 1 | 「等稳再发」能解决 | 等 30 秒照样丢 |
| 2 | 「本会话第一条必被丢弃」，用 `--wait` 检测 | 是竞态不是「第一条」；且 `--wait` 会假阳性 |
| 3 | 「0.9.1 已修」 | 那次探针本身就是假阳性 —— prompt 出现在 banner 之前，我看到 `OK-working` 就收了，从没确认 agy 真回答过 |

第 3 次尤其要记：**我当时手里已经有 banner 行号这个判据，但没去用。** 判据存在不等于判据被使用。

另外一条被推翻的旧说法：2026-09-22 早些时候写过「没报错就是已落地，不要补发」。实测 4 次立即发里有
1 次返回 `OK` 而指令其实丢了，那句话是错的（见 `SKILL.md` §2）。

## 版本

herdr **0.9.1** 上仍然复现。0.9.0 的发布说明确实写了「`agent prompt` now reliably sends the prompt
and Enter before reporting successful submission」，0.8.2 也写了 `agent start` 不再过早报告就绪 ——
**但对 agy 这条路径没有解决。** 升级仍然是对的（0.8.0 上连等 30 秒都没用，0.9.1 上等 banner 就稳），
只是别把发布说明当成已验证。

**什么观测会推翻本条**：轮询到 banner 之后发出的 prompt 仍然丢；或者立即发能稳定成功。任一出现，
回头重做上面那个对照实验，并先核 `herdr --version`。
