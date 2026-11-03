---
name: todo-recorder
description: Use when the user states a requirement, bug, rename, or change and wants it recorded into TODO.md (or an explicitly requested issue) without implementing it.
---

# TODO Recorder

## Overview

Record-only. The user speaks requirements; you write them into `TODO.md`. You never modify product code, never run tests or builds, never commit.

## When to Use

- User says 登记 / 记录 / 记一下 / 更新条目, or states a need ending with an implicit "write it down"
- User corrects or expands an existing TODO entry (rename target, new scope, confirmed spec list)

When NOT to use: user asks to implement, fix, or execute — that is `todo-executor`.

## Procedure

1. **Destination routing**:
   - **默认目标始终是仓库根目录 `TODO.md`**。除非用户明确指令（例如指明"登记到 issue / 建个 issue / 更新 issue #N"），**绝对不要查询或搜索 issue 追踪系统（禁止运行 `gh issue` 等相关命令）**。
   - 仅当用户明确要求登记到 issue 时，才路由到 issue，并遵循（若装了）`github-backlog` 的规则；跳过后续步骤 3–6。
   - 若用户指定了特定文件（非 TODO.md），则写入该文件。
2. **Verify before writing**: 在本地代码库中通过 grep/read 验证涉及的代码并引用真实 `file:line`（禁止去查 issue）。Verify 阶段发现不确定即用 harness 的提问工具（如 Claude Code 的 `AskUserQuestion`）与用户讨论，不带待确认裸写。若讨论后仍有待确认，写入时保留待确认标记，留给 executor 问。
3. **Deduplicate first**: 追加前先在 `TODO.md` 中 grep 是否存在同一主题的未完成条目（`- [ ]`）。**先读状态再动手**：命中同主题条目后必须先读它的 `**状态**` 行——只有 `[ ]` 且无 `In progress` 标记的 pending 条目可以直接原地更新（补充范围、确认值、调整标题），不要新增重复项。若该条目已被其他 session 认领（标记 `In progress`），提示用户并确认是就地更新还是另起条目；若已勾选 `[x]`（无论状态行写什么），绝不重开，一律另起新条目并在问题描述里注明原条目（见步骤 5）。
4. **New entry**: 仅在不存在同主题未完成条目时，追加到 `TODO.md` 末尾（使用最后一个条目的末尾作为唯一 anchor）。条目结构：
   ```markdown
   - [ ] **Title**
     - **问题**: what/where, with `file:line` refs
     - **要求**: numbered, each one bounded action; open points marked 待确认
     - **相关文件**: files touched
   ```
   使用用户的语言记录（用户使用中文则用中文）。
5. **Update entry**: 当用户提出更新/改名且匹配现有未完成条目时，先按步骤 3 确认它是 pending（`[ ]` 且无 `In progress`）再就地修改该条目（标题、范围、确认值），绝不改动其他条目。若该条目已完成（`[x]`），或正被他人执行（`In progress` 且用户未明确选就地），则为新需求追加新条目，不要重新打开已完成项、不要往执行中的条目里加范围。
6. **Verify after writing**: grep 新标题，确保在预期位置且只出现一次。若发生非唯一匹配错误，立即恢复并用更大上下文重新定位。
7. **Reply**: 先用提问工具讨论完待确认，再单行确认记录内容与位置。不改产品代码，未要求时不提交。

## Common Mistakes

- **不看状态行就追加要求**：往 `In progress` 条目里加范围会撞执行中的 session，往 `[x]` 条目里加等于复活已完成项——动手前先读 `**状态**` 行（步骤 3），拿不准就提问。
- **不讨论就带待确认裸写**：Verify 发现不确定必须先用提问工具问，不问直接写待确认是违例；问后仍无结论才保留标记留给 executor。
- **脱靶去查 issue 追踪系统**：用户未明确要求 issue 时，默认就是 `TODO.md`，严禁执行 `gh issue list/view/search` 等等价命令。
- 实现需求而不是记录 — 纯记录是唯一契约。
- 使用非唯一 anchor 追加导致截断或插入无关条目中间 — 必须 grep 校验。
- 新增条目标记为 `[x]` — 新记录永远是 `[ ]`。
