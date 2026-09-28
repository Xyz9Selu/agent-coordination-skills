#!/usr/bin/env bash
#
# bootstrap.sh —— coordinator 与 github-backlog 环境及仓库初始化
#
# 第一次在某个仓库里使用 /dispatch 协调调度或 github-backlog 前运行一次。
#
# 功能：
#   1. 检查：
#      - gh CLI 是否安装并登录；
#      - 当前目录是否为有效的 GitHub 仓库；
#      - herdr、claude/agy 是否安装及其版本（与基准实测版本对比提示，不阻断）。
#   2. 初始化：
#      - 检查仓库中是否具备 github-backlog 所需的标准标签（状态、类型、优先级、异常）；
#      - 列出缺失标签，确认后创建（支持 --yes 自动创建，--check 仅检查）。
#      - 已有标签不修改，支持安全幂等重复运行。
#
# 用法：
#   bootstrap.sh              # 检查并交互确认创建缺失标签
#   bootstrap.sh --check      # 仅检查，不创建任何标签
#   bootstrap.sh --dry-run    # 同 --check
#   bootstrap.sh --yes        # 非交互模式，自动创建缺失标签
#
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

echo "===== Dispatch / Backlog Bootstrap 检查 ====="
has_err=0

# 1. 检查 gh CLI
if ! command -v gh >/dev/null 2>&1; then
  echo "❌ 缺少 gh CLI。请安装 GitHub CLI: https://cli.github.com/" >&2
  has_err=1
else
  echo "✅ gh CLI: $(gh --version | head -1)"
  if ! gh auth status >/dev/null 2>&1; then
    echo "❌ gh 未登录。请运行 \`gh auth login\` 完成认证。" >&2
    has_err=1
  else
    echo "✅ gh 登录状态: 已登录"
  fi
fi

# 2. 检查当前仓库
repo_name=""
if command -v gh >/dev/null 2>&1; then
  repo_name="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "")"
  if [ -z "$repo_name" ]; then
    echo "❌ 当前目录不是 GitHub 仓库或无法访问远端。请在 GitHub 仓库工作区根目录执行。" >&2
    has_err=1
  else
    echo "✅ 当前 GitHub 仓库: $repo_name"
  fi
fi

# 3. 检查 herdr
if ! command -v herdr >/dev/null 2>&1; then
  echo "⚠ 未检测到 herdr。建议安装 herdr 以支持工作区隔离与多 worker 并行调度。" >&2
else
  herdr_ver="$(herdr --version 2>/dev/null | head -1 || echo "unknown")"
  echo "✅ herdr: $herdr_ver"
  case "$herdr_ver" in
    *"0.9.1"*) ;;
    *)
      echo "   ℹ 提示：当前 herdr 版本为 $herdr_ver，技能实测基准版本为 0.9.1（仅供参考，不影响运行）。"
      ;;
  esac
fi

# 4. 检查 agent harness (claude / agy)
found_harness=0
if command -v claude >/dev/null 2>&1; then
  claude_ver="$(claude --version 2>/dev/null | head -1 || echo "unknown")"
  echo "✅ claude CLI: $claude_ver"
  found_harness=1
fi
if command -v agy >/dev/null 2>&1; then
  agy_ver="$(agy --version 2>/dev/null | head -1 || echo "unknown")"
  echo "✅ agy CLI: $agy_ver"
  found_harness=1
fi
if [ "$found_harness" -eq 0 ]; then
  echo "⚠ 未检测到 claude 或 agy CLI。派发 worker 需至少一个可用 agent harness。" >&2
fi

if [ "$has_err" -ne 0 ]; then
  echo
  echo "❌ 前置环境检查未通过，请先修复上述错误后再运行 bootstrap。" >&2
  exit 1
fi

echo
echo "===== 标签体系初始化检查 ====="

# 5. 检查标签
REQUIRED_LABELS=(
  "In progress|d4c5f9|An agent has claimed the issue and is working on it"
  "In review|fbca04|Implementation done, awaiting acceptance/review"
  "Done|0e8a16|Accepted and ready to merge/close"
  "blocked|e11d21|Recoverable pause - waiting on something external"
  "deferred|c2e0c6|Pushed out of the current cycle"
  "duplicate|cfd3d7|Superseded by another issue"
  "wontfix|ffffff|Rejected - not applicable or will not be actioned"
  "bug|d73a4a|Something is not working"
  "enhancement|a2eeef|New feature or request"
  "documentation|0075ca|Improvements or additions to documentation"
  "priority: high|b60205|Urgent; prefer over other open candidates"
  "priority: medium|fbca04|Default priority"
  "priority: low|0e8a16|Safe to leave in the backlog"
)

existing_labels_file="$(mktemp)"
trap 'rm -f "$existing_labels_file"' EXIT
gh label list --limit 200 --json name --jq '.[].name' > "$existing_labels_file" 2>/dev/null || true

missing_labels=()

for item in "${REQUIRED_LABELS[@]}"; do
  IFS='|' read -r name color desc <<< "$item"

  if ! grep -qxF "$name" "$existing_labels_file"; then
    missing_labels+=("$item")
  fi
done

if [ "${#missing_labels[@]}" -eq 0 ]; then
  echo "✅ 标签检查：全部已存在，无需创建。"
  echo "===== Bootstrap 完成 ====="
  exit 0
fi

echo "⚠ 发现 ${#missing_labels[@]} 个缺失的 github-backlog 规范标签："
for item in "${missing_labels[@]}"; do
  IFS='|' read -r name color desc <<< "$item"
  printf "   - %-18s (color: #%s, desc: \"%s\")\n" "$name" "$color" "$desc"
done

if [ "$check_only" -eq 1 ]; then
  echo
  echo "ℹ 当前为 check/dry-run 模式，未执行创建。"
  exit 0
fi

if [ "$auto_yes" -eq 0 ]; then
  if [ ! -t 0 ]; then
    echo
    echo "ERR: 非交互终端环境下，请使用 --yes 确认自动创建缺失标签。" >&2
    exit 1
  fi
  read -r -p "是否在仓库 $repo_name 中创建上述缺失标签？[y/N] " reply
  case "$reply" in
    [yY][eE][sS]|[yY]) ;;
    *) echo "已取消创建。"; exit 0 ;;
  esac
fi

echo "正在创建缺失标签..."
for item in "${missing_labels[@]}"; do
  IFS='|' read -r name color desc <<< "$item"
  echo "创建标签: $name"
  gh label create "$name" --color "$color" --description "$desc" || {
    echo "❌ 创建标签 $name 失败" >&2
  }
done

echo "✅ 缺失标签创建完成。"
echo "===== Bootstrap 完成 ====="
