#!/usr/bin/env bash
#
# 给一个或几个 herdr agent 发同一条消息：等它不在 working、输入框是空的，再发。
# usage: deliver-when-idle.sh "<message>" agent1 agent2 ...
#   每 15 秒看一遍，最多 1 小时（240 轮）；测试用 DELIVER_ROUNDS / DELIVER_SLEEP 改。每个 agent 发出后打印一行 delivered rc=…；最后一行 remaining: 列出没发出去的。
#   rc=0 只说明 `agent prompt --wait` 看到了 working，**不等于送达**——送达照 SKILL.md §2 回读确认。
#   「输入框是空的」怎么判、为什么要判，见 SKILL.md §2「别往有人在打字的输入框里发」。

msg=$1; shift; pending="$*"
for i in $(seq 1 "${DELIVER_ROUNDS:-240}"); do
  left=""
  # 列表读不到不等于 agent 都没了（旧版会把它们全报成 gone、从此不再发）：整轮重试
  list=$(herdr agent list 2>/dev/null) || { echo "herdr agent list failed, retrying"; sleep "${DELIVER_SLEEP:-15}"; continue; }
  for a in $pending; do
    read -r st pane < <(python3 -c '
import json,sys
a=next((x for x in json.loads(sys.argv[2])["result"]["agents"] if x.get("name")==sys.argv[1]),None)
print(a["agent_status"], a["pane_id"]) if a else print("gone -")' "$a" "$list" 2>/dev/null || echo "gone -")
    [ "$st" = "gone" ] && { echo "$a gone"; continue; }
    if [ "$st" = "working" ]; then left="$left $a"; continue; fi
    # Don't type into a box someone is filling in; drop dim (ESC[2m) runs, which are Claude Code's grey
    # prompt suggestion, not typed text. Evidence and what would overturn it: SKILL.md §2.
    screen=$(herdr pane read "$pane" --source visible --format ansi 2>/dev/null)
    # A panel (e.g. the background-shell list) covers the input box and its cursor line also starts with ❯;
    # say so instead of "not empty", and don't press keys to close it. SKILL.md §2.
    if perl -pe 's/\e\[[0-9;]*m//g' <<<"$screen" | grep -aq 'Esc to close'; then
      echo "$a panel open over the input box (Esc to close), waiting"; left="$left $a"; continue; fi
    box=$(printf '%s\n' "$screen" | grep -a '❯' | tail -1 \
      | perl -CSD -Mutf8 -pe 's/\e\[2m.*?\e\[0m//g; s/\e\[[0-9;]*m//g; s/^.*?❯\s*//; s/\s+$//')
    if [ -n "$box" ]; then echo "$a input box not empty, waiting"; left="$left $a"; continue; fi
    herdr agent prompt "$a" "$msg" --wait --until working --timeout 20000 >/dev/null 2>&1; echo "$a delivered rc=$? (was $st)"
  done
  pending=$left; [ -z "$pending" ] && break; sleep "${DELIVER_SLEEP:-15}"
done; echo "remaining:$pending"
