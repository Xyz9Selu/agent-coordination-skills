#!/usr/bin/env bash
#
# merge-gate.sh 的可重复测试。每个场景在临时目录里建一个最小仓库（一个裸 origin + 一份 clone），造几个假迁移文件，
# 用一个假的 gh（打开的 PR 列表读一个文件；commit status 存在一个 JSON 里，每次 POST 记一行）跑迁移闸，断言它发了
# 哪些状态、按什么顺序发、没变化时什么都不发。不碰网络、不碰真的 gh、不读用户的 git 配置。
#
# 用法：chief-of-staff/scripts/test-merge-gate.sh            退出码 0 = 全过；VERBOSE=1 打印每个场景的输出

set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${GATE:-$here/merge-gate.sh}"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

root=$(mktemp -d) || exit 9
trap 'rm -rf "$root"' EXIT
pass=0 fail=0

# ---------- 假 gh ----------
# FAKE_GH_DIR 下：prs（每行「号 头分支 ready|draft [目标分支]」）、statuses.json（sha → context → 状态）、
# posts（每次 POST 记一行「#号 state 描述」）。FAKE_GH_FAIL=1 时 pr list 失败。
mkdir -p "$root/bin"
cat > "$root/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, subprocess, sys
D = os.environ["FAKE_GH_DIR"]
a = sys.argv[1:]
def git(*x):
    return subprocess.run(["git", *x], capture_output=True, text=True).stdout.strip()
def prs():
    out = []
    for line in open(os.path.join(D, "prs")):
        f = line.split()
        if not f:
            continue
        out.append({"number": int(f[0]), "headRefName": f[1], "headRefOid": git("rev-parse", "origin/" + f[1]),
                    "isDraft": f[2] == "draft", "baseRefName": f[3] if len(f) > 3 else "main",
                    "url": "https://example.invalid/pull/" + f[0], "title": "t" + f[0]})
    return out
sp = os.path.join(D, "statuses.json")
st = json.load(open(sp)) if os.path.exists(sp) else {}
if a[:2] == ["pr", "list"]:
    if os.environ.get("FAKE_GH_FAIL"):
        print("HTTP 502", file=sys.stderr); sys.exit(1)
    fields = a[a.index("--json") + 1]
    if fields == "headRefName":                       # scan-collisions.sh --prs（它带 --jq）
        print("\n".join(p["headRefName"] for p in prs()))
    elif fields == "number,isDraft,title":            # scan-workers.sh 的 PR 列表（它带 --jq）
        print("\n".join("%d\t%s\t%s" % (p["number"], "draft" if p["isDraft"] else "ready", p["title"]) for p in prs()))
    else:
        print(json.dumps([{k: p[k] for k in fields.split(",")} for p in prs()]))
elif a[:1] == ["api"]:
    path = next(x for x in a[1:] if x.startswith("repos/"))
    if "POST" in a:
        sha = path.rsplit("/", 1)[1]
        f = dict(a[i + 1].split("=", 1) for i, x in enumerate(a) if x in ("-f", "--raw-field", "-F"))
        if len(f.get("description", "")) > 140:
            print("Description is too long (maximum is 140 characters)", file=sys.stderr); sys.exit(1)
        st.setdefault(sha, {})[f["context"]] = {"state": f["state"], "description": f.get("description", ""),
                                                "target_url": f.get("target_url")}
        json.dump(st, open(sp, "w"))
        num = next((str(p["number"]) for p in prs() if p["headRefOid"] == sha), "?")
        with open(os.path.join(D, "posts"), "a") as fh:
            fh.write("#%s %s %s\n" % (num, f["state"], f.get("description", "")))
        print("{}")
    else:                                              # repos/{owner}/{repo}/commits/<sha>/status
        sha = path.split("?")[0].split("/")[4]
        print(json.dumps({"state": "pending",
                          "statuses": [dict(context=c, **v) for c, v in st.get(sha, {}).items()]}))
else:
    print("fake gh: unexpected " + " ".join(a), file=sys.stderr); sys.exit(1)
PY
chmod +x "$root/bin/gh"

mig() {  # $1=文件路径  $2=revision  $3=down_revision（None、一个 id，或空格分开的几个 id = 合并迁移）
  local d
  case "$3" in
    None) d=None ;;
    *" "*) d="($(printf '"%s", ' $3))" ;;
    *) d="\"$3\"" ;;
  esac
  mkdir -p "$(dirname "$1")"
  printf '"""x"""\nrevision: str = "%s"\ndown_revision: Union[str, None] = %s\n' "$2" "$d" > "$1"
}
export -f mig

# 新建一个仓库：main 上有迁移 0001 <- 0002。打印 clone 路径；场景目录（prs 等）是它的上一级。
new_repo() {
  local r="$root/$1"
  git init -q --bare -b main "$r/origin.git"
  git clone -q "$r/origin.git" "$r/w" 2>/dev/null
  (cd "$r/w" && git checkout -q -b main 2>/dev/null
   mig db/versions/0001.py 0001 None
   mig db/versions/0002.py 0002 0001
   echo hi > README
   git add -A && git commit -qm base && git push -q origin main)
  : > "$r/prs"
  echo "$r/w"
}

branch() {  # $1=仓库  $2=分支名  $3=基点；之后从 stdin 读要执行的 shell（在仓库里），提交并 push
  (cd "$1" && git checkout -q -b "$2" "$3" && bash -e && git add -A && git commit -qm "$2" && git push -q origin "$2" && git checkout -q main)
}

push_more() {  # $1=仓库  $2=分支名；stdin 是要执行的 shell：在那条分支上再提交一次并 push
  (cd "$1" && git checkout -q "$2" && bash -e && git add -A && git commit -qm "more" && git push -q origin "$2" && git checkout -q main)
}

squash_merge() {  # $1=仓库  $2=分支名：squash 合进 main 并 push（合并后分支上的同名同号迁移要当成已在 main 上）
  (cd "$1" && git checkout -q main && git merge -q --squash "origin/$2" >/dev/null && git commit -qm "merge $2" && git push -q origin main)
}

seed() {  # $1=仓库  $2=分支名  $3=state：给这条分支当前的 head 预置一条 migration-chain 状态（模拟上一轮发过的）
  local d sha; d=$(dirname "$1"); sha=$(git -C "$1" rev-parse "origin/$2")
  python3 - "$d/statuses.json" "$sha" "$3" <<'PY'
import json, os, sys
p, sha, state = sys.argv[1:]
st = json.load(open(p)) if os.path.exists(p) else {}
st.setdefault(sha, {})["migration-chain"] = {"state": state, "description": "上一轮发的", "target_url": None}
json.dump(st, open(p, "w"))
PY
}

gate() {  # $1=仓库  其余=参数；结果放进 $out / $rc；这一次发的状态在 $d/posts
  local w=$1; shift
  d=$(dirname "$w"); : > "$d/posts"
  out=$(cd "$w" && PATH="$root/bin:$PATH" FAKE_GH_DIR="$d" MIGRATION_DIR=db/versions "$GATE" --no-fetch "$@" 2>&1); rc=$?
}

check() {  # $1=场景名  $2=期望退出码  其余断言：
  #   out:<正则> / !out:<正则>   输出里有 / 没有
  #   post:<正则> / !post:<正则> 这一次发的状态里有 / 没有
  #   posts=<n>                  这一次一共发了 n 条
  #   greens<=1                  这一次结束后，所有打开 PR 的 head 上最多一张 success
  #   order:<正则A>:<正则B>      A 那条先于 B 那条发
  local name=$1 want=$2 ok=1 why="" p n a b la lb; shift 2
  [ "$rc" = "$want" ] || { ok=0; why="退出码 $rc ≠ $want"; }
  for p in "$@"; do
    case "$p" in
      out:*)   grep -qE -- "${p#out:}" <<<"$out" || { ok=0; why="$why；输出缺 /${p#out:}/"; } ;;
      '!out:'*) grep -qE -- "${p#!out:}" <<<"$out" && { ok=0; why="$why；输出不该有 /${p#!out:}/"; } ;;
      post:*)  grep -qE -- "${p#post:}" "$d/posts" || { ok=0; why="$why；没发 /${p#post:}/"; } ;;
      '!post:'*) grep -qE -- "${p#!post:}" "$d/posts" && { ok=0; why="$why；不该发 /${p#!post:}/"; } ;;
      posts=*) n=$(grep -c . "$d/posts"); [ "$n" = "${p#posts=}" ] || { ok=0; why="$why；发了 $n 条 ≠ ${p#posts=}"; } ;;
      'greens<=1')
        n=$(cd "$(dirname "$d")" && FAKE_GH_DIR="$d" python3 - "$d" <<'PY'
import json, os, subprocess, sys
d = sys.argv[1]; w = os.path.join(d, "w")
st = json.load(open(os.path.join(d, "statuses.json"))) if os.path.exists(os.path.join(d, "statuses.json")) else {}
n = 0
for line in open(os.path.join(d, "prs")):
    f = line.split()
    if not f: continue
    sha = subprocess.run(["git", "-C", w, "rev-parse", "origin/" + f[1]], capture_output=True, text=True).stdout.strip()
    n += st.get(sha, {}).get("migration-chain", {}).get("state") == "success"
print(n)
PY
)
        [ "$n" -le 1 ] || { ok=0; why="$why；有 $n 张绿"; } ;;
      order:*)
        a=${p#order:}; b=${a#*:}; a=${a%%:*}
        la=$(grep -nE -- "$a" "$d/posts" | head -1 | cut -d: -f1); lb=$(grep -nE -- "$b" "$d/posts" | head -1 | cut -d: -f1)
        { [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ]; } || { ok=0; why="$why；/$a/ 没有先于 /$b/ 发"; } ;;
    esac
  done
  if [ $ok = 1 ]; then pass=$((pass + 1)); echo "PASS $name"
    [ "${VERBOSE:-0}" = 1 ] && { echo "$out" | sed 's/^/    | /'; sed 's/^/    > /' "$d/posts"; }
  else fail=$((fail + 1)); echo "FAIL $name: ${why#；}"; echo "$out" | sed 's/^/    | /'; sed 's/^/    > /' "$d/posts"; fi
}

# ① 两张 PR 抢同一个父迁移：PR 号小的绿，另一张黄、说清排在谁后面
w=$(new_repo compete)
branch "$w" issue/1-a main <<<'mig db/versions/0003_a.py 0003a 0002'
branch "$w" issue/2-b main <<<'mig db/versions/0003_b.py 0003b 0002'
printf '1 issue/1-a ready\n2 issue/2-b ready\n' > "$(dirname "$w")/prs"
gate "$w"
check "抢同一个父迁移：号小的绿" 0 'post:^#1 success .*0002' \
  'post:^#2 pending 排在 #1 后面.*#1 合并后把 0003_b\.py 的 down_revision 改成 0003a' posts=2 'greens<=1' \
  'order:^#2 pending:^#1 success'

# ② 原样再跑一遍：什么都不发、什么都不打印（不刷屏）
gate "$w"
check "没变化就不重发" 0 posts=0 '!out:.'

# ③ #2 推了新提交（没动迁移）：只给它的新 head 重发，#1 不动
push_more "$w" issue/2-b <<<'echo more > notes.txt'
gate "$w"
check "推了新提交只重算那一张" 0 'post:^#2 pending .*#1' posts=1

# ④ #1 合并了：#2 还接在旧 head 0002 上 → 红，描述里说 main 已是 0003a；此时没有一张绿
squash_merge "$w" issue/1-a
printf '2 issue/2-b ready\n' > "$(dirname "$w")/prs"
gate "$w"
check "合并后，抢输的那张变红" 0 'post:^#2 failure .*0002.*0003a' '!post:success' 'greens<=1'

# ⑤ 叠着的：#2 的分支从 #1 拉出来（含 #1 的 0003），自己的 0004 接在 0003 上 → 黄（排在 #1 后面），不叫它改接；
#    #1 squash 合并后 #2 自动变绿
w=$(new_repo stacked)
branch "$w" issue/1-a main <<<'mig db/versions/0003.py 0003 0002'
branch "$w" issue/2-b issue/1-a <<<'mig db/versions/0004.py 0004 0003'
printf '1 issue/1-a ready\n2 issue/2-b ready\n' > "$(dirname "$w")/prs"
gate "$w"
check "叠在别的 PR 上（分支含它）：黄" 0 'post:^#1 success' 'post:^#2 pending 排在 #1 后面：0004 接在它新增的 0003 上' \
  '!post:改接' 'greens<=1'
squash_merge "$w" issue/1-a
printf '2 issue/2-b ready\n' > "$(dirname "$w")/prs"
gate "$w"
check "前一张合并后，叠着的那张变绿" 0 'post:^#2 success .*0003' posts=1

# ⑤b 只在 down_revision 里接 #1 的 0003（分支从 main 拉，不含 0003.py）→ 同样黄
w=$(new_repo stacked-ref)
branch "$w" issue/1-a main <<<'mig db/versions/0003.py 0003 0002'
branch "$w" issue/2-b main <<<'mig db/versions/0004.py 0004 0003'
printf '1 issue/1-a ready\n2 issue/2-b ready\n' > "$(dirname "$w")/prs"
gate "$w"
check "叠在别的 PR 上（只引用它）：黄" 0 'post:^#1 success' 'post:^#2 pending 排在 #1 后面：0004 接在它新增的 0003 上' \
  'greens<=1'

# ⑤c 一条分支把 #1、#2 两张抢同一个父迁移的 PR 都合了进来：它自己合进 main 就是双头 → 红，说出两个末端
w=$(new_repo both)
branch "$w" issue/1-a main <<<'mig db/versions/0003_a.py 0003a 0002'
branch "$w" issue/2-b main <<<'mig db/versions/0003_b.py 0003b 0002'
(cd "$w" && git checkout -q -b issue/3-c origin/issue/1-a && git merge -q --no-edit origin/issue/2-b && git push -q origin issue/3-c && git checkout -q main)
printf '1 issue/1-a ready\n2 issue/2-b ready\n3 issue/3-c ready\n' > "$(dirname "$w")/prs"
gate "$w"
check "分支里带着两张对手的迁移：红" 0 'post:^#3 failure .*分叉.*0003a、0003b' 'greens<=1'

# ⑥ draft 不抢绿：draft #1 和 ready #2 都接在 head 上 → #2 绿，#1 黄并写明 draft
w=$(new_repo draft)
branch "$w" issue/1-a main <<<'mig db/versions/0003_a.py 0003a 0002'
branch "$w" issue/2-b main <<<'mig db/versions/0003_b.py 0003b 0002'
printf '1 issue/1-a draft\n2 issue/2-b ready\n' > "$(dirname "$w")/prs"
gate "$w"
check "draft 不抢绿" 0 'post:^#2 success' 'post:^#1 pending .*draft' 'greens<=1'

# ⑦ 已经亮绿的保持：#2 上一轮是绿的，#1 号更小也接在 head 上 → #2 不动，#1 黄
w=$(new_repo incumbent)
branch "$w" issue/1-a main <<<'mig db/versions/0003_a.py 0003a 0002'
branch "$w" issue/2-b main <<<'mig db/versions/0003_b.py 0003b 0002'
printf '1 issue/1-a ready\n2 issue/2-b ready\n' > "$(dirname "$w")/prs"
seed "$w" issue/2-b success
gate "$w"
check "已亮绿的保持绿" 0 'post:^#1 pending .*#2' '!post:^#1 success' '!post:^#2 (pending|failure)' 'greens<=1'

# ⑧ 绿灯换人：#3 上一轮是绿的、现在接在过时的点上；#1 合格 → 先把 #3 发红，再给 #1 发绿
w=$(new_repo handover)
branch "$w" issue/3-c main <<<'mig db/versions/0003_c.py 0003c 0001'
branch "$w" issue/1-a main <<<'mig db/versions/0003_a.py 0003a 0002'
printf '1 issue/1-a ready\n3 issue/3-c ready\n' > "$(dirname "$w")/prs"
seed "$w" issue/3-c success
gate "$w"
check "绿灯换人：先发红、再发绿" 0 'post:^#3 failure .*0001.*0002' 'post:^#1 success' 'order:^#3 failure:^#1 success' 'greens<=1'

# ⑨ 没新增迁移的 PR 不挂状态
w=$(new_repo nomig)
branch "$w" issue/1-a main <<<'echo changed > README'
printf '1 issue/1-a ready\n' > "$(dirname "$w")/prs"
gate "$w"
check "没新增迁移的 PR 不挂" 0 posts=0

# ⑩ 自己新增的迁移分叉了 → 红
w=$(new_repo selffork)
branch "$w" issue/1-a main <<<'mig db/versions/0003.py 0003 0002; mig db/versions/0004.py 0004 0002'
printf '1 issue/1-a ready\n' > "$(dirname "$w")/prs"
gate "$w"
check "自己分叉：红" 0 'post:^#1 failure .*分叉'

# ⑪ 自己一条链 0003 <- 0004：绿，描述里有末端
w=$(new_repo chain)
branch "$w" issue/1-a main <<<'mig db/versions/0003.py 0003 0002; mig db/versions/0004.py 0004 0003'
printf '1 issue/1-a ready\n' > "$(dirname "$w")/prs"
gate "$w"
check "一条链：绿" 0 'post:^#1 success .*0004.*0002'

# ⑫ main 自己两个 head：普通 PR 红；把两个 head 合起来的合并迁移绿
w=$(new_repo twoheads)
(cd "$w" && mig db/versions/0003.py 0003 0002 && mig db/versions/0004.py 0004 0002 && git add -A && git commit -qm two && git push -q origin main)
branch "$w" issue/1-a main <<<'mig db/versions/0005.py 0005 0003'
branch "$w" issue/2-fix main <<<'mig db/versions/0005_merge.py 0005m "0003 0004"'
printf '1 issue/1-a ready\n2 issue/2-fix ready\n' > "$(dirname "$w")/prs"
gate "$w"
check "main 两个 head：合并迁移绿、其它红" 0 'post:^#1 failure .*2 个 head' 'post:^#2 success' 'greens<=1'

# ⑬ 与 main 同号、接在谁都没有的 revision 上 → 红
w=$(new_repo badparent)
branch "$w" issue/1-a main <<<'mig db/versions/9999_probe.py 0002 0002'
branch "$w" issue/2-b main <<<'mig db/versions/0003.py 0003 zzzz'
printf '1 issue/1-a ready\n2 issue/2-b ready\n' > "$(dirname "$w")/prs"
gate "$w"
check "与 main 同号 / 父迁移不存在：红" 0 'post:^#1 failure .*0002.*同号' 'post:^#2 failure .*zzzz' '!post:success'

# ⑭ 目标分支不是 main 的 PR 不归这道闸
w=$(new_repo otherbase)
branch "$w" issue/1-a main <<<'mig db/versions/0003.py 0003 0002'
printf '1 issue/1-a ready release\n' > "$(dirname "$w")/prs"
gate "$w"
check "目标不是 main 的 PR 不挂" 0 posts=0

# ⑮ --dry-run：每张都打印、一条都不发
w=$(new_repo dry)
branch "$w" issue/1-a main <<<'mig db/versions/0003_a.py 0003a 0002'
branch "$w" issue/2-b main <<<'mig db/versions/0003_b.py 0003b 0002'
printf '1 issue/1-a ready\n2 issue/2-b ready\n' > "$(dirname "$w")/prs"
gate "$w" --dry-run
check "--dry-run 只打印" 0 posts=0 'out:#1 success' 'out:#2 pending'

# ⑯ 描述不超过 140 字符：长 revision id 也截断，不让 GitHub 拒（假 gh 超长就失败）
w=$(new_repo longdesc)
L=$(printf 'r%.0s' {1..130})
branch "$w" issue/1-a main <<<"mig db/versions/x_a.py ${L}a 0001"
printf '1 issue/1-a ready\n' > "$(dirname "$w")/prs"
gate "$w"
check "描述截到 140 字符" 0 'post:^#1 failure' posts=1

# ⑰ gh 失败 → 退 9，一条都不发
w=$(new_repo ghfail)
branch "$w" issue/1-a main <<<'mig db/versions/0003.py 0003 0002'
printf '1 issue/1-a ready\n' > "$(dirname "$w")/prs"
FAKE_GH_FAIL=1 gate "$w"
check "gh 失败：退 9、不发" 9 posts=0

# ⑱ 没设 MIGRATION_DIR → 退 9（什么都不管却当成管了，正是要防的静默）
w=$(new_repo nodir)
d=$(dirname "$w"); : > "$d/posts"
out=$(cd "$w" && PATH="$root/bin:$PATH" FAKE_GH_DIR="$d" "$GATE" --no-fetch 2>&1); rc=$?
check "没设 MIGRATION_DIR：退 9" 9 posts=0

echo "---- $pass 过，$fail 败"
[ "$fail" -eq 0 ]
