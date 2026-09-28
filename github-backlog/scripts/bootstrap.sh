#!/usr/bin/env bash
#
# bootstrap.sh —— 第一次在某个 GitHub 仓库里用 github-backlog（单独用，或配合 dispatch）时跑一次。
#
# 为什么放在 github-backlog 里：它唯一会「写」的东西是 GitHub 标签，而标签清单必须和本技能
# SKILL.md 实际用到的一致——清单放在定义这些标签的技能旁边，改一处就够。herdr 与 agent CLI 的
# 版本检查不在这里，在 herdr-agents 技能的 scripts/check-env.sh：放进来会让 GitHub 工作流依赖 herdr。
#
# 做两件事：
#   1. 检查：gh 装了没、登录没；当前目录是不是一个能访问的 GitHub 仓库。缺什么就说缺什么、怎么补。
#   2. 初始化：列出仓库里缺的标签，**列出后经用户确认再建**。已经有的不动（不改颜色、不改描述）。
#      可以重复运行。标签分两组，分别确认：
#        - backlog：本技能 SKILL.md 用到的状态 / 类型 / 优先级 / 例外标签；
#        - dispatch：配合 dispatch 技能时，挂在 PR 上的三种核查标记（见 SKILL.md「给 dispatch 用」）。
#
# 不做：配置文件、安装向导、自动安装依赖、每次运行前的自检。
#
# 用法：
#   bootstrap.sh              # 检查，并逐组确认后创建缺失标签
#   bootstrap.sh --check      # 只检查、只列出，不创建任何标签（--dry-run 同义）
#   bootstrap.sh --yes        # 非交互：不问，直接创建所有缺失标签
#
# 退出码：0 = 检查通过（无论是否建了标签）；1 = 前置检查没通过；2 = 参数错误。
set -uo pipefail

check_only=0
auto_yes=0

for arg in "$@"; do
  case "$arg" in
    --check|--dry-run) check_only=1 ;;
    --yes|-y)          auto_yes=1 ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "未知参数: $arg" >&2
      echo "用法: $0 [--check|--dry-run] [--yes|-y]" >&2
      exit 2
      ;;
  esac
done

echo "===== github-backlog bootstrap：前置检查 ====="
has_err=0

if ! command -v gh >/dev/null 2>&1; then
  echo "❌ 没有 gh（GitHub CLI）。安装：https://cli.github.com/" >&2
  has_err=1
else
  echo "✅ gh: $(gh --version | head -1)"
  if ! gh auth status >/dev/null 2>&1; then
    echo "❌ gh 未登录。请你自己运行 \`gh auth login\`（交互式登录，本脚本不代跑）。" >&2
    has_err=1
  else
    echo "✅ gh 已登录"
  fi
fi

repo_name=""
if [ "$has_err" -eq 0 ]; then
  repo_name="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "")"
  if [ -z "$repo_name" ]; then
    echo "❌ 当前目录不是一个能访问的 GitHub 仓库。到仓库的工作区里再跑。" >&2
    has_err=1
  else
    echo "✅ 仓库: $repo_name"
    if [ "$(gh repo view --json hasIssuesEnabled --jq .hasIssuesEnabled 2>/dev/null)" != "true" ]; then
      echo "⚠ 这个仓库没开 Issues。本技能不替你开（SKILL.md「Read Before Write」：改仓库治理要用户同意）。"
    fi
  fi
fi

if [ "$has_err" -ne 0 ]; then
  echo
  echo "❌ 前置检查没通过，先补上面缺的再跑。" >&2
  exit 1
fi

# 名字|颜色|描述。名字必须与 SKILL.md 一致：改 SKILL.md 里的标签，就改这里。
BACKLOG_LABELS=(
  "In progress|a2eeef|Status: an agent has claimed it and is working it"
  "In review|d876e3|Status: PR open, awaiting pre-merge acceptance"
  "Done|0e8a16|Status: accepted and merged"
  "bug|d73a4a|Type: existing behavior is wrong"
  "enhancement|a2eeef|Type: new behavior or an improvement"
  "documentation|0075ca|Type: docs, ADRs, agent instructions; no code change"
  "priority: high|b60205|Priority: urgent; prefer when candidates compete"
  "priority: medium|f4a442|Priority: default"
  "priority: low|c5def5|Priority: safe to leave in the backlog"
  "blocked|d93f0b|Exception: recoverable pause; needs a 'blocked: <reason>' comment"
  "deferred|fbca04|Exception: pushed out of the cycle; claim released; needs a 'deferred:' comment"
  "duplicate|cfd3d7|Exception: superseded by another Issue (closed)"
  "wontfix|ffffff|Exception: rejected (closed); needs a 'wontfix:' comment"
)
DISPATCH_LABELS=(
  "占稀缺资源|d93f0b|本 PR 消耗迁移号/ADR 号/注册表项/端口等独占资源；细节见 coordinator 评论"
  "需按序合并|fbca04|本 PR 有硬性前置，顺序错了会坏；前置与理由见 coordinator 评论"
  "资源已核|0e8a16|coordinator 已核过资源足迹与两两冲突，结论在评论里（含基准 commit 与时间）。无此标签 = 尚未核"
)

existing="$(mktemp)"
trap 'rm -f "$existing"' EXIT
if ! gh label list --limit 500 --json name --jq '.[].name' > "$existing" 2>/dev/null; then
  echo "❌ 读不出这个仓库的标签列表（权限？网络？）。不继续——读不出就当「全缺」会乱建。" >&2
  exit 1
fi

# handle_group <组名> <label...>：列出缺的；按模式决定建不建
handle_group() {
  local group="$1"; shift
  local missing=() item name color desc reply
  for item in "$@"; do
    IFS='|' read -r name color desc <<< "$item"
    grep -qxF "$name" "$existing" || missing+=("$item")
  done

  echo
  if [ "${#missing[@]}" -eq 0 ]; then
    echo "✅ [$group] 标签全部已存在（$#/$#），不动。"
    return 0
  fi
  echo "⚠ [$group] 缺 ${#missing[@]} 个标签（共 $# 个）："
  for item in "${missing[@]}"; do
    IFS='|' read -r name color desc <<< "$item"
    printf "   - %-16s #%s  %s\n" "$name" "$color" "$desc"
  done

  if [ "$check_only" -eq 1 ]; then
    echo "   （--check：只列出，不创建）"
    return 0
  fi
  if [ "$auto_yes" -eq 0 ]; then
    if [ ! -t 0 ]; then
      echo "   非交互终端：不创建。要创建，重跑并加 --yes，或在终端里跑。" >&2
      return 0
    fi
    read -r -p "   在 $repo_name 里创建 [$group] 这 ${#missing[@]} 个标签？[y/N] " reply
    case "$reply" in
      [yY]|[yY][eE][sS]) ;;
      *) echo "   跳过 [$group]。"; return 0 ;;
    esac
  fi
  for item in "${missing[@]}"; do
    IFS='|' read -r name color desc <<< "$item"
    if gh label create "$name" --color "$color" --description "$desc" >/dev/null; then
      echo "   建了: $name"
    else
      echo "   ❌ 建失败: $name" >&2
    fi
  done
}

echo
echo "===== 标签 ====="
handle_group backlog "${BACKLOG_LABELS[@]}"
handle_group dispatch "${DISPATCH_LABELS[@]}"
echo
echo "===== bootstrap 结束 ====="
