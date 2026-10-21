#!/usr/bin/env bash
#
# 起一个 herdr worker：建 worktree → 起 claude → 等它真的就绪 → 把指令发一次 → 数 transcript 确认送达几次。
# usage: REPO=<仓库主 checkout> [MODEL=sonnet] [BASE=origin/main] launch.sh <branch> <label> <agent-name> <prompt-file> <token>
#   token = 指令里一段独有的字符串（例如 [WORKER-1278-KICKOFF]），用来在 transcript 里数送达次数。
#   最后一行：<name> ws=… pane=… wt=… delivered=<次数>。delivered 不是 1 就照 herdr-agents §2 处理（0 = 没送达，
#   ≥2 = 重复送达）。只支持 claude kind（数送达读的是 Claude Code 的 transcript）。
#
# 来历：前任 coordinator 2026-10 的 ~/.cache/smops-runs/coordinator/launch.sh（写死 smart-manu-ops）。
# 基于 origin/main（先 fetch），不基于本地 main：2026-10-07 本地 main 落后 298 个提交。2026-10-12 dev 分支并进 main
# 后 John 说「以后从 origin/main 拉，合并到 main」，当天用过的 dev 覆盖随之去掉；BASE 留着只为别的仓库。
#
# 信任框（2026-10-21 实测，Claude Code 2.1.306 + herdr 0.9.5，在一个从没信任过的目录里起 claude）：
#   ❯ No, exit
#     Yes, I trust this folder
# 光标默认在「No, exit」上。旧版看到「trust this folder」就按 Enter —— 按下去就退出了。现在不假设默认项：读 ❯ 那一行，
# 不在「Yes」上就按 down，在了才按 Enter。另外此时 `agent start` 立刻返回 agent_not_ready（它看得出被挡住了）。
# 什么会推翻：选项顺序或文案变了（就绪循环会跑满 60 次、报 NOT READY，不会误按）；新版不再弹框。

set -u
: "${REPO:?REPO=仓库主 checkout 的路径}"
branch=$1; label=$2; name=$3; pf=$4; token=$5
BASE=${BASE:-origin/main}
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
slug=$(echo "$wt" | sed 's#[/.]#-#g')
t=$(ls -t ~/.claude/projects/$slug/*.jsonl 2>/dev/null | head -1)
n=$(python3 - "$t" "$token" <<'PY'
import json,sys
n=0
for line in open(sys.argv[1],encoding='utf-8'):
    d=json.loads(line)
    if d.get('type')=='user' and not d.get('isMeta'):
        c=d.get('message',{}).get('content')
        t=c if isinstance(c,str) else ' '.join(x.get('text','') for x in c if isinstance(x,dict))
        if sys.argv[2] in t: n+=1
    # A prompt sent while the agent is busy lands as a queued_command attachment, never as
    # a 'user' record (herdr-agents §2). Don't count the queue-operation enqueue/remove pair.
    elif d.get('type')=='attachment' and d.get('attachment',{}).get('type')=='queued_command':
        if sys.argv[2] in str(d['attachment'].get('prompt','')): n+=1
print(n)
PY
)
echo "$name ws=$ws pane=$pane wt=$wt delivered=$n"
