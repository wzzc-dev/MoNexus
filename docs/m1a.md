# M1a — Chat 自举闭环与 M1a-4 验收

状态：自动化的 mock ACP 自举 E2E 已实现并在 Linux 上通过；真实 GUI +
真实 ACP + 已登录 `gh` 的 owner-run 验收 **待执行**。本文只定义和记录验收
方法，不声称 owner 环境已经跑通。

## 1. 闭环范围

M1a 的自举闭环是：

```
Project -> 本地 git workspace -> 隔离 worktree -> Project membership
  -> Chat -> AgentSession(worktree_id) -> Agent 读取 AGENTS.md/docs
  -> 修改 worktree 文件、执行验证命令 -> 可见 transcript
  -> worktree-scoped Git status/diff -> host 重启
  -> ended(host_restarted) + system 中断边界
  -> 同一 Chat 继续 AgentSession(handoff_from_session_id)
  -> 首条 send 注入可见历史 -> worktree commit/push
```

这一闭环建立在已合入的 Chat transcript 持久化、Project membership by Bot
name、`AgentSession.worktree_id` 和 worktree-scoped Git review 之上。M1a-4
只做端到端验收和文档收口，不引入新业务能力。

## 2. 自动化 bootstrap E2E

脚本：`scripts/m1a_bootstrap_e2e.sh`

运行前提：Linux、bash、`jq`、`git`、`node`、`sh`，以及已构建的
`_build/native/**/build/monexus/host/host.exe`。脚本不访问网络，不使用真实
模型、真实 ACP 账号、已登录 `gh` 或 owner 的 `~/.ssh`。

```bash
export PATH="$HOME/.moon/bin:$PATH"
packages="$(bash scripts/native_packages.sh)"
moon build --target native $packages
bash scripts/m1a_bootstrap_e2e.sh
```

当前期望输出（新增检查后行数可能增加）：

```
SUMMARY passed=78 failed=0
```

脚本使用 throwaway `HOME`、state dir、workspace、worktree 和 bare remote，
并以同一 state dir 重启 host。它覆盖两段互相独立的 workspace：

- A 段：MoNexus 风格的 `AGENTS.md` + `docs/` + `notes.txt` 仓库。
- B 段：MoUI 类项目的 `AGENTS.md` + `docs/` + `src/app.txt` 仓库；脚本和
  产品都不硬编码 MoNexus 自身路径。

每项检查打印 `PASS`/`FAIL`，失败时保留并打印 work dir 和 host log。成功时
自动清理；需要保留成功现场时：

```bash
MONEXUS_M1A_E2E_KEEP=1 bash scripts/m1a_bootstrap_e2e.sh
```

关键断言包括：runtime cwd 等于 `worktree.path`；工作树 diff 只含该
worktree 的修改且主 workspace 干净；commit 推送到临时 bare remote；重启后
`end_reason=host_restarted`、恰好一条 system 中断边界；同一 Chat 新
AgentSession 的 `handoff_from_session_id` 指向旧 session；首条 send 正常且
注入可见历史不超过 8 KiB；旧 cursor 不回退；worktree remove 在会话活跃时
被拒绝、结束后成功。

CI 接入位置：`.github/workflows/ci.yml` 的 Linux job
`build-test-acceptance`，在 Acceptance 和 Runtime e2e 之后增加
`M1a bootstrap e2e` 步骤。该步骤失败会直接标红，不依赖 `gh` 或外部服务。
macOS CI 不运行该门禁：脚本是 Linux-first，且 M1a 的 GUI 行为没有在 macOS
上做全量验证；这里明确记录为未覆盖，不会用 SKIP 冒充 PASS。

## 3. owner-run 手工验收

### 3.1 状态

| 项目 | 自动化门禁 | owner-run |
| --- | --- | --- |
| mock ACP + RPC 等价 New Chat 路径 | Linux CI PASS | 不需要 |
| 真实 GUI New Chat / 右栏 Git 审阅 | 不覆盖（用 RPC 等价路径） | **待执行** |
| 真实 ACP 模型回合 | 不覆盖（mock ACP） | **待执行** |
| 真实 GitHub PR | 不覆盖（temp bare remote） | **待执行** |

`M4_REAL_ACP=1` 和真实 PR 都是 opt-in 的 owner-run 验收，不进入 CI
gate。CI 只运行 mock ACP；仓库中的 `M4_REAL_ACP=1` 行为用于
`scripts/runtime_e2e.sh`/`scripts/agent_smoke.sh` 的本地真实适配器探测，
不改变本 E2E 的 mock 边界。

### 3.2 环境

- 有图形会话的 Linux 或 macOS 桌面（Wayland/X11/macOS 窗口；headless 不能
  代替真实 GUI 验收）。
- 已安装并登录的真实 ACP adapter（例如 `claude-code-acp`），且能在本机
  `agent.probe`/`agent.start` 路径上工作。
- 已登录的 GitHub CLI：`gh auth status` 返回成功；目标仓库的 remote 可用
  （SSH 需要 owner 自己的 key）。
- 本地 git clone、`git`、`jq`、`node`，以及要验收的 `monexus` 可执行文件。
- 一个最小项目仓库：`AGENTS.md`、`docs/overview.md`、一个可修改文本文件
  （下文用 `notes.txt`），并可创建 git worktree。

建议先做只读预检：

```bash
monexus version
monexus status
gh auth status
git --version
node --version
```

### 3.3 证据目录

```bash
EVIDENCE="${MONEXUS_STATE_DIR:-$HOME/.monexus}/artifacts/m1a-owner-run/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$EVIDENCE"
{
  date -u
  uname -a
  monexus version
  monexus status
  gh auth status
  git --version
  node --version
} >"$EVIDENCE/environment.txt" 2>&1
```

该目录位于 state dir 的 `artifacts/` 下，不进入仓库提交。至少保存：

```
environment.txt
01-new-chat-worktree.png
02-transcript-cwd.png
03-worktree-git-review.png
04-restart-ended.png
05-continue-handoff.png
06-real-pr.txt
chat-messages.json
events.json
```

接口证据可以在每一步后追加：

```bash
monexus host rpc --method chat.messages \
  --params '{"chat_id":"cht_...","after":"","limit":100}' \
  >"$EVIDENCE/chat-messages.json"
monexus host rpc --method events.list \
  --params '{"since":0,"limit":500}' >"$EVIDENCE/events.json"
```

不要把 token、私钥、adapter 凭据或真实用户主目录写进证据文件。

### 3.4 步骤与预期

1. **准备 Project、workspace、worktree 和 Bot 成员。** 当前 GUI 的
   Projects 页提供打开 workspace 和创建 worktree；Project 的创建/成员管理
   如未提供完整 GUI 表单，可用 CLI/RPC 准备，再用 GUI 验收 New Chat：

   ```bash
   monexus host rpc --method project.create \
     --params '{"name":"M1a owner run","repo_url":"","default_branch":"main","verify":[]}'
   monexus host rpc --method workspace.open \
     --params '{"target":"local","root":"/absolute/path/to/repo"}'
   monexus host rpc --method worktree.create \
     --params '{"workspace_id":"wsp_...","branch":"m1a/owner-run","path":"/absolute/path/to/repo-m1a-owner","base":""}'
   ```

   在 Bots 页面创建/确认一个 active Bot 和真实 ACP Agent；在 Project 页或
   Bot 页按 Bot 名称加入 Project membership。预期：membership 是 active，
   `access=[]`，界面显示 Bot 名称而不是原始 `bot_` id。

2. **真实 GUI New Chat。** 在桌面打开 **New Chat**，按名称选择 Bot、
   Project、Workspace、Agent；Worktree 选择已有的 `m1a/owner-run`，或选择
   **New isolated worktree · monexus/<short>**；点击 **Create Chat**。
   预期：Chat 创建成功，右栏显示 Project、Workspace、Worktree；session 的
   runtime cwd 是 worktree 路径，而不是主 checkout。

3. **真实 ACP 回合。** 发送例如：

   ```
   读取 AGENTS.md 和 docs/overview.md，在 notes.txt 末尾追加 OWNER-RUN-EDIT，
   然后运行 sh -c 'test -f AGENTS.md && echo ok'，报告 cwd 和命令结果。
   ```

   预期：可见 transcript 出现真实 adapter 的 assistant 输出；`notes.txt` 仅在
   worktree 中被修改；验证命令输出 `ok`；报告 cwd 等于 worktree 路径。
   保存截图 `01-new-chat-worktree.png`、`02-transcript-cwd.png`。

4. **右栏 Git 审阅。** 查看 Chat details rail 的 Git status/diff。预期：
   status 只列出 worktree 中的 `notes.txt`；diff 含 `OWNER-RUN-EDIT`；主
   workspace 的 status/diff 不含该修改。保存
   `03-worktree-git-review.png`。

5. **remove guard。** 在会话仍活跃时尝试删除该 worktree。预期：请求被拒绝，
   错误说明存在 non-terminal Chat AgentSession；结束会话后再次删除才成功。

6. **host 重启恢复。** 在同一 state dir 执行 `monexus stop` 和
   `monexus start`，重新打开 Chat。预期：
   - 旧 session 是 `ended`，`end_reason=host_restarted`；
   - 恰好一条 system 中断边界，重复启动不新增；
   - 用户/assistant 历史消息保留；
   - 点击 **Continue Agent session** 后新 session 的
     `handoff_from_session_id` 指向旧 session；
   - 首条 send 正常，注入的可见历史不超过 8 KiB，历史不丢且不重复；
   - 旧 cursor 不回退，新 runtime 从自己的 cursor 开始。

   保存 `04-restart-ended.png`、`05-continue-handoff.png`，以及
   `chat-messages.json`/`events.json`。

7. **真实交付闭环。** 在 worktree 中 commit，推送到真实 remote 的分支，并用
   已登录 `gh` 开 PR：

   ```bash
   git -C /absolute/path/to/worktree add -A
   git -C /absolute/path/to/worktree commit -m "M1a owner-run edit"
   git -C /absolute/path/to/worktree push origin HEAD:m1a/owner-run
   gh pr create --draft --base main --head m1a/owner-run \
     --title "M1a owner-run verification" \
     --body "Owner-run M1a bootstrap verification."
   ```

   预期：临时 remote 分支 head 等于 worktree HEAD，主 workspace HEAD 不变；
   PR URL 写入 `06-real-pr.txt`。真实 PR 由 owner 执行，代码不自动合并；CI
   不使用 `gh`，也不要求真实 PR。

失败时不要删除证据目录；保留 `host.log`、adapter 输出和相关截图，并记录
失败步骤与复现命令。owner-run 结论应在完成后单独更新，未执行时保持
**待执行**。

## 4. 限制

- 本自动化脚本只覆盖 mock ACP 和 host RPC，不覆盖真实模型输出质量。
- Environment/container-backed workspace 不支持 M1 worktree Chat review；
  其 Git 审阅会明确返回 unsupported。该能力不在本 E2E 范围内。
- 未接入 GitHub/CI connector；真实 PR 和真实 ACP 探测是 owner-run，不是
  CI gate。
- macOS 的 GUI 行为没有全量验证；macOS CI 不运行本 Linux-first E2E。
- 不包含同 Chat 切换 Agent、Bot memory 注入、群聊、远程 runtime 持久化和
  M1b/P1 范围。
