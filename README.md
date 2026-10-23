**English** | [简体中文](README.zh-CN.md)

# Agent coordination skills

Five skills for running **one coordinating agent that directs several coding agents working in parallel**.
Every claim about how a tool or environment behaves records how it was measured and which observation would
overturn it. Decisions the user made are stated as decisions.

| Skill | What it covers | Depends on | Standalone? |
|---|---|---|---|
| [`herdr-agents`](herdr-agents/SKILL.md) | Driving agents through herdr: start, confirm ready, deliver an instruction exactly once, read back, interrupt, pass messages between agents, tell alive / stuck / finished / restarted apart, wrap up | herdr (and the official `herdr` skill) | Yes |
| [`github-backlog`](github-backlog/SKILL.md) | Managing work in GitHub Issues: pick tasks, claim them, labels, PR conventions, acceptance | `gh` | Yes |
| [`chief-of-staff`](chief-of-staff/SKILL.md) | The user's chief of staff: survey work, group it by code footprint to avoid collisions, recommend groups for the user to pick, launch workers, patrol, close out, hand off | **`herdr-agents`** (required); a task system is optional | Needs `herdr-agents` |
| [`todo-recorder`](todo-recorder/SKILL.md) | Record-only: the user states requirements, you write them to `TODO.md` at the repo root (or to an issue when explicitly asked). Never implements | None | Yes |
| [`todo-executor`](todo-executor/SKILL.md) | Execute: scan `TODO.md`, pick items, implement, tick them off, commit, loop until none are left | None | Yes |

`chief-of-staff`'s rules know nothing about GitHub. They state the questions a "workflow" must answer (what work exists,
how to claim it, how to hand it in, which branch a task maps to). With no workflow configured it falls back to
a list the user gives in conversation. To manage work on GitHub, use `chief-of-staff` + `github-backlog` together;
[`for-chief-of-staff.md`](github-backlog/for-chief-of-staff.md) in the latter maps one onto the other.
Two of `chief-of-staff`'s scripts do touch GitHub, and say so: `closeout.sh` calls `github-backlog`'s `close-merged.sh`
(so it needs `gh` and the `github-backlog` skill installed next to it), and `scan-workers.sh` watches open PRs with
`gh` (turn that off with `WATCH_PRS=0`).

`todo-recorder` / `todo-executor` are a much lighter `TODO.md`-based flow than `chief-of-staff` + `github-backlog`:
no issue claiming, no collision grouping, just "write it down" and "do them one by one". They can be combined with
`github-backlog` (`todo-recorder` can route entries to issues when explicitly asked) or used entirely on their own.

> **Language note:** `herdr-agents` and `chief-of-staff` are currently written in Chinese; `github-backlog`,
> `todo-recorder` and `todo-executor` are in English (with a few Chinese trigger phrases). Agents read either
> fine, and translations of the Chinese skills are welcome.

## Requirements

- **[herdr](https://herdr.dev)** ([source](https://github.com/herdrdev/herdr)): a terminal workspace manager that keeps
  coding agents running in persistent panes and lets agents drive each other through a CLI. `herdr-agents` and
  `chief-of-staff` are built on it; install it first (see its [install section](https://github.com/herdrdev/herdr#install)).
  Measured against **0.9.5**.
- **The official `herdr` skill**: shipped with herdr itself. If herdr is installed, `herdr --skill` prints the copy that
  matches your binary (save it as `~/.agents/skills/herdr/SKILL.md`), or run `npx skills add herdrdev/herdr --skill herdr -g`;
  see [herdr's agent-skill page](https://herdr.dev/docs/agent-skill/). `herdr-agents` tells the agent to read it first.
- **`gh`** (GitHub CLI), logged in: needed by `github-backlog` and by the PR-watching parts of `chief-of-staff`. Measured
  with **2.95.0**.
- **At least one coding agent CLI** to run as a worker: **Claude Code** (measured with 2.1.306), **OpenCode** (1.18.32),
  or **agy** (1.2.12). `check-env.sh` compares your versions with these; a different version only gets a notice.
- **bash**, on **Linux and WSL2** (where everything was measured). macOS has not been tested; the scripts use `ps`, unix
  sockets and GNU-style tools, so expect differences.

## Quick start

1. Install the requirements above, then the skills (next section).
2. Start herdr, open a pane, and run your agent (e.g. `claude`) inside it, in a git repository you want to work on.
   Skills that drive herdr only work inside a herdr pane (`HERDR_ENV=1`).
3. Say: `/chief-of-staff bootstrap`. It runs `check-env.sh` and the bootstrap of your workflow (for GitHub Issues, it
   lists missing labels and asks before creating them).
4. Say: "Look at what work is open" (or give it a list). It groups tasks so their code does not collide and asks you to pick.
5. Pick a group. It starts workers in separate worktrees, patrols them, and tells you when a PR is ready to review.

For the lighter flow, skip herdr: tell the agent your requirements (`todo-recorder` writes them to `TODO.md`), then say
"work through the TODO list" (`todo-executor`).

## Scripts

| Script | Belongs to | What it does | Writes anything? |
|---|---|---|---|
| `herdr-agents/scripts/check-env.sh` | herdr-agents | Compares local herdr / claude / agy / opencode versions with the versions the skills were measured against; reports whether the five skills are installed under `~/.agents/skills/` and `~/.gemini/config/skills/` | No |
| `herdr-agents/scripts/launch.sh` | herdr-agents | Start a claude agent in a new worktree: wait until ready (answers the trust dialog), send one instruction, count deliveries (`DRY_RUN=1` prints only) | Creates a worktree, workspace and agent |
| `herdr-agents/scripts/count-delivered.sh` | herdr-agents | Count how many times an instruction reached a claude agent's transcript | No |
| `herdr-agents/scripts/deliver-when-idle.sh` | herdr-agents | Send a message once the agent is idle and its input box is empty | Sends the message |
| `herdr-agents/scripts/retire.sh` | herdr-agents | Wrap up: `exit` (send `/exit`, wait until the agent is gone; with `REPO=` it refuses an agent outside that repo), `remove` (remove the worktree, close its workspace) | Removes the worktree, closes the workspace |
| `herdr-agents/scripts/test-scripts.sh` | herdr-agents | Runs `launch.sh`'s name checks and `retire.sh`'s `REPO` guard against a fake herdr | Only in a temp dir |
| `github-backlog/scripts/bootstrap.sh` | github-backlog | Checks `gh` and the repo; lists missing labels and creates them only after confirmation (`--check` lists only) | Creates labels after confirmation |
| `github-backlog/scripts/claim-issue.sh` | github-backlog | Claim an issue, read-only check (`--check`), `--self-test` | Writes the issue when claiming |
| `github-backlog/scripts/close-merged.sh` | github-backlog | After merge: verify the PR landed, move its Issue `In review` → `Done` (`--check` verifies only) | Changes Issue labels |
| `chief-of-staff/scripts/scan-collisions.sh` | chief-of-staff | Scans for migration / ADR number collisions across branches (`MIGRATION_DIR` and/or `ADR_DIR` required; `--prs` uses `gh`) | No |
| `chief-of-staff/scripts/test-scan-collisions.sh` | chief-of-staff | Builds each collision case in a temporary repo and checks `scan-collisions.sh`'s output and exit code | Only in a temp dir |
| `chief-of-staff/scripts/scan-workers.sh` | chief-of-staff | Patrol event stream for the Monitor tool: this project's agents, PRs (`gh`), main moving, collisions, a second chief of staff on the same project, machine load, heartbeat | No (only `git fetch`) |
| `chief-of-staff/scripts/test-scan-workers.sh` | chief-of-staff | Runs `scan-workers.sh` against two temp repos and a fake herdr; checks project filtering, duplicate-chief detection and load events | Only in a temp dir |
| `chief-of-staff/scripts/closeout.sh` | chief-of-staff | After a PR merges, runs the cleanup in order: `close-merged.sh` → `retire.sh exit` → the project's `DROP_DB_CMD` → `retire.sh remove` → delete the local branch | Yes — labels, worktree, workspace, branch, and whatever `DROP_DB_CMD` does |

`/chief-of-staff bootstrap` runs `check-env.sh`, then the bootstrap of the workflow you configured (for GitHub, `bootstrap.sh`).

## Install (user level)

```bash
git clone https://github.com/Xyz9Selu/agent-coordination-skills.git ~/src/agent-coordination-skills
SKILLS="herdr-agents github-backlog chief-of-staff todo-recorder todo-executor"

# Pick the line(s) for the harness(es) you use:
mkdir -p ~/.claude/skills && for s in $SKILLS; do ln -s ~/src/agent-coordination-skills/$s ~/.claude/skills/$s; done          # Claude Code
mkdir -p ~/.agents/skills && for s in $SKILLS; do ln -s ~/src/agent-coordination-skills/$s ~/.agents/skills/$s; done          # OpenCode only
mkdir -p ~/.gemini/config/skills && for s in $SKILLS; do ln -s ~/src/agent-coordination-skills/$s ~/.gemini/config/skills/$s; done  # agy

~/src/agent-coordination-skills/herdr-agents/scripts/check-env.sh   # check versions, and which locations have the skills
```

- Only Claude Code: run only the Claude Code line.
- Claude Code **and** OpenCode: run only the Claude Code line. OpenCode scans `~/.claude/skills/` too, so a second
  link under `~/.agents/skills/` would make it list every skill twice.
- Only OpenCode: run the OpenCode line (or the Claude Code line; both directories are scanned).
- agy: add the agy line; it does not scan the other two.

**Why the locations differ**: each harness looks for user-level skills in a different place (measured 2026-09-28; details and
what would overturn it are in `herdr-agents` §8):

| Harness | User-level skills directory | Notes |
|---|---|---|
| Claude Code | `~/.claude/skills/` | Point `~/.claude/skills` at `~/.agents/skills`, or add symlinks under it |
| OpenCode 1.18.32 | scans both `~/.agents/skills/` and `~/.claude/skills/` | `opencode debug skill` shows what it found |
| agy 1.2.12 | `~/.gemini/config/skills/` (symlinks work); **does not scan `~/.agents/skills/`** | Ask agy to list its skills once in an empty directory to double-check |

Claude Code and OpenCode have not been tested with the `~/.agents/skills/<name> -> <elsewhere>` symlink shape. After
installing, run `check-env.sh` once and check each harness using the table above.

The official `herdr` skill must be installed separately: `herdr-agents` only documents what it leaves out. See
[Requirements](#requirements) for where to get it.

## License

MIT, see [`LICENSE`](LICENSE).
