#!/usr/bin/env bash
#
# 一个 PR 合并之后的收尾：核提交已落地 → Issue 改 Done → 让 worker /exit → 删它的数据库 → 删 worktree →
# 关 herdr workspace → 删本地分支。任何一步失败都打印出来，不静默跳过。
#
# usage: REPO=<仓库主 checkout> closeout.sh <pr> <issue> <agent-name>
#   agent-name 给 - 表示没有 worker 要叫停（例如它已经退出了）。
# 环境变量：
#   REPO                   必填
#   REVIEW_LABEL="In review"  DONE_LABEL=Done   Issue 上摘掉 / 加上的标签（github-backlog 工作流的写法）
#   DEFAULT_REMOTE=origin  DEFAULT_BRANCH=main
#   数据库：仓库里有 scripts/worktree-env.sh（smart-manu-ops 的每 worktree 一个库的约定）就用它；
#           否则设 DROP_DB_CMD，会以 `$DROP_DB_CMD <branch> <worktree 路径或空>` 调用；两者都没有 = 跳过并说出来。
#
# 来历：前任 coordinator 2026-10 的 ~/.cache/smops-runs/coordinator/closeout.sh（写死 smart-manu-ops）。改了：
# · 仓库路径、标签、数据库钩子参数化；
# · worktree 已经不在、数据库还在时，也按分支名推出库名删掉 —— 2026-10-21 就是这样漏了两个库：旧版只在找到
#   worktree 时才 drop-db，而 worktree 早被别的途径删了；
# · /exit 之后确认 agent 真的从 `herdr agent list` 里消失，才删它脚下的 worktree；
# · 收尾后跑一次 workspace 检查（herdr-agents §7「收工是三步」的完成判据）。
# 合并后远端分支由 GitHub 自动删（2026-10-13 起），这里不删远端分支。

set -u
: "${REPO:?REPO=仓库主 checkout 的路径}"
pr=${1:?usage: closeout.sh <pr> <issue> <agent-name|->}; issue=${2:?}; agent=${3:?}
REVIEW_LABEL=${REVIEW_LABEL:-In review}; DONE_LABEL=${DONE_LABEL:-Done}
BASE=${DEFAULT_REMOTE:-origin}/${DEFAULT_BRANCH:-main}
cd "$REPO" || exit 1

# 1 · 核落地：PR 是 MERGED，且合并提交在主干上
git fetch -q "${DEFAULT_REMOTE:-origin}" || echo "⚠ git fetch failed — checking against the cached $BASE"
mc=$(gh pr view "$pr" --json mergeCommit,state --jq 'select(.state=="MERGED")|.mergeCommit.oid')
[ -n "$mc" ] || { echo "#$pr NOT MERGED"; exit 1; }
git merge-base --is-ancestor "$mc" "$BASE" && echo "#$pr LANDED ${mc:0:8}" || { echo "#$pr NOT ON $BASE"; exit 1; }
br=$(gh pr view "$pr" --json headRefName --jq .headRefName)

# 2 · Issue 改 Done
gh issue edit "$issue" --remove-label "$REVIEW_LABEL" --add-label "$DONE_LABEL" >/dev/null \
  && echo "#$issue -> $DONE_LABEL ($(gh issue view "$issue" --json state --jq .state))" \
  || echo "⚠ #$issue label change failed"

# 3 · 让 worker /exit，等它从列表里消失
gone() { herdr agent list 2>/dev/null | python3 -c 'import json,sys;sys.exit(any(a.get("name")==sys.argv[1] for a in json.load(sys.stdin)["result"]["agents"]))' "$1"; }
if [ "$agent" != - ]; then
  herdr agent prompt "$agent" "/exit" >/dev/null 2>&1
  for i in $(seq 1 15); do gone "$agent" && break; sleep 1; done
  gone "$agent" && echo "agent $agent exited" || echo "⚠ agent $agent still in herdr agent list — not removing its worktree"
fi

wt=$(git worktree list --porcelain | awk -v b="refs/heads/$br" '/^worktree /{w=substr($0,10)} $0=="branch "b{print w}')
if [ -n "$wt" ] && [ "$agent" != - ] && ! gone "$agent"; then exit 1; fi

# 4 · 数据库
drop_db() {  # $1=branch  $2=worktree 路径（可空）
  local envtool="$REPO/scripts/worktree-env.sh" db tmp
  if [ -x "$envtool" ]; then
    if [ -n "$2" ] && [ -f "$2/.env" ]; then
      "$envtool" drop-db "$2" 2>&1 | tail -1
    else
      # worktree 没了：drop-db 只认 worktree 路径（从它的 .env 读库名），所以按分支推出库名，给它一个只含连接参数的临时 .env
      db=$("$envtool" db-name "$1") || { echo "⚠ cannot derive db name for $1"; return; }
      tmp=$(mktemp -d) && chmod 700 "$tmp"
      grep -E '^(POSTGRES_HOST|POSTGRES_PORT|POSTGRES_USER|POSTGRES_PASSWORD)=' "$REPO/.env" > "$tmp/.env"
      echo "POSTGRES_DB=$db" >> "$tmp/.env"
      "$envtool" drop-db "$tmp" 2>&1 | tail -1
      rm -rf "$tmp"
    fi
  elif [ -n "${DROP_DB_CMD:-}" ]; then
    $DROP_DB_CMD "$1" "$2"
  else
    echo "ℹ no scripts/worktree-env.sh and no DROP_DB_CMD — database step skipped"
  fi
}
drop_db "$br" "$wt"

# 5 · worktree、6 · workspace
if [ -n "$wt" ]; then
  ws=$(herdr workspace list | python3 -c 'import json,sys;wt=sys.argv[1];[print(w["workspace_id"]) for w in json.load(sys.stdin)["result"]["workspaces"] if (w.get("worktree") or {}).get("checkout_path")==wt]' "$wt")
  git worktree remove --force "$wt" && echo "wt removed $wt"
  [ -n "$ws" ] && { herdr workspace close "$ws" >/dev/null 2>&1 && echo "ws closed $ws" || echo "⚠ ws close $ws failed"; }
else
  echo "ℹ no worktree on $br"
fi

# 7 · 本地分支
git branch -D "$br" 2>&1 | tail -1

# 完成判据：没有 workspace 还挂着这个 worktree
[ -n "$wt" ] && herdr workspace list | grep -qF "\"$wt\"" && echo "⚠ a workspace still points at $wt"
exit 0
