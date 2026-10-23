#!/usr/bin/env bash
#
# scan-workers.sh 的多项目行为：在临时目录里造两个仓库、一个假的 herdr（读一个 JSON 文件当 agent 列表）、一个假的
# loadavg 文件，跑脚本几轮，断言它的事件行。只写临时目录，不碰真的 herdr、gh。
#
# 覆盖：只报本项目的 agent（主 checkout 与 worktree 都算，别的仓库、不在仓库里的只计数）；同项目另一个幕僚长报
# COS-DUPLICATE 且只报一次、自己的 pane 不算、别的项目的幕僚长不算；整机负载 LOAD-HIGH / LOAD-OK（连续两轮才翻）。
#
# usage: test-scan-workers.sh     退出码 0 = 全过

set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d) || exit 9
trap 'kill "$pid" 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
has()    { if grep -qE -- "$2" "$T/out"; then ok "$1"; else bad "$1"; fi; }
hasnt()  { if grep -qE -- "$2" "$T/out"; then bad "$1"; else ok "$1"; fi; }
count()  { local n; n=$(grep -cE -- "$2" "$T/out"); if [ "$n" = "$3" ]; then ok "$1"; else bad "$1（$n 次，应为 $3）"; fi; }

# ---------- 两个仓库，A 带一个 worktree ----------
git -c init.defaultBranch=main init -q --bare "$T/origin.git"
for r in A B; do
  git -c init.defaultBranch=main init -q "$T/$r"
  git -C "$T/$r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
done
git -C "$T/A" remote add origin "$T/origin.git"
git -C "$T/A" push -q origin main
git -C "$T/A" worktree add -q -b issue/1-a "$T/A-wt"

# ---------- 假 herdr ----------
mkdir "$T/bin"
cat > "$T/bin/herdr" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "agent list") cat "$T/agents.json" ;;
  "pane read")  echo "some screen" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/herdr"

agents() {  # 每个参数：name|status|pane|cwd|title
  python3 - "$@" > "$T/agents.json.tmp" <<'PY'
import json,sys
rows=[dict(zip(["name","agent_status","pane_id","cwd","terminal_title_stripped"], a.split("|"))) for a in sys.argv[1:]]
for r in rows:
    if not r["name"]: del r["name"]
print(json.dumps({"result":{"agents":rows}}))
PY
  mv "$T/agents.json.tmp" "$T/agents.json"
}

agents "worker-1-a|working|wA:p1|$T/A-wt|" \
       "|idle|wA:self|$T/A|Me - CoS of A" \
       "|idle|wA:dup|$T/A|Ann - CoS of Acme" \
       "drafter|working|wB:p2|$T/B|" \
       "|idle|wB:p1|$T/B|Zoe - CoS of B" \
       "loose|idle|wX:p1|$T/nowhere|"
echo "9.00 8.00 7.00 1/100 1" > "$T/loadavg"

PATH="$T/bin:$PATH" REPO="$T/A" INTERVAL=1 HEARTBEAT=0 WATCH_PRS=0 SELF_PANE=wA:self \
  LOADAVG_FILE="$T/loadavg" LOAD_WARN=4 "$here/scan-workers.sh" > "$T/out" 2>&1 &
pid=$!
sleep 4
# 第二段：别的项目来了新 agent、本项目来了新 agent、负载降下来
agents "worker-1-a|working|wA:p1|$T/A-wt|" \
       "|idle|wA:self|$T/A|Me - CoS of A" \
       "|idle|wA:dup|$T/A|Ann - CoS of Acme" \
       "drafter|working|wB:p2|$T/B|" \
       "reviewer|idle|wB:p3|$T/B|" \
       "helper|idle|wA:p2|$T/A|" \
       "|idle|wB:p1|$T/B|Zoe - CoS of B" \
       "loose|idle|wX:p1|$T/nowhere|"
echo "0.50 1.00 2.00 1/100 1" > "$T/loadavg"
sleep 4
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

has   "快照里有本项目 worktree 里的 worker"            'SCAN-READY agents: worker-1-a=working \|'
has   "快照里别的项目 / 不在仓库里的只计数（3 个，1 个 working）" '其它项目 agent 3 个（working 1）'
hasnt "别的项目的 agent 名不出现"                        'drafter|reviewer|loose|Zoe'
count "同项目另一个幕僚长报一次 COS-DUPLICATE"           'COS-DUPLICATE wA:dup' 1
hasnt "自己的 pane 不算重复幕僚长"                       'COS-DUPLICATE wA:self'
has   "本项目主 checkout 里新来的 agent 报 AGENT-NEW"   'AGENT-NEW helper'
count "负载越线报一次 LOAD-HIGH"                         'LOAD-HIGH load 9.00' 1
count "负载回落报一次 LOAD-OK"                           'LOAD-OK load 0.50' 1
hasnt "没有探测失败"                                     'PROBE-ERROR'

echo "---- $pass 过，$fail 败"
[ $fail = 0 ] || { echo "---- 脚本输出："; cat "$T/out"; exit 1; }
