# ADR-0012：配对远端 runtime（A1）——控制面留在主控，执行面下沉

- 状态：Accepted（owner 于 2026-11-25 按条件通过 D8，并批准开工 A1.0 设计验证）
- 日期：2026-11-25
- 依据：`docs/architecture.md` §6、§7、§8、§11、§18/D8；ADR-0003（MachineProvider）、ADR-0008（SSH 接入）、ADR-0011（Agent over SSH PoC）；`docs/v0.2-plan.md` A1
- 关系：本 ADR 细化 D8 的 A1 边界；V0.1 的 SSH 直连路径保持为基线、引导与回退通道。

## 背景

V0.1 已用系统 `ssh` 完成了机器、Workspace、Task/Run、终端与真实远程 ACP 的基线；ADR-0011 的 `ssh -T` PoC 也验证了远端 Agent 传输与失败语义。但 SSH 直连有两个结构性限制：

1. 每个操作依赖主控的 SSH 客户端、网络可达性与登录状态；NAT/弱网下不能可靠地维持远端执行。
2. 远端只作为命令目标，没有一个常驻执行面来承载长 Run、PTY 复用、事件补发、执行侧策略和重连。

V0.2 的 A1 要解决这两个问题，同时不能把 MoNexus 变成第二套集群控制面。A1 的最小目标是：主控仍是唯一权威，远端 runtime 只做受控执行与上报；配对建立信任，断线后不重复执行、不制造假成功；SSH 仍可工作并且不被替换。

## 决策

### 1. 角色与权威

- **主控 host（primary）**：组织、成员、Task、Run、Decision、审批结果、事件日志与审计的唯一权威；持有机器/Workspace/Agent 的注册与凭据；对 runtime 下发策略快照。
- **远端 runtime（node）**：`monexus-host --runtime` 的常驻执行节点。它在自己的 state 目录（`~/.monexus/runtime/<runtime_id>/`，0700）保存运行状态、日志、事件 outbox 与策略快照；执行命令/PTY、读写受控 Workspace、承载 AgentRuntime、按策略做本地检查。
- **node 不拥有控制面**：不能创建 Task/Decision、不能写组织/成员、不能批准自己的请求、不能产生权威审计结论。node 的本地状态是缓存与待上报队列，冲突时以 primary 的事件日志为准，可丢弃重建。
- **A1 一对一**：一个 runtime 只登记到一个 primary；支持吊销与重新配对，不支持多主控、集群选主或跨 runtime 迁移。

### 2. 配对与认证

- **由 node 主动外连 primary**，不为 node 打开入站端口。A1 要求 primary 有一个可达的 TLS 端点（公网、内网或既有 VPN/Tailscale 均可）；若 primary 本身完全在 NAT 后，先用现有 SSH 反向隧道引导，公网 relay 不在 A1 范围。
- **一次性短时配对码**：primary 生成高熵配对码，TTL ≤ 10 分钟、单次使用、错误尝试有速率限制；配对码只存哈希，不写日志/事件。node 在配对时提交自己的 `runtime_id`、公钥、版本与能力清单。
- **双向认证**：
  - TLS 保护通道；primary 提供证书，node 在首次配对时显示并固定证书/公钥指纹，后续不静默更换。
  - node 生成机器密钥对，primary 记录公钥并签发按机器 scoped、可吊销的短期凭据；重连用挑战签名，不把长期明文 token 放进 URL、argv、日志或事件。
  - 配对成功后主控写入 enrollment 事件；吊销、轮换、过期与重新配对均产生审计事件。密钥轮换不改变 runtime_id。
- **拒绝重放**：配对码、挑战、审批凭据均带 nonce/有效期，服务端去重；错误/过期/已用的配对码返回统一错误，不泄漏哪一步失败。
- **实现可行性**：A1 spike 先验证 MoonBit `moonbitlang/async` 的 TLS 入口、证书固定和签名库；若某平台缺少可用实现，不降低为明文，改为只支持已验证平台并在 doctor 中拒绝其他平台。

### 3. 传输与协议

- **WSS + JSON-RPC 2.0**，复用 host RPC 的信封约定（请求 id、错误对象、notification），但使用独立的 `runtime.*` 方法命名空间；不做第二条 HTTP/自定义控制协议。
- node 发起连接并维持心跳；断线按指数退避重连，禁止无限快速重试；primary 可下发 `drain`，让 node 停止接新 Run 后安全退出。
- 消息有界：单帧上限、每通道排队上限、stdout/stderr 分块上限与背压；超限断开并生成可读诊断，不静默丢弃关键事件。
- 方法面最小集：
  - `runtime.hello` / `runtime.heartbeat` / `runtime.drain`
  - `runtime.probe`（无副作用）
  - `runtime.exec.start` / `runtime.exec.cancel` / `runtime.exec.status`
  - `runtime.process.*`（通用双工进程流，供 AgentRuntime 使用；协议里不出现 ACP 类型）
  - `runtime.pty.open|resize|input|close`
  - `runtime.fs.*` / `runtime.git.*`（受 Workspace 根目录白名单约束）
  - `runtime.event`（node → primary，带 `run_id`/`session_id`/单调 `seq`）与 `runtime.ack`
- **ACP 边界不变**：AgentRuntime 仍负责 ACP 会话；它通过 `runtime.process.*` 取得双工进程流，MachineProvider 不持有或返回 ACP 句柄。远端 runtime 不理解 ACP 语义，只负责字节流、进程生命周期和资源上限。

### 4. 执行、事件与幂等

- **稳定标识**：Run/会话使用 primary 分配的 `run_id` / `session_id`；node 的每个事件带 `runtime_id`、`run_id`、单调 `seq` 与内容哈希，重连按 primary 最后确认的 cursor 补发。
- **幂等键**：`exec.start`、`pty.open`、写文件等变更请求带 `client_request_id`；node 对已完成/进行中的键返回原结果或当前状态，不重复执行。重复的 `start` 不能创建第二个进程。
- **outbox 持久化**：node 先落本地 outbox 再执行/上报，primary 确认后按游标推进；事件去重以 `(runtime_id, run_id, seq)` 为键。primary 不把“收到的最后一条”当作“run 已完成”。
- **断线语义**：
  - **exec/PTY**：node 上的受管进程继续运行；重连后 primary 查询状态并补齐事件，不重复启动。node 进程真实退出时以退出码/信号结算。
  - **Agent 会话**：A1 支持通过 `runtime.process.*` 启动远端 ACP；连接丢失时，若无法证明进程与控制流仍可恢复，会话按 ADR-0011 记为 `lost`，不自动重连、不假装 transcript 完整。ACP stream 的跨连接 reattach 作为 A1 后续增强，不在首个 spike 承诺。
  - **node 崩溃/重启**：未完成 Run 由 primary reconcile 标为 `lost` 或按策略重试；已结算结果不回滚。重试必须沿用同一幂等键，不能产生重复结算。
- **不假成功**：只有在证据门通过或显式豁免后才结算；断线、超时、未收到退出码都不能记为成功。

### 5. 策略与审批

- primary 向 node 下发带版本/哈希的策略快照；node 在执行前做**同一条**风险检查。快照过期、哈希不匹配或未知策略时，高风险操作拒绝或等待，不按默认放行。
- 高风险命令（安装、宿主挂载、删除、提权、任意 `sh -c` 等）由 node 返回 `approval_required`；primary 创建现有 Decision，owner 回答后下发**绑定请求**的短期审批凭据（包含 run_id、命令摘要、策略版本、nonce、过期时间）。node 校验摘要和有效期后执行一次；不能复用到另一条命令。
- primary 不可达时，高风险操作只能等待或最终 `unverifiable`；不允许离线放行，也不允许 node 自己批准。低风险只读探测可按策略快照在本地放行，但仍记录事件。
- 所有审批、拒绝、过期、策略版本变化均进 primary 审计；node 只保存执行所需的本地快照与结果，不另建审批状态机。

### 6. Workspace 与资源边界

- node 只暴露被 primary 登记的 Workspace 根目录和 runtime state 目录；fs/git/terminal 方法在解析真实路径后做根目录包含检查，拒绝 `..`、绝对路径逃逸、符号链接逃逸和跨 Workspace 访问。
- 写文件使用临时文件 + 原子 rename；删除/移动记录审计事件；工作树操作仍由 git 执行，遵守现有租约与 Worktree 规则。
- 每个 Run/Agent 有 CPU/内存/并发上限；A1 先复用现有每机器 `max_parallel`，资源配额与 cgroup 留到 A2/A5。PTY 与进程在 drain、取消、连接丢失时有明确清理路径；不能自动收割的孤儿进程记录 PID 供 owner 处理。
- node 不以 root 运行；不复制主控 `~/.ssh`、模型凭据或私钥到 Workspace。子进程默认最小环境，显式 env allowlist；密钥值不进入事件、日志、Artifact 或 argv。
- 日志、stderr、事件做有界收集与现有 redaction；诊断中最多出现环境变量名，不出现值。

### 7. 运行与回退

- `machine.add` 增加显式 `provider=runtime` 选项；SSH 仍是默认与回退路径。A1 上线不改变既有 `kind=ssh` 机器的行为、ID、事件或审批路径。
- runtime 安装、版本与 doctor 由独立命令/配置完成；协议版本不兼容时 node 拒绝连接并给出可读错误，不自动降级到不安全协议。
- 吊销或回退：primary 删除 enrollment、关闭端点、作废凭据；node 停止接新 Run，已有 Run 按 drain 完成或取消；本地 state 可丢弃，不以 node 状态恢复控制面。
- 迁移与回退文档必须包含：如何从 runtime 切回 SSH、如何清理 node state/日志、如何确认没有重复 Run。

### 8. 非目标

- 多主控/HA、集群选主、跨 runtime 迁移、跨 runtime 调度。
- 远端独立组织、任务、Decision 或第二套审批。
- 公网 relay/中继服务、WireGuard/Tailscale 的自动编排（可作为部署前置）。
- 自动更新 runtime、任意插件/脚本市场、远程代码执行以外的 Agent 特权。
- 在 A1 首发承诺 ACP 跨连接 reattach；该项需要单独设计。

## 备选方案

- **继续只用 SSH**：保留为基线与回退，但不能满足常驻执行、断线继续与事件补发；不选为 V0.2 唯一方案。
- **公网 relay/集中网关**：对 NAT 最友好，但引入新的托管服务、信任与计费面；A1 不实现，留作部署选项或 V0.3。
- **SSH 反向隧道承载全部 runtime 流量**：可作为 A1 引导与无公网端点时的临时方式，但仍受 SSH 连接生命周期限制，不作为长期传输。
- **把 ACP 放进 MachineProvider**：拒绝；破坏三轴边界。所有远端 Agent 仍经 AgentRuntime。

## 后果与风险

- **安全面扩大**：新增公网监听端点、长期机器凭据与执行侧策略。缓解：TLS、证书固定、scoped/短期凭据、吊销、速率限制、最小方法面、审计与 redaction 测试。
- **状态重复/假成功**：断线重连是最容易出错的部分。缓解：幂等键、持久 outbox、单调游标、证据门、失败即 `lost`，不做“最佳猜测”结算。
- **协议与实现复杂度**：MoonBit TLS/签名可用性和跨平台差异需要 spike 验证；若不可用，A1 缩减到已验证平台，不用明文替代。
- **运维负担**：runtime 需要安装、升级、诊断与日志清理。缓解：doctor、版本握手、drain、显式回退 SSH、文档。
- **网络边界**：primary 必须可达；完全 NAT 对 NAT 不在 A1。缓解：文档明确部署前置，必要时用 SSH 反向隧道或后续 relay。

## 验证计划

1. **配对安全**：正确码、过期、错误、重放、已吊销、证书指纹变化、重复配对均得到预期拒绝；审计无明文配对码。
2. **执行与终端**：远端 exec/PTY 的 stdout/stderr 分流、退出码、超时、取消、资源上限；路径/符号链接逃逸被拒。
3. **重连幂等**：断开后重连补齐事件；同一 `client_request_id` 只执行一次；同一 `run_id` 不重复结算；node 重启后未完成 Run 正确标 `lost`。
4. **策略/审批**：高风险命令进入 primary Decision；审批绑定命令摘要；primary 不可达时停等或 `unverifiable`；策略版本过期拒绝。
5. **Agent 路径**：通过 `runtime.process.*` 跑一次真实 ACP 会话；连接丢失按 ADR-0011 语义结算，不产生假成功。
6. **SSH 回归**：V0.1 的 machine/workspace/task/recovery/agent_ssh smoke 与 acceptance 全部保持绿色；runtime 与 SSH 机器互不污染。
7. **真实部署**：两台机器、无 node 入站端口、至少一次弱网/断线演练；日志与事件经 redaction 检查。

## 实施顺序（A1）

- **A1.0 设计验证（spike）**：TLS/签名/证书固定的最小配对与心跳；不改变 V0.1 路径，不合并为默认能力。
- **A1.1 执行面**：`runtime.exec` / `runtime.pty` / `runtime.fs` / `runtime.git`，根目录白名单、幂等、outbox。
- **A1.2 事件与重连**：游标补发、reconcile、drain/吊销、审计。
- **A1.3 策略与审批**：快照、风险检查、绑定审批、不可达语义。
- **A1.4 Agent 路径**：`runtime.process.*` 接 AgentRuntime，跑真实远端 ACP；不承诺 reattach。
- **A1.5 端到端**：两台真实机器、SSH 回归、断线演练、文档与回退。

A1.0 的 spike 若发现 TLS/签名不可用或与现有打包冲突，不降低安全边界；缩小到已验证平台并回写本 ADR 的后果，不把 A1 标记完成。
