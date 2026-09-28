#!/usr/bin/env bash
#
# 稀缺顺序标识符撞号扫描 —— coordinator 巡检用（见 dispatch 技能 patrol.md「稀缺顺序标识符撞号」）。
#
# 为什么存在：两条分支各占一个数据库迁移号或 ADR 编号时，**文件路径不冲突，git 会干净地把
# 两个都合进去**，直到数据库升级报双头，或两份同号 ADR（例如两个 ADR-094）同时躺在 ADR 目录里。
# 分组时叮嘱每个 worker「别占号」失效过两次（一次迁移双头、一次 ADR 撞号）—— 检查必须落在
# coordinator 已经会重复发生的巡检循环里。
#
# 扫 DEFAULT_REMOTE/DEFAULT_BRANCH（默认 origin/main）+ 本机所有 worktree + 未合并进主干的远端分支，报三类：
#   ① 两条分支各自新增了同一个 id；
#   ② 某条分支的 id 与主干上某个相同、**但文件名不同** —— 这一种 git 完全看不见，最危险；
#   ③ 同一条分支内部两个文件撞同一个 id。
#
# 迁移号按**文件内容里的 `revision = '...'`** 解析（Python 迁移文件的这种写法），不按文件名
# （文件名不同而 id 相同正是 ② ）。别的迁移工具，改下面的 parse_rev。
# ADR 号只能按文件名解析（`NNN-标题.md`，编号不在正文里），所以 ② 对 ADR 同样成立且同样只有这里能抓到。
# 扫的是各 worktree 的**工作区文件**（未提交的也算），撞号越早发现越便宜。
#
# 退出码：0 = 无撞号；1 = 发现撞号；9 = 脚本自身出错。
# 三者分开，是因为巡检脚本崩溃和真实告警在退出码上分不出来时已经误报过两次。
#
# 用法：MIGRATION_DIR=<迁移目录> ADR_DIR=<ADR 目录> scan-collisions.sh [--no-fetch] [--days N]
#       N = 远端分支的新鲜度窗口，默认 2 天
# 环境变量：
#   MIGRATION_DIR  迁移文件目录（相对仓库根），不设 = 不扫迁移号，并在输出里说出来
#   ADR_DIR        ADR 目录（相对仓库根），不设 = 不扫 ADR 编号，并在输出里说出来
#                  两个都不设 = 报错退出 9：什么都不扫却报「无撞号」，正是要防的那种静默
#   DEFAULT_REMOTE=origin  DEFAULT_BRANCH=main
# 两个目录没有默认值是有意的：写死某个项目的路径，换到别的仓库就会目录不存在、扫空、报「无撞号」。

set -uo pipefail

DEFAULT_REMOTE="${DEFAULT_REMOTE:-origin}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
MIGRATION_DIR="${MIGRATION_DIR:-}"
ADR_DIR="${ADR_DIR:-}"

do_fetch=1
days=2
while [ $# -gt 0 ]; do
  case "$1" in
    --no-fetch) do_fetch=0 ;;
    --days) shift; days="${1:-2}" ;;
    *) echo "用法: $0 [--no-fetch] [--days N]" >&2; exit 9 ;;
  esac
  shift
done
case "$days" in ''|*[!0-9]*) echo "ERR: --days 要一个整数" >&2; exit 9 ;; esac

here="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [ -z "$here" ]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  here="$(git -C "$here" rev-parse --show-toplevel 2>/dev/null || echo "")"
fi
[ -n "$here" ] || { echo "ERR: 不在 git 仓库里" >&2; exit 9; }

if [ -z "$MIGRATION_DIR" ] && [ -z "$ADR_DIR" ]; then
  echo "ERR: MIGRATION_DIR 与 ADR_DIR 都没设——什么都不扫。至少设一个（相对仓库根的目录）" >&2
  exit 9
fi
for d in "$MIGRATION_DIR" "$ADR_DIR"; do
  [ -z "$d" ] && continue
  [ -d "$here/$d" ] || { echo "ERR: 目录 $d 在 $here 下不存在——路径写错会扫空、误报「无撞号」" >&2; exit 9; }
done

target_base="${DEFAULT_REMOTE}/${DEFAULT_BRANCH}"

if [ "$do_fetch" -eq 1 ]; then
  # fetch 失败不致命：用本地缓存的主干分支继续扫，但要说出来，免得把「没 fetch」读成「没撞号」
  git -C "$here" fetch "$DEFAULT_REMOTE" --quiet || echo "⚠ git fetch 失败，下面用的是本地缓存的 $target_base" >&2
fi
git -C "$here" rev-parse --verify --quiet "$target_base" >/dev/null || { echo "ERR: 没有 $target_base" >&2; exit 9; }

tmp=$(mktemp -d) || exit 9
trap 'rm -rf "$tmp"' EXIT

# 从一个迁移文件里解析 revision id（兼容单双引号）
parse_rev() {
  sed -nE "s/^revision[^=]*=[[:space:]]*['\"]([^'\"]+)['\"].*/\1/p" "$1" 2>/dev/null | head -1
}

# ---------- 主干上已有的号：id <TAB> 文件名 ----------
: > "$tmp/main_rev"
: > "$tmp/main_adr"

: > "$tmp/main_mig_files"
[ -n "$MIGRATION_DIR" ] && { git -C "$here" ls-tree -r --name-only "$target_base" -- "$MIGRATION_DIR/" 2>/dev/null \
  | grep -E '\.py$' | grep -v '__init__' > "$tmp/main_mig_files" || true; }

while read -r f; do
  [ -n "$f" ] || continue
  git -C "$here" show "$target_base:$f" > "$tmp/one.py" 2>/dev/null || continue
  r=$(parse_rev "$tmp/one.py")
  [ -n "$r" ] && printf '%s\t%s\n' "$r" "$(basename "$f")" >> "$tmp/main_rev"
done < "$tmp/main_mig_files"

[ -n "$ADR_DIR" ] && { git -C "$here" ls-tree -r --name-only "$target_base" -- "$ADR_DIR/" 2>/dev/null \
  | grep -oE '[0-9]{3}-[^/]*\.md$' \
  | while read -r b; do printf '%s\t%s\n' "${b:0:3}" "$b"; done > "$tmp/main_adr" || true; }

main_file_for() {  # $1=main_rev|main_adr  $2=id
  awk -F'\t' -v id="$2" '$1==id {print $2; exit}' "$tmp/$1"
}

# ---------- 收集各来源相对主干新增的号 ----------
: > "$tmp/new_rev"      # id <TAB> 来源 <TAB> 文件名
: > "$tmp/new_adr"
: > "$tmp/vs_main"      # 类别 <TAB> id <TAB> 来源 <TAB> 分支文件名 <TAB> 主干文件名
: > "$tmp/report"

record() {  # $1=rev|adr  $2=id  $3=来源  $4=文件名
  local mf
  mf=$(main_file_for "main_$1" "$2")
  if [ -n "$mf" ]; then
    [ "$mf" = "$4" ] && return 0                       # 主干上就是这个文件，正常继承
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$mf" >> "$tmp/vs_main"
    return 0
  fi
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" >> "$tmp/new_$1"
}

scan_worktree() {  # $1=路径  $2=来源标签
  local wt="$1" src="$2" f r n
  if [ -n "$MIGRATION_DIR" ] && [ -d "$wt/$MIGRATION_DIR" ]; then
    for f in "$wt"/$MIGRATION_DIR/*.py; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in __init__.py) continue ;; esac
      r=$(parse_rev "$f"); [ -n "$r" ] || continue
      record rev "$r" "$src" "$(basename "$f")"
    done
  fi
  if [ -n "$ADR_DIR" ] && [ -d "$wt/$ADR_DIR" ]; then
    for f in "$wt"/$ADR_DIR/[0-9][0-9][0-9]-*.md; do
      [ -f "$f" ] || continue
      n=$(basename "$f")
      record adr "${n:0:3}" "$src" "$n"
    done
  fi
}

scan_ref() {  # $1=ref  $2=来源标签
  local ref="$1" src="$2" f r n
  : > "$tmp/ref_mig"; : > "$tmp/ref_adr"
  [ -n "$MIGRATION_DIR" ] && { git -C "$here" ls-tree -r --name-only "$ref" -- "$MIGRATION_DIR/" 2>/dev/null \
    | grep -E '\.py$' | grep -v '__init__' > "$tmp/ref_mig" || true; }
  while read -r f; do
    [ -n "$f" ] || continue
    git -C "$here" show "$ref:$f" > "$tmp/one.py" 2>/dev/null || continue
    r=$(parse_rev "$tmp/one.py"); [ -n "$r" ] || continue
    record rev "$r" "$src" "$(basename "$f")"
  done < "$tmp/ref_mig"

  [ -n "$ADR_DIR" ] && { git -C "$here" ls-tree -r --name-only "$ref" -- "$ADR_DIR/" 2>/dev/null \
    | grep -oE '[0-9]{3}-[^/]*\.md$' > "$tmp/ref_adr" || true; }
  while read -r n; do
    [ -n "$n" ] || continue
    record adr "${n:0:3}" "$src" "$n"
  done < "$tmp/ref_adr"
}

echo "===== 撞号扫描 $(date '+%F %H:%M:%S') ====="
[ -n "$MIGRATION_DIR" ] || echo "ℹ 未设 MIGRATION_DIR：本次不扫迁移号"
[ -n "$ADR_DIR" ] || echo "ℹ 未设 ADR_DIR：本次不扫 ADR 编号"
echo "$target_base: 迁移最大 $(cut -f1 "$tmp/main_rev" | sort | tail -1)  ADR 最大 $(cut -f1 "$tmp/main_adr" | sort | tail -1)"
echo

# 本机 worktree（含主 checkout —— 它也可能停在一条领先主干的分支上）
git -C "$here" worktree list --porcelain | sed -n 's/^worktree //p' > "$tmp/wts"
while read -r wt; do
  [ -d "$wt" ] || continue
  br=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null) || continue
  [ "$br" = "HEAD" ] && br="detached@$(git -C "$wt" rev-parse --short HEAD 2>/dev/null)"
  before_r=$(wc -l < "$tmp/new_rev"); before_a=$(wc -l < "$tmp/new_adr")
  scan_worktree "$wt" "$br"
  nr=$(awk -F'\t' -v n="$before_r" 'NR>n {printf "%s ", $1}' "$tmp/new_rev")
  na=$(awk -F'\t' -v n="$before_a" 'NR>n {printf "%s ", $1}' "$tmp/new_adr")
  [ -n "$nr$na" ] && printf "  %-38s 迁移:[%s] ADR:[%s]\n" "$br" "${nr% }" "${na% }"
done < "$tmp/wts"

# 未合并进主干的远端分支 —— worktree 被删掉、交付物还开着的那些，号照样被占着。
# 只看最近 $days 天有提交的：更老的分支多半是废弃的，而废弃分支里的历史撞号（曾有一个仓库改过一次
# 迁移文件命名，老分支里 `<日期>_0046_*.py` 与主干的 `0046.py` 同 id）会刷满屏，把真信号埋掉。
# 2 天这个口径取自一个工作流判占住「陈旧」用的线（换了工作流就对齐它的口径，用 --days N）。
cutoff=$(( $(date +%s) - days * 86400 ))
skipped_old=0
git -C "$here" for-each-ref --format='%(committerdate:unix) %(refname:short)' "refs/remotes/${DEFAULT_REMOTE}" \
  | grep -v " ${target_base}\$" | grep -v " ${DEFAULT_REMOTE}\$" > "$tmp/allrefs" || true
: > "$tmp/refs"
while read -r ts ref; do
  [ -n "${ref:-}" ] || continue
  git -C "$here" merge-base --is-ancestor "$ref" "$target_base" 2>/dev/null && continue
  if [ "$ts" -lt "$cutoff" ]; then skipped_old=$((skipped_old + 1)); continue; fi
  echo "$ref" >> "$tmp/refs"
done < "$tmp/allrefs"
[ "$skipped_old" -gt 0 ] && echo "  （跳过 $skipped_old 条 $days 天内无提交的未合并远端分支，用 --days N 放宽）"
while read -r ref; do
  [ -n "$ref" ] || continue
  short=${ref#${DEFAULT_REMOTE}/}
  grep -qxF "$short" <(git -C "$here" worktree list --porcelain | sed -n 's/^branch refs\/heads\///p') && continue
  before_r=$(wc -l < "$tmp/new_rev"); before_a=$(wc -l < "$tmp/new_adr")
  scan_ref "$ref" "$ref"
  nr=$(awk -F'\t' -v n="$before_r" 'NR>n {printf "%s ", $1}' "$tmp/new_rev")
  na=$(awk -F'\t' -v n="$before_a" 'NR>n {printf "%s ", $1}' "$tmp/new_adr")
  [ -n "$nr$na" ] && printf "  %-38s 迁移:[%s] ADR:[%s]\n" "$ref" "${nr% }" "${na% }"
done < "$tmp/refs"

echo
hit=0

# ①③ 同一个新号被多处占用（不同分支，或同一分支两个文件）
for kind in rev adr; do
  [ -s "$tmp/new_$kind" ] || continue
  label="迁移 revision"; [ "$kind" = adr ] && label="ADR 编号"
  sort -u "$tmp/new_$kind" | awk -F'\t' -v L="$label" '
    { c[$1]++; w[$1] = w[$1] " " $2 "(" $3 ")" }
    END { for (k in c) if (c[k] > 1) print "  🔴 " L " " k " 被多处占用:" w[k] }
  ' | sort > "$tmp/out"
  [ -s "$tmp/out" ] && { cat "$tmp/out"; hit=1; }
done

# ② 与主干上同号但文件名不同 —— git 合并时路径不冲突，两个文件都会进去
if [ -s "$tmp/vs_main" ]; then
  awk -F'\t' -v target_base="$target_base" '
    { L = ($1 == "adr" ? "ADR 编号" : "迁移 revision")
      print "  🔴 " L " " $2 " 与 " target_base " 上的 " $5 " 同号，但来源是 " $3 " 的 " $4 \
            " —— 文件名不同，git 合并不冲突，两个都会进去" }
  ' "$tmp/vs_main" | sort -u
  hit=1
fi

[ "$hit" -eq 0 ] && { echo "  ✅ 无撞号"; exit 0; }
echo
echo "  处理：先占者保号，协调后占的一方改号；改号若涉及已被任务记录引用的编号，连带更新引用。"
exit 1
