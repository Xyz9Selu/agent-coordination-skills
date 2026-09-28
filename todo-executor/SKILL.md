---
name: todo-executor
description: Use when the user asks to work through the TODO list, picking open items and implementing them one by one until done.
---

# TODO Executor

## Overview

Scan `TODO.md`, pick one item (or a batch affecting the same files), implement it fast, mark it done, commit, re-scan, repeat until no open items remain.

## When to Use

- User says 执行 TODO / 把 TODO 做完 / 从 TODO 挑一批做 / run the TODOs

When NOT to use: user only wants something recorded — that is `todo-recorder`.

## Loop

Repeat until no `- [ ]` entry remains or the user stops you:

1. **Scan**: read the FULL repo-root `TODO.md` from line 1 to end-of-file, every iteration — never a partial/offset read, never a cached earlier read. `TODO.md` is live: open, unclaimed entries may be edited at any time, so only a fresh full read counts. List all open (`- [ ]`) entries. Treat entries carrying another session's `In progress` claim as taken — do not pick them.
2. **Pick**: one entry, or a batch whose code footprints overlap (same page, same feature area). Pick from the LATEST text of the entry as just re-read — never from memory of an earlier scan. 遇到待确认停下，用 harness 的提问工具（如 Claude Code 的 `AskUserQuestion`）逐条问完再继续；执行中发现新待确认也及时提问。只有用户明确 defer/跳过才留到下一轮。
3. **Claim**: immediately mark the picked entry in `TODO.md` before touching code — add `  - **状态**: In progress (<branch/session, UTC time)` as its first sub-bullet. A picked batch claims every entry in the batch. Never start work on an unclaimed entry. The moment you claim it, the entry's spec is FROZEN at the claim-time text: implement exactly that, and ignore any later edits to the claimed entry while you work (someone else editing a claimed entry is their error, not your new spec).
4. **Implement**: minimal diff, quick modification. **No tests**: do not write or run test suites, typecheck, or builds — this is an explicit standing user order that overrides the repo's normal test gates. This is the user's deliberate choice, made precisely so it can override the project's own test policy while this skill is in use; a user who does not want that trade-off should delete this rule from their copy of the skill rather than expect the agent to infer an exception. If an entry's own acceptance text demands a test run, follow the entry over this rule and say so.
5. **Update**: flip the entry `- [ ]` → `- [x]` and set its status line to `Done (<UTC time>)` once the change is in place. If you abandon a claimed entry, remove the `In progress` line so it returns to the pickable pool.
6. **Commit**: one commit per completed entry (or per batch), concise message, including any commit trailer the project requires (e.g. a `Co-Authored-By` line). **Amend shortcut**: if the finished work is a small follow-up patch to the immediately previous commit (same files / same feature — e.g. a column-reorder tweak right after a column-adding commit) AND that commit has not been pushed yet (check `git status -sb`: the branch line shows `ahead`, i.e. local-only commits exist), fold it in with `git commit --amend --no-edit` (message + trailer stay) instead of a new commit. Only ever amend `HEAD`; never amend a pushed commit or one mixing unrelated work. Keep the working tree clean — only intended files staged, never secrets.
7. **Re-scan**: re-read the FULL `TODO.md` again (same rule as step 1 — whole file, fresh read) and go to step 2. The just-completed entry is done; every still-open entry is re-evaluated by its CURRENT text, which may have changed since your last scan.

## Stop Conditions

- No open entries left — report the count completed.
- An entry needs a user decision — 用提问工具问完再继续；用户明确 defer/跳过才留 open 并继续下一个。
- The user interrupts — stop immediately, leave `TODO.md` status accurate.

## Common Mistakes

- **遇到待确认直接跳过不问**：必须用提问工具逐条讨论后才继续；执行中冒出的新待确认同样及时提问，只有用户明确 defer 才留 open。
- Running the test suite "to be safe" — the user explicitly forbids it here; speed is the point
- Marking `[x]` without implementing — status must reflect reality
- Batching unrelated entries into one commit — one entry (or one coherent batch), one commit
- Minting a new commit for a small follow-up fix on top of an unpushed commit — amend into `HEAD` instead (see step 5)
- Refactoring adjacent code along the way — touch only what the entry requires
- Re-scanning with a partial/offset read or trusting an earlier scan — `TODO.md` is live, only a fresh FULL read picks up appended/edited open entries
- Chasing mid-work edits to your own claimed entry — its spec froze at claim time; finish that, the new text becomes a new pick next loop if still open
