**English** | [简体中文](README.zh-CN.md)

# Agent coordination skills

Five skills for running **one coordinating agent that directs several coding agents working in parallel**.
Every claim about how a tool or environment behaves records how it was measured and which observation would
overturn it. Decisions the user made are stated as decisions.

| Skill | What it covers | Depends on | Standalone? |
|---|---|---|---|
| [`herdr-agents`](herdr-agents/SKILL.md) | Driving agents through herdr: start, confirm ready, deliver an instruction exactly once, read back, interrupt, pass messages between agents, tell alive / stuck / finished / restarted apart, wrap up | herdr (and the official `herdr` skill) | Yes |
| [`github-backlog`](github-backlog/SKILL.md) | Managing work in GitHub Issues: pick tasks, claim them, labels, PR conventions, acceptance | `gh` | Yes |
| [`dispatch`](dispatch/SKILL.md) | The coordinator: group work by code footprint to avoid collisions, recommend groups for the user to pick, launch workers, patrol | **`herdr-agents`** (required); a task system is optional | Needs `herdr-agents` |
| [`todo-recorder`](todo-recorder/SKILL.md) | Record-only: the user states requirements, you write them to `TODO.md` at the repo root (or to an issue when explicitly asked). Never implements | None | Yes |
| [`todo-executor`](todo-executor/SKILL.md) | Execute: scan `TODO.md`, pick items, implement, tick them off, commit, loop until none are left | None | Yes |

`dispatch`'s rules know nothing about GitHub. They state the questions a "workflow" must answer (what work exists,
how to claim it, how to hand it in, which branch a task maps to). With no workflow configured it falls back to
a list the user gives in conversation. To manage work on GitHub, use `dispatch` + `github-backlog` together;
[`for-dispatch.md`](github-backlog/for-dispatch.md) in the latter maps one onto the other.
Two of `dispatch`'s scripts do touch GitHub, and say so: `closeout.sh` calls `github-backlog`'s `close-merged.sh`
(so it needs `gh` and the `github-backlog` skill installed next to it), and `scan-workers.sh` watches open PRs with
`gh` (turn that off with `WATCH_PRS=0`).

`todo-recorder` / `todo-executor` are a much lighter `TODO.md`-based flow than `dispatch` + `github-backlog`:
no issue claiming, no collision grouping, just "write it down" and "do them one by one". They can be combined with
`github-backlog` (`todo-recorder` can route entries to issues when explicitly asked) or used entirely on their own.

> **Language note:** `herdr-agents` and `dispatch` are currently written in Chinese; `github-backlog`,
> `todo-recorder` and `todo-executor` are in English (with a few Chinese trigger phrases). Agents read either
> fine, and translations of the Chinese skills are welcome.

## Scripts

| Script | Belongs to | What it does | Writes anything? |
|---|---|---|---|
| `herdr-agents/scripts/check-env.sh` | herdr-agents | Compares local herdr / claude / agy / opencode versions with the versions the skills were measured against; reports whether the five skills are installed under `~/.agents/skills/` and `~/.gemini/config/skills/` | No |
| `herdr-agents/scripts/launch.sh` | herdr-agents | Start a claude agent in a new worktree: wait until ready (answers the trust dialog), send one instruction, count deliveries (`DRY_RUN=1` prints only) | Creates a worktree, workspace and agent |
| `herdr-agents/scripts/count-delivered.sh` | herdr-agents | Count how many times an instruction reached a claude agent's transcript | No |
| `herdr-agents/scripts/deliver-when-idle.sh` | herdr-agents | Send a message once the agent is idle and its input box is empty | Sends the message |
| `herdr-agents/scripts/retire.sh` | herdr-agents | Wrap up: `exit` (send `/exit`, wait until the agent is gone), `remove` (remove the worktree, close its workspace) | Removes the worktree, closes the workspace |
| `github-backlog/scripts/bootstrap.sh` | github-backlog | Checks `gh` and the repo; lists missing labels and creates them only after confirmation (`--check` lists only) | Creates labels after confirmation |
| `github-backlog/scripts/claim-issue.sh` | github-backlog | Claim an issue, read-only check (`--check`), `--self-test` | Writes the issue when claiming |
| `github-backlog/scripts/close-merged.sh` | github-backlog | After merge: verify the PR landed, move its Issue `In review` → `Done` (`--check` verifies only) | Changes Issue labels |
| `dispatch/scripts/scan-collisions.sh` | dispatch | Scans for migration / ADR number collisions across branches (`MIGRATION_DIR` and/or `ADR_DIR` required; `--prs` uses `gh`) | No |
| `dispatch/scripts/test-scan-collisions.sh` | dispatch | Builds each collision case in a temporary repo and checks `scan-collisions.sh`'s output and exit code | Only in a temp dir |
| `dispatch/scripts/scan-workers.sh` | dispatch | Patrol event stream for the Monitor tool: agents, PRs (`gh`), main moving, collisions, heartbeat | No (only `git fetch`) |
| `dispatch/scripts/closeout.sh` | dispatch | After a PR merges, runs the cleanup in order: `close-merged.sh` → `retire.sh exit` → the project's `DROP_DB_CMD` → `retire.sh remove` → delete the local branch | Yes — labels, worktree, workspace, branch, and whatever `DROP_DB_CMD` does |

`/dispatch bootstrap` runs `check-env.sh`, then the bootstrap of the workflow you configured (for GitHub, `bootstrap.sh`).

## Install (user level)

```bash
git clone https://github.com/Xyz9Selu/agent-coordination-skills.git ~/src/agent-coordination-skills
mkdir -p ~/.agents/skills ~/.gemini/config/skills
for s in herdr-agents github-backlog dispatch todo-recorder todo-executor; do
  ln -s ~/src/agent-coordination-skills/$s ~/.agents/skills/$s          # Claude Code, OpenCode
  ln -s ~/src/agent-coordination-skills/$s ~/.gemini/config/skills/$s   # agy
done
~/.agents/skills/herdr-agents/scripts/check-env.sh              # check versions, and which of the two locations have the skills
```

**Why two locations**: each harness looks for user-level skills in a different place (measured 2026-09-28; details and
what would overturn it are in `herdr-agents` §8):

| Harness | User-level skills directory | Notes |
|---|---|---|
| Claude Code | `~/.claude/skills/` | Point `~/.claude/skills` at `~/.agents/skills`, or add symlinks under it |
| OpenCode 1.18.32 | scans both `~/.agents/skills/` and `~/.claude/skills/` | `opencode debug skill` shows what it found |
| agy 1.2.12 | `~/.gemini/config/skills/` (symlinks work); **does not scan `~/.agents/skills/`** | Ask agy to list its skills once in an empty directory to double-check |

Claude Code and OpenCode have not been tested with the `~/.agents/skills/<name> -> <elsewhere>` symlink shape. After
installing, run `check-env.sh` once and check each harness using the table above.

The official `herdr` skill must be installed separately: `herdr-agents` only documents what it leaves out.

## License

MIT, see [`LICENSE`](LICENSE).
