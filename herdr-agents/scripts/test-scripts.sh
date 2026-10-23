#!/usr/bin/env bash
#
# launch.sh 的名字检查、retire.sh 的 REPO 护栏：用一个假的 herdr（读写临时目录里的 JSON、把每次调用记进日志）跑一遍，
# 断言输出、退出码、以及该不该调到 herdr。只写临时目录，不碰真的 herdr。
#
# usage: test-scripts.sh     退出码 0 = 全过

set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d) || exit 9
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() {  # check <说明> <期望退出码> <输出须含的 ERE> <命令…>
  local what=$1 want_rc=$2 want_out=$3; shift 3
  local out rc; out=$("$@" 2>&1); rc=$?
  if [ "$rc" = "$want_rc" ] && grep -qE -- "$want_out" <<<"$out"; then echo "PASS $what"; pass=$((pass + 1))
  else echo "FAIL $what (rc=$rc, want $want_rc)"; sed 's/^/     | /' <<<"$out"; fail=$((fail + 1)); fi
}
called()    { if grep -qE -- "$2" "$T/calls"; then echo "PASS $1"; pass=$((pass + 1)); else echo "FAIL $1"; fail=$((fail + 1)); fi; }
notcalled() { if grep -qE -- "$2" "$T/calls"; then echo "FAIL $1"; fail=$((fail + 1)); else echo "PASS $1"; pass=$((pass + 1)); fi; }

# ---------- 两个仓库：A（带 origin，launch.sh 要 fetch）、B ----------
git -c init.defaultBranch=main init -q --bare "$T/origin.git"
for r in A B; do
  git -c init.defaultBranch=main init -q "$T/$r"
  git -C "$T/$r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
done
git -C "$T/A" remote add origin "$T/origin.git"
git -C "$T/A" push -q origin main

# ---------- 假 herdr ----------
# agent list 读 $T/agents（每行 name|cwd）；agent prompt <名> /exit 把那一行删掉；agent start 按 $T/start_err 报错
mkdir "$T/bin"; : > "$T/calls"
cat > "$T/bin/herdr" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/calls"
case "\$1 \$2" in
  "agent list")
    python3 -c 'import json,sys
rows=[l.rstrip("\n").split("|") for l in open(sys.argv[1]) if l.strip()]
print(json.dumps({"result":{"agents":[{"name":n,"cwd":c,"pane_id":"w:p","agent_status":"idle"} for n,c in rows]}}))' "$T/agents" ;;
  "agent prompt") [ "\$4" = /exit ] && grep -v "^\$3|" "$T/agents" > "$T/agents.tmp"; mv "$T/agents.tmp" "$T/agents" 2>/dev/null; echo '{"result":{}}' ;;
  "agent start")  if [ -s "$T/start_err" ]; then cat "$T/start_err"; exit 1; fi; echo '{"result":{}}' ;;
  "worktree create")
    git -C "$T/A" worktree add -q -b "\$6" "$T/wt" >/dev/null 2>&1
    echo '{"result":{"root_pane":{"pane_id":"wN:p1"},"tab":{"tab_id":"wN:t1"},"workspace":{"workspace_id":"wN"},"worktree":{"path":"$T/wt"}}}' ;;
  "tab rename") echo '{"result":{}}' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/herdr"
export PATH="$T/bin:$PATH"
echo "hello [TOK-1]" > "$T/prompt"

# ---------- launch.sh：名字 ----------
printf 'drafter|%s\n' "$T/B" > "$T/agents"
long=worker-proj-1234-a-rather-long-name   # 35 字符
check "名字超过 32 字符：建 worktree 之前就拒" 1 "invalid agent name '$long' \(35 chars\)" \
  env REPO="$T/A" DRY_RUN=1 "$here/launch.sh" b1 L "$long" "$T/prompt" "[TOK-1]"
check "大写字母：拒" 1 "invalid agent name" \
  env REPO="$T/A" DRY_RUN=1 "$here/launch.sh" b1 L "Worker-1" "$T/prompt" "[TOK-1]"
check "名字被别的项目占着：拒，并说出占用者的 cwd" 1 "agent name drafter is already taken \(held by pane w:p, cwd $T/B\)" \
  env REPO="$T/A" DRY_RUN=1 "$here/launch.sh" b1 L drafter "$T/prompt" "[TOK-1]"
notcalled "名字不合格时没去建 worktree" "worktree create"
check "合格且没人用的名字：DRY_RUN 照常打印" 0 "herdr agent start worker-a-1-x" \
  env REPO="$T/A" DRY_RUN=1 "$here/launch.sh" b1 L worker-a-1-x "$T/prompt" "[TOK-1]"

echo '{"error":{"code":"agent_pane_not_found","message":"agent target pane wN:p1 not found"}}' > "$T/start_err"
check "agent start 失败：把 herdr 的报错原样打出来，不报成 NOT READY" 1 "agent start failed: .*agent_pane_not_found" \
  env REPO="$T/A" "$here/launch.sh" issue/1-x L worker-a-1-x "$T/prompt" "[TOK-1]"

# ---------- retire.sh exit：REPO 护栏 ----------
: > "$T/calls"
printf 'drafter|%s\n' "$T/B" > "$T/agents"
check "同名 agent 在别的项目：带 REPO 时拒收，退 3" 3 "not in $T/A" env REPO="$T/A" "$here/retire.sh" exit drafter
notcalled "也没给它发 /exit" "agent prompt drafter"
mkdir -p "$T/A/sub"
printf 'mine|%s\n' "$T/A/sub" > "$T/agents"
check "agent 在本仓库（子目录也算）：照常收" 0 "agent mine exited" env REPO="$T/A" "$here/retire.sh" exit mine
called "发了 /exit" "agent prompt mine /exit"
printf 'drafter|%s\n' "$T/B" > "$T/agents"
check "不带 REPO：行为不变（只凭名字）" 0 "agent drafter exited" "$here/retire.sh" exit drafter

echo "---- $pass 过，$fail 败"
[ $fail = 0 ]
