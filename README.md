# Coordinator & Multi-Agent Dispatch Skills

面向多 Agent 协同开发的任务调度与 Backlog 治理技能库。

通过将大型项目的工作积压（GitHub Issues）进行依赖与冲突分析、合理分组，并利用隔离的 Git Worktree 驱动多个独立 Agent 并行开发，同时由 Coordinator 统一负责冲突巡检与进度护航。

## 包含内容

- **`dispatch`**：Coordinator 调度技能。负责候选 Issue 勘察、代码足迹冲突检测、分组推荐、Worker/Grill Agent 派发与定期巡检。
  - `dispatch/scripts/bootstrap.sh`：依赖环境检查与仓库标准标签体系一键初始化。
  - `dispatch/scripts/scan-collisions.sh`：数据库迁移版本号与 ADR 编号等稀缺顺序标识符的跨分支/跨工作区撞号扫描。
- **`github-backlog`**：基于 GitHub Issues 的六轴治理与互斥认领协议。
  - `github-backlog/scripts/claim-issue.sh`：跨会话结构化认领、活性检测与陈旧释放脚本。

## 依赖要求

1. **`gh` (GitHub CLI)**：已安装并完成认证 (`gh auth status`)。
2. **`herdr`**：用于多工作区与 Agent 终端进程的生命周期管理（推荐基准版本 `0.9.1+`）。
3. **Agent Harness**：至少安装并配置好以下一种：
   - `claude` (Claude Code)
   - `agy` (Antigravity CLI)
   - `opencode`

## 用户级安装方法

本技能库设计为用户级全局安装，各具体开发仓库按需引用。

1. **克隆本仓库到本地固定路径**（例如 `~/coordinator-skills`）：
   ```bash
   git clone <repo-url> ~/coordinator-skills
   ```

2. **安装到用户级技能目录**：
   ```bash
   mkdir -p ~/.agents/skills
   ln -s ~/coordinator-skills/dispatch ~/.agents/skills/dispatch
   ln -s ~/coordinator-skills/github-backlog ~/.agents/skills/github-backlog
   ```

3. **配置 harness 支持**：
   - **Claude Code**：确保 `~/.claude/skills` 能够加载技能。若 `~/.claude/skills` 为目录，可在其下建立软链接指向 `~/.agents/skills/` 对应技能目录，或将 `~/.claude/skills` 本身软链至 `~/.agents/skills`。
   - **OpenCode**：原生扫描 `~/.agents/skills/`，创建软链后即可自动识别。
   - **Antigravity CLI (agy)**：目前原生扫描工作区 `.agents/` 及 `~/.gemini/config/skills/`，详情参考接入报告。

4. **在项目仓库中初始化**：
   在任何目标 GitHub 仓库中，首次使用前执行：
   ```bash
   ~/.agents/skills/dispatch/scripts/bootstrap.sh
   ```
   该脚本将自动验证前置工具，并提示创建 `github-backlog` 所需的 13 个基础标签。

## 许可证 (License)

待定 (Pending discussion)。
