#!/usr/bin/env bash
#
# 稀缺顺序标识符撞号扫描 —— coordinator 巡检用（见 dispatch 技能 patrol.md「稀缺顺序标识符撞号」）。
#
# 为什么存在：两条分支各占一个数据库迁移号或 ADR 编号时，**文件路径不冲突，git 会干净地把两个都合进去**，
# 直到数据库升级报双头，或两份同号 ADR 同时躺在 ADR 目录里。分组时叮嘱每个 worker「别占号」失效过两次
# （一次迁移双头、一次 ADR 撞号）—— 检查必须落在 coordinator 已经会重复发生的巡检循环里。
#
# 查什么（只看每个来源相对基准**新增 / 改动**的文件，`git diff --name-only <基准>...<分支>`）：
#   迁移（Alembic 写法：文件里 `revision = '…'`、`down_revision = '…'` 或元组；按内容解析，不按文件名）
#     · 过时的 head：新增迁移链的根，`down_revision` 不是基准当前的 head —— 合并后双头。
#     · 分叉：两个来源的新迁移接在同一个点上（编号不同也一样）—— 两条都合并后双头。
#     · 同号：新 revision 与基准上的、或与另一个来源的相同（文件名不同 git 也不报冲突）。
#     · 分支内部：同一来源两个文件同号，或它自己的新迁移有两个末端。
#   ADR（编号只在文件名 `NNN-标题.md` 里）：与基准同号不同文件名、来源之间同号、来源内部同号。
#
# 来源（扫谁）：命令行给的 ref、`--worktree` 给的工作区（**未提交的也算**，撞号越早发现越便宜）、`--prs` 打开着的
# PR 的头分支。三者都没给时等于 `--prs`。同一条分支既有 worktree 又有 ref 时只扫 worktree（它更新）。
# 不扫「本机所有 worktree」：别的会话留下的旧 worktree 会刷满噪音（2026-10 前任 coordinator 只好在外面套
# `grep -v worktree-agent-`）。由调用方（scan-workers.sh）决定哪些 worktree 是在飞的。
#
# 退出码：0 = 无撞号；1 = 发现撞号；9 = 脚本自身出错（目录不存在、ref 解析不了、gh 失败……）。
# 三者分开，是因为巡检脚本崩溃和真实告警在退出码上分不出来时已经误报过两次。
#
# 用法：MIGRATION_DIR=<迁移目录> ADR_DIR=<ADR 目录> scan-collisions.sh [--no-fetch] [--base REF]
#                                                    [--prs] [--worktree PATH]... [REF]...
#   在要扫的仓库里（或其任一 worktree 里）运行。
#   MIGRATION_DIR / ADR_DIR  相对仓库根；不设 = 不扫那一类并在输出里说出来；两个都不设 = 退出 9
#                            （什么都不扫却报「无撞号」，正是要防的那种静默）。没有默认值是有意的：写死某个
#                            项目的路径，换到别的仓库就会目录不存在、扫空、报「无撞号」。
#   --base REF               基准，默认 origin/main（DEFAULT_REMOTE / DEFAULT_BRANCH 可改）
#   --no-fetch               不先 git fetch（调用方已 fetch 过时用）
#
# 输出：发现撞号的每一行以 🔴 开头，内容只取决于各分支的内容，不含时间戳 —— 调用方可以直接 diff 两次的 🔴 行。
#
# 旧版（2026-10-21 前）为什么换掉：只读 `revision`、从不读 `down_revision`，「编号不同但接在同一个点上」和
# 「接在过时的 head 上」两种双头都报「无撞号」；对每个 ref 把全部迁移文件逐个 `git show`，smart-manu-ops 上一次
# 34 秒、占满一个核；结尾提示「先占者保号」，和 patrol.md 的「先合并的保号」相反。可重复的对照见
# test-scan-collisions.sh（`SCAN=<旧版> LEGACY=1` 能复现旧版的失败）。

set -uo pipefail

DEFAULT_REMOTE="${DEFAULT_REMOTE:-origin}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
export MIGRATION_DIR="${MIGRATION_DIR:-}" ADR_DIR="${ADR_DIR:-}"

do_fetch=1
base="${DEFAULT_REMOTE}/${DEFAULT_BRANCH}"
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-fetch) do_fetch=0 ;;
    --base) shift; base="${1:-}" ;;
    --prs) args+=(--prs) ;;
    --worktree) shift; [ -d "${1:-}" ] || { echo "ERR: --worktree ${1:-} 不是目录" >&2; exit 9; }
                args+=(--worktree "$(cd "$1" && pwd)") ;;
    --days) shift; echo "ℹ --days 已不再使用（不再扫全部远端分支），忽略" >&2 ;;
    -*) echo "用法: $0 [--no-fetch] [--base REF] [--prs] [--worktree PATH]... [REF]..." >&2; exit 9 ;;
    *) args+=(--ref "$1") ;;
  esac
  shift
done
[ ${#args[@]} -gt 0 ] || args=(--prs)

here="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERR: 不在 git 仓库里" >&2; exit 9; }

if [ -z "$MIGRATION_DIR" ] && [ -z "$ADR_DIR" ]; then
  echo "ERR: MIGRATION_DIR 与 ADR_DIR 都没设——什么都不扫。至少设一个（相对仓库根的目录）" >&2
  exit 9
fi
for d in "$MIGRATION_DIR" "$ADR_DIR"; do
  [ -z "$d" ] && continue
  [ -d "$here/$d" ] || { echo "ERR: 目录 $d 在 $here 下不存在——路径写错会扫空、误报「无撞号」" >&2; exit 9; }
done

if [ "$do_fetch" -eq 1 ]; then
  # fetch 失败不致命：用本地缓存继续扫，但要说出来，免得把「没 fetch」读成「没撞号」
  git -C "$here" fetch "$DEFAULT_REMOTE" --quiet || echo "⚠ git fetch 失败，下面用的是本地缓存的 $base"
fi
git -C "$here" rev-parse --verify --quiet "$base^{commit}" >/dev/null || { echo "ERR: 没有 $base" >&2; exit 9; }

exec python3 - "$here" "$base" "$DEFAULT_REMOTE" "${args[@]}" <<'PY'
import os, re, subprocess, sys
from collections import defaultdict

repo, base, remote, *argv = sys.argv[1:]
MIG = os.environ["MIGRATION_DIR"].strip("/")
ADR = os.environ["ADR_DIR"].strip("/")

def die(msg):
    print("ERR: " + msg, file=sys.stderr)
    sys.exit(9)

def git(*a, cwd=repo, ok=(0,)):
    p = subprocess.run(["git", "-C", cwd, *a], capture_output=True, text=True)
    if p.returncode not in ok:
        die("git %s 失败: %s" % (" ".join(a), p.stderr.strip()))
    return p.stdout

REV = re.compile(r"""^revision\b[^=]*=\s*['"]([^'"]+)['"]""", re.M)
DOWN = re.compile(r"^down_revision\b[^=]*=\s*(.+)$", re.M)

def parse_mig(text):
    """(revision, [down_revision...])；不是迁移文件返回 None。"""
    m = REV.search(text)
    if not m:
        return None
    d = DOWN.search(text)
    downs = re.findall(r"""['"]([^'"]+)['"]""", d.group(1)) if d else []
    return m.group(1), downs

def is_mig(path):
    return bool(MIG) and os.path.dirname(path) == MIG and path.endswith(".py") \
        and not os.path.basename(path).startswith("__")

ADR_NAME = re.compile(r"^(\d+)-.*\.md$")
def adr_num(path):
    if not ADR or os.path.dirname(path) != ADR:
        return None
    m = ADR_NAME.match(os.path.basename(path))
    return m.group(1) if m else None

# ---------- 基准 ----------
base_sha = git("rev-parse", "--short=8", base).strip()
main_rev = {}            # revision -> 文件名
main_file_rev = {}       # 文件名 -> revision
downs_all = set()
if MIG:
    # 一次 git grep 读完基准上所有迁移文件的 revision / down_revision 两行
    out = git("grep", "-E", r"^(down_)?revision\b", base, "--", MIG + "/*.py", ok=(0, 1))
    per = defaultdict(str)
    for line in out.splitlines():
        _, path, text = line.split(":", 2)
        if is_mig(path):
            per[path] += text + "\n"
    for path, text in per.items():
        r = parse_mig(text)
        if r:
            main_rev[r[0]] = os.path.basename(path)
            main_file_rev[os.path.basename(path)] = r[0]
            downs_all.update(r[1])
main_heads = sorted(set(main_rev) - downs_all)
main_adr = defaultdict(set)
if ADR:
    for path in git("ls-tree", "--name-only", base, ADR + "/").splitlines():
        n = adr_num(path)
        if n:
            main_adr[int(n)].add(os.path.basename(path))

# ---------- 来源 ----------
sources = []             # (标签, 分支名, ("ref", ref) | ("wt", path))
wt_branches = set()
i = 0
want_prs = False
while i < len(argv):
    a = argv[i]
    if a == "--prs":
        want_prs = True
    elif a == "--worktree":
        wt = argv[i + 1]; i += 1
        common = lambda d: os.path.realpath(git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=d).strip())
        if common(wt) != common(repo):
            die("%s 不是本仓库的 worktree" % wt)
        br = git("rev-parse", "--abbrev-ref", "HEAD", cwd=wt).strip()
        if br == "HEAD":
            br = "detached@" + git("rev-parse", "--short", "HEAD", cwd=wt).strip()
        wt_branches.add(br)
        sources.append((br, br, ("wt", wt)))
    elif a == "--ref":
        sources.append((argv[i + 1], None, ("ref", argv[i + 1]))); i += 1
    i += 1
if want_prs:
    p = subprocess.run(["gh", "pr", "list", "--state", "open", "--limit", "200",
                        "--json", "headRefName", "--jq", ".[].headRefName"],
                       cwd=repo, capture_output=True, text=True)
    if p.returncode != 0:
        die("gh pr list 失败: " + p.stderr.strip())
    for h in p.stdout.split():
        sources.append((remote + "/" + h, None, ("ref", remote + "/" + h)))

seen, scanned = set(), []
for label, br, (kind, where) in sources:
    if kind == "ref":
        if subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", where + "^{commit}"],
                          capture_output=True).returncode != 0:
            die("ref %s 解析不了（没 fetch？分支已删？）—— 不能当成「没新增」" % where)
        short = where[len(remote) + 1:] if where.startswith(remote + "/") else where
        if short in wt_branches or where in wt_branches:
            continue                      # 同一条分支的 worktree 已经在扫，它更新
        key = git("rev-parse", where).strip()
    else:
        key = where
    if key in seen:
        continue
    seen.add(key)
    scanned.append((label, kind, where))

dirs = [d for d in (MIG, ADR) if d]
mig_new = {}             # 标签 -> [(文件名, revision, downs)]
adr_new = {}             # 标签 -> [(编号, 文件名)]
for label, kind, where in scanned:
    files = {}
    if kind == "ref":
        for path in git("diff", "--name-only", "--diff-filter=AMR", base + "..." + where, "--", *dirs).splitlines():
            if is_mig(path):
                files[path] = git("show", where + ":" + path)
            elif adr_num(path):
                files[path] = ""
    else:
        mb = git("merge-base", base, "HEAD", cwd=where).strip()
        paths = git("diff", "--name-only", "--diff-filter=AMR", mb, "--", *dirs, cwd=where).splitlines()
        paths += git("ls-files", "--others", "--exclude-standard", "--", *dirs, cwd=where).splitlines()
        for path in paths:
            if is_mig(path):
                with open(os.path.join(where, path), encoding="utf-8", errors="replace") as f:
                    files[path] = f.read()
            elif adr_num(path):
                files[path] = ""
    ms, ads = [], []
    for path, text in sorted(files.items()):
        name = os.path.basename(path)
        if is_mig(path):
            r = parse_mig(text)
            if r and main_file_rev.get(name) != r[0]:     # 改了基准上已有的迁移、号没变 = 正常继承
                ms.append((name, r[0], r[1]))
        else:
            n = adr_num(path)
            if name not in main_adr.get(int(n), ()):
                ads.append((int(n), name))
    mig_new[label], adr_new[label] = ms, ads

# ---------- 报告 ----------
print("基准 %s@%s：迁移 head %s，ADR 最大 %s" % (
    base, base_sha, "、".join(main_heads) if MIG else "（未设 MIGRATION_DIR，不扫）",
    ("%03d" % max(main_adr)) if main_adr else ("无" if ADR else "（未设 ADR_DIR，不扫）")))
for label, _, _ in scanned:
    m = " ".join(r for _, r, _ in mig_new[label])
    a = " ".join("%03d" % n for n, _ in adr_new[label])
    if m or a:
        print("  %-40s 新增 迁移:[%s] ADR:[%s]" % (label, m, a))
if not scanned:
    print("  （没有要扫的来源）")
print()

hits = []
H = "、".join(main_heads)
if MIG and len(main_heads) > 1:
    hits.append("迁移：%s 自己就有 %d 个 head（%s）—— 先在主干上补一个合并迁移" % (base, len(main_heads), H))

all_new_rev = defaultdict(list)          # revision -> [(标签, 文件名)]
for label, ms in mig_new.items():
    for name, r, _ in ms:
        all_new_rev[r].append((label, name))

forks = defaultdict(list)                # 接入点 -> [(标签, 根 revision, 末端)]
for label, ms in mig_new.items():
    if not ms:
        continue
    revs = {r for _, r, _ in ms}
    for name, r, _ in ms:
        if r in main_rev:
            hits.append("迁移 revision %s：%s 的 %s 与 %s 上的 %s 同号 —— 文件名不同，git 合并不冲突，两个都会进去"
                        % (r, label, name, base, main_rev[r]))
    dup = defaultdict(list)
    for name, r, _ in ms:
        dup[r].append(name)
    for r, names in sorted(dup.items()):
        if len(names) > 1:
            hits.append("迁移 revision %s：%s 内部 %d 个文件同号（%s）" % (r, label, len(names), "、".join(names)))
    used = {d for _, _, ds in ms for d in ds}
    tips = sorted(revs - used)
    if len(tips) > 1:
        hits.append("迁移：%s 自己新增的迁移分叉了，有 %d 个末端（%s）—— 合并后多个 head，要串成一条链"
                    % (label, len(tips), "、".join(tips)))
    tip = tips[0] if len(tips) == 1 else "/".join(tips)
    for name, r, ds in ms:
        ext = [d for d in ds if d not in revs] or ([] if ds else ["None"])
        if ds and not ext:
            continue                     # 链中间的一环
        for d in ext:
            if d in main_heads:
                forks[d].append((label, r, tip))
            elif d in main_rev or d == "None":
                hits.append("迁移：%s 的 %s（revision %s）接在 %s 上，但 %s 的 head 已是 %s —— 合并后双头；把它的 "
                            "down_revision 改成 %s，号排在 %s 后面" % (label, name, r, d, base, H, H, H))
                forks[d].append((label, r, tip))
            elif d in all_new_rev:
                owners = "、".join(l for l, _ in all_new_rev[d] if l != label)
                print("ℹ %s 的 %s 接在 %s 新增的 %s 上 —— 需按序合并（先合 %s）" % (label, r, owners, d, owners))
            else:
                hits.append("迁移：%s 的 %s（revision %s）接在 %s 上，但 %s 和任何在扫的分支里都没有这个 revision"
                            % (label, name, r, d, base))

for r, owners in sorted(all_new_rev.items()):
    labels = sorted({l for l, _ in owners})
    if len(labels) > 1:
        hits.append("迁移 revision %s 被多处占用: %s" % (r, " ".join("%s(%s)" % o for o in sorted(owners))))

for point, who in sorted(forks.items()):
    labels = sorted({w[0] for w in who})
    if len(labels) < 2:
        continue
    desc = "、".join("%s 的 %s" % (l, r) for l, r, _ in sorted(who))
    who = sorted(who)
    plan = "；".join("若 %s 先合并：%s 改接 %s、号排其后" % (
        l, "、".join("%s 的 %s" % (l2, r2) for l2, r2, _ in who if l2 != l), t) for l, _, t in who)
    hits.append("迁移分叉于 %s：%s 都接在它上面 —— 都合并后有多个 head。先合并的保号，后合并的把根迁移的 "
                "down_revision 改接到先合并那条的末端（%s）" % (point, desc, plan))

if ADR:
    for label, ads in adr_new.items():
        cnt = defaultdict(list)
        for n, name in ads:
            cnt[n].append(name)
            if n in main_adr:
                hits.append("ADR 编号 %03d：%s 的 %s 与 %s 上的 %s 同号 —— 文件名不同，git 合并不冲突，两个都会进去"
                            % (n, label, name, base, "、".join(sorted(main_adr[n]))))
        for n, names in sorted(cnt.items()):
            if len(names) > 1:
                hits.append("ADR 编号 %03d：%s 内部 %d 个文件同号（%s）" % (n, label, len(names), "、".join(names)))
    by_num = defaultdict(set)
    for label, ads in adr_new.items():
        for n, name in ads:
            by_num[n].add((label, name))
    for n, owners in sorted(by_num.items()):
        if len({l for l, _ in owners}) > 1:
            hits.append("ADR 编号 %03d 被多处占用: %s" % (n, " ".join("%s(%s)" % o for o in sorted(owners))))

if not hits:
    print("  ✅ 无撞号")
    sys.exit(0)
for h in hits:
    print("  🔴 " + h)
print()
print("  处理：先合并的保号，后合并的让路 —— 让路的一方改号（迁移还要把 down_revision 改接到那时的 head）；")
print("  改掉的号若已被任务记录引用，连带更新引用。来历见 dispatch 技能 patrol.md「稀缺顺序标识符撞号」。")
sys.exit(1)
PY
