---
name: github-backlog
description: Use when work is tracked in GitHub Issues and needs selecting, claiming, labelling, PR linking, acceptance, releases, or gh CLI coordination — especially when several agent sessions share one backlog. Also when the dispatch skill needs its workflow questions answered on GitHub.
---

# GitHub Backlog

GitHub is operational; repository documents preserve requirements and decisions. Never invent configuration or write external resources silently.

**First time in a repository:** run `scripts/bootstrap.sh` from this skill's directory (installed user-level: `~/.agents/skills/github-backlog/scripts/bootstrap.sh`), from inside the repo. It checks `gh`, login, and the repo, then lists the labels this skill uses that the repo lacks and creates them only after you confirm. `--check` lists without creating. It is a one-time setup, not a pre-flight for every run.

Scripts below are written as `claim-issue.sh`; the installed path is `~/.agents/skills/github-backlog/scripts/claim-issue.sh` (or wherever you installed this skill). Run them from inside the repository's worktree.

The human who accepts work before merge is called **the maintainer** below.

## Route The Work

If you have these skills installed:

- Feedback/bugs: `triage`; QA: `qa`.
- Design/planning: `brainstorming`, then `writing-plans`; approved plans to Issues: `to-issues`.
- GitHub sync: this skill.
- Running several worker agents against this backlog: the `dispatch` skill, with this one as its workflow — see [Answering the dispatch skill](#answering-the-dispatch-skill).

## Read Before Write

Identify repo before every write:

```bash
gh auth status
gh repo view --json nameWithOwner,hasIssuesEnabled,url,defaultBranchRef
```

For Project work, verify owner, Project, fields, options, and item before selecting IDs:

```bash
gh project list --owner <owner> --limit 100
gh project field-list <project-number> --owner <owner>
gh project item-list <project-number> --owner <owner> --limit 100
```

Read requirement/spec/plan/Issue/PR links; a matching title is not identity.

If `gh`, authentication, or a scope is missing, explain it and offer the exact setup command. Projects require:

```bash
gh auth refresh -s project
```

Do not run interactive authentication, expand token scopes, enable Issues, or change repository governance without the user's approval.

## The Axes

Every Issue carries at most one value on each of six independent axes. Never encode one axis in another's field — that is what makes parallel agents collide.

| Axis | Question | Where it lives |
|---|---|---|
| **Ownership** | Who is working on it right now? | The **`claim:` comment** (assignee is only a filter hint) |
| **Lifecycle** | How far along is it? | Status **label** (`In progress` / `In review` / `Done`) |
| **Type** | What kind of work is it? | Type **label** (`bug` / `enhancement` / `documentation`) |
| **Priority** | How urgent is it? | Priority **label** (`priority: high` / `priority: medium` / `priority: low`) |
| **Grouping** | What does it belong with? | **Parent Issue** (sub-issue link) |
| **Exception** | Why is it not moving, or not happening? | Exception **label** (`blocked` / `deferred` / `duplicate` / `wontfix`) |

Ownership is deliberately NOT a label. Labels are a shared many-to-many vocabulary; ownership is a single holder. Putting ownership in a label is what causes duplicate selection.

Ownership is also not the **assignee**, even though the assignee is where you look first. When every session authenticates as the same GitHub account, `gh issue edit <N> --add-assignee @me` on an Issue another session already holds **exits 0 with no diff and no warning**. The write cannot fail, and the assignee it produces cannot tell one session from another. So the assignee answers only *is anyone on this?* — a cheap filter, and the reason step 1's query works at all. The `claim:` comment is the only place that answers *which session, since when, and is it still alive?*, which is why steps 2–3 require it and why its fields are fixed rather than free text.

There is deliberately **no release-line axis**. An Issue does not carry the version it is planned for; only the exception — an Issue pushed out of the current cycle — is marked, with `deferred`. The consequence is intended: "what ships in 1.1.0" is not a label query. The repository's own release files (for example `VERSION` and `CHANGELOG.md`) are the release record.

## Source And State

Requirements live in GitHub Issues. Lifecycle status is one label per Issue:

`Backlog` → `In progress` → `In review` → `Done`

- **`Backlog`** — initial state. Represented by **no status label**; there is no `Backlog` label.
- **`In progress`** — an agent has claimed the Issue and is working it (see Selecting Work).
- **`In review`** — implementation done and a PR is open, awaiting the maintainer's pre-merge acceptance. The assignee stays.
- **`Done`** — set only after the maintainer's acceptance; accepted PRs merge and close their Issues.

Status is reversible: a grill that ends unclear rolls back to `Backlog`, and the claim is released. After merge, new findings use linked bug/follow-up Issues; do not reopen completed work.

Exception markers are a separate axis — see [Exception Markers](#exception-markers). An Issue can be `blocked` while `In progress`; the exception never replaces the lifecycle status.

Status transitions are agent-maintained (see Write Boundaries): `Backlog`/`In progress`/`In review` transitions require no preflight; `Done` requires the maintainer's acceptance first.

Link Issues to documents; do not advance Markdown from an Issue or PR.

## Selecting Work

**Multiple agent sessions may run in parallel against one backlog.** Selecting an Issue another session already holds wastes a session and produces conflicting branches. Selection is therefore a protocol, not a judgement call.

### 1. Select — this is the only permitted selection query

```bash
gh issue list --state open --limit 100 \
  --search 'no:assignee -label:"In progress" -label:"In review" -label:deferred -label:blocked' \
  --json number,title,labels,subIssuesSummary \
  --jq '[.[] | select(.subIssuesSummary.total == 0)]'
```

Never select from an unfiltered `gh issue list`. Anything this query omits is held by another agent, parked by an exception, or a tracking container — none of it is available, however suitable it looks.

Claim granularity is the **atomic Issue**. The `subIssuesSummary.total == 0` filter drops parent Issues from the candidate set: a parent is a tracking container, and claiming one would lock its whole batch. Claim the sub-Issues you will actually work.

The two exception labels are excluded for the same reason as the status labels — the work is not available — but the mechanism differs, and it is worth knowing which:

- **`In progress` / `In review`** are held by an agent, so `no:assignee` would usually catch them anyway. The labels are belt-and-braces.
- **`deferred` / `blocked`** are *not* held by anyone. `deferred` explicitly releases its claim, and a `blocked` Issue may never have had one. Without these two clauses they pass `no:assignee` cleanly and read as free work — which is exactly backwards: a `deferred` Issue was pushed out of the cycle on purpose, and a `blocked` Issue is waiting on something the picker cannot supply.
- **`duplicate` / `wontfix`** need no clause; they close the Issue, and `--state open` already drops it.

### 1b. Finding the parked work again

Excluding an Issue from selection is how it gets left alone; it is also how it gets forgotten. A `blocked` label whose blocker cleared months ago is indistinguishable from live work that nobody may touch. So the exclusion comes with an obligation to look:

```bash
gh issue list --state open --limit 100 --label blocked \
  --json number,title,labels,comments \
  --jq '.[] | {number, title, reason: [.comments[].body | select(startswith("blocked:"))] | last}'
gh issue list --state open --limit 100 --label deferred \
  --json number,title --jq '.[] | "#\(.number) \(.title)"'
```

Read the reason comment, not the label — the label only says *that* something is parked. **The moment a blocker clears, remove `blocked` (and say so in a comment); that is what puts the Issue back in the candidate set.** Same for `deferred` when it is pulled back into a cycle. Leaving the label on after the reason expires re-creates the permanent-invisibility failure that unreleased claims cause.

Do not clear someone else's exception to make an Issue selectable for yourself. If you believe a `blocked` reason has expired, say so in a comment and let the reason's author or the maintainer clear it — the same courtesy the stale-claim rule extends to claims.

### 2. Claim — immediately, for every Issue selected

Do this before any planning, grilling, or branch work, and do it for the whole set you intend to work — not only the first one.

**The selection query is not the only way an Issue number reaches you.** Numbers also arrive in a user prompt, out of a grilling or triage discussion, as a reference inside another Issue, or in a peer's message. Every one of those paths skips step 1 — and step 1 is where the protocol's only interlock lives. So the rule is not "claim what you selected". It is:

> **Claim before you read the first file.** Whatever the source of the number, steps 2 and 3 come before any research, planning, grilling, or branch.

An Issue you are merely *thinking about* is invisible to every other session: it has no assignee, no label, no `claim:` comment. Reading code for forty minutes before claiming is how two sessions independently design the same fix.

**A forked session is the sharpest case of this**, and forking is routine in multi-agent work. A fork inherits its parent's whole context — including the Issue numbers the parent was weighing — and it never runs step 1, so it is structurally invisible to any protocol whose entry point is the selection query. Two rules follow. If the fork is doing the work, the claim is the fork's to post, with the fork's own `sid`/`pid`/`sock` (a claim naming a session that is not the one writing code is worse than no claim: it points peers at the wrong place to negotiate). And if the parent already holds the Issue, the fork posts a `claim:` comment of its own noting it supersedes the parent's — the holder must be the session a peer can actually reach.

One command does the whole claim — preflight, both writes, and the step-3 verify — for the whole set:

```bash
claim-issue.sh 148 153          # claim a set in one call
claim-issue.sh --check 148      # read-only: holder, liveness, stale grounds
claim-issue.sh --dry-run 148    # show the comment, write nothing
claim-issue.sh --self-test      # check the liveness table on this box
```

**Read its output.** It refuses to claim an Issue whose holder it can prove is alive, and it prints `⚠ N unreleased claims` when step 3 catches a race. Neither is advisory.

The claim's fields are **fixed**, because a peer has to act on them mechanically, and assembling six coordinates by hand produces a different claim every time — the board this protocol was written on already showed one claim naming a worktree that did not exist and another naming a branch that did not exist. The script is a convenience for that, not a necessity: the fallback further down works, and you should use it when you cannot run the script. What the script buys is `--self-test`, `--check`, uniform output, and no quoting traps around `·`.

Two quirks of a Claude Code worktree-isolated session's Bash are worth knowing before you hand-roll anything, because each one refuses a shape that looks obviously fine (measured 2026-08-25, one shape per call):

| Command | Result |
|---|---|
| `echo "claim: $(git branch --show-current)"` | passes |
| `echo "$(hostname)"` | **refused** |
| `echo "home is $HOME"` | passes |
| `echo "pid $CLAUDE_PID"` | **refused** |
| `echo "pid $(printenv CLAUDE_PID)"` | passes |

1. An argument that is *entirely* a command substitution is refused; the same substitution embedded in literal text passes. So **`git` is not a trigger** and substitution is not the problem — a bare `$(...)` argument is.
2. **`$CLAUDE_*` expansion** is refused even inside literal text (while `$HOME` passes). Reach those values with `$(printenv VAR)` instead, which is a command and so falls under rule 1.

(Five successive explanations of this wall were written down that day and were wrong — see the header comment of `claim-issue.sh`. Only the two above survived measurement. Before writing "cannot" into a doc other agents copy from, try one equivalent form.)

What the script writes, and the contract any hand-written claim must still meet:

```
claim: <branch> · <UTC ISO8601>
  worktree: <a path a peer can resolve, or "none">
  host: <hostname>  sid: <session id, first 8>  pid: <process id>
  sock: <messaging socket path, or "none">
```

`worktree:` takes either form — the script emits it relative to the repo root, the fallback below emits it absolute. Both resolve; what matters is that it names a directory that exists.

`host:` is not decoration. A socket path is meaningful only on the machine that created it, so without a hostname a claim from another machine is indistinguishable from a claim whose session has died — and the safe-looking reading is the dangerous one. See step 3.

`sock:` is what makes a claim **verifiable**. It names a socket that exists only while that session is alive, so any peer can ask "is the holder still there?" without guessing from timestamps (steps 3 and 5). If your harness does not export a messaging socket — OpenCode, Codex, Cursor, agy, plain CI — write `sock: none` honestly. A claim with `sock: none` is still a valid claim; it just cannot be liveness-checked, so only the commit-age rule in step 5 applies to it. **Never invent a socket path.** A path that resolves to nothing reads as a dead session and invites a reclaim of live work.

**Without the script** — another machine, a fresh clone, a harness that cannot run it — all six fields fit in one plain command, and this runs inside a Claude Code worktree-isolated session (verified 2026-08-25):

```bash
echo "claim: $(git branch --show-current) · $(date -u +%Y-%m-%dT%H:%M:%SZ) worktree: $(git rev-parse --show-toplevel) host: $(hostname) sid: $(printenv CLAUDE_CODE_SESSION_ID) pid: $(printenv CLAUDE_PID) sock: $(printenv CLAUDE_CODE_MESSAGING_SOCKET)"
```

Pipe it to a file, or paste the output into `gh issue comment <N> --body-file <path>`. All six fields on one line parse the same as the four-line form — `claim-issue.sh --self-test` covers that shape on purpose, so the fallback is not a trap. Two things to get right: use `--show-toplevel`, **not** `--show-prefix` (which is empty at a worktree root and silently yields `worktree: .`), and never `--body` with an inline multi-line string.

### 2b. Editing an Issue you do not hold

Rewriting an Issue's body, title, or labels — triage, a count correction, a `deferred` marker — is a **third class of action**, neither selection nor implementation, and the claim rule does not stretch to cover it in either direction:

- Requiring a claim would mean claiming 49 Issues to run one triage sweep. That locks the entire board to do read-mostly work. Not acceptable.
- Requiring nothing lets two sessions rewrite the same body an hour apart with no coordination. That has already happened: one Issue's body was rewritten by one session, then rewritten again by another after a related PR merged (which also corrected an error in the first rewrite). Neither knew of the other.

So triage editing needs **no claim**, and instead carries two obligations:

1. **Read the last `claim:` comment before you edit.** Not the body — the comment. This is the same read as step 3 and costs one call.
2. **If the Issue is held, leave a comment addressed to the holder after you edit**, saying what you changed and why it matters to the work in flight. A silent edit to an Issue somebody is implementing right now is a spec change delivered by no one.

Editing a *held* Issue is legitimate and often urgent — a wrong count or a superseded scope is worse left standing. What is not legitimate is making that edit invisible to the session building from it.

### 3. Verify — re-read after writing

GitHub offers no compare-and-swap, and the assignee write cannot fail (see *The Axes*), so **step 3 is the only place a collision ever surfaces**. Two sessions can both pass step 1 in the same minute and both succeed at step 2. Skipping this step is not "saving a call" — it is choosing not to find out.

```bash
gh issue view <N> --json assignees,comments \
  --jq '[.comments[].body | select(startswith("claim:") or startswith("release:") or startswith("reclaim:"))]'
```

If more than one unreleased `claim:` comment exists, **the earliest timestamp wins**. The loser releases and re-selects. No negotiation, no waiting.

"Unreleased" means **posted after the last `release:` or `reclaim:`** — both end every claim before them (step 5 posts the reclaim before the new claim). Counting every `claim:` in the history instead turns any claim → release → claim into a phantom race; `claim-issue.sh` did exactly that until 2026-09-30 and stopped two workers holding sole claims. Its `--self-test` now covers these sequences — if you change the reclaim protocol, change `OPEN_CLAIMS_JQ` with it.

Before concluding you are the earliest, check the earlier holder's liveness:

```bash
claim-issue.sh --check <N>     # read-only; writes nothing
```

**The check is deliberately asymmetric — it can prove life, but it can barely prove death:**

| Reading | Conclusion |
|---|---|
| socket exists | **Alive.** It is theirs. Stop. This is the fast, reliable direction. |
| `sock: none` | **Unknown.** The holder's harness had no socket to report. |
| `host:` ≠ this machine | **Unknown.** The path is meaningless here — it would fail `ls` even with the holder happily writing code on the other machine. |
| `host:` matches, socket absent | **Probably dead.** The only reading that may escalate — go to step 5. |

Never invert the first row into a death test. A socket path from another host, or from before a reboot, is *absent for reasons that have nothing to do with the holder*, and "absent ⇒ free to take" would hand you live work with the protocol's blessing. When the reading is **Unknown**, the commit-age rule in step 5 is the only authority — it depends on no runtime state and holds across machines.

The one false positive that remains is PID reuse: socket filenames are process ids, so a dead session's path can be reoccupied by an unrelated process and read as "alive". That direction is safe — it makes you too cautious, never too bold — so it needs no handling beyond knowing it exists.

Reading the last `claim:` comment has a second payoff worth naming, because it is what actually went wrong once on the board this was written for: **the holder's progress lives in the comments, not the body.** PR links, scope corrections, and "already done, see #…" all land there. A session that reads only the Issue body can find a fully-claimed, fully-labelled Issue and still redo work that shipped an hour ago.

When the holder *is* alive and you still believe the work should be yours, that is a conversation, not a reclaim. Message the session at its `sock:` (Claude Code: `SendMessage` to the peer from `ListAgents`); if your harness cannot message peers, say what you want in an Issue comment and leave the claim alone. Taking live work is never correct — the whole cost of a duplicate is paid before anyone notices.

### 4. Release — required whenever you stop

An Issue you hold but abandon is locked forever. Release is not optional.

```bash
gh issue edit <N> --remove-assignee @me --remove-label "In progress"
gh issue comment <N> --body 'release: <reason>'
```

Release when: you drop the Issue, the grill ends unclear, the scope moves elsewhere, or you end a session without opening a PR. A merged PR needs no release — `Closes #N` closes the Issue.

### 5. Reclaim stale holds

A claim is stale on either of two independent grounds:

1. **Its session is gone** — `host:` matches this machine **and** the `sock:` path no longer exists. Both halves are required; step 3's table says why an absent socket on its own means nothing. This ground is immediate: a session that has exited is not coming back to the work.
2. **Its branch has gone quiet** — no commit in **2 days**, or the branch no longer exists. This is the only ground available whenever ground 1 reads *Unknown* (`sock: none`, or a claim from another machine), and it is the authority that holds everywhere.

One command reports both grounds, and the unmerged work the next paragraph is about:

```bash
claim-issue.sh --check <N>
```

**A dead session does not mean no work was done.** Ground 1 fires in minutes, not days, so it will regularly catch sessions that finished real work and exited — an unmerged branch, an open PR, a green suite nobody merged. `--check` prints the unmerged commits and any PR for the claimed branch for exactly this reason.

If there are commits or a PR, the Issue is not free work — it is finished-or-partial work that needs picking up, and the reclaim comment must say so and point at what exists. Reclaiming it as if from scratch throws that away silently. The shape to recognise: an Issue that is CLOSED and `Done`, with its worktree, branch, and exited session all still on disk.

Post the reclaim before claiming, naming the ground you used:

```bash
gh issue comment <N> --body 'reclaim: superseding claim of <original timestamp> — session <sid> gone (socket absent, N peers still live); branch <branch> has <k> unmerged commits / no commits'
```

Never reclaim without posting this comment first.

## An Issue States The Pain, Not The Cure

Write the Issue as the **observed problem** — what is wrong, who it hurts, and how you know. Put candidate approaches in a clearly-marked section below, as candidates. Do not make a solution the title or the ask.

The reason is not style. **A solution outlives its own validity; the pain outlives the solution.** A decision landed a week later can forbid the approach an Issue prescribes while leaving every symptom it reported fully intact — and then the Issue is unactionable as written, even though the problem is real and unfixed.

A real case: an Issue titled *"auto-create the local application when the external system syncs an overtime or leave record"* was filed roughly four hours *after* an accepted decision record said the sync signal «only updates an existing, matching local application to `approved` — **it never auto-creates one**». So:

- Implementing the Issue as titled violates an accepted decision.
- Closing it as `wontfix` reads as "we do not care" — but the pain is real: the external system holds a record, the local system does not, and the employee cannot see their own leave in this system.
- Neither option is right, and the Issue sat unactionable. Had it been titled *"overtime/leave that exists externally but not locally is invisible to the employee"*, the decision would have **narrowed** it (auto-create is out; a read-only external record, or a better notification to the administrator, is in) instead of **invalidating** it.

So, when writing:

- **Title and body**: the symptom, its impact, and the evidence (a reproduction, a query, a file:line). A `bug` also needs its *found version*.
- **Approaches**: a separate section, marked as candidates, with the trade-offs. Say plainly which decisions constrain them.
- **Unknowns**: an `Open questions` section. An unanswered question is information; a guess dressed as a requirement is not.

And when triaging an existing Issue whose title is a solution that a decision has since forbidden: **rewrite it to the pain, do not close it** — unless the pain itself is gone. Closing it loses the only record that the problem exists. Note the rewrite in a comment so the original framing stays auditable.

## Type

Every Issue carries exactly one type label. This is the coarsest axis and the most used — set it at creation.

- **`bug`** — existing behavior is wrong. Needs a *found version* (below) and, where possible, a reproduction.
- **`enhancement`** — new behavior, or an improvement to correct behavior.
- **`documentation`** — docs, ADRs, agent instructions. No code change.

`duplicate`, `wontfix`, `invalid`, `question`, `good first issue`, and `help wanted` are GitHub defaults. Only `duplicate` and `wontfix` are used here, and they are **exception markers**, not types — see below. Do not use the others.

## Priority

Every Issue also carries exactly one priority label, set at creation alongside type.

- **`priority: high`** — urgent; prefer it over other open candidates when claiming.
- **`priority: medium`** — default. Use when nothing marks the Issue as high or low.
- **`priority: low`** — safe to leave in the backlog; claim after higher-priority work is taken.

Priority does not gate the [selection query](#1-select--this-is-the-only-permitted-selection-query) — a `priority: low` Issue is still a valid claim, just not the preferred one when candidates compete. It is not a substitute for `deferred`: pushing an Issue out of the current cycle is an exception, independent of how urgent it would be if worked.

## Exception Markers

An exception says why an Issue is not moving, or not happening. It is orthogonal to lifecycle: an Issue can be `blocked` while `In progress`. **The exception label never replaces the status label.**

A label cannot carry a reason, so every exception marker requires a comment.

| Label | Meaning | Comment | Issue state | In selection? |
|---|---|---|---|---|
| `blocked` | Recoverable pause — waiting on something external | `blocked: <what we are waiting on>` | stays open, keeps its status and assignee | **excluded** |
| `deferred` | Pushed out of the current cycle | `deferred: <reason> → <version, or TBD>` | stays open, claim **released** | **excluded** |
| `duplicate` | Superseded by another Issue | `duplicate of #N` | closed | excluded (closed) |
| `wontfix` | Rejected — not applicable, or will not be actioned | `wontfix: <reason>` | closed | excluded (closed) |

Both open exceptions are excluded from the selection query (see [Selecting Work](#1-select--this-is-the-only-permitted-selection-query)). That makes **removing the label the act that returns an Issue to the candidate set** — the labels are not decoration, they gate availability. Review them with the queries in *Finding the parked work again* rather than waiting to stumble on them.

- Remove `blocked` the moment the blocker clears; a stale `blocked` reads as abandoned.
- `deferred` is the **only** version-related marker. There is no `target/*` axis — an Issue is not tagged with the release it is planned for, only with the fact that it slipped.
- Absorb a genuinely-merged requirement with `duplicate`, never by editing two Issues into one.

## Batches And Versions

- **Found version**: record the version in which the issue was found, at creation time, as a `## Found in` section in the Issue body. Not a label. A bug without a found version is incomplete.
- **Grouping is a parent Issue, never a label.** When planning decomposes one design into several atomic Issues, open a parent Issue titled `[Batch] <topic>` and link the sub-Issues:

  ```bash
  gh issue edit <parent> --add-sub-issue <sub>,<sub>,<sub>
  gh issue list --state open --json number,title,subIssuesSummary
  ```

  The parent owns overall tracking and renders its own completion count; each sub-Issue stays atomic, individually claimable, and individually closed by its own PR. A label description that enumerates Issue numbers goes stale silently — sub-Issue links do not.

- Do not merge multiple Issues into one; absorb a genuinely-merged requirement with `duplicate` instead (see [Exception Markers](#exception-markers)).

## Pull Requests Link Their Issues

When creating a PR that implements an Issue, add `Closes #N` (or `Fixes #N` for bugs) in the PR body referencing the Issue it implements. This makes the Issue auto-close on merge.

- `Closes #N` is valid only after the maintainer's pre-merge acceptance; until then the PR is a draft-style link, not a close signal.
- One PR implements at most one atomic Issue. A parent Issue (batch) is closed when its last sub-Issue merges; the PR closes the sub-Issue, not the parent.

## Write Boundaries

| Operation | Approval needed |
|---|---|
| Read, report, dry-run manifest | No |
| Claim (assignee + `In progress` + `claim:` comment), verify, release, documented stale reclaim | No preflight; automatic |
| Status label transitions `Backlog` / `In progress` / `In review` (one Issue, at the workflow trigger point) | No preflight; automatic |
| Apply or clear `blocked` (with its reason comment) | No preflight; automatic |
| Apply `deferred`, `duplicate`, or `wontfix` (each closes or parks work) | Direct request after preflight |
| Set `Done` (requires the maintainer's acceptance first) | Direct request after preflight |
| One explicit Issue create/comment/verified transition | Direct request after preflight |
| One explicit PR create/comment/review request | Direct request after preflight (body includes `Closes #N` for the Issue it implements) |
| Merge or close a PR | Direct request after base/head, checks/reviews, conflicts, and Issue verification |
| Take an Issue held by another agent without a documented stale reclaim | Not permitted |
| Create or edit a Project, fields, label taxonomy, templates, milestones, rulesets, scopes, or environments | Show the exact change set and obtain confirmation |
| Bulk migration, bulk state transition, release, or source-document replacement | Show a reconciliation manifest and obtain confirmation |

Before a confirmed write, state target, affected objects/files, transition, and rollback/preservation. Re-read and report changed objects.

## Bootstrap And Migration

Bootstrap: inspect, then present Project, fields, labels, templates, migration mapping, duplicate rule, and source policy. After approval, configure/migrate and reconcile; preserve Markdown history unless approved otherwise.

The label part of that is `scripts/bootstrap.sh` (see the top of this skill): it lists the labels this skill uses that are missing and creates them only on confirmation — the label-taxonomy row of *Write Boundaries* applied. Existing labels are left untouched. Projects, templates, and migrations are still done by hand, with the change set shown first.

## Release

Release per the repository's own procedure — for example synchronized `VERSION` files, `CHANGELOG.md`, and a verified annotated tag only on the release commit. A Milestone needs confirmation.

## Acceptance Feedback

The maintainer accepts while the Issue is in `In review` (before merge). Small in-scope changes revise the same PR and repeat acceptance. Material scope/rule changes need a linked follow-up Issue; do not expand the accepted PR. After merge, new findings use linked bug/follow-up Issues; do not reopen completed work.

## Answering The Dispatch Skill

The `dispatch` skill does not know GitHub. It names four questions a workflow must answer (Q1 what work exists, Q2 how it is held, Q3 how it is delivered, Q4 which branch it is on) and two optional ones (QA where coordinator check marks go, QB how a container's completion is read). When you run `dispatch` with this skill as its workflow, **read [`for-dispatch.md`](for-dispatch.md)** — it maps each question to the commands and readings on this page, plus the GitHub-only traps the coordinator hits.

## Common Mistakes

- Selecting from an unfiltered `gh issue list`. Always use the Selecting Work query — an Issue held by another session looks perfectly available otherwise.
- Claiming only the first Issue of a set. Claim every Issue you intend to work, or the rest read as free to everyone else.
- Claiming without the `claim:` comment. An anonymous hold cannot be told apart from a stale one, so other agents will rightly ignore it.
- Reading a successful `--add-assignee @me` as evidence the Issue was free. When every session is the same GitHub account, that command exits 0 whether or not somebody already holds it. It is not a lock and never fails; step 3 is where a collision surfaces.
- Working an Issue whose number came from a prompt, a triage discussion, or another Issue's text — without claiming it, because it never came through the selection query. The query is one entrance among several; the claim is the interlock. Claim before the first file you read.
- Reading only the Issue body. Progress lives in the comments: the PR link, the scope correction, the "already done". A body-only read of a correctly-claimed Issue can still send you off to redo shipped work.
- Reading an absent socket as a dead session. Absent is *Unknown* unless `host:` matches this machine — otherwise you are about to reclaim work whose owner is alive on another box.
- Letting a fork work under its parent's claim. The claim must name the session that is writing the code, or peers negotiate with the wrong session.
- Editing a held Issue's body or title without telling the holder. The edit is often right; delivering a spec change to nobody is not.
- Assigning a parent Issue. Claims belong on atomic sub-Issues; a claimed parent locks the whole batch.
- Encoding ownership in a topic label. A topic label means "belongs with", not "taken" — two agents inside one topic is legitimate.
- Using an exception marker as a status. `blocked` sits *alongside* `In progress`; swapping one for the other loses where the work actually stands.
- Applying an exception label without its comment. The label says something is wrong; only the comment says what, and a reasonless `blocked` is indistinguishable from an abandoned Issue.
- Tagging an Issue with the release it is planned for. There is no `target/*` axis — only `deferred`, and only when it slips.
- Abandoning a claim without releasing. This is how an Issue becomes permanently invisible to selection.
- Leaving `blocked` on after the blocker cleared. Since the selection query excludes it, a stale `blocked` is the same permanent invisibility as an unreleased claim — just with a label to explain it away. Clearing the label is the act that returns the Issue to the candidate set.
- Dropping the `-label:deferred -label:blocked` clauses when re-typing the selection query from memory. Neither of those Issues has an assignee, so without the clauses they sail through `no:assignee` and read as the freest work on the board.
- Making the proposed fix the title. When a later decision forbids that fix, the Issue becomes unimplementable *and* unclosable — the pain is still real, so `wontfix` is wrong too. Title the pain; keep approaches in their own section.
- Closing a solution-titled Issue because its solution is now forbidden. Rewrite it to the pain instead; closing it deletes the only record that the problem exists.
- `Closes #123` is valid only after the maintainer's pre-merge acceptance.
- Status is a label on the Issue, not a Project field. One status label per Issue.
- Setting `Done` on your own; wait for the maintainer's acceptance.
