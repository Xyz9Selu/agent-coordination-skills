# github-backlog history

"See HISTORY #n" in the body points here. Read it only when you need the backstory; it is not loaded day to day. Each entry: title (date), original text or evidence, why, and what would overturn it (if anything).

## #1 · Merged PR = accepted (maintainer's decision, 2026-10-21)

**Was (overturned):** acceptance was a separate step after the merge. That left a merged Issue with no defined moment to become `Done`. "Pull Requests Link Their Issues" correspondingly said `Closes #N` was valid only after a separate pre-merge acceptance; with merge = acceptance, that step no longer exists.

## #2 · Why the claim's fields are fixed

**Evidence:** the board this protocol was written on already showed hand-assembled claims that disagreed: one named a worktree that did not exist, another named a branch that did not exist. Coordinates a peer cannot resolve are worth nothing.

## #3 · Claude Code worktree-session Bash quirks (measured 2026-08-25)

Measured one shape per call; the table in SKILL.md step 2 is the result. The one-line fallback that emits all six claim fields was verified the same day inside a worktree-isolated session.

**Five successive explanations of the wall were written down that day and were wrong:** `git` in a substitution / substitution plus compound flow / substitution refused wholesale / an argument that is entirely a substitution / `$CLAUDE_*` being unreachable. Only two survived measurement: a bare `$(...)` argument is refused while the same substitution inside literal text passes, and `$CLAUDE_*` *expansion* is refused — which `$(printenv VAR)` sidesteps. Lesson: before writing "cannot" into a doc other agents copy from, try one equivalent form.

## #4 · Triage edits with no coordination

**Evidence:** one Issue's body was rewritten by one session, then rewritten again by another after a related PR merged (which also corrected an error in the first rewrite). Neither knew of the other. Requiring a claim instead would have meant claiming 49 Issues for one triage sweep.

## #5 · Counting open claims (fixed 2026-09-30)

**Was (overturned):** "0 if the last marker is a release, else every claim and reclaim ever posted". It never looked for the *last* boundary, so any claim → release → claim read as a race, and a documented reclaim counted the reclaim marker itself as a claim. Observed 2026-09-30: it read as "2 unreleased claims" and stopped two workers whose claims were sole holds.

Related, fixed 2026-09-29: `claim_branch` also matched `reclaim:` lines, and `--check` printed "claimed branch: superseding".

## #6 · Progress lives in the comments

**Evidence:** on the board this was written for, a session read only the Issue body, found a fully-claimed, fully-labelled Issue, and redid work that had shipped an hour earlier.

## #7 · Only the leading prefix is machine-readable (2026-08-31 / 2026-09-28)

**Evidence:** 2026-08-31, a comment intended to both reclaim and release two stale claims (it also cleared the assignee and the `In progress` label) opened with bold Chinese prose instead of a prefix. Every script and session that read the thread afterward still counted both old claims as open, because the reset had no `release:`/`reclaim:` to match. The confusion surfaced 2026-09-28, four weeks later, when a new worker's `claim-issue.sh` run had to sort it out by hand.

## #8 · An Issue states the pain: the real case

An Issue titled *"auto-create the local application when the external system syncs an overtime or leave record"* was filed roughly four hours *after* an accepted decision record said the sync signal «only updates an existing, matching local application to `approved` — **it never auto-creates one**». So:

- Implementing the Issue as titled violates an accepted decision.
- Closing it as `wontfix` reads as "we do not care" — but the pain is real: the external system holds a record, the local system does not, and the employee cannot see their own leave in this system.
- Neither option is right, and the Issue sat unactionable. Had it been titled *"overtime/leave that exists externally but not locally is invisible to the employee"*, the decision would have **narrowed** it (auto-create is out; a read-only external record, or a better notification to the administrator, is in) instead of **invalidating** it.

## #9 · Selection query lags just after a label change (2026-08-26)

**Evidence:** that round released two Issues and immediately ran the selection query; only one came back into the candidate set, while `gh issue view` showed both clean. `gh issue list --search` goes through GitHub's search index, which is eventually consistent; `gh issue view` reads live.

## #10 · Old-format claims read `UNKNOWN` (2026-08-25)

**Evidence:** on the 2026-08-25 board, two Issues carried single-line claims with no `sock:` field; both read `UNKNOWN`. By design, not a fault; it fades as sessions re-claim in the new format.

## #11 · Why `close-merged.sh` lives here (2026-10-21)

Before 2026-10-21 this logic lived inside the dispatch skill's `closeout.sh`, which made the coordinator skill write GitHub labels while its README said it "knows nothing about GitHub". When to set `Done` belongs to this skill, so the command does too.
