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
mkdir -p ~/.agents/skills ~/.gemini/config/skills
for s in herdr-agents github-backlog chief-of-staff todo-recorder todo-executor; do
  ln -s ~/src/agent-coordination-skills/$s ~/.agents/skills/$s          # Claude Code、OpenCode
  ln -s ~/src/agent-coordination-skills/$s ~/.gemini/config/skills/$s   # agy
done
~/.agents/skills/herdr-agents/scripts/check-env.sh              # 核版本，并列出两处各装没装
```

**为什么要链两处**：各 harness 从哪里找用户级技能不一样（2026-09-28 实测，细节与推翻条件见 `herdr-agents` §8）：

| harness | 用户级技能目录 | 备注 |
|---|---|---|
| Claude Code | `~/.claude/skills/` | 让 `~/.claude/skills` 指向 `~/.agents/skills`，或在其下再建软链 |
| OpenCode 1.18.32 | `~/.agents/skills/` 与 `~/.claude/skills/` 都扫 | `opencode debug skill` 可查 |
| agy 1.2.12 | `~/.gemini/config/skills/`（软链也行）；**不扫 `~/.agents/skills/`** | 在空目录里让 agy 列一次技能可复核 |

Claude Code、OpenCode 对 `~/.agents/skills/<名> -> <别处>` 这种软链形状没测过。装完跑一次 `check-env.sh`，再用上表的方法
各看一眼。

官方 `herdr` 技能要另外装：`herdr-agents` 只写它没写的东西。

## 许可证

MIT，见 [`LICENSE`](LICENSE)。
