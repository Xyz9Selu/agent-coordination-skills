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

# ---------- 迁移闸：每轮都算，状态没变就不再发、不再报 ----------
# 仓库 G：main 上有迁移 0001，打开的 PR #7 新增 0002 <- 0001。假 gh 记下每次 POST。
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare -b main "$T/G.git"
git clone -q "$T/G.git" "$T/G" 2>/dev/null
(cd "$T/G" && git checkout -q -b main 2>/dev/null && mkdir db \
  && printf 'revision = "0001"\ndown_revision = None\n' > db/0001.py && git add -A && git commit -qm base && git push -q origin main \
  && git checkout -q -b issue/7-x && printf 'revision = "0002"\ndown_revision = "0001"\n' > db/0002.py \
  && git add -A && git commit -qm m && git push -q origin issue/7-x && git checkout -q main)
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env python3
import json, os, subprocess, sys
a = sys.argv[1:]
sha = subprocess.run(["git", "-C", "$T/G", "rev-parse", "origin/issue/7-x"], capture_output=True, text=True).stdout.strip()
sp = "$T/statuses.json"
st = json.load(open(sp)) if os.path.exists(sp) else {}
if a[:2] == ["pr", "list"]:
    f = a[a.index("--json") + 1]
    if f == "headRefName": print("issue/7-x")
    elif f == "number,isDraft,title": print("7\tready\tadd 0002")
    else: print(json.dumps([{"number": 7, "headRefName": "issue/7-x", "headRefOid": sha, "isDraft": False,
                             "baseRefName": "main", "url": "https://example.invalid/pull/7"}]))
elif "POST" in a:
    kv = dict(a[i + 1].split("=", 1) for i, x in enumerate(a) if x == "-f")
    st.setdefault(sha, {})[kv["context"]] = {"state": kv["state"], "description": kv["description"]}
    json.dump(st, open(sp, "w"))
    open("$T/posts", "a").write(kv["state"] + "\n"); print("{}")
elif a[:1] == ["api"]:
    print(json.dumps({"statuses": [dict(context=c, **v) for c, v in st.get(sha, {}).items()]}))
else:
    sys.exit(1)
EOF
chmod +x "$T/bin/gh"
agents
echo "0.10 0.10 0.10 1/100 1" > "$T/loadavg"
gate_run() {  # 其余参数是额外的环境变量；跑约 5 秒（几轮），输出在 $T/out
  rm -f "$T/statuses.json" "$T/posts"
  env PATH="$T/bin:$PATH" REPO="$T/G" INTERVAL=1 HEARTBEAT=0 WATCH_PRS=1 MIGRATION_DIR=db SELF_PANE=me \
    LOADAVG_FILE="$T/loadavg" LOAD_WARN=4 "$@" "$here/scan-workers.sh" > "$T/out" 2>&1 &
  pid=$!
  sleep 5
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}
gate_run
count "迁移闸：#7 变绿只报一次 GATE（之后几轮不重报）"  'GATE #7 success' 1
n=$(grep -c . "$T/posts" 2>/dev/null); if [ "${n:-0}" = 1 ]; then ok "迁移闸：几轮下来只发了一次状态"; else bad "迁移闸：几轮下来发了 ${n:-0} 次状态，应为 1"; fi
hasnt "迁移闸：没有探测失败"                              'PROBE-ERROR'
gate_run MERGE_GATE=0
hasnt "MERGE_GATE=0：不出 GATE"                           'GATE #'
if [ -s "$T/posts" ]; then bad "MERGE_GATE=0：不该发状态"; else ok "MERGE_GATE=0：一条状态都不发"; fi

echo "---- $pass 过，$fail 败"
[ $fail = 0 ] || { echo "---- 脚本输出："; cat "$T/out"; exit 1; }
