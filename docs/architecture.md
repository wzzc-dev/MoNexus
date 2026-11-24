# MoNexus（墨枢）架构设计 · V0.1

- 版本：0.1（r4）
- 日期：2026-11-25
- 状态：D1–D6 已定，D7 按建议执行，待 M0 spike
- 依据：《MoNexus（墨枢）产品与技术建设总计划》；2026-11-24 本机调研（MoUI 0.9.1 框架、orca-moui、MoUI `examples/mo_workbench`、`examples/terminal/pty_host`、MoSpace `services/remote`）。

## 0. 摘要

1. **交付形态**：MoUI 0.9.1 原生桌面应用（独立仓库）+ 本地守护进程 `monexus-host` + Provider 适配层。三者分开演进，UI 不直接碰 ssh / 文件系统 / 上游 API。
2. **V0.1 验收**：一条垂直切片——主控机上管理本地 + 一台远程 Ubuntu x86_64（RISC-V 延后），在各自 Workspace 执行命令、实时看输出、关窗不中断、重开能恢复。
3. **状态权威**：V0.1 的组织、成员、任务、审批、机器注册与命令策略全部由 MoNexus host 持有；不引入外部控制面，也不预留第二套状态机。
4. **不自研基础设施**：SSH 复用系统 `ssh`（模式来自 MoSpace `services/remote`），终端复用 MoUI `pty_host`，Agent 会话复用 ACP（模式来自 `mo_workbench`）；组织/任务/审批与机器注册只做薄层。
5. **宿主语言**：`monexus-host` 首选 MoonBit（复用 MoSpace 的 services 模式），Node.js 只在接入 Node 生态的上游适配时出现，不进入关键路径。
6. **MoUI 边界**：默认消费发布版；框架缺能力时按官方 vendor 流程在 `vendor/MoUI` 做本地覆盖并向上游提 PR，`vendor/` 不入库（见 §15）。
7. **机管 Agent**：V0.1 放一个 `ops` 种子角色管理机器与 Workspace，走同一套工具与审批；巡检与自愈放 V0.2（见 §9.1、D7）。

## 1. 目标、范围与非目标

### 1.1 V0.1 范围

| 模块 | 范围 | 验收 |
|---|---|---|
| Machine Center | 本地自动发现；SSH 添加/探测/删除；多机器列表与状态 | 能注册一台 Ubuntu 远程机并显示架构/工具链（RISC-V 不进 V0.1） |
| Workspace Center | 本地与远程目录浏览、文件查看/编辑、Git status/diff、终端 | 同一项目在本地与 Ubuntu 上的 Workspace 可打开、可操作 |
| Agent Center | 单 Agent 会话（ACP 优先），输出流、停止、恢复 | 在指定 Workspace 启动 Agent 并看到流式输出 |
| Task Center | 创建任务、选 Agent/机器/Workspace、执行、日志、结果 | 一条任务在本地与远程并行执行并汇总 |
| Activity Center | 事件流（连接、运行、审批、产物） | 关窗重开后事件不丢、可回放 |
| 安全 | 风险分级、执行端审批、审计 | 高风险命令必须审批，记录可查 |

### 1.2 明确不做（V0.1）

- 不做多组织、多用户、云端控制面；不做自动任务拆分与 CEO Agent。
- 不接 RISC-V（首批只支持 macOS/Linux 本机 + 远程 Ubuntu x86_64；RISC-V 在 SSH profile 稳定后再加）。
- 不做 Docker/K8s/Coder 集成；不做 SFTP 协议栈；不做完整 VT 终端仿真。
- 不引入外部组织/机器控制面；组织、任务、审批与机器注册都在 MoNexus 内实现。
- 不 fork MoUI，不把 MoNexus 放进 MoUI 的 `moon.work`；不改上游项目代码。
- 不做跨平台一致的打包之外的分发体系（首版先定一个主控平台）。

### 1.3 成功标准（MVP）

> 在主控机一个窗口里，把 MoUI 项目在本地与 Ubuntu 两处各构建一次，看到实时输出，关闭应用后远程任务继续，重开后恢复状态并生成兼容性报告。（RISC-V 作为后续版本的同一流程扩展。）

## 2. 系统架构

### 2.1 总览

```text
┌──────────────────────────── 主控机 ────────────────────────────┐
│  MoNexus Desktop（MoUI 0.9.1 / MoonBit）                       │
│  UI · 只读投影 · 用户意图 · 审批交互                            │
│              │  JSON-RPC over WebSocket（127.0.0.1 + token）    │
│  monexus-host（MoonBit 可执行）                                 │
│   ├─ Domain + SQLite（事件日志 / 投影 / 设置）                   │
│   ├─ Scheduler（能力匹配）+ Policy（执行端判定）                 │
│   ├─ Provider Registry                                        │
│   │   ├─ LocalMachineProvider / SSHMachineProvider             │
│   │   ├─ LocalWorkspaceProvider / SSHWorkspaceProvider         │
│   │   ├─ ACPAgentRuntime / 本地进程 Runtime                     │
│   │   └─ 组织/任务（内建，SQLite）                              │
│   └─ EventBus + Reconcile                                      │
└───────┬──────────────────┬──────────────────┘
   SSH / Tailscale     SSH + tmux
   Ubuntu x86_64       RISC-V（后续）
```

外部系统（按版本接入）：

| 版本 | 外部系统 | 角色 |
|---|---|---|
| V0.1 | 系统 ssh、本地 PTY、ACP stdio agent | 机器连接、终端、Agent 运行时 |
| 后续 | 待实际需求决定 | 新接入必须先写 ADR 并保持 Provider 边界；不预置外部控制面 |

### 2.2 分层

| 层 | 组件 | 职责 | 不做什么 |
|---|---|---|---|
| Presentation | `apps/desktop`（MoUI） | 渲染投影、收集意图、审批 UI | 不执行 ssh、不读写业务数据库、不调上游 API |
| Application | `monexus-host` | 任务生命周期、调度、策略、事件、存储 | 不渲染 UI |
| Domain | `packages/domain` | 对象、状态机、不变量 | 不含 IO |
| Contracts | `packages/contracts` | RPC 方法、事件 schema、错误码 | 不含业务规则 |
| Providers | `packages/providers/*` | 机器/工作空间/Agent 适配 | 不跨 Provider 调用 |
| Storage | SQLite（本地） | 事件、投影、设置、引用 | 不存远端代码副本 |
| Transport | 本地 WS + 远程 SSH | 连接与传输 | 不做自研广域协议 |

### 2.3 五条架构原则

1. **UI 只读投影**：桌面端只持有 host 投影的缓存；所有写操作都是 RPC。UI 崩溃不影响任务。
2. **Provider 接口优先**：业务层只认 `MachineProvider` / `WorkspaceProvider` / `AgentRuntimeProvider`，不认 SSH、ACP 等具体形态。
3. **执行端权威**：状态与审批在真正执行的一侧判定；UI 的「允许」只是请求，不是授权。
4. **事件溯源**：所有状态变化发事件，事件带 ID 与序号，支持断线补偿与重放；WebSocket 推送只是加速，不是唯一真相。
5. **单一控制面**：每个领域只有一个可写权威；MoNexus 是 V0.1 全部业务状态的唯一可写方。

## 3. 领域模型

### 3.1 对象与 ID

| 对象 | ID 前缀 | 关键字段 | 说明 |
|---|---|---|---|
| Organization | `org_` | name, policy, created_at | V0.1 单组织（`org_local`） |
| Agent | `agt_` | name, role, profile, runtime_ref, permissions | 身份与模型解绑 |
| Machine | `mch_` | provider, host, arch, os, status, capabilities, last_seen | 计算节点 |
| Workspace | `wsp_` | project_id, machine_id, root, git_ref, state | 某一机器上的执行环境 |
| Project | `prj_` | name, repo_url | 逻辑项目，跨机器 |
| Task | `tsk_` | title, goal, status, assignee, workspace_id, parent_id | 工作目标 |
| Run | `run_` | task_id, agent_id, machine_id, status, idempotency_key, started_at, heartbeat_at | 一次执行尝试 |
| Session | `ses_` | agent_id, runtime, run_id, external_id, state | Agent 会话 |
| Artifact | `art_` | run_id, kind, uri, bytes, sha256 | 产物引用，不复制大文件 |
| Event | `evt_` | type, subject, seq, payload, causation_id | 不可变事件 |

ID 规则：`前缀 + ULID`（字典序即时间序）；所有跨对象引用只存 ID，不存路径或名字。

### 3.2 关系

```text
Organization 1─* Team 1─* Agent
Agent 1─* Session 1─* Run *─1 Task
Project 1─* Workspace *─1 Machine
Task 1─* Run 1─* Artifact
```

**硬不变量**：Project / Workspace / Machine 三者分离；同一 Workspace 同一时间最多归属一个活跃 Run（并发代码任务必须用 Git Worktree 隔离）。

### 3.3 状态机

| 对象 | 状态 |
|---|---|
| Machine | `online / connecting / offline / degraded / pending_approval` |
| Agent | `idle / working / waiting / blocked / error / stopped` |
| Task | `draft / planned / ready / running / waiting_approval / blocked / failed / succeeded / cancelled` |
| Workspace | `available / creating / running / stopped / error / disconnected` |
| Run | `queued / running / waiting_approval / succeeded / failed / cancelled / lost` |

状态只能由 host 的状态机迁移；每次迁移同时写事件与投影（同一事务）。

## 4. 状态权威与同步

| 领域 | 权威（写） | MoNexus 存什么 | 版本 |
|---|---|---|---|
| 组织、成员、任务、审批、预算 | MoNexus host | 业务表 + 事件（SQLite） | V0.1 |
| 机器注册、连接、命令面、设备能力 | MoNexus host / MachineProvider | 机器表 + 策略 + 连接投影 | V0.1 |
| 项目、Workspace 映射、本地偏好、运行记录、事件 | MoNexus host | 本地 SQLite | V0.1 |
| Agent 会话内容 | Agent Runtime（ACP 等） | 会话元数据 + 事件索引 + 产物引用 | V0.1 |

规则：

- **R1**：组织、任务、审批、机器注册的模型由 `packages/domain` 定义并版本化；任何后续外部接入只能以 `external_id` 关联，不得改写本地状态机。
- **R2**：MoNexus 是 V0.1 所有业务状态的唯一可写权威；不保留第二份可写副本。
- **R3**：事件与投影不一致时，以事件重放修正投影；标记 `stale` 并触发 reconcile。
- **R4**：删除用 tombstone 事件，不做物理级联删除。
- **R5**：内部 reconcile 按游标扫描事件；失败退避，不阻塞任务执行。

## 5. 事件模型

### 5.1 信封

```json
{
  "id": "evt_01J...",
  "org_id": "org_local",
  "type": "run.started",
  "ts": "2026-11-25T10:00:00.123Z",
  "subject": { "kind": "run", "id": "run_01J..." },
  "seq": 42,
  "causation_id": "evt_01J...",
  "correlation_id": "tsk_01J...",
  "idempotency_key": "run:run_01J...:started",
  "payload": { "task_id": "tsk_01J...", "machine_id": "mch_...", "workspace_id": "wsp_..." }
}
```

- `seq` 按 subject 单调递增；事件表另有全局 `rowid` 供游标拉取。
- 事件不可变；修正用补偿事件（`*.corrected`），不改历史。
- 幂等键全局唯一，重复投递直接丢弃。

### 5.2 事件族

```text
machine.registered / machine.probed / machine.connected / machine.disconnected / machine.degraded
workspace.opened / workspace.changed / workspace.closed
agent.registered / agent.session.started / agent.session.output / agent.session.stopped / agent.error
task.created / task.assigned / task.status.changed / task.cancelled
run.queued / run.started / run.progress / run.heartbeat / run.waiting_approval
run.succeeded / run.failed / run.cancelled / run.lost
approval.requested / approval.granted / approval.denied
artifact.created / artifact.gc
sync.reconcile.started / sync.reconcile.completed / sync.conflict
```

`agent.session.output` 是高容量事件：只保留有界缓冲 + 落盘日志引用，不全量进投影。

### 5.3 存储与回放

- SQLite 表：`events`（append-only）、`projections_*`（machines/workspaces/tasks/runs/sessions）、`cursor`、`outbox`。
- 订阅：桌面端带 `last_event_id` 连接，先补拉再订阅；游标过期时以快照 + `Full` 重建。
- 保留：状态事件 90 天；输出日志按 Run 保留 30 天或按体积上限回收，回收前写 `artifact` 引用。

## 6. Provider 契约

所有接口在 `packages/contracts` 定义，语言为 MoonBit；错误统一 `ProviderError { Unavailable(reason), Unauthorized, Denied, NotFound, Timeout, Upstream(code, msg) }`。

### 6.1 MachineProvider

```text
trait MachineProvider {
  probe(target) -> MachineProfile          // 无副作用探测
  connect(target) -> ConnectionHandle
  capabilities(handle) -> CapabilitySet
  run(handle, CommandSpec) -> RunHandle    // 异步，返回 run_id
  openSession(handle, SessionSpec) -> PtyHandle
  heartbeat(handle) -> Status
  close(handle) -> Unit
}
```

- `CommandSpec { argv: Array[String], cwd, env, timeout_s, risk: RiskTier, stdin? }`，**不接受整串 shell**；需要管道/重定向时显式包装 `sh -c` 并标为高风险。
- `MachineProfile { arch, os, hostname, shell, toolchains[], has_docker, has_gui, notes }`，RISC-V 单独 profile（`no assumed Docker/GUI`，V0.1 之后）。

### 6.2 WorkspaceProvider

```text
trait WorkspaceProvider {
  open(machine, root) -> WorkspaceHandle
  list(handle, path) -> Array[Entry]
  stat / readText / writeText / move / remove
  gitStatus(handle) -> GitStatus
  gitDiff(handle, range) -> Diff
  watch(handle, cb) -> Subscription
  openTerminal(handle, size) -> PtyHandle
}
```

- 本地用 MoUI `apphost` 的文件/PTY 能力；远端用 `ssh` 上的 POSIX 命令（见第 8 节）。
- 写文件必须走临时文件 + 原子 rename；远端写同样。

### 6.3 AgentRuntimeProvider

```text
trait AgentRuntimeProvider {
  start(session_spec) -> SessionHandle     // 异步
  send(handle, Message) -> Unit
  stop(handle) -> Unit
  resume(handle) -> SessionHandle          // 仅当 runtime 支持
  stream(handle) -> Stream[RuntimeEvent]
}
```

- V0.1 首个实现：ACP stdio（`mo_workbench` 的 `acp_native_transport` 是现成参考，需补 Linux 入口）。
- 第二个实现：本地 CLI Agent 的逐行 stdout 模式（无结构化协议时降级）。
- 会话规格 `SessionSpec { agent_id, workspace, command, args, env_allowlist }`；host 只拿会话元数据和事件，不解析模型输出语义。

### 6.4 组织与任务（内建）

组织、成员、任务与审批由 host 直接管理（SQLite），不经过外部 Provider；`packages/domain` 定义字段与状态机，`services/host` 提供服务。V0.1 只有一个可写权威，不为不存在的集成预留复杂度。

### 6.5 调度与策略

```text
fn schedule(task, agents, machines) -> Plan
  // 规则：需求(arch/os/toolchain/docker/gpu) → 能力匹配 → 可用性 → 默认机
fn evaluate(cmd: CommandSpec, target, agent) -> Decision // allow | ask | deny
```

调度只做能力匹配，不做 AI 资源优化；策略判定在 host（本地执行）与远端执行包装器两侧执行，执行前均校验。

## 7. monexus-host

### 7.1 职责

- 持有任务/Run 生命周期与状态机；持有事件日志与投影。
- 通过 Provider 执行；管理并发、队列、重试、心跳、幂等。
- 提供本地 RPC 给桌面端；提供审批判定与审计。
- 维护事件与投影的一致性；以事件重放修正投影，不做反向写。

### 7.2 进程与生命周期

- 独立可执行 `monexus-host`，由桌面端启动并看护（单实例锁 + 端口文件）；桌面端退出后 host 继续运行（配置项 `keepAlive`）。
- 长任务与 Agent 会话必须有宿主级持久性：本地用 `tmux`（或独立子进程 + 日志文件），远程用 `ssh -tt` + 远端 `tmux`；host 重启后按 `run_id` + `tmux` 会话名重连。
- 心跳：每 5s 写 `run.heartbeat`；30s 无心跳标 `lost`，由 reconcile 决定重试或失败。

### 7.3 RPC

- WebSocket JSON-RPC 2.0，监听 `127.0.0.1` 随机端口；启动时把 `{port, token}` 写到 `~/.monexus/host.json`（0600）。
- 方法：`host.status`、`machine.add/probe/remove/list`、`workspace.open/list/read/write`、`session.start/send/stop`、`run.start/cancel`、`task.create/list`、`approval.respond`、`events.subscribe(since)`。
- 事件用 notification 推送；RPC 全部幂等（带 `client_request_id`）。

### 7.4 语言决策

选 MoonBit 的理由：MoSpace 已在 MoonBit 中验证 fs、PTY、ssh 调用、设置持久化与 worker 并发；与桌面端共享 `domain`/`contracts`，避免两套类型；不引入 Node 运行时到关键路径。Node 不进入关键路径；若未来接入外部系统，只作为独立 sidecar 或 HTTP 客户端出现。

## 8. SSH 接入（V0.1 主路径）

### 8.1 基线

MoSpace `services/remote` 已验证的模式（Apache-2.0，可复用并注明来源）：

- `Target { host, port, identity, timeout_seconds }`
- `ssh_argv(target, remote_command)` → `ssh -o BatchMode=yes -o ConnectTimeout=...`
- `shell_quote(path)` → 单引号 + `'\''` 转义，远端只假定 POSIX shell
- `list_dir` = `ls -1ap --`，读 = `cat --`，写 = 临时文件 + `mv`
- 复用用户 `~/.ssh/config`、agent、跳板机；不引入 sftp

### 8.2 V0.1 扩展

| 能力 | 实现 |
|---|---|
| `probe` | `uname -srm`、`[ -n "$SHELL" ]`、`command -v git gcc clang cmake moon` |
| `run` | `ssh target -- sh -lc <quoted argv>`（或 `ssh -tt ... tmux new-session -d -s monexus-<runid>`） |
| 日志 | 远端 `tmux pipe-pane` 写 `~/.monexus/logs/<run_id>.log`，host 定期 `tail` 增量 |
| 结果 | 退出码 + 结尾标记 `__MONEXUS_DONE__<code>`，避免把日志当状态 |
| 恢复 | `tmux has-session` → 重连；`tmux capture-pane` 补最近输出 |
| 终端 | `ssh -tt` 交互；V0.1 用 MoUI 的转写区 + 整行输入，不做 VT 网格 |
| 文件 | 沿用 MoSpace 的 ls/cat/写临时文件；大文件/目录递归后续再评估 sftp |

### 8.3 配置策略

- **显式配置优先**：主机、用户、端口、身份文件存 host 数据库；`~/.ssh/config` 继承作为显式开关（默认开，但记录实际生效的 `ssh -G` 解析结果）。
- 无人值守任务禁止依赖环境变量/agent 的隐式身份；启动时 `ssh -o BatchMode=yes` 探测失败直接报 `Unauthorized`。
- 远端只假定 POSIX shell；RISC-V 设备（V0.1 之后）按 `MachineProfile` 声明能力，不假设 Docker/GUI。

## 9. Agent 运行时

- **协议**：ACP 优先（stdio JSON-RPC）。`mo_workbench/acp_native_transport` 已实现协议与 worker；当前只接 macOS 入口，V0.1 需补 Linux 入口（这也是 M0 spike 的验证点）。
- **降级**：不支持 ACP 的 CLI 用逐行 stdout 模式，输出进 `agent.session.output` 事件，退出码决定结果。
- **隔离**：同一 Workspace 上并发 Agent 必须各自使用 Git Worktree（`git worktree add ../<branch>`），Workspace 租约由 host 管理。
- **会话所有权**：Adapter 拥有进程；host 拥有元数据、心跳、取消与恢复请求；桌面端只是观察者。

### 9.1 机管 Agent（`ops`，V0.1 种子角色）

- **是角色，不是特权通道**：`ops` 是组织里的普通 Agent（`role=ops`），只用 host 对所有 Agent 开放的同一套工具操作机器与 Workspace；命令仍受 §11 策略与审批约束，不绕过权威层。
- **V0.1 工具面**：机器列表/探测（`machine.list` / `machine.describe`）、SSH 连通性检查、Workspace 创建/归档、Run 诊断（心跳、日志、退出码）。写操作（安装工具链、删除 Workspace、重启机器）一律落 `waiting_approval`。
- **不进关键路径**：没有 `ops` 时，UI 也能完成同样的操作；`ops` 只是把多步操作变成一次可审计的 Run，方便验证 Agent→工具→策略→审批这条链路。
- **V0.2**：routine 巡检（磁盘/负载/失联机器）、失败任务自动重试、扩容建议。

## 10. UI 架构

- **依赖**：默认只消费发布版 `wzzc-dev/moui@0.9.1` 及子包（`moui_skia_renderer` 等）；独立仓库、`moui new` 结构。**MoUI 缺能力时按官方 vendor 流程**：`git clone` 到 `vendor/MoUI`（gitignored），在 `moon.work` 加入实际用到的模块做本地覆盖，在 MoNexus 中验证后向 `wzzc-dev/MoUI` 提 PR；上游发布后 bump 版本并移除覆盖（见 §15）。
- **结构**：`app/` 持有 `Model/Msg/update/view`；平台入口 `linux_skia/`、`macos_skia/`、`web_wasm/` 只做薄接线；`scenes/` 供截图与状态快照。
- **Model 划分**：`HostProjection`（只读缓存）+ `UiState`（选中、面板、输入）；RPC 调用作为 `Effect`，事件订阅作为 `Subscription`。
- **页面（V0.1）**：Home（组织概览 + 全局任务输入）、Machines、Projects/Workspaces、Agents/Sessions、Tasks、Activity、Settings。
- **复用映射**：

| 需要 | 来源 | 用法 |
|---|---|---|
| 壳、侧栏、标签、命令面板 | orca-moui | 参考结构与视觉，确认许可后再复制代码 |
| Agent 会话面板 | `examples/mo_workbench` | ACP 传输与 chat 表面 |
| 终端 | `examples/terminal/pty_host` | 本地 PTY；远端另行包装 |
| 文件树 / 远程浏览器 / 设置页 | MoSpace | 交互与实现模式（Apache-2.0） |
| 桌面壳、多窗口 | `examples/mo_desktop`、`examples/multi_window` | 多窗口与菜单模型 |

- 视觉：深石墨灰 + 青绿强调（计划 §5.7），IDE 式侧栏 + 主工作区；不在首版做完整代码编辑器。
- 可访问性/自动化：`moui_agent` + `moui_agent_mcp` 提供语义树与 MCP 表面，可用于后续「AI 操作 UI」的场景，V0.1 不启用。

## 11. 安全与权限

### 11.1 风险分级与策略

| 等级 | 示例 | 默认 |
|---|---|---|
| 低 | 列目录、读文件、git status | allow |
| 中 | 写文件、运行测试、构建 | allow（Workspace 授权内） |
| 高 | 删除批量文件、改系统配置、安装依赖 | ask |
| 极高 | root、部署、密钥、网络策略 | deny（除非显式一次性授权） |

### 11.2 强制执行点

1. 桌面端提交 `CommandSpec`，不能提交整串 shell。
2. host `evaluate()` 按 Agent/Workspace/Machine 策略判定；`ask` 进 `approval.requested`，UI 只是应答通道。
3. 执行端二次校验：本地执行前由 host 校验；远端 SSH 只执行 host 生成的受限 argv，命令面由机器策略表控制。
4. 每次判定写审计事件（谁、什么、为何、结果）。
5. 密钥只进系统 keychain / 0600 文件；不写日志、不进事件 payload。

### 11.3 威胁与对策

| 威胁 | 对策 |
|---|---|
| Agent 通过配置文件绕过授权 | 策略在 host 进程内，配置只读；命令解析拒绝 shell 元字符 |
| 远端主机被误路由 | 显式目标优先，记录 `ssh -G` 生效值 |
| host 被本地其他用户访问 | WS 仅 127.0.0.1 + 随机端口 + token 0600 |
| 产物里带密钥 | Artifact 写入前做模式扫描，命中则拒绝并告警 |

## 12. 存储

| 数据 | 位置 | 说明 |
|---|---|---|
| 事件、投影、设置、机器注册 | `~/.monexus/monexus.db`（SQLite） | WAL；迁移脚本版本化 |
| 运行日志 | `~/.monexus/logs/<run_id>.log` | 远端日志在目标机 `~/.monexus/logs` |
| 产物 | 原机器路径或对象存储 | host 只存 URI + 哈希 + 大小 |
| 远端代码 | 不复制 | Workspace 只存引用 |

不把远端仓库全量同步到本地；不做全局文件索引（V0.1）。

## 13. 可靠性与恢复

| 场景 | 行为 |
|---|---|
| 桌面端退出 | host 与远端 tmux 继续；重开后补拉事件 |
| host 崩溃 | 启动时扫描 `running` Run：tmux 会话在则重连，不在则标 `lost` 并进入 retry |
| SSH 断线 | 心跳缺失 → `disconnected`；退避重连；运行不因短断线失败 |
| 重复派发 | `idempotency_key` + 唯一索引；第二次派发返回既有 Run |
| 远程机器关机 | 心跳超时 → `lost` → 按策略重试或失败，产物部分保留 |
| 多 Agent 同项目 | Workspace 租约 + Git Worktree；无租约拒绝启动 |
| Workspace 被删除 | 运行前 `stat` 校验；失败标 `failed` 并保留日志 |

测试：单元（状态机/策略/事件幂等）、Provider 契约（本地/SSH 双实现）、恢复矩阵（上表逐项）、UI（导航/状态）、安全（越权/注入/密钥泄漏）。

## 14. 里程碑与验收

| 里程碑 | 内容 | 验收 | 估算 |
|---|---|---|---|
| M0 spike | 壳 + 本地 PTY + SSH 执行 + ACP 会话（`mo_workbench` Linux 入口） | 一个窗口里本地与远程各跑一条命令，ACP agent 有流式输出 | 1–2 天 |
| M1 桌面壳 | orca-moui 结构 + host 连接 + 导航 | 可启动、可连 host、页面可切换 | 3–5 天 |
| M2 机器注册 | SSH 添加/探测/删除、多机器、状态 | Ubuntu 可注册并显示 profile（RISC-V 延后） | 4–6 天 |
| M3 Workspace | 文件树、读写、Git status/diff、本地/远程终端 | 本地与 Ubuntu 上打开同一项目 | 5–8 天 |
| M4 Agent 会话 | ACP 启动、流式输出、停止、恢复 | 指定 Workspace 启动并看到输出 | 4–6 天 |
| M5 Task/Run/事件 | 任务创建、调度、并行、事件流、产物 | 一条任务在本地与远程并行并汇总 | 5–8 天 |
| M6 恢复与安全 | tmux 重连、审批、审计、恢复测试 | 关窗/断线/重启三场景通过 | 3–5 天 |
| M7 打包 | host 看护、应用打包、首次运行 | 干净机器一键启动 | 2–3 天 |

合计约 24–38 人日（不含 V0.2/V0.3 集成）；比计划的 112–180 小时更宽，因为双平台打包与恢复/安全测试按经验上修。每个里程碑必须产出可运行版本。

D7 的 `ops` 角色不计入上表：它复用 M4 的会话与 M6 的审批通路，接入约 +1–2 天；若推迟到 V0.2，里程碑不变。

## 15. 仓库与工程约束

```text
MoNexus/
├── apps/desktop/            # MoUI 应用（app/ + 平台入口 + scenes/）
├── packages/
│   ├── domain/              # 对象、状态机、不变量
│   ├── contracts/           # RPC、事件、错误
│   └── providers/
│       ├── machine-local/
│       ├── machine-ssh/
│       ├── workspace-local/
│       ├── workspace-ssh/
│       └── agent-acp/
├── services/host/           # monexus-host
├── docs/
│   ├── architecture.md
│   └── adr/
└── deployment/
```

约束：

1. 桌面端默认只依赖发布版 `wzzc-dev/*`。**MoUI 缺能力时走 vendor 流程**（MoUI `docs/vendor-workflow.md`）：clone `wzzc-dev/MoUI` 到 `vendor/MoUI`（gitignored，不进提交）、在 `moon.work` 加实际用到的模块做本地覆盖、在 MoNexus 中验证并跑 MoUI 对应 gate，然后向 MoUI 提 PR；上游发布后 bump 版本并移除覆盖。禁止提交 `vendor/`，禁止没有上游 PR 的孤儿补丁。
2. `domain` 与 `contracts` 不依赖 MoUI、HTTP、SQLite。
3. Provider 之间不直接调用；跨域编排只在 host。
4. 每个重大依赖/边界变化先写 ADR：0001 总体架构、0002 host 与 RPC、0003 Machine Provider、0004 数据模型与事件、0005 Agent Runtime、0006 权限模型、0007 UI 与 MoUI 边界、0008 SSH 接入。
5. CI：Linux + macOS 构建，只用注册表版本（不启用 vendor 覆盖）；RISC-V 的远程 smoke 在后续版本加入。桌面 UI 测试用 `moon test` + scene 快照。

## 16. 决策记录（2026-11-25 定稿）

| # | 决策 | 决定 | 影响 |
|---|---|---|---|
| D1 | `monexus-host` 语言 | **MoonBit**（复用 MoSpace services，类型共享） | Node 只在接入上游生态时出现，不进关键路径 |
| D2 | host ↔ 桌面 RPC | **WebSocket JSON-RPC + token** | stdio 只作调试用途 |
| D3 | SSH 配置策略 | **显式优先 + 可选继承 `~/.ssh/config`** | 无人值守行为可预测 |
| D4 | 组织/任务层的最小范围 | **单组织 + 团队/角色 + 任务 + 审批**；目标/预算放 V0.2 | 自研工作量与 V0.2 计划 |
| D5 | 首个打包/主控平台 | **Linux 开发机先行，macOS 随后** | 影响 CI 与签名/分发 |
| D6 | 仓库初始化 | **`git init` + 私有远端**；远端地址待 owner 提供 | M0 前完成 |
| D7 | 机管 Agent 的范围 | **V0.1 种子角色 `ops`**：只读诊断 + 写操作需审批；完整巡检/自愈放 V0.2（见 §9.1） | 若推迟到 V0.2，V0.1 只留 UI/API，不加人日 |

已确认（2026-11-25）：V0.1 不接 RISC-V；不引入外部组织/机器控制面（组织、任务、审批、机器连接由 MoNexus 自研）；MoUI 缺能力时使用官方 vendor 流程（见 §15，`vendor/` 不入库、改动必须有上游 PR）。

这也意味着 V0.2/V0.3 不能再按「接外部组织层/节点网络」来排：组织与任务层自研做到多深、是否自建常驻节点，都在 V0.1 结束后重新规划。

## 17. 风险登记

| 风险 | 影响 | 对策 |
|---|---|---|
| 自研控制面范围膨胀 | 组织/任务层铺得过大、延期 | 固定 V0.2 最小集；事件模型先行；Skill/Resource Center 不进 V0.1 |
| MoUI 版本漂移 | 构建/行为变化 | 锁 0.9.1；升级单独里程碑；不 fork |
| vendor 覆盖失同步 | 升级困难、孤儿补丁 | 按 `docs/vendor-workflow.md`：每个依赖改动必须有上游 PR；`vendor/` 不入库；CI 用注册表版本 |
| 依赖系统 ssh | Windows/受限环境不可用 | 首版仅 macOS/Linux；Windows 走 OpenSSH 或 V0.3 自研常驻节点 |
| 只支持 POSIX shell | 设备差异 | MachineProfile 探测；非 POSIX 明确不支持 |
| ACP 在 Linux 未接线 | Agent 会话阻塞 | M0 spike 先验证，失败则降级 stdout 模式 |
| 远程机器只能靠 SSH | 无主动注册/节点策略，弱网与 NAT 场景受限 | SSH + Tailscale 作为长期基线；若引入常驻节点，策略必须在节点侧执行并被 Provider 抽象 |
| 多 Agent 文件冲突 | 代码损坏 | Worktree + Workspace 租约 |
| 范围膨胀 | 交付延期 | 固定 MVP 场景；Skill/Resource Center 不进 V0.1 |

## 附录 A：事件类型清单

见 §5.2；新增事件必须在 `contracts/events` 注册 schema，旧事件只增字段不删字段。

## 附录 B：本机参考实现索引

| 主题 | 路径 | 可复用点 |
|---|---|---|
| 远程 SSH 浏览 | `/home/chuang/Code/MoSpace/services/remote/remote.mbt` | `Target`、`ssh_argv`、`shell_quote`、ls/cat/写 |
| 远程 UI/worker | `/home/chuang/Code/MoSpace/app/remote_view.mbt`、`app/worker.mbt` | 任务队列、UI 不阻塞 |
| 本地 PTY 终端 | `/home/chuang/Code/MoSpace/services/terminal/` | PTY 生命周期、ack 流控、转写 |
| ACP 传输 | `/home/chuang/Code/MoUI/examples/mo_workbench/acp_native_transport/` | ACP stdio 协议与 worker |
| 真 PTY 示例 | `/home/chuang/Code/MoUI/examples/terminal/pty_host/` | `pty.c` + MoonBit 绑定 |
| 桌面壳 | `/home/chuang/Code/MoUI/examples/mo_desktop/` | 菜单栏、Dock、多窗口 |
| Agent IDE 壳 | `/home/chuang/Code/orca-moui/` | 信息架构与视觉（需确认代码许可） |
| MoUI 约束 | `/home/chuang/Code/MoUI/AGENTS.md`、`docs/invariants.md` | 包边界与发布约束 |
| MoUI vendor 流程 | `/home/chuang/Code/MoUI/docs/vendor-workflow.md` | 缺能力时 clone/覆盖/上游 PR/回退 |
