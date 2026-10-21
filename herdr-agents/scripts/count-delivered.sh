#!/usr/bin/env bash
#
# 数一条指令在 claude agent 的 transcript 里送达了几次（SKILL.md §2「只送达了一次」的判据）。
# usage: count-delivered.sh <worktree 路径 | transcript.jsonl> <token>
#   token = 指令里一段独有的字符串（例如 [WORKER-1278-KICKOFF]）。给 worktree 路径时取它最新的 transcript。
#   输出一个数：1 = 正好一次；0 = 没送达；≥2 = 重复送达。找不到 transcript 时输出 0 并在 stderr 说明，退出 1。
#   只支持 claude kind（读的是 Claude Code 的 transcript）。
#
# 数什么、不数什么（每条都是实测）：
# · `type: user` 且不是 `isMeta` 的记录 —— 空闲时发的指令记成这样。
# · `type: attachment`、`attachment.type: queued_command` —— 忙时发的指令排队，进入对话时记成这样，没有 user 记录。
#   同时记下的 `queue-operation` enqueue / remove 两条不数，否则一次数成三次。
# · **不数 `isMeta` 的 user 记录**：斜杠命令（`/grill-with-docs <参数>`）展开出的技能正文是一条 isMeta 的 user
#   记录，参数会在里面再出现一次；不排除就把一次送达数成两次。实测与旧版两份计数代码见 HISTORY.md #12。
# 什么会推翻：Claude Code 改了 transcript 的记法（排队消息、斜杠命令展开的记录类型）。

set -u
src=${1:?usage: count-delivered.sh <worktree|transcript.jsonl> <token>}; token=${2:?token}
if [ -f "$src" ]; then
  t=$src
else
  # transcript 目录 = worktree 绝对路径把 / 和 . 都换成 -（SKILL.md §2）
  slug=$(cd "$src" 2>/dev/null && pwd | sed 's#[/.]#-#g') || { echo 0; echo "no such worktree: $src" >&2; exit 1; }
  t=$(ls -t ~/.claude/projects/"$slug"/*.jsonl 2>/dev/null | head -1)
fi
[ -n "$t" ] && [ -f "$t" ] || { echo 0; echo "no transcript for $src" >&2; exit 1; }
python3 - "$t" "$token" <<'PY'
import json,sys
n=0
for line in open(sys.argv[1],encoding='utf-8'):
    try: d=json.loads(line)
    except ValueError: continue
    if d.get('type')=='user' and not d.get('isMeta'):
        c=d.get('message',{}).get('content')
        t=c if isinstance(c,str) else ' '.join(x.get('text','') for x in c if isinstance(x,dict))
        if sys.argv[2] in t: n+=1
    elif d.get('type')=='attachment' and d.get('attachment',{}).get('type')=='queued_command':
        if sys.argv[2] in str(d['attachment'].get('prompt','')): n+=1
print(n)
PY
