# ADR-0011：Agent over SSH——ACP over `ssh -T` stdio

- 状态：Accepted（owner 于 2026-11-25 批准）
- 日期：2026-11-25
- 依据：`docs/architecture.md` §6.1、§6.3、§8、§9；ADR-0003（MachineProvider）、ADR-0005（AgentRuntime）、ADR-0008（SSH 接入）；`services/host/agents.mbt` 的 `agent_target_dir`（约 844、862 行）

## 背景

V0.1 的 Agent 会话只在本地 Workspace/Worktree 运行：`agent.start` 在
`services/host/agents.mbt` 的 `agent_target_dir` 中检查
`machine_is_local(...)`，对 SSH 后端的 worktree（约 844 行）和 workspace
（约 862 行）分别返回 `unsupported`（“agent sessions currently run only on
local worktrees/workspaces”）。远程机器已经能注册与探测，Workspace 已能
读写/git/终端，Task/Run 也已在远端执行命令；缺的是 Agent 进程的远程传输。

owner 已批准远程 Agent 项目，但只先做 PoC，不直接建完整远程运行时。必须先
定传输方式，否则 PoC 会各自假设一套连接、认证和失败语义。

## 决策

1. **方法 A：ACP over `ssh -T` 的双向 stdio，不分配 PTY。**
   host 启动本地 `ssh` 子进程；stdin 写 ACP 请求，stdout 读 ACP 响应，stderr
   单独收集。`-T` 明确禁止 PTY，避免提示符、控制字符、密码/口令提示和行编辑
   序列混进 ACP stdout。ACP 仍是换行分隔的 JSON-RPC，传输只负责字节流。

2. **远端命令固定在 Workspace/Worktree 的 cwd 启动，复用现有 SSH 规则。**
   复用 `SshTarget`、`target_options`、`ssh_argv` 与 `remote_exec_command`
   （`packages/providers/ssh/ssh_target.mbt`）：远端命令形如
   `sh -c 'cd -- "$1" && shift && exec "$@"' monexus-run '<cwd>' '<argv0>' ...`。
   cwd 取 Workspace root 或 Worktree path；每个 argv 元素经 `shell_quote`
   作为位置参数传递，脚本本身不含用户输入，因此路径/参数里的元字符保持数据。
   不加 `-tt`，不把整串命令拼进 shell 字符串。命令解析（adapter 是否存在、
   默认 `npx`/`claude-code-acp`）必须在远端执行，host 不能用本地 PATH 代替
   远端事实。

3. **stderr 与 ACP stdout 严格分离。**
   `ssh` 的 stderr 只进有界日志/诊断和错误分类，绝不并入 ACP 解析器；stdout
   只按 ACP 行协议解析。SSH 自身的连接错误（exit 255）按传输失败分类，不能
   当成 Agent 的 JSON 输出或成功结果。

4. **AgentRuntime 通过 ProcessLauncher 边界取得句柄，MachineProvider 不认识
   ACP。**
   三条 Provider 轴保持独立：MachineProvider 负责机器连接、探测与执行事实；
   WorkspaceProvider 负责项目文件、git、终端与 worktree 路径；AgentRuntime
   负责 Agent 的启动、通信、会话。AgentRuntime 不为远端另写一套协议栈，而是
   通过一个 `ProcessLauncher` 内部接缝（不是第四条 Provider 轴）取得本地或
   远程的双工进程句柄（stdin/stdout/stderr + 退出码）；SSH 只是这个接缝的一
   种实现。MachineProvider 不得返回或持有 ACP 类型；WorkspaceProvider 不启动
   Agent；AgentRuntime 不自行打开 SSH 目标或读取机器凭据。

5. **认证与凭据：远端用自己的运行时和登录，host 不搬运密钥。**
   远端 Agent 使用该机器上已安装的 CLI/runtime 及其自己的登录状态；host 不
   复制模型凭据、token 或私钥到远端，也不把主机 `~/.ssh` 内容写进远端
   Workspace。启动时只传显式 `env`（非密钥配置）并统一加
   `env -u CLAUDECODE`，不继承 host 的任意环境变量。密钥值不得进入 argv、
   日志、事件、Artifact 或审计详情；事件里最多出现环境变量名，不出现值。
   SSH 身份仍沿用现有 target 的 `identity`/`known_hosts` 规则。

6. **生命周期与失败语义。**
   - **handshake 超时**：`initialize` + `session/new` 有界超时（沿用
     `MONEXUS_ACP_TIMEOUT_MS`，默认 60s；SSH 连接另有 `ConnectTimeout`）。
     超时即失败并关闭本地 `ssh`，生成可读错误或 readiness Decision，不无限
     挂起。
   - **cancel**：`agent.stop` 走现有 ACP `session/cancel`，等待有界时间；
     adapter 不响应时关闭 stdin 并终止本地 `ssh`，会话结束为 `cancelled`。
   - **远端退出**：观察到远端进程退出（`ssh` 非 255 退出码）时，若在 turn
     中途退出则记为 `interrupted`；正常 turn 结束仍以 ACP `stop_reason`
     （如 `end_turn`）结算。
   - **连接丢失**：无法观察远端进程或退出码（例如 `ssh` exit 255、网络中断、
     读流截断）时记为 `lost`，绝不标记成功。`interrupted`/`lost` 均为终态；
     待处理的 permission Decision 按现有逻辑过期。`interrupted`/`lost` 是
     远端 PoC 的会话语义；落到现有会话状态/stop reason 常量时，由 PoC 决定
     是否新增常量，本 ADR 不改代码。
   - **不自动重连、不自动恢复 transcript**：本设计不做远端进程持久化、
     reattach 或 ACP `session/load` 跨连接恢复，也不自动重启远端 Agent。
     持久化远端 Agent 进程与 reattach 属 V0.2 paired runtime 的工作。V0.1 的
     `agent.resume` 仍是本地会话能力，不能声称对远端可用。
   - **孤儿进程清理**：正常 stop/cancel 通过 ACP cancel、关闭 stdin 并结束本地
     `ssh` 让远端子进程退出；PoC 必须验证远端进程确实结束。连接缺少 RST 或
     网络分区时，远端子进程可能被 sshd 重新托管而存活；此时只能把会话标为
     `lost`，并记录远端 PID（若已获得）供 owner 手工清理，不承诺自动收割。
     不在远端使用 `nohup`/`setsid` 主动制造孤儿。

7. **权限请求仍走现有 Decision 路径。**
   ACP `session/request_permission` 不因传输变化而自动批准或由本地代答；继续
   转成 Decision，进入 Inbox，由 owner 回答后才回写 ACP 响应。传输层不得绕过
   审批，也不新增第二套权限通道。

8. **范围：先 PoC，再决定完整 Remote ACP Runtime。**
   - 第 1 轮：mock ACP over SSH——`initialize`、`session/new`、prompt 流式输出、
     cancel、stderr 分离、远端 cwd 全部通过。
   - 第 2 轮：真实 DSH 在远端 Workspace 中跑一轮。
   - 两轮结果出来后才决定完整 Remote ACP Runtime 的形态与 V0.1.1 范围。本
     ADR 不改变 V0.1 行为：`agent.start` 继续拒绝 SSH 后端，直到 PoC 验收
     通过后另开实现/决策。

## 第 2 轮实现记录（2026-11-25）

本节只记录 PoC 第 2 轮如何落地上面的决策，不改变决策本身。

- **新增常量**：`AGENT_STATE_LOST` / `AGENT_STOP_LOST` /
  `EVENT_AGENT_SESSION_LOST`（传输丢失）与 `AGENT_STATE_INTERRUPTED` /
  `AGENT_STOP_INTERRUPTED` / `EVENT_AGENT_SESSION_INTERRUPTED`（远端进程
  turn 中途退出）。`agent_terminal_state` / `agent_session_end_event` 负责
  stop reason → 状态/事件的映射；`lost`/`interrupted` 都是非 active 终态。
- **退出码观察**：`AgentProcess` 保留创建它的 `ProcessLauncher`，并在 EOF
  后通过 `@process.Process::try_wait()` 做有界观察（每 50 ms 重试，最多约
  2 s）；拿不到状态时返回 unknown，避免 host 永久阻塞。
- **EOF 语义**：仅对 SSH launch 生效。`RuntimeMessage::Eof` 时在 host 锁下
  检查 `runtime.active_prompts`：无 active prompt 保持既有 `exited`；有
  active prompt 时，255、unknown 或本地 ssh 被信号杀死记为 `lost`，其他
  非 255 退出码记为 `interrupted`。两种情况都写可读 `last_error`，不设置
  idle/end_turn，不自动重连或重启。本地 launch 的 EOF 行为本轮不变。
- **终态消费方**：`services/host/tasks.mbt` 的 Run 等待把 `lost` /
  `interrupted` 视为会话结束（不再等到 turn 超时）；桌面状态色把
  `interrupted` 归入警告色，`lost` 归入危险色。pending permission Decision
  仍由 `finalize_agent_session` 正常过期。
- **测试**：`scripts/agent_ssh_smoke.sh` 在临时 loopback sshd 上用 mock ACP
  agent 验证三种情况：杀本地 ssh → `lost`/`lost`/`agent.session.lost`；杀
  远端 mock（非 255 退出）→ `interrupted`/`interrupted`/
  `agent.session.interrupted`；正常 turn 后 EOF → `exited`。纯映射函数另有
  contracts 与 provider 单测。
- **真实主机证据（Debian 13，非本仓库 CI 环境）**：远端 DSH 0.2.2-rc.5、
  Node 24.22.3，命令 `@deepseek-ai/dsh/lib/bin.js --profile acp`，真实模型
  `llm-local` / `DeepSeek-V4.1-Flash-1017-Local-02`；workspace 读写、
  permission Decision、cancel 均通过。第 2 轮同时执行了 kill 本地 ssh
  （`lost`）和 kill 远端 DSH（`interrupted`）两个故障用例，当时二者都错误
  地落到 `exited`——这正是本轮修复的缺陷；修复后的映射由上述 mock smoke
  覆盖，本环境没有 DSH，未在真实主机上复测，也不对 Ubuntu/macOS 作任何
  声明。

## 备选方案

- **PTY（`ssh -tt`）**：拒绝。PTY 会把提示符、控制字符、密码/口令提示和行
  编辑序列混入 stdout，破坏 ACP 帧；还要终端仿真与额外清理。`ssh -T` 的裸
  stdio 更适合机器协议。
- **配对远端 host runtime**：V0.2 方向（`kind=runtime`，ADR-0003）。它解决
  NAT/弱网、持久进程、reattach 与策略双侧执行，但工程量远大于 PoC，不作为
  当前传输。
- **各 Agent 原生 API/SDK**：暂不做。会引入 N 套认证、状态和事件模型，偏离
  ACP 统一会话与现有 Decision 通路。
- **OpenClaw**：拒绝，不进入本产品架构；Paperclip 同样保持在外。

## 后果与风险

- **网络丢失**：会话可能变 `lost`，输出截断。缓解：stderr 分离、有界读、
  观测退出码；不自动重试、不假装成功；owner 通过 Inbox 决定。
- **远端环境漂移**：Node、adapter 版本、登录状态、PATH 与本地不同。缓解：
  在远端做 readiness/handshake，错误可读；PoC 明确记录实际版本；不静默回退。
- **日志与 stderr 卫生**：远端 CLI 可能把提示或敏感信息写到 stderr。缓解：
  有界收集、按现有 secret 规则 redaction、不把原始 env/argv 密钥写入事件或
  Artifact。
- **进程孤儿**：无 PTY 时连接丢失可能留下远端子进程。缓解：正常 stop 关闭
  stdin 并验证退出；`lost` 时记录 PID 供手工清理；持久化与自动收割留 V0.2。
- **远端认证/安装前提**：目标机必须已安装运行时并登录。缓解：readiness
  Decision 加文档说明；host 不搬运凭据/私钥。
- **权限面扩大**：远端 Agent 自己的工具调用可能超出 host 生成的命令面。缓解：
  ACP 权限请求统一进 Decision；PoC 不扩大自动批准；远端侧策略执行仍是 V0.2
  paired runtime 的课题。
- **SSH 命令注入**：路径与参数来自 Workspace 记录。缓解：固定脚本 + 位置参数
  + `shell_quote`；PoC 需覆盖带空格、引号、元字符的 cwd/argv。
- **退出码歧义**：`ssh` 自身失败用 255，远端命令也可能返回 255，仅凭退出码
  无法区分。缓解：优先用 ACP 响应与流 EOF 判定 turn 结束；255 且没有 ACP
  终态时按 `lost` 处理，宁可不确定也不假成功。

**PoC 必须证明**：`initialize`/`session/new`/prompt 流式/cancel 在 `ssh -T`
上可用；stderr 不污染 stdout；远端 cwd 正确；连接断开与远端退出分别得到
`lost`/`interrupted` 且无假成功；正常 stop 后远端进程结束；显式 env 与
`env -u CLAUDECODE` 生效且密钥不进日志/事件/Artifact；权限请求仍落 Decision。
