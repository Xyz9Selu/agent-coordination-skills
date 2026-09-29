#!/usr/bin/env bash
# watch-workers.sh — coordinator 的廉价看门脚本（不调用任何模型）。
#
# 每 INTERVAL 秒给每个 worker / grill agent 拍一张「地面事实」快照：
#   进程在不在 / 屏幕在干活还是在等 / 分支 head / 交付物状态
# 只在「值得叫醒 coordinator 的变化」出现时打印差异并退出（退出码 0）。
# 退出本身就是叫醒信号：在 Claude Code 里用 Bash run_in_background 跑它，
# 退出时 coordinator 会收到一条完成通知。别的 harness 见 patrol.md「巡检由什么触发」。
#
# 用法：
#   watch-workers.sh               # 循环，有值得叫醒的变化才退出
#   watch-workers.sh --once        # 打印一次当前快照，不写状态、不循环
#   watch-workers.sh --rebaseline  # 把当前快照写成基线后退出（coordinator 自己
#                                  #   起停 worker 之后先跑它，免得被自己的动作叫醒）
#   watch-workers.sh --stop        # 按 pid 文件停掉正在跑的实例
#
# 退出码：0 = 有变化（stdout 是差异）；9 = 脚本自己出错（herdr 读不到等），
#   这也会叫醒你——出错和「没变化」必须分得开，静默失败等于没人在看。
#
# 环境变量（都有默认值）：
#   INTERVAL        快照间隔秒数，默认 900
#   STATE_DIR       状态与 pid 文件目录，默认 ${XDG_STATE_HOME:-$HOME/.local/state}/dispatch-watch
#   NAME_RE         要盯的 herdr agent 名，默认 '^(worker|grill)-'
#   DELIVERABLE_CMD 由分支名查交付物状态的命令，分支名以 $1 传入，输出一行短文本；
#                   默认用 gh 查 PR（工作流不是 GitHub 时换掉它）
#   BG_WORK_RE      「worker 在等自己起的后台任务」的任务行特征，默认匹配常见测试/构建命令
#
# 本脚本里每条屏幕判定规则的来历与推翻条件，见 ../patrol.md「巡检由什么触发」。
# 改规则前先读那一节——特别是为什么不用 `visible`、为什么「N task(s)」不算在干活。

set -u
INTERVAL=${INTERVAL:-900}
STATE_DIR=${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dispatch-watch}
NAME_RE=${NAME_RE:-'^(worker|grill)-'}
BG_WORK_RE=${BG_WORK_RE:-'pytest|playwright|run-backend-gate|vitest|jest|pnpm (run )?(test|build)|npm (run )?(test|build)|tsc'}
DELIVERABLE_CMD=${DELIVERABLE_CMD:-'gh pr list --head "$1" --state all --json number,state --jq ".[0] // empty | \"#\(.number) \(.state)\""'}
STATE="$STATE_DIR/state.tsv"
PIDFILE="$STATE_DIR/watch.pid"
mkdir -p "$STATE_DIR"

# 屏幕分类。输入：herdr 用来做状态检测的那块底部快照（--source detection）。
#   working        底部几行有「正在干活」标记（各 kind 的中断提示）
#   WAITING-PERM   停在权限/确认对话框
#   WAITING-ERROR  agy 模型接口报错后停住（herdr 自己的 agy 规则仍会报 working）
#   WAITING-QUEUED 有排队消息没被取走（agy 空闲也不自动取）
#   WAITING-BG     停着，但它自己起的测试/构建还在后台跑——跑完它会自己接着干，不叫醒
#   WAITING        停着等人
classify() {
  local snap=$1 bottom
  bottom=$(printf '%s\n' "$snap" | grep -v '^[[:space:]]*$' | tail -4)
  if printf '%s\n' "$bottom" | grep -qiE 'esc to (cancel|interrupt)|esc interrupt'; then echo working; return; fi
  if printf '%s\n' "$snap" | grep -qiE 'requesting permission for:|Do you want to proceed\?'; then echo WAITING-PERM; return; fi
  if printf '%s\n' "$snap" | grep -qiE 'Internal error encountered|request contains invalid parameters'; then echo WAITING-ERROR; return; fi
  if printf '%s\n' "$snap" | grep -qE 'Press up to edit queued'; then echo WAITING-QUEUED; return; fi
  if printf '%s\n' "$snap" | grep -E '●.* running[[:space:]]*$' | grep -qE "$BG_WORK_RE"; then echo WAITING-BG; return; fi
  echo WAITING
}

snapshot() {
  local list
  list=$(herdr agent list 2>/dev/null) || { echo "herdr agent list failed" >&2; return 9; }
  printf '%s' "$list" | NAME_RE="$NAME_RE" python3 -c '
import sys, json, os, re
pat = re.compile(os.environ["NAME_RE"])
for a in json.load(sys.stdin)["result"]["agents"]:
    n = a.get("name") or ""
    if pat.search(n):
        print(n, a["pane_id"], a.get("cwd") or "", a.get("agent") or "", sep="\t")' || return 9
  return 0
}

row() {  # name pane cwd kind -> 一行快照
  local name=$1 pane=$2 cwd=$3 kind=$4 alive=dead p snap screen head br dl
  # 按进程名精确匹配再比 cwd。别用 pgrep -f：它匹配整条命令行，会把 coordinator
  # 自己那条带 "claude"/"agy" 字样的命令读成「worker 还活着」（herdr-agents §6）。
  for p in $(pgrep -x "$kind" 2>/dev/null); do
    [ "$(readlink "/proc/$p/cwd" 2>/dev/null)" = "$cwd" ] && { alive=alive; break; }
  done
  snap=$(herdr pane read "$pane" --source detection 2>/dev/null) || snap=''
  if [ -z "$snap" ]; then screen=UNREADABLE; else screen=$(classify "$snap"); fi
  head=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null || echo none)
  br=$(git -C "$cwd" branch --show-current 2>/dev/null)
  dl=''
  # 在 worker 的 worktree 里跑，gh 才知道是哪个仓库
  [ -n "$br" ] && dl=$(cd "$cwd" 2>/dev/null && bash -c "$DELIVERABLE_CMD" _ "$br" 2>/dev/null | head -1)
  printf '%s\t%s\t%s\thead=%s\tdeliverable=%s\n' "$name" "$alive" "$screen" "$head" "${dl:-none}"
}

take() {
  local agents
  agents=$(snapshot) || return 9
  [ -z "$agents" ] && return 0
  printf '%s\n' "$agents" | while IFS=$'\t' read -r name pane cwd kind; do row "$name" "$pane" "$cwd" "$kind"; done | sort
}

# 值得叫醒的变化：
#   1) 进程死活变了、agent 出现/消失（名字集合变了）
#   2) 交付物状态变了（开了 / 合了 / 关了）
#   3) 屏幕「进入」一个需要人的状态（WAITING / -PERM / -ERROR / -QUEUED / UNREADABLE）
# 不叫醒、只静默记下：新提交（head 变）、回到 working、进入 WAITING-BG。
facts() { awk -F'\t' '{print $1, $2, $5}' | sort; }
needs_human() { awk -F'\t' '$3 ~ /^(WAITING(-PERM|-ERROR|-QUEUED)?|UNREADABLE)$/ {print $1, $3}' | sort; }

case "${1:-}" in
  --once) take; exit $? ;;
  --rebaseline) cur=$(take) || exit 9; printf '%s\n' "$cur" > "$STATE"; echo "baseline written: $STATE"; exit 0 ;;
  --stop)
    if [ -s "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then kill "$(cat "$PIDFILE")" && echo "stopped $(cat "$PIDFILE")"; else echo "no running watcher"; fi
    rm -f "$PIDFILE"; exit 0 ;;
  '') ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

# 单实例：已有一个在跑就不再起第二个（重复实例的通知会收不到或重复）。
exec 8>"$STATE_DIR/watch.lock"
flock -n 8 || { echo "another watcher is already running (pid $(cat "$PIDFILE" 2>/dev/null))"; exit 9; }
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

prev=$(cat "$STATE" 2>/dev/null)
while :; do
  cur=$(take) || { echo "[$(date +%H:%M)] watcher error: snapshot failed"; exit 9; }
  entered=$(comm -13 <(printf '%s\n' "$prev" | needs_human) <(printf '%s\n' "$cur" | needs_human))
  if [ "$(printf '%s\n' "$cur" | facts)" != "$(printf '%s\n' "$prev" | facts)" ] || [ -n "$entered" ]; then
    echo "[$(date +%H:%M)] worker state changed:"
    diff <(printf '%s\n' "$prev") <(printf '%s\n' "$cur") | grep '^[<>]'
    printf '%s\n' "$cur" > "$STATE"
    exit 0
  elif [ "$cur" != "$prev" ]; then
    printf '%s\n' "$cur" > "$STATE"; prev=$cur
  fi
  sleep "$INTERVAL"
done
