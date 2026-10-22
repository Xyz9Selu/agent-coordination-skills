[English](README.md) | **简体中文**

# Agent coordination skills

五个给「一个主 agent 指挥多个 coding agent 并行干活」用的技能。凡是关于工具或环境行为的说法，都带着当时怎么测出来的、以及什么观测会推翻它；用户做的决定就写成决定。

| 技能 | 管什么 | 依赖 | 能单独用吗 |
|---|---|---|---|
| [`herdr-agents`](herdr-agents/SKILL.md) | 用 herdr 起 agent、确认就绪、可靠送达指令、回读、打断、agent 之间传话、判断死活/卡住/干完/被重启、收工 | herdr（以及官方 `herdr` 技能） | 能 |
| [`github-backlog`](github-backlog/SKILL.md) | 用 GitHub Issues 管活：挑任务、认领、标签、PR 规范、验收 | `gh` | 能 |
| [`chief-of-staff`](chief-of-staff/SKILL.md) | 用户的幕僚长：勘察、按代码足迹分组防撞车、推荐给用户挑、派活、巡检、收尾、交接 | **强依赖 `herdr-agents`**；任务系统可选 | 需要 `herdr-agents` |
| [`todo-recorder`](todo-recorder/SKILL.md) | 记录：用户说需求，写进仓库根 `TODO.md`（或明确要求的 issue），从不实现 | 无 | 能 |
| [`todo-executor`](todo-executor/SKILL.md) | 执行：扫 `TODO.md`，挑条目实现、打勾、提交，循环到没有为止 | 无 | 能 |

`chief-of-staff` 的规则不认识 GitHub。它写清了自己需要「工作流」回答的问题（有哪些活、怎么占住、怎么交差、活对应哪个分支），没配工作流时退回到「用户在对话里给清单」。要用 GitHub 管活，就同时用 `chief-of-staff` + `github-backlog`；后者的 [`for-chief-of-staff.md`](github-backlog/for-chief-of-staff.md) 是两者之间的对照。
`chief-of-staff` 有两个脚本确实碰 GitHub，各自写明了：`closeout.sh` 调 `github-backlog` 的 `close-merged.sh`（所以要 `gh`，且 `github-backlog` 装在它旁边）；`scan-workers.sh` 用 `gh` 盯打开的 PR（`WATCH_PRS=0` 关掉）。

`todo-recorder` / `todo-executor` 是同一类「基于 `TODO.md` 的轻量任务流」，但比 `chief-of-staff` + `github-backlog` 轻得多：不认领 Issue、不分组防撞车，只是「记下来」和「挨个做完」。两者可以配合 `github-backlog` 使用（`todo-recorder` 在用户明确要求时可以把条目路由到 issue），也可以完全不装 `github-backlog` 单独用。

> **语言说明：** `herdr-agents` 和 `chief-of-staff` 目前是中文；`github-backlog`、`todo-recorder`、`todo-executor` 是英文（带少量中文触发词）。agent 读哪种都没问题，欢迎为中文技能提交翻译。

## 依赖

- **[herdr](https://herdr.dev)**（[源码](https://github.com/herdrdev/herdr)）：给 coding agent 用的终端工作区管理器，让 agent 在常驻的 pane 里持续运行，并能通过 CLI 互相驱动。`herdr-agents` 和 `chief-of-staff` 都建在它上面，先装它（见其[安装说明](https://github.com/herdrdev/herdr#install)）。实测版本 **0.9.5**。
- **官方 `herdr` 技能**：随 herdr 一起发布。装好 herdr 后 `herdr --skill` 会打印与你二进制版本匹配的那一份（存成 `~/.agents/skills/herdr/SKILL.md`），或者运行 `npx skills add herdrdev/herdr --skill herdr -g`；见 [herdr 的 agent-skill 页](https://herdr.dev/docs/agent-skill/)。`herdr-agents` 要求 agent 先读它。
- **`gh`**（GitHub CLI），已登录：`github-backlog` 和 `chief-of-staff` 里盯 PR 的部分要用。实测版本 **2.95.0**。
- **至少一个 coding agent CLI** 当 worker：**Claude Code**（实测 2.1.306）、**OpenCode**（1.18.32）或 **agy**（1.2.12）。`check-env.sh` 会拿你的版本和这些对一遍，版本不同只提醒。
- **bash**，在 **Linux 和 WSL2** 上实测。macOS 没测过；脚本用到 `ps`、unix socket 和 GNU 风格的工具，预计有差异。

## 快速上手

1. 装好上面的依赖，再装技能（见下一节）。
2. 启动 herdr，开一个 pane，在你要干活的 git 仓库里运行 agent（如 `claude`）。驱动 herdr 的技能只能在 herdr pane 里用（`HERDR_ENV=1`）。
3. 对 agent 说：`/chief-of-staff bootstrap`。它会跑 `check-env.sh` 和你所配工作流的 bootstrap（用 GitHub Issues 时，会列出缺的标签、确认后才建）。
4. 说：「看看有什么活」（或者直接给它一份清单）。它会把任务按代码足迹分组防撞车，请你挑。
5. 挑一组。它在各自的 worktree 里起 worker、巡检，PR 好了告诉你来验收。

想用轻量流程就不需要 herdr：把需求告诉 agent（`todo-recorder` 写进 `TODO.md`），再说「把 TODO 做完」（`todo-executor`）。

## 脚本

| 脚本 | 属于 | 干什么 | 写东西吗 |
|---|---|---|---|
| `herdr-agents/scripts/check-env.sh` | herdr-agents | 本机 herdr / claude / agy / opencode 版本 vs 技能里的实测版本；五份技能在 `~/.agents/skills/`、`~/.gemini/config/skills/` 各装没装 | 不写 |
| `herdr-agents/scripts/launch.sh` | herdr-agents | 在新 worktree 里起 claude：等就绪（按掉信任框）、发一次指令、数送达次数（`DRY_RUN=1` 只打印） | 建 worktree、workspace、agent |
| `herdr-agents/scripts/count-delivered.sh` | herdr-agents | 数一条指令在 claude 的 transcript 里送达了几次 | 不写 |
| `herdr-agents/scripts/deliver-when-idle.sh` | herdr-agents | 等 agent 空闲、输入框为空再发消息 | 发消息 |
| `herdr-agents/scripts/retire.sh` | herdr-agents | 收工：`exit`（发 `/exit`、等它离开列表）、`remove`（删 worktree、关它的 workspace） | 删 worktree、关 workspace |
| `github-backlog/scripts/bootstrap.sh` | github-backlog | 检查 gh 与仓库；列出缺的标签，确认后才建（`--check` 只列） | 确认后建标签 |
| `github-backlog/scripts/claim-issue.sh` | github-backlog | 认领、只读检查（`--check`）、`--self-test` | 认领时写 Issue |
| `github-backlog/scripts/close-merged.sh` | github-backlog | 合并后核 PR 已落地、Issue 从 `In review` 改 `Done`（`--check` 只核） | 改 Issue 标签 |
| `chief-of-staff/scripts/scan-collisions.sh` | chief-of-staff | 迁移号 / ADR 编号跨分支撞号扫描（`MIGRATION_DIR`、`ADR_DIR` 至少给一个；`--prs` 要 `gh`） | 不写 |
| `chief-of-staff/scripts/test-scan-collisions.sh` | chief-of-staff | 在临时仓库里造出每种撞号情形，断言 `scan-collisions.sh` 的输出与退出码 | 只写临时目录 |
| `chief-of-staff/scripts/scan-workers.sh` | chief-of-staff | 给 Monitor 用的巡检事件流：agent、PR（`gh`）、main 前进、撞号、心跳 | 不写（只 `git fetch`） |
| `chief-of-staff/scripts/closeout.sh` | chief-of-staff | PR 合并后按顺序收尾：`close-merged.sh` → `retire.sh exit` → 项目的 `DROP_DB_CMD` → `retire.sh remove` → 删本地分支 | 写——标签、worktree、workspace、分支，以及 `DROP_DB_CMD` 做的事 |

`/chief-of-staff bootstrap` = 跑 `check-env.sh`，再跑你所配工作流的 bootstrap（配 GitHub 就是 `bootstrap.sh`）。

## 安装（用户级）

```bash
git clone https://github.com/Xyz9Selu/agent-coordination-skills.git ~/src/agent-coordination-skills
SKILLS="herdr-agents github-backlog chief-of-staff todo-recorder todo-executor"

# 按你用的 harness 挑对应的行：
mkdir -p ~/.claude/skills && for s in $SKILLS; do ln -s ~/src/agent-coordination-skills/$s ~/.claude/skills/$s; done          # Claude Code
mkdir -p ~/.agents/skills && for s in $SKILLS; do ln -s ~/src/agent-coordination-skills/$s ~/.agents/skills/$s; done          # 只用 OpenCode
mkdir -p ~/.gemini/config/skills && for s in $SKILLS; do ln -s ~/src/agent-coordination-skills/$s ~/.gemini/config/skills/$s; done  # agy

~/src/agent-coordination-skills/herdr-agents/scripts/check-env.sh   # 核版本，并列出各处装没装
```

- 只用 Claude Code：只跑 Claude Code 那行。
- Claude Code **和** OpenCode 都用：只跑 Claude Code 那行。OpenCode 也会扫 `~/.claude/skills/`，再往 `~/.agents/skills/` 链一份，它会把每个技能列两遍。
- 只用 OpenCode：跑 OpenCode 那行（跑 Claude Code 那行也行，两个目录它都扫）。
- agy：另加 agy 那行；它不扫上面两个目录。

**为什么要分几处**：各 harness 从哪里找用户级技能不一样（2026-09-28 实测，细节与推翻条件见 `herdr-agents` §8）：

| harness | 用户级技能目录 | 备注 |
|---|---|---|
| Claude Code | `~/.claude/skills/` | 让 `~/.claude/skills` 指向 `~/.agents/skills`，或在其下再建软链 |
| OpenCode 1.18.32 | `~/.agents/skills/` 与 `~/.claude/skills/` 都扫 | `opencode debug skill` 可查 |
| agy 1.2.12 | `~/.gemini/config/skills/`（软链也行）；**不扫 `~/.agents/skills/`** | 在空目录里让 agy 列一次技能可复核 |

Claude Code、OpenCode 对 `~/.agents/skills/<名> -> <别处>` 这种软链形状没测过。装完跑一次 `check-env.sh`，再用上表的方法
各看一眼。

官方 `herdr` 技能要另外装：`herdr-agents` 只写它没写的东西。从哪里拿见[依赖](#依赖)。

## 许可证

MIT，见 [`LICENSE`](LICENSE)。
