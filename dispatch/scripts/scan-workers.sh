#!/usr/bin/env bash
#
# coordinator 巡检的事件流：每 INTERVAL 秒看一遍盘面，**每行输出 = 一个事件**，没变化就不出声（心跳除外）。
# 只读：不写 gh、不写 git，唯一的写是 `git fetch`。
# 依赖：herdr、git；盯 PR（PR-* 事件、撞号扫描的 --prs）要 gh 且仓库在 GitHub 上 —— 不是的话设 WATCH_PRS=0。
#
# ── 怎么挂 ────────────────────────────────────────────────────────────────────────────────────────
# 用 Claude Code 的 Monitor 工具（每行 stdout 变成一条通知）：
#
#   Monitor(
#     description: "dispatch 巡检 <仓库名>",
#     command: "REPO=/path/to/repo MIGRATION_DIR=<迁移目录> ADR_DIR=<ADR 目录> \
#               ~/.agents/skills/dispatch/scripts/scan-workers.sh",
#     timeout_ms: 1800000)           # 上限 30 分钟；到期收到通知就原样再挂一次
#
# 重挂会丢掉内存里的状态：第一轮只记基线、不报变化，然后出一行 SCAN-READY 当快照。
# 不需要在外面再套 grep 过滤：撞号只扫 herdr 管着的 worker 的 worktree 和打开着的 PR（见下）。
#
# 环境变量：
#   REPO           仓库主 checkout 的路径（必填）
#   MIGRATION_DIR  迁移目录、ADR_DIR  ADR 目录（相对 REPO，交给 scan-collisions.sh；都不设 = 不扫撞号，开头说一次）
#   INTERVAL=90    轮询间隔（秒）
#   HEARTBEAT=300  心跳间隔（秒）；0 = 不出心跳
#   DEFAULT_REMOTE=origin  DEFAULT_BRANCH=main
#   WATCH_PRS=1    0 = 不调 gh：不出 PR-* 事件，撞号只扫 worker 的 worktree（开头说一次）
#
# ── 事件，以及 coordinator 该怎么反应 ────────────────────────────────────────────────────────────
#   SCAN-READY     开始盯了：盯着哪些 agent、几个打开的 PR、main 在哪。核对名单是不是你以为的那些。
#   HEARTBEAT      定时轻看一眼（默认每 5 分钟轻看，事件来了再全查；2026-10-21 用户定的节奏）。行里带当前状态
#                  一览；没有别的事件就不必做什么，有异常（某个 working 很久不动之类）再去读那个 pane。
#   AGENT-NEW      herdr 里出现了一个新的有名字的 agent。是你起的就核它送达了没有；不是你起的，弄清是谁的。
#   AGENT-GONE     agent 从 `herdr agent list` 里消失（进程退出）。收尾过的正常；没收尾的去看 worktree、分支、PR。
#   AGENT-STATUS   状态变了，**连续两轮一致才报**（防抖，见下），附画面最后几行。working→idle/done 多半是
#                  做完一步或在等人：读回它说了什么，该回话就回话。
#                  看不清的：agy 接口报错停住只报成 idle（和做完分不出）、pane 被滚上去时的新权限框（读的是
#                  visible）——见 patrol.md「事件流」的「它看不清的东西」。
#   AGENT-PROMPT   画面上有权限 / 确认框，**不防抖，立刻报**。去看框里问的是什么；在授权范围内就替用户点，
#                  否则转给用户。
#   PR-NEW / PR-STATE / PR-LEFT   新 PR、draft↔ready、PR 离开 open 列表（附现在的状态：MERGED / CLOSED）。
#                  新 PR → 核它的足迹（patrol.md「三种核查标记」）；MERGED → 核落地、收尾（closeout.sh）。
#   MAIN-MOVED     origin/main 前进了（通常是有 PR 合并），附最多三条提交标题。所有在飞分支的「vs 主干」结论
#                  作废（patrol.md「否定结论会腐烂」的表），撞号这一轮已经自动重扫。
#   COLLISION      撞号扫描的 🔴 行变了（新出现或内容变化），附全部 🔴 行。按 scan-collisions.sh 的建议协调：
#                  先合并的保号，后合并的让路。
#   COLLISION-CLEAR  之前报过的撞号都没了。
#   PROBE-ERROR    某个探测失败（herdr / gh / git fetch / 撞号扫描退出 9）。**失败不吞掉**，但同一个错误只在
#                  第一次出现时报一行；PROBE-OK 表示它恢复了。没恢复之前，这一项的「没事件」不是「没变化」。
#
# ── 为什么这样 ───────────────────────────────────────────────────────────────────────────────────
# 底子是一个 coordinator 2026-10 在会话临时目录里用了三周的 scan-workers.sh（自动盯所有有名字的
# agent、AGENT-NEW/GONE、状态变化附画面、权限框检测、全部打开的 PR 逐个比、探测失败报成事件）。在它上面改的：
# · 状态防抖：herdr 的 agent_status 是刮屏得来的、会抖（herdr-agents §3 陷阱 ③），旧版 10-14 至 10-21 一周报了
#   三千多条 AGENT-STATUS。新状态要连续两轮一致才报；权限框是要人动手的，不防抖。
# · 心跳：Monitor 没事件就不会叫醒 coordinator，「没事件」和「脚本挂了」分不出来；心跳把两者分开，也给轻看定了节奏。
# · 撞号：旧版扫本机所有 worktree，别的会话留下的 `worktree-agent-*` 刷满 COLLISION-SCAN，只好在外面套 grep -v；
#   而且一次 34 秒。现在只把 herdr agent 所在的、属于 REPO 的 worktree 交给新的 scan-collisions.sh（≈1 秒）。
# · 仓库路径、目录都从环境变量来，不再写死某个仓库；main 前进单独成事件。
# 文件放在技能仓库里，不放会话临时目录（重启会清掉 /tmp，第一份就是这么丢的）。

set -u
: "${REPO:?REPO=仓库主 checkout 的路径}"
REPO=$(cd "$REPO" && pwd) || exit 9
INTERVAL=${INTERVAL:-90}
HEARTBEAT=${HEARTBEAT:-300}
DEFAULT_REMOTE=${DEFAULT_REMOTE:-origin}
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
WATCH_PRS=${WATCH_PRS:-1}
BASE="$DEFAULT_REMOTE/$DEFAULT_BRANCH"
SCAN_COLLISIONS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scan-collisions.sh"
export MIGRATION_DIR="${MIGRATION_DIR:-}" ADR_DIR="${ADR_DIR:-}"

STATE=$(mktemp -d) || exit 9
trap 'rm -rf "$STATE"' EXIT
declare -A reported pending pending_n prompt_on probe_err
first=1
last_beat=$(date +%s)
main_sha=""
collisions=""
repo_common=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "ERR: $REPO 不是 git 仓库" >&2; exit 9; }

emit() { echo "[$(date +%H:%M)] $*"; }

# 同一个探测的同一个错误只报一次；恢复时报 PROBE-OK
probe_fail() { [ "${probe_err[$1]:-}" = "$2" ] || emit "PROBE-ERROR $1: $2"; probe_err[$1]=$2; }
probe_ok()   { [ -n "${probe_err[$1]:-}" ] && emit "PROBE-OK $1"; probe_err[$1]=""; }

screen_tail() {  # 画面最后三行有内容的，去掉 TUI 的装饰行
  herdr pane read "$1" --source visible 2>/dev/null \
    | grep -vE '^\s*$|^[─━]|auto mode|bypass|shift\+tab|esc to interrupt|Press up to edit|new task\?|Tip:' \
    | tail -3 | tr '\n' ' ' | cut -c1-260
}

[ -z "$MIGRATION_DIR$ADR_DIR" ] && emit "ℹ 没设 MIGRATION_DIR / ADR_DIR：不扫撞号"
[ "$WATCH_PRS" = 1 ] || emit "ℹ WATCH_PRS=0：不盯 PR，撞号只扫 worker 的 worktree"

while true; do
  # ---------- herdr agents ----------
  worktrees=()
  if agents_json=$(herdr agent list 2>&1); then
    probe_ok herdr
    mapfile -t rows < <(python3 -c '
import json,sys
for a in json.load(sys.stdin)["result"]["agents"]:
    if a.get("name"):
        print("\t".join([a["name"], a["agent_status"], a["pane_id"], a.get("cwd") or ""]))' <<<"$agents_json" 2>/dev/null)
    declare -A seen=()
    for row in "${rows[@]}"; do
      IFS=$'\t' read -r name status pane cwd <<<"$row"
      seen[$name]=1
      # 属于 REPO 的 linked worktree 交给撞号扫描（主 checkout 本身不算：那是 coordinator 自己站的地方）
      if [ -n "$cwd" ] && top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) && [ "$top" != "$REPO" ] \
         && [ "$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" = "$repo_common" ]; then
        worktrees+=(--worktree "$top")
      fi
      scr=$(herdr pane read "$pane" --source visible 2>/dev/null)
      if [ -z "${reported[$name]:-}" ]; then
        [ $first = 1 ] || emit "AGENT-NEW $name ($pane) status=$status cwd=$cwd"
        reported[$name]=$status; pending[$name]=""; pending_n[$name]=0
      elif [ "$status" = "${reported[$name]}" ]; then
        pending[$name]=""; pending_n[$name]=0
      else
        # 防抖：新状态连续两轮一致才报
        if [ "$status" = "${pending[$name]:-}" ]; then pending_n[$name]=$(( ${pending_n[$name]} + 1 ))
        else pending[$name]=$status; pending_n[$name]=1; fi
        if [ "${pending_n[$name]}" -ge 2 ]; then
          emit "AGENT-STATUS $name ${reported[$name]} -> $status | $(screen_tail "$pane")"
          reported[$name]=$status; pending[$name]=""; pending_n[$name]=0
        fi
      fi
      # 权限 / 确认框：不防抖
      if grep -qE 'Do you want to (proceed|make this edit|create)|❯ 1\. Yes|Allow (once|always)|requires permission|trust this folder' <<<"$scr"; then
        [ "${prompt_on[$name]:-0}" = 1 ] || emit "AGENT-PROMPT $name ($pane) is waiting on a permission/approval prompt | $(screen_tail "$pane")"
        prompt_on[$name]=1
      else
        prompt_on[$name]=0
      fi
    done
    for name in "${!reported[@]}"; do
      if [ -z "${seen[$name]:-}" ]; then
        emit "AGENT-GONE $name (no longer in herdr agent list; last status ${reported[$name]})"
        unset "reported[$name]" "pending[$name]" "pending_n[$name]" "prompt_on[$name]"
      fi
    done
    unset seen
  else
    probe_fail herdr "herdr agent list failed: $(head -c 200 <<<"$agents_json")"
  fi

  # ---------- main 前进 ----------
  if err=$(git -C "$REPO" fetch -q "$DEFAULT_REMOTE" 2>&1); then probe_ok fetch
  else probe_fail fetch "git fetch failed: $(head -c 200 <<<"$err")"; fi
  if sha=$(git -C "$REPO" rev-parse --verify --quiet "$BASE"); then
    if [ -n "$main_sha" ] && [ "$sha" != "$main_sha" ]; then
      emit "MAIN-MOVED $BASE ${main_sha:0:8} -> ${sha:0:8} | $(git -C "$REPO" log --format='%s' "$main_sha..$sha" | head -3 | tr '\n' ';' | cut -c1-260)"
    fi
    main_sha=$sha
  else
    probe_fail main "no $BASE in $REPO"
  fi

  # ---------- 打开的 PR ----------
  if [ "$WATCH_PRS" != 1 ]; then :
  elif prs=$(cd "$REPO" && gh pr list --state open --limit 100 --json number,isDraft,title \
        --jq '.[] | "\(.number)\t\(if .isDraft then "draft" else "ready" end)\t\(.title[:70])"' 2>&1); then
    probe_ok gh
    sort <<<"$prs" | grep . > "$STATE/prs.new"
    if [ -f "$STATE/prs.old" ]; then
      while IFS=$'\t' read -r num st title; do
        old=$(awk -F'\t' -v n="$num" '$1==n{print $2}' "$STATE/prs.old")
        if [ -z "$old" ]; then emit "PR-NEW #$num ($st) $title"
        elif [ "$old" != "$st" ]; then emit "PR-STATE #$num $old -> $st $title"; fi
      done < "$STATE/prs.new"
      while IFS=$'\t' read -r num st title; do
        if ! awk -F'\t' -v n="$num" '$1==n{f=1} END{exit !f}' "$STATE/prs.new"; then
          s=$(cd "$REPO" && gh pr view "$num" --json state --jq .state 2>/dev/null || echo "?")
          emit "PR-LEFT #$num now $s $title"
        fi
      done < "$STATE/prs.old"
    fi
    mv "$STATE/prs.new" "$STATE/prs.old"
  else
    probe_fail gh "gh pr list failed: $(head -c 200 <<<"$prs")"
  fi

  # ---------- 撞号 ----------
  if [ -n "$MIGRATION_DIR$ADR_DIR" ]; then
    src=("${worktrees[@]}"); [ "$WATCH_PRS" = 1 ] && src+=(--prs)
    if [ ${#src[@]} = 0 ]; then out=""; rc=0   # 没有在飞的 worktree、也不看 PR：没东西可扫（不带参数调它会默认 --prs）
    else out=$(cd "$REPO" && "$SCAN_COLLISIONS" --no-fetch "${src[@]}" 2>&1); rc=$?; fi
    if [ $rc = 9 ] || { [ $rc != 0 ] && [ $rc != 1 ]; }; then
      probe_fail collisions "scan-collisions.sh rc=$rc: $(tail -2 <<<"$out" | tr '\n' ' ' | cut -c1-200)"
    else
      probe_ok collisions
      now=$(grep '🔴' <<<"$out" | sed 's/^ *//')
      if [ "$now" != "$collisions" ]; then
        if [ -n "$now" ]; then emit "COLLISION $(tr '\n' ' ' <<<"$now" | cut -c1-1500)"
        else emit "COLLISION-CLEAR 之前报的撞号都没了"; fi
      fi
      collisions=$now
    fi
  fi

  # ---------- 首轮快照 / 心跳 ----------
  overview() {
    local a s=""
    for a in "${!reported[@]}"; do s+="$a=${reported[$a]} "; done
    local n; n=$(grep -c . "$STATE/prs.old" 2>/dev/null)
    echo "agents: ${s:-（无）}| open PRs: ${n:-?} | $BASE ${main_sha:0:8} | 撞号 $(grep -c '🔴' <<<"$collisions")"
  }
  if [ $first = 1 ]; then
    emit "SCAN-READY $(overview)"
    first=0
  elif [ "$HEARTBEAT" -gt 0 ] && [ $(( $(date +%s) - last_beat )) -ge "$HEARTBEAT" ]; then
    emit "HEARTBEAT $(overview)"
    last_beat=$(date +%s)
  fi
  sleep "$INTERVAL"
done
