#!/usr/bin/env bash
#
# 「起 worker 时 herdr 顺带建出来的主 checkout workspace」的记录与回收。launch.sh / retire.sh 调用，不单独用。
# 为什么要这样（herdr 的行为、判据）：SKILL.md §7。
#
#   root-ws.sh find <主checkout>      打印挂着这个主 checkout 的 workspace id（非 linked worktree），没有就什么都不打。
#   root-ws.sh record <主checkout>    把现在挂着它的 workspace id 记进 <git-common-dir>/herdr-agents-root-ws。
#                                     只在 launch.sh 建 worktree 前确认「当时没有」的情况下调用，所以记下的都是我们引出来的。
#   root-ws.sh reap <主checkout>      对记录里的每个 id：满足全部判据才 `herdr workspace close`，并从记录里删掉；
#                                     不满足就留着、打 ℹ 说明原因（拿不准就不关）。DRY_RUN=1 只打印。
#
# 关闭判据（全部满足）：workspace 还在、仍挂着这个主 checkout、同仓库没有 linked worktree 的 workspace 还开着、
# 只有 1 个 pane、agent_status 不是 working/blocked。
set -u
cmd=${1:?usage: root-ws.sh find|record|reap <main-checkout>}; main=${2:?}
rec=$(git -C "$main" rev-parse --path-format=absolute --git-common-dir)/herdr-agents-root-ws

py() { herdr workspace list | python3 -c "$1" "$main" "${2:-}"; }
case "$cmd" in
  find)   py 'import json,sys;[print(w["workspace_id"]) for w in json.load(sys.stdin)["result"]["workspaces"] if (w.get("worktree") or {}).get("checkout_path")==sys.argv[1] and not w["worktree"].get("is_linked_worktree")]' ;;
  record) "$0" find "$main" >> "$rec" ;;
  reap)
    [ -s "$rec" ] || exit 0
    keep=$(mktemp); trap 'rm -f "$keep"' EXIT
    while read -r id; do
      [ -n "$id" ] || continue
      why=$(py 'import json,sys
ws=json.load(sys.stdin)["result"]["workspaces"]; main,id=sys.argv[1],sys.argv[2]
w=next((x for x in ws if x["workspace_id"]==id),None)
if w is None: print("GONE"); sys.exit()
wt=w.get("worktree") or {}
if wt.get("checkout_path")!=main or wt.get("is_linked_worktree"): print("not the main checkout any more")
elif any((x.get("worktree") or {}).get("is_linked_worktree") and x["worktree"].get("repo_key")==wt.get("repo_key") for x in ws): print("linked worktree workspaces still open")
elif w.get("pane_count")!=1: print("has %s panes"%w.get("pane_count"))
elif w.get("agent_status") in ("working","blocked"): print("agent_status "+w["agent_status"])
else: print("OK")' "$id")
      case "$why" in
        GONE) ;;
        OK) if [ "${DRY_RUN:-}" = 1 ]; then echo "herdr workspace close $id"; echo "$id" >> "$keep"
            elif herdr workspace close "$id" >/dev/null 2>&1; then echo "root ws closed $id"
            else echo "⚠ root ws close $id failed"; echo "$id" >> "$keep"; fi ;;
        *) echo "ℹ root ws $id kept: $why"; echo "$id" >> "$keep" ;;
      esac
    done < <(sort -u "$rec")
    [ "${DRY_RUN:-}" = 1 ] || { [ -s "$keep" ] && cp "$keep" "$rec" || rm -f "$rec"; } ;;
  *) echo "usage: root-ws.sh find|record|reap <main-checkout>"; exit 2 ;;
esac
