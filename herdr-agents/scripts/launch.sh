#!/usr/bin/env bash
#
# 起一个 claude agent：建 worktree → 起 claude → 等它真的就绪 → 把指令发一次 → 数 transcript 确认送达几次。
# 这是 SKILL.md §1–§2 对 claude kind 的落地；每一步为什么这样做写在那两节，这里只写脚本自己的取舍。
#
# usage: REPO=<仓库主 checkout> [MODEL=sonnet] [BASE=origin/main] [DRY_RUN=1] launch.sh <branch> <label> <agent-name> <prompt-file> <token>
#   token = 指令里一段独有的字符串（例如 [WORKER-1278-KICKOFF]），用来在 transcript 里数送达次数（count-delivered.sh）。
#   BASE  = 新分支的基点，`<remote>/<branch>` 形式，脚本先 fetch 它。默认 origin/main；用哪个基点是调用方的事
#           （chief-of-staff 的规矩写在它自己的「发牌序列」里）。
#   DRY_RUN=1 只打印将执行的命令和解析出的路径，不建、不起、不发。
#   最后一行：<name> ws=… pane=… wt=… delivered=<次数>。delivered 不是 1 就照 SKILL.md §2 处理（0 = 没送达，
#   ≥2 = 重复送达）。只支持 claude kind（数送达读的是 Claude Code 的 transcript）。
#
# 名字：herdr 的 agent 名在整台机器上唯一（不分项目），且限 `[a-z][a-z0-9_-]{0,31}`。建 worktree 之前先查这两条，
# 免得留下一个没人用的 worktree；`agent start` 自己报的错原样打出来，不吞成 NOT READY（见 HISTORY #23）。
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
[[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo "invalid agent name '$name' (${#name} chars): herdr wants [a-z][a-z0-9_-]{0,31}"; exit 1; }
if holder=$(herdr agent list 2>/dev/null | python3 -c 'import json,sys;[print("pane",a.get("pane_id")+",","cwd",a.get("cwd")) for a in json.load(sys.stdin)["result"]["agents"] if a.get("name")==sys.argv[1]]' "$name") \
   && [ -n "$holder" ]; then
  echo "agent name $name is already taken (held by $holder) — herdr names are machine-wide; pick another"; exit 1
fi
if [ "${DRY_RUN:-}" = 1 ]; then
  echo "git -C $REPO fetch -q ${BASE%%/*} ${BASE#*/}"
  echo "herdr worktree create --cwd $REPO --branch $branch --base $BASE --label \"$label\""
  echo "herdr agent start $name --kind claude --pane <root_pane> --timeout 90000 -- --model ${MODEL:-sonnet}"
  echo "herdr agent prompt $name <$pf> --wait --until working --timeout 15000"
  echo "$here/count-delivered.sh <worktree> $token"
  exit 0
fi
git -C "$REPO" fetch -q "${BASE%%/*}" "${BASE#*/}"
# herdr 的 `worktree create` 会把 worktree 归到主 checkout 的 workspace 下；没有这个 workspace 就替你建一个，且没有
# 参数能关掉（SKILL.md §7）。建之前先看有没有，没有的话建完把新出现的那个记下来，retire.sh remove 凭这条记录收它。
main=$(dirname "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)")
had_root=$("$here/root-ws.sh" find "$main")
r=$(herdr worktree create --cwd "$REPO" --branch "$branch" --base "$BASE" --label "$label") || { echo "worktree create failed: $r"; exit 1; }
read -r pane tab ws wt < <(echo "$r" | python3 -c 'import json,sys;r=json.load(sys.stdin)["result"];print(r["root_pane"]["pane_id"],r["tab"]["tab_id"],r["workspace"]["workspace_id"],r["worktree"]["path"])')
[ -n "$had_root" ] || "$here/root-ws.sh" record "$main"
herdr tab rename "$tab" "$label" >/dev/null
out=$(herdr agent start "$name" --kind claude --pane "$pane" --timeout 90000 -- --model "${MODEL:-sonnet}" 2>&1) \
  || { echo "agent start failed: $(head -c 400 <<<"$out")"; echo "left behind: wt=$wt ws=$ws pane=$pane"; exit 1; }
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
