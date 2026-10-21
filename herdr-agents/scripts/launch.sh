#!/usr/bin/env bash
#
# 起一个 claude agent：建 worktree → 起 claude → 等它真的就绪 → 把指令发一次 → 数 transcript 确认送达几次。
# 这是 SKILL.md §1–§2 对 claude kind 的落地；每一步为什么这样做写在那两节，这里只写脚本自己的取舍。
#
# usage: REPO=<仓库主 checkout> [MODEL=sonnet] [BASE=origin/main] [DRY_RUN=1] launch.sh <branch> <label> <agent-name> <prompt-file> <token>
#   token = 指令里一段独有的字符串（例如 [WORKER-1278-KICKOFF]），用来在 transcript 里数送达次数（count-delivered.sh）。
#   BASE  = 新分支的基点，`<remote>/<branch>` 形式，脚本先 fetch 它。默认 origin/main；用哪个基点是调用方的事
#           （dispatch 的规矩写在它自己的「发牌序列」里）。
#   DRY_RUN=1 只打印将执行的命令和解析出的路径，不建、不起、不发。
#   最后一行：<name> ws=… pane=… wt=… delivered=<次数>。delivered 不是 1 就照 SKILL.md §2 处理（0 = 没送达，
#   ≥2 = 重复送达）。只支持 claude kind（数送达读的是 Claude Code 的 transcript）。
#
# 来历：一个 coordinator 2026-10 写在会话临时目录里、写死了某个仓库的启动脚本，2026-10-21 搬进 dispatch 并参数化，
# 同日按「herdr 层的东西归 herdr-agents」挪到这里。
#
# 就绪判据与信任框：见 SKILL.md §1「claude kind」（特征串 `Claude Code v`；信任框默认选中「No, exit」，
# 读 ❯ 那一行，不在「Yes」上就按 down，在了才按 Enter）。框的文案或顺序变了，就绪循环会跑满 60 次、报
# NOT READY，不会误按。

set -u
: "${REPO:?REPO=仓库主 checkout 的路径}"
branch=${1:?usage: launch.sh <branch> <label> <agent-name> <prompt-file> <token>}; label=${2:?}; name=${3:?}; pf=${4:?}; token=${5:?}
BASE=${BASE:-origin/main}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -f "$pf" ] || { echo "no prompt file: $pf"; exit 1; }
grep -qF -- "$token" "$pf" || { echo "token $token not in $pf — delivery could not be counted"; exit 1; }
if [ "${DRY_RUN:-}" = 1 ]; then
  echo "git -C $REPO fetch -q ${BASE%%/*} ${BASE#*/}"
  echo "herdr worktree create --cwd $REPO --branch $branch --base $BASE --label \"$label\""
  echo "herdr agent start $name --kind claude --pane <root_pane> --timeout 90000 -- --model ${MODEL:-sonnet}"
  echo "herdr agent prompt $name <$pf> --wait --until working --timeout 15000"
  echo "$here/count-delivered.sh <worktree> $token"
  exit 0
fi
git -C "$REPO" fetch -q "${BASE%%/*}" "${BASE#*/}"
r=$(herdr worktree create --cwd "$REPO" --branch "$branch" --base "$BASE" --label "$label") || { echo "worktree create failed: $r"; exit 1; }
read -r pane tab ws wt < <(echo "$r" | python3 -c 'import json,sys;r=json.load(sys.stdin)["result"];print(r["root_pane"]["pane_id"],r["tab"]["tab_id"],r["workspace"]["workspace_id"],r["worktree"]["path"])')
herdr tab rename "$tab" "$label" >/dev/null
herdr agent start "$name" --kind claude --pane "$pane" --timeout 90000 -- --model "${MODEL:-sonnet}" >/dev/null
ready=0
for i in $(seq 1 60); do
  scr=$(herdr pane read "$pane" --source visible)
  if echo "$scr" | grep -q "trust this folder"; then
    if echo "$scr" | grep '❯' | grep -q 'Yes'; then herdr pane send-keys "$pane" Enter; sleep 2
    else herdr pane send-keys "$pane" down; sleep 0.5; fi
    continue
  fi
  if echo "$scr" | grep -q "Claude Code v"; then ready=1; break; fi
  sleep 1
done
[ $ready = 1 ] || { echo "NOT READY $name pane=$pane"; exit 1; }
herdr agent prompt "$name" "$(cat "$pf")" --wait --until working --timeout 15000 >/dev/null 2>&1
sleep 12
n=$("$here/count-delivered.sh" "$wt" "$token")
echo "$name ws=$ws pane=$pane wt=$wt delivered=$n"
