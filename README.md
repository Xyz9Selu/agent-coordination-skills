**English** | [简体中文](README.zh-CN.md)

# Agent coordination skills

Five skills for running **one coordinating agent that directs several coding agents working in parallel**.
Every rule records how it was measured and which observation would overturn it.

| Skill | What it covers | Depends on | Standalone? |
|---|---|---|---|
| [`herdr-agents`](herdr-agents/SKILL.md) | Driving agents through herdr: start, confirm ready, deliver an instruction exactly once, read back, interrupt, pass messages between agents, tell alive / stuck / finished / restarted apart, wrap up | herdr (and the official `herdr` skill) | Yes |
| [`github-backlog`](github-backlog/SKILL.md) | Managing work in GitHub Issues: pick tasks, claim them, labels, PR conventions, acceptance | `gh` | Yes |
| [`dispatch`](dispatch/SKILL.md) | The coordinator: group work by code footprint to avoid collisions, recommend groups for the user to pick, launch workers, patrol | **`herdr-agents`** (required); a task system is optional | Needs `herdr-agents` |
| [`todo-recorder`](todo-recorder/SKILL.md) | Record-only: the user states requirements, you write them to `TODO.md` at the repo root (or to an issue when explicitly asked). Never implements | None | Yes |
| [`todo-executor`](todo-executor/SKILL.md) | Execute: scan `TODO.md`, pick items, implement, tick them off, commit, loop until none are left | None | Yes |

`dispatch` knows nothing about GitHub. It states the questions it needs a "workflow" to answer (what work exists,
how to claim it, how to hand it in, which branch a task maps to). With no workflow configured it falls back to
a list the user gives in conversation. To manage work on GitHub, use `dispatch` + `github-backlog` together;
[`for-dispatch.md`](github-backlog/for-dispatch.md) in the latter maps one onto the other.

`todo-recorder` / `todo-executor` are a much lighter `TODO.md`-based flow than `dispatch` + `github-backlog`:
no issue claiming, no collision grouping, just "write it down" and "do them one by one". They can be combined with
`github-backlog` (`todo-recorder` can route entries to issues when explicitly asked) or used entirely on their own.

> **Language note:** `herdr-agents` and `dispatch` are currently written in Chinese; `github-backlog`,
> `todo-recorder` and `todo-executor` are in English (with a few Chinese trigger phrases). Agents read either
> fine, and translations of the Chinese skills are welcome.

## Scripts

| Script | Belongs to | What it does | Writes anything? |
|---|---|---|---|
| `herdr-agents/scripts/check-env.sh` | herdr-agents | Compares local herdr / claude / agy / opencode versions with the versions the skills were measured against; reports whether the skills are installed under `~/.agents/skills/` and `~/.gemini/config/skills/` | No |
| `github-backlog/scripts/bootstrap.sh` | github-backlog | Checks `gh` and the repo; lists missing labels and creates them only after confirmation (`--check` lists only) | Creates labels after confirmation |
| `github-backlog/scripts/claim-issue.sh` | github-backlog | Claim an issue, read-only check (`--check`), `--self-test` | Writes the issue when claiming |
| `dispatch/scripts/scan-collisions.sh` | dispatch | Scans for migration / ADR number collisions across branches (`MIGRATION_DIR` and `ADR_DIR` are required) | No |

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

The observation behind the agy row: a probe skill placed at `~/.gemini/config/skills/<name>/SKILL.md` showed up when
agy was asked (with tools explicitly forbidden) to list its skills in an empty directory; replacing it with a symlink to
elsewhere still showed up; the same probe in `~/.agents/skills/` did not. **What would overturn it**: agy changes its
global skills directory or starts scanning `~/.agents/skills/` — then linking `~/.agents/skills/` alone is enough.

Claude Code and OpenCode have not been tested with the `~/.agents/skills/<name> -> <elsewhere>` symlink shape. After
installing, run `check-env.sh` once and check each harness using the table above.

The official `herdr` skill must be installed separately: `herdr-agents` only documents what it leaves out.

## License

MIT, see [`LICENSE`](LICENSE).
