# 给 dispatch 用：GitHub 怎么回答它的问题

`dispatch` 技能不认识 GitHub，它只列出工作流要回答的问题（它的 `SKILL.md`「工作流要回答的问题」）。用本技能当它的
工作流时，答案如下。**本页只放映射和 GitHub 独有的坑；规则本身以 [`SKILL.md`](SKILL.md) 为准，两边不一致时那边
是权威。**

## Q1 有哪些活

**`SKILL.md` §1 Select 那条查询，原样用，是唯一允许的候选来源。** 它漏掉的，要么被别人持有，要么被例外标签停放，
要么是 parent 容器 —— 一个都不能发。**`deferred` / `blocked` 两条子句不许删**，原因见 `SKILL.md` §1；别抄一份
在别处，以那边为准。

「读一件活的全部记录」在 GitHub 上就是**正文加评论**。被 grill 过的 Issue 正文是旧的，真实范围在评论里；只读
正文会算错影响面。

**坑（2026-08-26 实测）：改完标签/assignee 后立刻跑选取查询会失真。** `gh issue list --search` 走 GitHub 搜索
索引，最终一致；`gh issue view` 读实时。那一轮释放两件 Issue 后立刻跑选取查询，只有一件回到候选池，而 `view`
显示两者都已干净。判断刚变更过的 Issue 状态，用 `view` 不用查询。

## Q2 怎么占住

**worker 的指令里写这一条**（原样，连同绝对路径）：

> 第一件事是跑 `~/.agents/skills/github-backlog/scripts/claim-issue.sh <这批号>`，动第一个文件之前。并且要读它的
> 输出：持有者活着时它会 `REFUSING to claim` 并退非零（**这时候停下来报告你，不要 `--force`**），抢跑时它会打印
> `⚠ N unreleased claims` 并告诉你最早时间戳赢。退非零就是「这张牌没拿到」，必须回头找 coordinator。

这个脚本不是锁 —— 所有 session 用同一个 GitHub 账号时，assignee 那次写入不可能失败。它的价值全在输出里。

**coordinator 读占住状态用 `claim-issue.sh --check <N>...`（只读），不要手搓 `gh issue view` 抓评论。** 它多给
两样你正需要的：**活性判定**，以及**回收依据**（分支在不在、两天内有没有提交、相对主干有几个未合并提交、分支上的
PR 状态）。输出与 `dispatch` 的四个读数一一对应：

| `--check` 输出 | dispatch 的读数 |
|---|---|
| `no prior claim` | 还没占 |
| `HOLDER ALIVE` | 占了且活着 |
| `UNKNOWN` | 占了但活性未知 |
| `probably dead` | 占了但大概死了 |

- 旧格式的 claim（单行式，没有 `sock:` 字段）一律读成 `UNKNOWN` —— 这是设计如此，不是故障。
- agy 起的 worker 写的是 `sock: none`，`--check` 对它恒报 `UNKNOWN`；活性按 `herdr-agents` 技能 §6 用进程判断。
- `UNKNOWN` 时唯一权威是 `SKILL.md` §5 的「2 天无提交」规则，`--check` 会连同分支状态一起打印。
- 刚被 `claude --resume` 重启过的 worker，`sock:` 指向旧 pid，`--check` 会报 `probably dead` 或 `HOLDER ALIVE`——
  它没有「重启过」这个读数，判法见 `herdr-agents` §6。

## Q3 怎么交差

- **交付物是 PR。** 「未完成的交付物」= draft PR；转正 = `gh pr ready`。按 `SKILL.md`「Pull Requests Link Their
  Issues」写 `Closes #N`（只在 maintainer 验收之后才算关闭信号）。
- **grill 的结论写回 Issue 评论，不重写正文**（被 grill 过的 Issue 正文是旧的、评论是新的，这是有意的）。
- **`CLOSED` / `Done` 不等于做完了。** development 链接会自动关 Issue，绕过验收协议；有一件 Issue 就是 CLOSED +
  `Done` 而 worktree、分支、已退出的 session 全在盘上。以地面事实为准。
- **核「已合并」**（dispatch 的 `secondhand-claims.md`「用户口头说的『已合并』也要核」）：
  ```bash
  gh pr view <N> --json state,mergedAt
  git show origin/main:<该 PR 改过的文件> | grep -c "<它应该删掉的东西>"
  ```
- **未完成交付物的年龄**：`gh pr list --draft` 配 `git log --oneline origin/main..HEAD`。
- 「可合并」的辅助信号：`gh pr view <N> --json mergeable` 的 `MERGEABLE`。
- 停摆判定里「没有已开的交付物」这一项：`gh pr list --head <分支名>`。

## Q4 活对应哪个分支

- Issue → 分支：最后一条 `claim:` 评论的第一个字段；`claim-issue.sh --check` 会打印它。
- 分支 → Issue / PR：`gh pr list --head <分支名>`；分支名里带的号只是约定，**以 claim 评论为准**。
- claim 评论里的分支名必须与实际分支一致——grill 转实施沿用 `grill/<议题>` 分支时尤其要对上，否则会被同伴当成过期
  claim 抢走。

## QA 核查标记：PR 标签

`dispatch` 的三态核查标记在 GitHub 上是三个 **PR 标签**，`scripts/bootstrap.sh` 的 `dispatch` 组会列出、确认后建：

| dispatch 的标记 | PR 标签 |
|---|---|
| 占稀缺资源 | `占稀缺资源` |
| 需按序合并 | `需按序合并` |
| 已核 | `资源已核`（绿色） |

细节写在 PR 评论里，不写在标签本身；**无标签 = 尚未核**。

## QB 容器的完成度：parent Issue 扫描

```bash
gh issue list --state open --limit 200 --json number,title,labels,subIssuesSummary \
  --jq '[.[] | select(.subIssuesSummary.total > 0)]
        | sort_by(.subIssuesSummary.completed / .subIssuesSummary.total) | reverse
        | .[] | "#\(.number)  \(.subIssuesSummary.completed)/\(.subIssuesSummary.total)  \(.title)"'
```

`gh api repos/<owner>/<repo>/issues/<N>/sub_issues` 能列出子项及其状态与标签。子项全完之后能不能关，按 `dispatch`
的 `patrol.md`「容器没人关」判断——先读 parent 正文，带自己验收标准的逐条核实。
