#!/usr/bin/env bash
#
# scan-collisions.sh 的可重复测试。每个场景在临时目录里建一个最小仓库（一个裸 origin + 一份 clone），
# 造几个假迁移文件 / ADR，跑扫描，断言输出和退出码。不碰网络、不碰 gh、不读用户的 git 配置。
#
# 用法：dispatch/scripts/test-scan-collisions.sh            测同目录下的 scan-collisions.sh
#       SCAN=<别的脚本> LEGACY=1 test-scan-collisions.sh     测旧版（旧版不收 ref 参数，扫全部远端分支）
#
# 旧版在「分叉」「接在过时的 head 上」和「先占者保号」上判失败，见 dispatch/HISTORY.md #29。

set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="${SCAN:-$here/scan-collisions.sh}"
LEGACY="${LEGACY:-0}"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

root=$(mktemp -d) || exit 9
trap 'rm -rf "$root"' EXIT
pass=0 fail=0

mig() {  # $1=文件路径  $2=revision  $3=down_revision（None 或 id）
  local d; [ "$3" = None ] && d=None || d="\"$3\""
  mkdir -p "$(dirname "$1")"
  printf '"""x"""\nrevision: str = "%s"\ndown_revision: Union[str, None] = %s\n' "$2" "$d" > "$1"
}

export -f mig

# 新建一个仓库：main 上有迁移 0001 <- 0002，ADR 001、002。打印 clone 路径。
new_repo() {
  local name=$1 r="$root/$1"
  git init -q --bare -b main "$r/origin.git"
  git clone -q "$r/origin.git" "$r/w" 2>/dev/null
  (cd "$r/w" && git checkout -q -b main 2>/dev/null
   mig db/versions/0001.py 0001 None
   mig db/versions/0002.py 0002 0001
   mkdir -p adr && echo a > adr/001-a.md && echo b > adr/002-b.md
   git add -A && git commit -qm base && git push -q origin main)
  echo "$r/w"
}

branch() {  # $1=仓库  $2=分支名  $3=基点；之后从 stdin 读要执行的 shell（在仓库里），提交并 push
  (cd "$1" && git checkout -q -b "$2" "$3" && bash -e && git add -A && git commit -qm "$2" && git push -q origin "$2" && git checkout -q main)
}

scan() {  # $1=仓库  其余=ref；结果放进 $out / $rc
  local w=$1; shift
  if [ "$LEGACY" = 1 ]; then
    out=$(cd "$w" && MIGRATION_DIR=db/versions ADR_DIR=adr "$SCAN" --no-fetch 2>&1); rc=$?
  else
    out=$(cd "$w" && MIGRATION_DIR=db/versions ADR_DIR=adr "$SCAN" --no-fetch "$@" 2>&1); rc=$?
  fi
}

check() {  # $1=场景名  $2=期望退出码  其余=输出里必须出现的正则（前缀 ! = 必须不出现）
  local name=$1 want=$2 ok=1 why="" p; shift 2
  [ "$rc" = "$want" ] || { ok=0; why="退出码 $rc ≠ $want"; }
  for p in "$@"; do
    if [ "${p:0:1}" = '!' ]; then
      echo "$out" | grep -qE -- "${p:1}" && { ok=0; why="$why；不该出现 /${p:1}/"; }
    else
      echo "$out" | grep -qE -- "$p" || { ok=0; why="$why；缺 /$p/"; }
    fi
  done
  if [ $ok = 1 ]; then pass=$((pass + 1)); echo "PASS $name"; [ "${VERBOSE:-0}" = 1 ] && echo "$out" | sed "s/^/    | /"
  else fail=$((fail + 1)); echo "FAIL $name: ${why#；}"; echo "$out" | sed 's/^/    | /'; fi
}

# ① 正常：一条分支接在 main 的 head 上
w=$(new_repo normal)
branch "$w" issue/1-a main <<<'mig db/versions/0003.py 0003 0002'
scan "$w" origin/issue/1-a
check "正常一条分支" 0 '无撞号' '!🔴'

# ② 两条分支同号
w=$(new_repo same-id)
branch "$w" issue/1-a main <<<'mig db/versions/0003_a.py 0003 0002'
branch "$w" issue/2-b main <<<'mig db/versions/0003_b.py 0003 0002'
scan "$w" origin/issue/1-a origin/issue/2-b
check "两条分支同号" 1 '🔴.*0003.*issue/1-a.*issue/2-b|🔴.*0003.*issue/2-b.*issue/1-a' '先合并的保号' '!先占者保号'

# ③ 不同号、同一个 down_revision：合并后双头
w=$(new_repo fork)
branch "$w" issue/1-a main <<<'mig db/versions/0003.py 0003 0002'
branch "$w" issue/2-b main <<<'mig db/versions/0004.py 0004 0002'
scan "$w" origin/issue/1-a origin/issue/2-b
check "两条分支分叉" 1 '🔴.*分叉.*0002' '先合并的保号' '!先占者保号'

# ④ 分支接在过时的 head 上：main 已经前进到 0003，分支的 0004 还接 0002
w=$(new_repo stale)
branch "$w" issue/1-a main <<<'mig db/versions/0004.py 0004 0002'
(cd "$w" && mig db/versions/0003.py 0003 0002 && git add -A && git commit -qm m3 && git push -q origin main)
scan "$w" origin/issue/1-a
check "接在过时的 head 上" 1 '🔴.*issue/1-a.*0004.*0002.*0003'

# ⑤ ADR 同号不同文件名：两条分支之间，以及与 main 之间
w=$(new_repo adr)
branch "$w" issue/1-a main <<<'echo x > adr/003-x.md'
branch "$w" issue/2-b main <<<'echo y > adr/003-y.md'
branch "$w" issue/3-c main <<<'echo c > adr/002-c.md'
scan "$w" origin/issue/1-a origin/issue/2-b origin/issue/3-c
check "ADR 同号不同文件名" 1 '🔴.*ADR.*003.*003-x\.md.*003-y\.md|🔴.*ADR.*003.*003-y\.md.*003-x\.md' \
  '🔴.*ADR.*002.*002-c\.md.*002-b\.md|🔴.*ADR.*002.*002-b\.md.*002-c\.md' '!先占者保号'

# ⑥ 与 main 上的 revision 同号、文件名不同（git 合并不冲突）
w=$(new_repo vs-main)
branch "$w" issue/1-a main <<<'mig db/versions/9999_probe.py 0002 0002'
scan "$w" origin/issue/1-a
check "与 main 同 revision 不同文件" 1 '🔴.*0002.*9999_probe\.py'

if [ "$LEGACY" != 1 ]; then
  # ⑦ worktree 里未提交的迁移也算；worktree 所在分支即使也作为 ref 传进来，只报一次
  w=$(new_repo worktree)
  branch "$w" issue/1-a main <<<'mig db/versions/0003.py 0003 0002'
  (cd "$w" && git worktree add -q "$root/worktree/wt-b" -b issue/2-b main 2>/dev/null)
  mig "$root/worktree/wt-b/db/versions/0004.py" 0004 0002
  scan "$w" origin/issue/1-a --worktree "$root/worktree/wt-b"
  check "worktree 未提交的迁移" 1 '🔴.*分叉.*0002' 'issue/2-b'

  # ⑧ 同一条分支自己新增两个根（两个新迁移都接 main 的 head）
  w=$(new_repo two-roots)
  branch "$w" issue/1-a main <<<'mig db/versions/0003.py 0003 0002; mig db/versions/0004.py 0004 0002'
  scan "$w" origin/issue/1-a
  check "分支内部分叉" 1 '🔴.*issue/1-a.*分叉'

  # ⑨ 分支内一条链 0003 <- 0004 是正常的
  w=$(new_repo chain)
  branch "$w" issue/1-a main <<<'mig db/versions/0003.py 0003 0002; mig db/versions/0004.py 0004 0003'
  scan "$w" origin/issue/1-a
  check "分支内一条链" 0 '无撞号'

  # ⑩ 目录不存在 → 9（扫空会误报「无撞号」）
  w=$(new_repo baddir)
  out=$(cd "$w" && MIGRATION_DIR=nope "$SCAN" --no-fetch 2>&1); rc=$?
  check "目录不存在" 9

  # ⑪ 不认识的 ref → 9，不能当成没新增
  w=$(new_repo badref)
  scan "$w" origin/issue/does-not-exist
  check "不存在的 ref" 9
fi

echo "---- $pass 过，$fail 败"
[ "$fail" -eq 0 ]
