#!/usr/bin/env bash
#
# 给一个或几个 herdr agent 发同一条消息：等它不在 working、输入框是空的，再发。
# usage: deliver-when-idle.sh "<message>" agent1 agent2 ...
#   每 15 秒看一遍，最多 1 小时（240 轮）。每个 agent 发出后打印一行 delivered rc=…；最后一行 remaining: 列出没发出去的。
#   rc=0 只说明 `agent prompt --wait` 看到了 working，**不等于送达**——送达照 herdr-agents §2 回读确认。
#
# 来历：前任 coordinator 2026-10 的 ~/.cache/smops-runs/coordinator/deliver-when-idle.sh，与仓库无关，原样搬来，
# 只改了三处：agent 名走 argv（不再拼进 python 源码）；每轮只调一次 `herdr agent list`；列表读失败时重试。

msg=$1; shift; pending="$*"
for i in $(seq 1 240); do
  left=""
  # 列表读不到不等于 agent 都没了（旧版会把它们全报成 gone、从此不再发）：整轮重试
  list=$(herdr agent list 2>/dev/null) || { echo "herdr agent list failed, retrying"; sleep 15; continue; }
  for a in $pending; do
    read -r st pane < <(python3 -c '
import json,sys
a=next((x for x in json.loads(sys.argv[2])["result"]["agents"] if x.get("name")==sys.argv[1]),None)
print(a["agent_status"], a["pane_id"]) if a else print("gone -")' "$a" "$list" 2>/dev/null || echo "gone -")
    [ "$st" = "gone" ] && { echo "$a gone"; continue; }
    if [ "$st" = "working" ]; then left="$left $a"; continue; fi
    # Don't type into a box the user is filling in (2026-10-13: a delivery was appended to
    # John's half-written answer in a grill pane). The prompt line is the one starting with ❯.
    # Read with ANSI and drop dim (ESC[2m) runs: that is Claude Code's grey prompt suggestion,
    # not typed text (2026-10-14: John pointed out "合并 PR 1007" in a worker box was a suggestion;
    # the plain-text read had made me tell him several times to "press Enter" on text he never typed).
    # Checked on 4 panes showing suggestions -> empty. Not yet seen: real typed text (should stay non-empty).
    box=$(herdr pane read "$pane" --source visible --format ansi 2>/dev/null | grep -a '❯' | tail -1 \
      | perl -CSD -Mutf8 -pe 's/\e\[2m.*?\e\[0m//g; s/\e\[[0-9;]*m//g; s/^.*?❯\s*//; s/\s+$//')
    if [ -n "$box" ]; then echo "$a input box not empty, waiting"; left="$left $a"; continue; fi
    herdr agent prompt "$a" "$msg" --wait --until working --timeout 20000 >/dev/null 2>&1; echo "$a delivered rc=$? (was $st)"
  done
  pending=$left; [ -z "$pending" ] && break; sleep 15
done; echo "remaining:$pending"
