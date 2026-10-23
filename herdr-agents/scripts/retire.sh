#!/usr/bin/env bash
#
# 收工（SKILL.md §7「正常收工」那条路径）的两个 herdr 动作，分开调用，好让调用方在中间插自己的步骤
# （例如删那个 worktree 用的数据库——它要读 worktree 里的配置，所以得在删 worktree 之前）：
#
#   retire.sh exit <agent-name>    往 agent 发 `/exit`，等它从 `herdr agent list` 消失（最多 15 秒）。
#                                  退出码 0 = 已消失；1 = 还在（这时别删它脚下的 worktree）。
#   retire.sh remove <worktree>    找挂着这个 worktree 的 workspace（按 `worktree.checkout_path`）→
#                                  `git worktree remove --force` → `herdr workspace close` → 再看一遍
#                                  `herdr workspace list`，还有 workspace 指着它就报 ⚠、退出 1。
#   DRY_RUN=1                      只打印会做什么。
#   REPO=<仓库>                    给了就只收这个仓库的 agent：exit 时 agent 的 cwd 不在 REPO 那个 git 仓库（主 checkout
#                                  或它的 worktree）里，拒绝并退出 3。agent 名在整台机器上唯一、不分项目，自己的 worker
#                                  已经走了而别的项目恰好有同名 agent 时，只凭名字会收错人（见 HISTORY #23）。
#
# 只适用于 claude kind 且 agent 空闲时（`/exit` 是 Claude Code 的斜杠命令）；agent 卡住、正忙、或不是 claude
# 时走 §7 的 kill 路径。为什么分两条路径见 §7。

set -u
cmd=${1:?usage: retire.sh exit <agent> | remove <worktree>}; arg=${2:?usage: retire.sh exit <agent> | remove <worktree>}
dry() { [ "${DRY_RUN:-}" = 1 ]; }

in_list() {  # 0 = 名字还在 agent list 里
  herdr agent list 2>/dev/null | python3 -c 'import json,sys;sys.exit(0 if any(a.get("name")==sys.argv[1] for a in json.load(sys.stdin)["result"]["agents"]) else 1)' "$1"
}

case "$cmd" in
  exit)
    if dry; then echo "herdr agent prompt $arg /exit; wait until $arg leaves herdr agent list (15s)"; exit 0; fi
    in_list "$arg" || { echo "agent $arg not in herdr agent list (already gone)"; exit 0; }
    if [ -n "${REPO:-}" ]; then
      cwd=$(herdr agent list 2>/dev/null | python3 -c 'import json,sys;[print(a.get("cwd") or "") for a in json.load(sys.stdin)["result"]["agents"] if a.get("name")==sys.argv[1]]' "$arg" | head -1)
      want=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
      got=$( [ -n "$cwd" ] && git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
      if [ -z "$want" ] || [ "$got" != "$want" ]; then
        echo "⚠ agent $arg is not in $REPO (cwd: ${cwd:-?}) — not touching another project's agent"; exit 3
      fi
    fi
    herdr agent prompt "$arg" "/exit" >/dev/null 2>&1
    for i in $(seq 1 15); do in_list "$arg" || break; sleep 1; done
    if in_list "$arg"; then echo "⚠ agent $arg still in herdr agent list"; exit 1; fi
    echo "agent $arg exited"
    ;;
  remove)
    wt=$(cd "$arg" 2>/dev/null && pwd) || { echo "ℹ no worktree at $arg"; exit 0; }
    main=$(dirname "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)") || exit 1
    ws=$(herdr workspace list | python3 -c 'import json,sys;wt=sys.argv[1];[print(w["workspace_id"]) for w in json.load(sys.stdin)["result"]["workspaces"] if (w.get("worktree") or {}).get("checkout_path")==wt]' "$wt")
    if dry; then echo "git -C $main worktree remove --force $wt"; echo "herdr workspace close ${ws:-<none found>}"; exit 0; fi
    git -C "$main" worktree remove --force "$wt" && echo "wt removed $wt" || { echo "⚠ git worktree remove $wt failed"; exit 1; }
    for w in $ws; do herdr workspace close "$w" >/dev/null 2>&1 && echo "ws closed $w" || echo "⚠ ws close $w failed"; done
    # 完成判据：没有 workspace 还挂着这个 worktree
    if herdr workspace list | grep -qF "\"$wt\""; then echo "⚠ a workspace still points at $wt"; exit 1; fi
    ;;
  *) echo "usage: retire.sh exit <agent> | remove <worktree>"; exit 2 ;;
esac
