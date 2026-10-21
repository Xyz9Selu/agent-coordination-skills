#!/usr/bin/env bash
#
# 一个 PR 合并之后的收尾，只编排顺序；每一步由负责它的那一方提供：
#   1 核落地 + Issue 改 Done   github-backlog 的 scripts/close-merged.sh（什么时候算 Done 归它定）
#   2 让 worker /exit           herdr-agents 的 scripts/retire.sh exit（§7「正常收工」）
#   3 删它的数据库              项目给的 DROP_DB_CMD 钩子（库怎么建、怎么删归项目）
#   4 删 worktree、关 workspace herdr-agents 的 scripts/retire.sh remove
#   5 删本地分支
# 任何一步失败都打印出来，不静默跳过。
#
# usage: REPO=<仓库主 checkout> closeout.sh <pr> <issue> <agent-name>
#   agent-name 给 - 表示没有 worker 要叫停（例如它已经退出了）。
# 环境变量：
#   REPO          必填
#   DROP_DB_CMD   可选。以 `$DROP_DB_CMD <branch> <worktree 路径或空>` 调用；worktree 已经不在时第二个参数为空，
#                 钩子要能只凭分支名删掉那个库。不设 = 跳过数据库这一步并说出来。
#   SKILLS_DIR    三份技能所在的目录，默认是本技能目录的上一级（用户级安装时是 ~/.agents/skills）。
#   DEFAULT_REMOTE / DEFAULT_BRANCH / REVIEW_LABEL / DONE_LABEL   原样传给 close-merged.sh。
# 依赖：gh（经 close-merged.sh）、herdr、git。工作流目前只接了 github-backlog；换别的工作流，第 1 步要换成那个
# 工作流提供的「核落地 + 交差」命令。
#
# 为什么这样写：
# · worktree 已经不在、数据库还在时，也按分支名删库 —— 只在找到 worktree 时才删库的旧版漏过两个库（worktree 早被
#   别的途径删了）；
# · /exit 之后确认 agent 真的从 `herdr agent list` 里消失，才删它脚下的 worktree；
# · 收尾后跑一次 workspace 检查（herdr-agents §7 的完成判据）。
# · 删库只认 DROP_DB_CMD，不自动探测仓库里的脚本：旧版探测 `scripts/worktree-env.sh` 拼 .env 去删库，那是某一个
#   项目的约定，别的仓库碰巧有同名脚本就会被当成同一套约定调用。
# 远端分支这里不删：合并时由仓库设置（GitHub 的「Automatically delete head branches」）删，没开就手动删。

set -u
: "${REPO:?REPO=仓库主 checkout 的路径}"
pr=${1:?usage: closeout.sh <pr> <issue> <agent-name|->}; issue=${2:?}; agent=${3:?}
SKILLS_DIR=${SKILLS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
close_merged=$SKILLS_DIR/github-backlog/scripts/close-merged.sh
retire=$SKILLS_DIR/herdr-agents/scripts/retire.sh
for s in "$close_merged" "$retire"; do [ -x "$s" ] || { echo "missing $s (set SKILLS_DIR)"; exit 1; }; done
cd "$REPO" || exit 1

# 1 · 核落地、Issue 改 Done（最后一行是 branch=…）
out=$("$close_merged" "$pr" "$issue"); rc=$?
grep -v '^branch=' <<<"$out"
[ $rc = 0 ] || exit 1
br=$(sed -n 's/^branch=//p' <<<"$out" | tail -1)
[ -n "$br" ] || { echo "⚠ close-merged.sh gave no branch"; exit 1; }

# 2 · 让 worker /exit，等它从列表里消失
exited=1
if [ "$agent" != - ]; then "$retire" exit "$agent" || exited=0; fi

wt=$(git worktree list --porcelain | awk -v b="refs/heads/$br" '/^worktree /{w=substr($0,10)} $0=="branch "b{print w}')
if [ -n "$wt" ] && [ $exited = 0 ]; then echo "⚠ not removing $wt while $agent is still there"; exit 1; fi

# 3 · 数据库
if [ -n "${DROP_DB_CMD:-}" ]; then
  $DROP_DB_CMD "$br" "$wt" || echo "⚠ DROP_DB_CMD failed for $br"
else
  echo "ℹ no DROP_DB_CMD — database step skipped"
fi

# 4 · worktree、workspace
if [ -n "$wt" ]; then "$retire" remove "$wt"; else echo "ℹ no worktree on $br"; fi

# 5 · 本地分支
git branch -D "$br" 2>&1 | tail -1
exit 0
