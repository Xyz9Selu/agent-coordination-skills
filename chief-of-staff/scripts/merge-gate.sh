#!/usr/bin/env bash
#
# 迁移闸 —— 给新增了数据库迁移的打开 PR 的 head 提交挂一个 commit status（默认 context `migration-chain`），让用户在
# PR 页面上就看得出「这张现在能不能合」。幕僚长巡检用（见 chief-of-staff 技能 patrol.md「迁移闸」）；scan-workers.sh
# 每轮调它。
#
# 为什么存在：scan-collisions.sh 扫得出分叉，但只报给幕僚长，管不到合并按钮——两张接在同一个父迁移上的 PR 曾在同一
# 分钟里被先后合并，main 出现两个 head（见 chief-of-staff/HISTORY.md #40）。私有仓库在免费账号上设不了必需检查
# （branch protection / rulesets 返回 403），所以这里只亮灯，拦不住按钮。
#
# 规则 —— 同一时刻，新增了迁移的打开 PR 里最多一张是绿的：
#   绿 success  新迁移是一条线性链，根接在 main 唯一的 head 上（main 有几个 head 时，只有恰好把它们全接上的合并迁移
#               才算接上），不是 draft，并且在「接在同一个点上、可以合」的几张里排第一。
#   排第一      已经亮绿的那张保持绿；没有亮绿的，PR 号小的先。（「已亮绿」读的是 GitHub 上它当前 head 的状态，
#               不靠本地记录。推了新提交就没有了，重新排。）
#   黄 pending  链没毛病，只是要等：排在别的 PR 后面（同接一个点，或接在别的 PR 新增的迁移上），或者还是 draft。
#   红 failure  现在就得改：接在过时的 head 上、自己的新迁移分叉 / 同号、与 main 同号、接在谁都没有的 revision 上、
#               main 自己有多个 head。描述里写清改成什么。
#   不挂        没新增迁移的 PR（它碰不到链）；目标分支不是 DEFAULT_BRANCH 的 PR。
# 用户只要记一条：新增了迁移的 PR，绿的才合；没有这个状态的也先别合（刚推的提交，或幕僚长没在巡检）。不管先合哪张
# 绿的都安全：合并后其余几张要么还接在旧 head 上（下一轮变红，等改接），要么接在刚合进去的那张上（下一轮变绿）。
#
# 写：只写 commit status，不发 PR 评论。状态（state + 描述）没变就不发；先发所有不是绿的，最后才发绿的——中途失败也
# 不会出现两张绿。描述截到 140 字符（GitHub 的上限，超了 422）。
#
# 退出码：0 = 算完了（发没发都算）；9 = 出错（gh / git 失败、目录不对）。出错时还没发的就不发了，下一轮重算。
# 输出：每发一条状态打一行「#N state 描述」，没变化就没有输出——scan-workers.sh 把每一行当一个 GATE 事件。
#
# 用法：MIGRATION_DIR=<迁移目录> merge-gate.sh [--no-fetch] [--dry-run]
#   在要管的仓库里（或其任一 worktree 里）运行；要 gh 已登录、仓库在 GitHub 上。
#   MIGRATION_DIR    相对仓库根；必填，没有默认值（写死某个项目的路径，换到别的仓库会扫空、什么都不挂）
#   --dry-run        只算不写：每张新增了迁移的 PR 打一行「#N state 描述（不变 / 会改）」
#   --no-fetch       不先 git fetch（调用方已 fetch 过时用）
#   GATE_CONTEXT=migration-chain   status 的 context
#   DEFAULT_REMOTE=origin  DEFAULT_BRANCH=main
# 迁移按文件内容解析（Alembic：`revision = '…'`、`down_revision = '…'` 或元组），规则与 scan-collisions.sh 相同，
# 改一处要连另一处一起改。

set -uo pipefail

DEFAULT_REMOTE="${DEFAULT_REMOTE:-origin}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
export MIGRATION_DIR="${MIGRATION_DIR:-}" GATE_CONTEXT="${GATE_CONTEXT:-migration-chain}"

do_fetch=1 dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-fetch) do_fetch=0 ;;
    --dry-run) dry=1 ;;
    *) echo "用法: MIGRATION_DIR=<迁移目录> $0 [--no-fetch] [--dry-run]" >&2; exit 9 ;;
  esac
  shift
done

here="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERR: 不在 git 仓库里" >&2; exit 9; }
[ -n "$MIGRATION_DIR" ] || { echo "ERR: 没设 MIGRATION_DIR——不知道迁移在哪，什么都不挂" >&2; exit 9; }
[ -d "$here/$MIGRATION_DIR" ] || { echo "ERR: 目录 $MIGRATION_DIR 在 $here 下不存在" >&2; exit 9; }
base="$DEFAULT_REMOTE/$DEFAULT_BRANCH"
if [ "$do_fetch" -eq 1 ]; then
  git -C "$here" fetch -q "$DEFAULT_REMOTE" || { echo "ERR: git fetch 失败——用旧的 $base 算会把过时的绿灯留着" >&2; exit 9; }
fi
git -C "$here" rev-parse --verify --quiet "$base^{commit}" >/dev/null || { echo "ERR: 没有 $base" >&2; exit 9; }

exec python3 - "$here" "$base" "$DEFAULT_REMOTE" "$DEFAULT_BRANCH" "$dry" <<'PY'
import json, os, re, subprocess, sys
from collections import defaultdict

repo, base, remote, branch, dry = sys.argv[1:]
dry = dry == "1"
MIG = os.environ["MIGRATION_DIR"].strip("/")
CTX = os.environ["GATE_CONTEXT"]

def die(msg):
    print("ERR: " + msg, file=sys.stderr)
    sys.exit(9)

def run(cmd, ok=(0,)):
    p = subprocess.run(cmd, cwd=repo, capture_output=True, text=True)
    if p.returncode not in ok:
        die("%s 失败: %s" % (" ".join(cmd[:3]), (p.stderr or p.stdout).strip()[:300]))
    return p.stdout

def git(*a, ok=(0,)):
    return run(["git", *a], ok)

REV = re.compile(r"""^revision\b[^=]*=\s*['"]([^'"]+)['"]""", re.M)
DOWN = re.compile(r"^down_revision\b[^=]*=\s*(.+)$", re.M)

def parse_mig(text):
    m = REV.search(text)
    if not m:
        return None
    d = DOWN.search(text)
    return m.group(1), (re.findall(r"""['"]([^'"]+)['"]""", d.group(1)) if d else [])

def is_mig(path):
    return os.path.dirname(path) == MIG and path.endswith(".py") and not os.path.basename(path).startswith("__")

# ---------- main 上的迁移 ----------
main_rev, main_file_rev, downs_all = {}, {}, set()
per = defaultdict(str)
for line in git("grep", "-E", r"^(down_)?revision\b", base, "--", MIG + "/*.py", ok=(0, 1)).splitlines():
    _, path, text = line.split(":", 2)
    if is_mig(path):
        per[path] += text + "\n"
for path, text in per.items():
    r = parse_mig(text)
    if r:
        main_rev[r[0]] = os.path.basename(path)
        main_file_rev[os.path.basename(path)] = r[0]
        downs_all.update(r[1])
heads = sorted(set(main_rev) - downs_all)
H = "、".join(heads) or "（无）"

# ---------- 打开的 PR 与它们新增的迁移 ----------
prs = json.loads(run(["gh", "pr", "list", "--state", "open", "--limit", "200",
                      "--json", "number,headRefName,headRefOid,isDraft,baseRefName,url"]) or "[]")
prs = [p for p in prs if p.get("baseRefName", branch) == branch]
new = {}                                   # 号 -> [(文件名, revision, downs)]
for p in prs:
    n, sha = p["number"], p["headRefOid"]
    if subprocess.run(["git", "-C", repo, "cat-file", "-e", sha + "^{commit}"], capture_output=True).returncode:
        git("fetch", "-q", remote, "refs/pull/%d/head" % n)      # 别的 fork 来的、或这一轮还没 fetch 到
    ms = []
    for path in git("diff", "--name-only", "--diff-filter=AMR", base + "..." + sha, "--", MIG).splitlines():
        if not is_mig(path):
            continue
        r = parse_mig(git("show", sha + ":" + path))
        if r and main_file_rev.get(os.path.basename(path)) != r[0]:   # 同名同号 = main 上已有（例如被 squash 合进去的）
            ms.append((os.path.basename(path), r[0], r[1]))
    if ms:
        new[n] = ms
byn = {p["number"]: p for p in prs}
def shape(ms):
    """(末端, 根)。一条线性链 = 恰好一个末端、一个根。"""
    rs = {r for _, r, _ in ms}
    return (sorted(rs - {d for _, _, ds in ms for d in ds}),
            [(f, r, ds) for f, r, ds in ms if not ds or any(d not in rs for d in ds)])

# 分支从另一张 PR 拉出来时，会带着那张的迁移（同名同号）。同号、分叉按整条分支判（它合进 main 带进去的就是这些）；
# 找接入点时只看它自己多出来的那段，根自然接在那张新增的 revision 上 —— 下面判成「排在那张后面」。多出来的那段
# 不成一条链（或什么都不剩），就按整条判。
pairs = {n: {(f, r) for f, r, _ in ms} for n, ms in new.items()}
own = {}
for n, ms in new.items():
    inherited = set().union(*[pairs[m] for m in pairs if m != n and pairs[m] < pairs[n]])
    rest = [x for x in ms if (x[0], x[1]) not in inherited]
    t, r = shape(rest)
    own[n] = rest if len(t) == 1 and len(r) == 1 else ms
owner_of = defaultdict(set)                # revision -> {号}（只算各自多出来的）
for n, ms in own.items():
    for _, r, _ in ms:
        owner_of[r].add(n)

# ---------- 每张的判定 ----------
def nums(ns):
    return " ".join("#%d" % x for x in sorted(ns))

verdict, eligible, chain_of, tip_of, file_of = {}, [], {}, {}, {}
for n in sorted(new):
    ms, p = new[n], byn[n]
    revs = [r for _, r, _ in ms]
    rs = set(revs)
    dup = sorted({r for r in revs if revs.count(r) > 1})
    clash = [(r, main_rev[r]) for r in sorted(rs) if r in main_rev]
    tips, roots = shape(ms)
    if dup:
        verdict[n] = ("failure", "自己有几个文件同号（%s），改号" % "、".join(dup), None)
        continue
    if clash:
        verdict[n] = ("failure", "revision %s 与 main 上的 %s 同号，改号" % clash[0], None)
        continue
    if len(tips) != 1 or len(roots) != 1:
        verdict[n] = ("failure", "自己新增的迁移分叉了（末端 %s），串成一条链" % "、".join(tips or ["?"]), None)
        continue
    ms = own[n]
    rs = {r for _, r, _ in ms}
    tips, roots = shape(ms)
    f, root, ds = roots[0]
    attach = sorted({d for d in ds if d not in rs})
    tip = tips[0]
    chain = root if root == tip else "%s…%s" % (root, tip)
    chain_of[n], tip_of[n], file_of[n] = chain, tip, f
    on = "、".join(attach) or "None"
    if attach == heads:
        if p["isDraft"]:
            verdict[n] = ("pending", "draft：链没问题（%s 接在 main 的 head %s 上），转正后再排队" % (chain, H), None)
        else:
            eligible.append(n)
        continue
    stacked = sorted({o for a in attach for o in owner_of.get(a, ()) if o != n})
    if stacked:
        verdict[n] = ("pending", "排在 %s 后面：%s 接在它新增的 %s 上，那张合并后再排" % (nums(stacked), chain, on),
                      byn[stacked[0]].get("url"))
    elif attach and all(a in main_rev for a in attach):
        if len(heads) > 1:
            verdict[n] = ("failure", "main 自己有 %d 个 head（%s），先合把它们接起来的合并迁移" % (len(heads), H), None)
        else:
            verdict[n] = ("failure", "%s 接在 %s 上，main 的 head 是 %s：把 %s 的 down_revision 改成 %s"
                          % (chain, on, H, f, H), None)
    elif not attach and heads:
        verdict[n] = ("failure", "%s 的 down_revision 是 None，main 的 head 是 %s：改接到 %s" % (chain, H, H), None)
    else:
        missing = "、".join(a for a in attach if a not in main_rev and a not in owner_of)
        verdict[n] = ("failure", "%s 接在 %s 上，main 和打开的 PR 里都没有这个 revision" % (chain, missing or on), None)

# ---------- 现在挂着的状态 ----------
cur = {}
for n in new:
    st = json.loads(run(["gh", "api", "repos/{owner}/{repo}/commits/%s/status?per_page=100" % byn[n]["headRefOid"]]))
    for s in st.get("statuses", []):
        if s.get("context") == CTX:
            cur[n] = (s.get("state"), s.get("description") or "")

# 接在 head 上、可以合的几张：已亮绿的先，再按 PR 号
if eligible:
    order = sorted(eligible, key=lambda x: (cur.get(x, ("",))[0] != "success", x))
    win = order[0]
    verdict[win] = ("success", "可合：%s 接在 main 的 head %s 上，接这个点的 PR 里排第一" % (chain_of[win], H), None)
    for n in order[1:]:
        verdict[n] = ("pending", "排在 #%d 后面：都接在 %s 上（已亮绿的先，再按 PR 号）；#%d 合并后把 %s 的 down_revision 改成 %s"
                      % (win, H, win, file_of[n], tip_of[win]), byn[win].get("url"))

def clip(s):
    return s if len(s) <= 140 else s[:139] + "…"

# ---------- 发 ----------
changes = []
for n in sorted(verdict):
    state, desc, url = verdict[n]
    desc = clip(desc)
    same = cur.get(n) == (state, desc)
    if dry:
        print("#%d %s %s（%s）" % (n, state, desc, "不变" if same else "会改"))
    elif not same:
        changes.append((state == "success", n, state, desc, url))
for _, n, state, desc, url in sorted(changes):          # 绿的排最后：先把别的降下来
    cmd = ["gh", "api", "-X", "POST", "repos/{owner}/{repo}/statuses/" + byn[n]["headRefOid"],
           "-f", "state=" + state, "-f", "context=" + CTX, "-f", "description=" + desc]
    if url:
        cmd += ["-f", "target_url=" + url]
    run(cmd)
    print("#%d %s %s" % (n, state, desc))
PY
