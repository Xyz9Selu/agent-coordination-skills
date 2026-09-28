#!/usr/bin/env bash
#
# check-env.sh —— 把本机 herdr 与各 agent CLI 的版本，和 herdr-agents 技能里标注的实测版本对一遍。
#
# 只读：不装、不改、不建任何东西。版本不同只提醒，不拦——技能里的每条实测都绑在一个版本上，
# 版本变了意味着那些条目该复测，不意味着不能用。
#
# 用法：check-env.sh
#
# 退出码：0 = herdr 在（其余只是提醒）；1 = 没有 herdr，本技能无从谈起。
#
# 下面的实测版本必须与 SKILL.md / startup-evidence.md 里写的一致；改了那边的实测，就改这里。
set -uo pipefail

TESTED_HERDR="0.9.1"      # SKILL.md「版本绑定」、startup-evidence.md
TESTED_AGY="1.2.12"       # startup-evidence.md ①a、SKILL.md §8
TESTED_OPENCODE="1.18.32" # SKILL.md §8（技能发现）

case "${1:-}" in
  -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
  "") ;;
  *) echo "未知参数: $1" >&2; exit 2 ;;
esac

rc=0

# 从一段版本输出里取第一个 x.y.z
ver_of() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1; }

report() {  # 名字 实测版本 本机输出
  local name="$1" tested="$2" out="$3" v
  v="$(printf '%s\n' "$out" | ver_of)"
  if [ -z "$v" ]; then
    echo "⚠ $name：读不出版本号（输出：$(printf '%s' "$out" | head -1)）"
  elif [ -z "$tested" ]; then
    echo "✅ $name $v（技能里没有记录这个 CLI 的实测版本）"
  elif [ "$v" = "$tested" ]; then
    echo "✅ $name $v（与实测版本一致）"
  else
    echo "ℹ $name $v —— 技能里的实测版本是 $tested。相关条目未在 $v 上复测，对不上时先查发布说明。"
  fi
}

if [ "${HERDR_ENV:-}" != "1" ]; then
  echo "ℹ 当前不在 herdr 管理的 pane 里（HERDR_ENV != 1）。官方 herdr 技能要求在 herdr 里运行控制命令。"
fi

if command -v herdr >/dev/null 2>&1; then
  report herdr "$TESTED_HERDR" "$(herdr --version 2>&1)"
else
  echo "❌ 没有 herdr。本技能的所有步骤都需要它。"
  rc=1
fi

found=0
if command -v claude >/dev/null 2>&1; then report claude "" "$(claude --version 2>&1)"; found=1; fi
if command -v agy >/dev/null 2>&1; then report agy "$TESTED_AGY" "$(agy --version 2>&1)"; found=1; fi
if command -v opencode >/dev/null 2>&1; then report opencode "$TESTED_OPENCODE" "$(opencode --version 2>&1)"; found=1; fi
[ "$found" -eq 1 ] || echo "⚠ claude / agy / opencode 一个都没找到——没有可以起的 agent。"

exit "$rc"
