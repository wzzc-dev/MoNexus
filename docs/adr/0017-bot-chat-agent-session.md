# ADR-0017：Bot / Chat / AgentSession 领域模型——身份、执行与迁移

- 状态：Accepted（2026-11-27，owner 已确认模型并指示开始实现）
- 日期：2026-11-27
- 依据：`docs/architecture.md` §2.3、§3、§5、§6.3、§7、§9.2、§10、§11；ADR-0004（数据模型与事件）、ADR-0005（Agent 运行时）、ADR-0006（权限模型）、ADR-0007（UI 与 MoUI）、ADR-0012（配对远端 runtime）、ADR-0015（技能包）、ADR-0016（账户托管）；`packages/contracts/agent.mbt`、`packages/contracts/task.mbt`、`packages/contracts/events.mbt`、`services/host/agents.mbt`、`packages/machines/agent_store.mbt`
- 关系：本 ADR 正式化 owner 已确认的 Bot/Chat/AgentSession 模型。它不改变 A1 的「主控唯一权威」、A5 的账户/凭据边界或 ADR-0006 的策略判定点；只重新划分身份、执行与用户可见会话的对象边界，并给出旧对象的安全迁移。接受本 ADR 后，ADR-0005 的「每 Agent 独立记忆」、ADR-0007 的 Agents/Sessions 页面和 ADR-0015 的 `scope=agent` 语义需要同步改成「Bot 长期身份 / Agent 执行器」两轴；在完成文档同步前，所有新设计必须注明 legacy Agent 与 new Agent worker 的区别，不能静默混用。

## 背景

V0.1 已经有一个事实上的长期身份：`agent_id` 跨 Run 存在，有独立 home、`AGENTS.md`、`MEMORY.md`、权限、技能绑定和 credential binding。运行态又把一次 ACP 会话记录成 `AgentSessionRecord`，而 `agent.start` 目前用 `agt_<ULID>` 作为会话 id。于是同一个人格身份和一个运行时会话在名字、ID 前缀和 UI 上都可能叫 Agent，产生三个直接问题：

1. **身份与执行器混淆**：同一个人格的长期记忆、权限和项目关系，与「用哪个 CLI、模型、工具执行」被压进同一个名词；换软件时无法表达「同一个 Bot 换一个执行器」。
2. **会话与聊天混淆**：现有运行态 session 同时承担用户可见对话线程和进程/ACP 句柄两种职责；一个 Chat 想跨多个执行 session 时没有稳定的用户可见对象。
3. **迁移歧义**：现有 `agent_id` 可以是任意合法字符串，现有 session id 又由 host 分配为 `agt_`；同一个 `agt_` 值可能既是旧身份 id，又是旧 session id。任何全局裸 ID 查找都会在迁移时产生错误指向。

owner 已确定的模型是：**Bot 是长期人格身份，Agent 是该 Bot 下的固定软件执行器，Chat 是用户可见的持久对话，AgentSession 是 Chat 内的一次执行 session，Project 是工作范围**。切换 Agent/软件保持同一个 Chat，只结束旧 AgentSession、开始新 AgentSession，并显示交接边界。只有显式「新建 Chat」才产生新 Chat。

本 ADR 的核心结论：

- Bot、Agent、Chat、AgentSession、Project 都是 host 的领域对象；事件日志是唯一权威，Bot/Project 视图只是同一 Chat 投影的不同索引，不复制 Chat。
- Bot 的权限策略是上限；Agent 的有效权限是 Bot 上限、项目成员资格、Agent 配置/工具/技能和任务范围的交集。切换 Agent 或创建 Agent 不能扩大权限，也不能复用旧审批。
- Bot 长期记忆只有一份，所有 Agent 共享；Agent 只有工作/会话上下文。需要独立长期人格时，必须建新 Bot，不能给某个 Agent 克隆一份记忆。
- 新对象使用新的规范 ID 前缀；旧 `agt_` 通过**按引用类型区分的 alias 表**兼容。迁移一次性完成，旧存储只读，禁止双写，不存在第二个可写权威。

## 决策

### 1. 领域对象、所有权与不变量

#### 1.1 对象定义

| 对象 | 规范 ID | 所有者/权威 | 语义与关键字段 |
|---|---|---|---|
| Organization | `org_` | 主控 host | 现状不变；V1 仍为单组织 `org_local`。所有对象都必须带 `org_id`。 |
| **Bot** | `bot_<ULID>` | 主控 host | **一个人格身份**。有名称、persona/instructions、共享长期记忆引用、home、权限上限、项目成员关系、Agent 创建策略、Agent 数量/并发上限和软件 allowlist。Bot 不是群聊，也不是团队容器。 |
| **Agent** | `agw_<ULID>` | 主控 host | Bot 下的长期专用执行器，必须且只能属于一个 Bot。字段包括 `bot_id`、专长/标签、固定 `runtime_binding`（软件/适配器、模型、工具、技能与运行配置的指纹）、权限子集、可用状态、创建/退休时间。`agw_` 是新的 worker 命名，刻意避开旧 `agt_`。 |
| **Chat** | `cht_<ULID>` | 主控 host | 用户可见、持久的对话线程，有参与者（V1 为 Bot）、可选 `project_id`、状态和 Chat transcript/summary。Chat 是唯一用户可见线程对象，不因从 Bot 页还是 Project 页进入而复制。 |
| **AgentSession** | `asn_<ULID>` | 主控 host | 一个 Agent 在一个 Chat 内的一次执行 session。字段包括 `chat_id`、`agent_id`、内部 `runtime_session_id`、项目/工作区范围快照、权限快照哈希、状态、开始/结束和 `handoff_from_session_id`。它是执行分段，不是 Chat 参与者。 |
| **Project** | `prj_<ULID>` | 主控 host | 工作范围，沿用现有 Project 字段（repo、default branch、verify 等）；增加成员关系和归档状态。Bot 可属于多个 Project；一个 Chat 最多一个 Project。 |
| ChatParticipant（关系） | `(chat_id, bot_id)` | 主控 host | Chat 的参与者关系，V1 只允许一个 active Bot 参与者；未来群聊可增加多个 Bot。Agent 永远不能直接成为 Chat 参与者。 |
| ProjectMembership（关系） | `(project_id, bot_id)` | 主控 host | Bot 对 Project 的访问关系；项目范围 Chat 的所有 Bot 参与者都必须有 active membership。 |
| BotMemory（逻辑对象） | 不单独暴露 ID | 主控 host | Bot 的共享长期记忆命名空间。每个 Agent 通过 host 读取同一份 Bot memory，不拥有独立长期记忆副本。 |
| AgentWorkingContext（逻辑对象） | 随 `asn_` 存在 | 主控 host | Agent 在某个 AgentSession 内的工作上下文、工具临时状态和可见摘要。默认不跨 AgentSession 持久化。 |

现有 `Run`、`Task`、`Decision`、`Artifact` 仍是一等对象，ID 前缀保持 `run_`、`tsk_`、`dec_`、`art_`。它们的新关系见 §1.3。

#### 1.2 硬不变量

以下不变量必须由 host 在领域命令/事务中校验；UI 的隐藏按钮、过滤器和表单校验不算约束。

1. **I1 身份与 Chat 分离**：Bot 是长期身份，Chat 是对话线程。Bot 不是群聊，不能把 Bot 当作 Chat 容器；Chat 也不能替代 Bot 的 persona、权限或记忆。
2. **I2 Agent 归属唯一**：一个 Agent 必须属于恰好一个 Bot；一个 Bot 可以有多个 Agent。Agent 不是 Chat 参与者，Chat 参与者只能是 Bot。
3. **I3 会话参与合法**：AgentSession 的 Agent 所属 Bot 必须是该 Chat 的 active 参与者；项目范围 Chat 还要求该 Bot 有 active Project membership。
4. **I4 V1 单 Bot、单 active AgentSession**：V1 每个 Chat 恰好一个 active Bot 参与者，且最多一个非终态 AgentSession。未来群聊放松参与者数量，但每个参与 Bot 仍最多一个非终态 AgentSession。
5. **I5 顺序而非并行人格**：一个 Chat 可随时间有多个 AgentSession，但它们在 Chat 内是顺序的；切换 Agent 产生新 AgentSession，不新建 Chat。只有显式「新建 Chat」命令产生新 Chat。
6. **I6 运行时绑定固定**：Agent 的 `runtime_binding` 创建后不可变。换软件 = 选择/创建该 Bot 的另一个 Agent；不允许在同一 Agent 或同一 AgentSession 内静默改 CLI、模型或执行适配器。
7. **I7 共享记忆**：Bot 只有一份长期记忆；同一 Bot 的所有 Agent 共享它。Agent 不得克隆、分叉或拥有独立长期身份记忆；需要独立长期身份时创建新 Bot。
8. **I8 权限只取交集**：Agent 有效权限永远不超过 Bot 权限上限；项目范围 Chat 还要经过 Project membership 和项目策略。切换 Agent、创建 Agent、选择不同软件都不能扩大权限。
9. **I9 审批不可转移**：审批/Decision 绑定具体的 AgentSession、Action 或 Run，只对当前作用域有效；新 AgentSession 重新评估权限，不继承旧审批、临时 token 或工具状态。
10. **I10 单一权威**：主控 host 的事件日志与事务是唯一可写权威。Bot 页与 Project 页是同一 Chat 投影的索引；节点/runtime 只持有执行句柄与本地运行态，不持有 Bot/Agent/Chat 的可写权威。
11. **I11 项目 Chat 的参与资格**：项目范围 Chat 的所有 Bot 参与者都必须有该项目访问权；无项目 Chat 只出现在 Bot 视图，不进入 Project 视图。
12. **I12 受控创建**：新 Agent 的创建受 Bot 的 `Off / Ask / Auto` 策略、Agent 数量上限、并发上限、软件 allowlist 和 Bot 权限上限共同约束；创建与选择成功/拒绝都必须审计。
13. **I13 归档不等于删除**：Bot、Agent、Chat、Project 的归档/退休是 tombstone 语义，不做物理级联删除；归档对象保留历史事件与原 ID 的只读访问。

#### 1.3 与现有 Session/Run 的关系

现有实现中没有一个独立的 `agents` 投影表：`agent_id` 是自由字符串，`agent.start` 每次分配 `agt_<ULID>` 的 `AgentSessionRecord.id`，session 记录里同时有 `agent_id`、mode、command、args、workspace/worktree、ACP session、状态和 transcript 边界。`Run` 另有 `session_id` 指向这个运行态 session。因此本 ADR 不做「把 Agent 表改名为 Bot」这种简单替换，而是按语义重建：

| 现有对象/字段 | 本 ADR 中的归属 | 迁移后的含义 |
|---|---|---|
| 旧 `agent_id` + `state_dir/agents/<agent_id>/` home + `AGENTS.md`/`MEMORY.md` + 旧 Agent 权限、技能、credential binding | **Bot**（迁移中的 legacy Agent identity） | 旧身份变成一个 Bot；home、persona/instructions、长期记忆、权限上限和项目相关关系迁入 Bot。 |
| 旧 `AgentSessionRecord`（运行态 `agt_<ULID>` session） | **Chat + AgentSession + 内部 runtime session** | 用户可见线程变成 Chat；执行分段变成 AgentSession；原 session 记录保留为 host 内部的 runtime 句柄/执行元数据，不再是用户可见 Chat 的权威。 |
| 架构文档中的 `Session`（`ses_`） | 兼容 alias → **AgentSession** | 现有 host 实际未分配 `ses_`；如外部记录出现 `ses_`，只能按 session 引用类型解析为 AgentSession alias，不能当 Bot/Agent id。 |
| `Run`（`run_`） | 保留 **Run** | Run 仍是一次执行尝试/派工，不变成 Chat 或 AgentSession。新增可选 `chat_id`、`agent_session_id` 关联；`Task`/`Run` 的旧 `session_id` 指向 runtime session 句柄，解析到对应 AgentSession。 |
| `Task`（`tsk_`） | 保留 **Task** | Task 可关联 Chat/AgentSession（可选），但 Task 仍是工作目标；不把 Chat 当作 Task。 |
| `Decision`（`dec_`） | 保留 **Decision** | 审批/提问仍走 Inbox。作用域增加 `agent_session_id`/`chat_id`（可选）；旧审批只对旧 AgentSession 有效。 |
| `Artifact`（`art_`） | 保留 **Artifact** | 仍引用 Run/AgentSession；Chat 只引用 Artifact，不复制大文件。 |
| `Project`（`prj_`） | 保留 **Project** | 字段与 `prj_` 前缀保留；新增 Bot membership、归档状态与 Project Chat 视图。 |

关键边界：

- **Chat 不是 runtime session**。Chat transcript/summary 是用户可见对话的权威；runtime session 的原始 stdout、ACP 消息和工具中间态是执行元数据，不自动等于用户可见 Chat message。AgentSession 引用 runtime session；Chat 通过 AgentSession 边界组织历史。
- **一个 AgentSession 可以有零个或多个 Run**；一个 Run 最多关联一个 AgentSession 和一个 Chat。多个 Run 不能合并成新的 Chat，Chat 也不是 Run 的替代。
- **一个 Chat 可以有多个 AgentSession**。旧模型「每次 agent.start 就是一个 session」的 UX 在迁移后映射为「每次旧 session 变成一个 Chat + 一个 AgentSession」；未来同一 Chat 内的切换不再创建 Chat。
- **Bot 回复带执行元数据**：每条 `role=assistant` 的 Chat message 必须记录产生它的 `agent_session_id`（并可由 host 派生 `agent_id`）；用户/系统消息可为空。Agent 仍是内部执行元数据，不是 Chat 参与者。
- 现有 `agent.session.*` 事件继续表示 runtime session/执行句柄事件；新 Chat/AgentSession 领域事件使用 `chat.agent_session.*` 命名，避免与旧事件类型混淆。两者都写同一个 `events` 表，但投影和语义不同。

### 2. ID、alias 与命名迁移

#### 2.1 规范 ID

新对象只由 host 分配以下规范前缀：

| 用途 | 规范前缀 | 说明 |
|---|---|---|
| Bot | `bot_` | 旧 Agent identity 迁移后的规范身份 |
| Agent（执行器） | `agw_` | 新 worker；不复用 `agt_` |
| Chat | `cht_` | 用户可见稳定线程 |
| AgentSession | `asn_` | Chat 内执行分段 |
| Project | `prj_` | 保持现有前缀 |
| Run / Task / Decision / Artifact / Event | `run_` / `tsk_` / `dec_` / `art_` / `evt_` | 保持不变 |

`agt_` 和 `ses_` 在新规范中不再用于新对象。`agt_` 只作为旧对象 alias 出现；`ses_` 只作为文档/外部旧引用的 alias。任何新写入不得再生成 `agt_` 或 `ses_`。

#### 2.2 旧 `agt_` 冲突的处理

现有代码有两个可能撞值的来源：

- 旧身份：调用方传入的 `agent_id` 可能是 `agt_<ULID>`，也可能完全不带前缀；
- 旧运行态 session：host 自己分配 `agt_<ULID>`，并写进 `AgentSessionRecord.id` 与 `Run.session_id`。

因此不能建立一个「裸 `agt_` → 一个对象」的全局 alias。host 使用**按引用类型区分的 alias 表**：

```text
legacy_aliases(
  alias_kind,       -- agent_identity | agent_session | architecture_session
  alias_value,      -- 旧值原样保存，不做大小写/前缀猜测
  canonical_kind,   -- bot | agent_session
  canonical_id,
  migration_run_id,
  created_at,
  UNIQUE(alias_kind, alias_value)
)
```

解析规则：

1. 旧 `agent_id` 字段、旧 Agent 视图链接、旧权限/技能/credential 的 `agent` scope → `alias_kind=agent_identity` → Bot。
2. 旧 `session_id`、旧 `AgentSessionRecord.id`、旧 session 链接、旧 `Run.session_id` → `alias_kind=agent_session` → AgentSession；再由 AgentSession 找 Chat 做稳定跳转。
3. `ses_` 仅按 `architecture_session` 解析为 AgentSession alias；找不到则返回可读的 `legacy_not_found`，不能猜测成 Bot/Agent。
4. API/存储读取必须携带期望类型；**禁止裸 ID 自动跨类型回退**。同一个 `agt_x` 同时存在于 identity 和 session alias 中是合法的，但只能被对应类型的字段解析。
5. alias 表是只读兼容层，不是第二套对象表；alias 只指向规范对象，不承载权限、状态或可写字段。规范对象被归档时 alias 仍可读，但写操作返回 `archived`/`legacy_read_only`。

迁移预检必须分别扫描两个 alias 命名空间。若同一 `(alias_kind, alias_value)` 指向多个不同规范对象，或旧字段无法判定类型，立即中止迁移并输出冲突清单，不能静默择一。

#### 2.3 旧 API/深链兼容

- 旧 `agent.list` 等身份 RPC 通过兼容适配器返回 Bot 视图；旧 `agent.start` 解析旧 identity 为 Bot，选择该 Bot 的迁移 Agent，按旧语义创建新 Chat + AgentSession，并在响应中同时返回新 `chat_id`、`agent_session_id` 和 legacy alias。它调用 host 的同一领域命令，不写旧表。
- 旧 `agent.send/read/stop` 以旧 `session_id` 解析为 AgentSession；新 UI/新客户端使用 `chat.agent_session.*`。两种入口共用同一权威和同一实现，不能各写一份。
- 旧 `agent/<old_id>` 深链解析为 Bot；旧 `session/<old_id>` 深链解析为 AgentSession，并重定向到其 Chat 的稳定地址。历史链接永远不解析成另一个同值对象。
- 旧 `Task`/`Run`/`Decision`/credential/skill 记录在新的读取投影中包含 `bot_id` 和新的 `agent_id`（worker）视图；旧 JSON 字段只保留在 `_legacy` 只读快照中。新写入不使用旧字段承载新语义。

### 3. 状态机与转换

#### 3.1 Bot

| 当前状态 | 允许转换为 | 触发 | 守卫 |
|---|---|---|---|
| `active` | `suspended` / `archived` | owner 操作 | 归档前必须结束或转交其项目 Chat 的 active AgentSession；有未结算的 active 会话时返回冲突。 |
| `suspended` | `active` / `archived` | owner 操作 | 恢复前重新校验软件 allowlist、项目成员和权限快照。 |
| `archived` | 无（V1） | 归档 | V1 不物理删除；只读历史。恢复另立事件，不在本 ADR 的 V1 范围。 |

#### 3.2 Agent

| 当前状态 | 允许转换为 | 触发 | 守卫 |
|---|---|---|---|
| `provisioning` | `active` / `retired` | 创建完成或失败 | 必须满足 Bot 策略、cap、allowlist、权限子集；失败不产生可用 Agent。 |
| `active` | `suspended` / `retired` | owner/策略操作 | 退役前结束其 active AgentSession，或要求先切换。 |
| `suspended` | `active` / `retired` | owner 操作 | 恢复前重新校验 runtime binding、软件 allowlist 和 readiness。 |
| `retired` | 无 | 退役 | 终端；要换软件/重新启用，创建新 Agent，不复活旧 binding。 |

`runtime_binding` 在 `provisioning` 期间确定，进入 `active` 后不可变。`runtime_binding` 至少包含软件/适配器标识、命令或 ACP 启动方式、模型 profile、工具/技能能力和版本/哈希；它不包含秘密。模型或软件变化必须产生新 Agent（或先退役再创建），不能修改原 Agent。

#### 3.3 Chat 与 ChatParticipant

| 对象 | 当前状态 | 允许转换为 | 说明 |
|---|---|---|---|
| Chat | `active` | `archived` | 归档前结束 active AgentSession；归档后只读，不能新建 AgentSession。 |
| Chat | `archived` | `active` | 显式恢复；恢复时必须重新验证参与者与项目访问。 |
| ChatParticipant | `active` | `removed` | 移除唯一参与者前必须结束 active AgentSession；项目范围 Chat 移除参与者后不得留下无权限参与者。 |
| ChatParticipant | `removed` | `active` | 重新加入必须重新校验 Project membership 和 Bot 状态。 |

V1 的 Chat 写入守卫：

- 创建 Chat 时恰好写入一个 BotParticipant；
- `chat.participant.added` 在 V1 仅允许在创建时或有明确迁移/兼容动作时发生，最终 active Bot 参与者数必须为 1；
- 未来群聊可加入多个 Bot，但每个 Bot 的 active AgentSession 仍最多一个，且参与者必须对 Chat 的项目范围有访问权。

#### 3.4 AgentSession

| 当前状态 | 允许转换为 | 触发 | 说明 |
|---|---|---|---|
| `starting` | `active` / `failed` | runtime readiness/握手 | 失败写 `chat.agent_session.*` 终态或 `audit.recorded`，不留下幽灵 active session。 |
| `active` | `waiting` / `ending` / `failed` / `lost` | Agent 状态变化、停止、故障 | `waiting` 表示等待 Decision/输入，不是新的 Chat。 |
| `waiting` | `active` / `ending` / `failed` / `lost` | Decision 回答、取消、故障 | 回答旧 session 的 Decision 不能让新 session 获得授权。 |
| `ending` | `ended` / `failed` / `lost` | 正常收尾或异常 | `ended` 带 `end_reason`。 |
| `failed` / `lost` / `ended` | 无 | 终端 | 新执行必须创建新 AgentSession，不能复活终端 session。 |

`end_reason` 至少覆盖 `turn_end`、`cancelled`、`error`、`exited`、`host_restart`、`lost`、`interrupted`、`agent_switch`、`project_access_revoked`、`chat_archived`。UI 必须能区分正常结束、主动切换、权限撤销和故障。

#### 3.5 Agent 切换/交接

切换必须走一个 host 领域命令 `chat.agent.switch`，不能由 UI 直接改 session 字段：

1. 解析目标 Agent；目标必须属于当前 Chat 的 Bot、状态为 `active`、软件在 Bot allowlist 内；目标 Agent 的 `runtime_binding` 必须与旧 Agent 不同（否则是同 Agent 重新开始，不是软件切换）。
2. 在切换提交前完成目标 runtime readiness/凭证准备；准备失败则旧 AgentSession 保持原状态，不产生交接。
3. 在同一 host 事务中按顺序写 `chat.agent_session.ended`（旧 session，`end_reason=agent_switch`）、`chat.agent.switched`（可见交接边界，带旧/新 Agent、旧/新 session 和权限快照哈希）、`chat.agent_session.started`（新 session）。三事件的 `correlation_id` 相同；新 session 继承范围见 §5。
4. 新 AgentSession 只能继承 Chat transcript/summary、Bot 长期记忆和当前 Project/Workspace 范围；不得继承旧 session 的隐藏上下文、临时工具状态、runtime 进程、session token、旧审批或旧权限快照。host 在 `started` 前重新调用策略评估并写入新的权限快照哈希。
5. 事务失败则 runtime 准备被丢弃；不允许出现旧 session 已结束但新 session 无记录、或两个 active AgentSession 并存。

#### 3.6 Project 与 ProjectMembership

| 对象 | 当前状态 | 允许转换为 | 说明 |
|---|---|---|---|
| Project | `active` | `archived` | 归档前结束其范围 Chat 的 active AgentSession；归档后不新建 Chat。 |
| Project | `archived` | `active` | 显式恢复；恢复后重新校验成员和 Chat 参与者。 |
| ProjectMembership | `active` | `removed` | 移除前必须处理引用该 Project 的 Chat；不能留下参与者无权限的项目 Chat。 |
| ProjectMembership | `removed` | `active` | 重新加入写 membership 事件，恢复后重新评估所有 active session。 |

项目成员移除导致某个项目范围 Chat 的 Bot 失去访问时，host 必须结束该 Chat 的 active AgentSession（`end_reason=project_access_revoked`），拒绝新 turn/Run，并在 Inbox 创建可读 Decision 让 owner 选择重新授权、添加其他有权限参与者或归档 Chat。不能继续用旧 session 的权限偷偷执行。

### 4. 权限、审批与 Agent 创建策略

#### 4.1 权限继承：Bot 是上限

对一次 AgentSession 的请求，host 计算：

```text
effective_permission =
  organization_policy
  ∩ bot.permission_ceiling
  ∩ project_policy(project_id, if project-scoped)
  ∩ project_membership(bot_id, project_id, if project-scoped)
  ∩ agent.permission_scope
  ∩ task/session scope
  ∩ tool/skill allowlist
```

运行时的策略判定还可以进一步拒绝（例如具体命令风险、workspace 租约、机器能力），但任何一级都不能被其他级扩大。具体规则：

- **Bot 上限不是建议值**：Agent 的权限子集、技能声明、工具请求、Task 范围只能取更小集合；不存在「Agent 自报权限后取并集」或「首次允许即永久」。
- **Project access 是硬门**：项目 Chat 在创建、添加参与者、选择 Agent、开始 AgentSession、每次 turn/Run 启动和策略判定时都检查 active membership。创建 Agent 或选择另一个 Agent 不会改变 Project membership。
- **审批作用域**：Decision 绑定 `agent_session_id`，有 Run 时再绑定 `run_id`；一次性授权消费后不可复用。旧 AgentSession 的审批、session token、临时工具状态在新 AgentSession 中全部不可见且不可转移；敏感操作必须产生新的 Decision。
- **切换不继承**：切换后权限快照重新计算；如果旧 session 有额外授权，新 session 不会自动获得。旧审批可以在 Inbox 中作为历史记录查看，但不能对新 session 生效。
- **项目成员撤销立即收紧**：撤销 membership 是安全事件；active session 结束、后续 Run 拒绝，不能依赖下一次 UI 刷新或进程自行退出。
- **Agent 不能绕过 Bot**：Agent 的创建者、调用者、技能、记忆或 Chat message 都不能授予 Bot 上限之外的权限；Bot 的权限变更本身也要审计。

host 仍是唯一策略判定点；节点只执行由主控签发的策略快照/授予，不能自行放宽或把旧 session 授权复用给新 session。

#### 4.2 Agent 创建策略：Off / Ask / Auto

每个 Bot 有且只有一个三态创建策略；owner 可以把它称为「开关」，领域语义固定为三态：

| 策略 | 行为 |
|---|---|
| `Off` | 禁止创建新 Agent（包括为解决软件切换而创建新 Agent）；现有 active Agent 仍可使用。请求返回 `agent_creation_disabled` 并写审计。 |
| `Ask` | 创建 Agent 前必须产生一个 owner Decision；Decision 必须带 Bot、runtime binding 哈希、请求的软件/权限范围、cap 与 allowlist 校验结果。只有批准且再次通过校验后才创建；拒绝/超时写 `bot.agent.creation_denied`。 |
| `Auto` | 在 Bot 的 Agent 数量上限、active AgentSession 并发上限、软件 allowlist 和权限上限内自动创建，不需要逐实例 owner Decision；仍写 `bot.agent.created` 审计。新工具或权限提升仍按 §4.1 进入审批。 |

无论策略为何，创建都必须满足：

- `runtime_binding.software_id` 在 Bot 的软件 allowlist 中；不在 allowlist → 拒绝，不回退到任意 CLI；
- 该 Bot 的 active Agent 数不超过 `agent_count_cap`；并发 active AgentSession 不超过 `agent_concurrency_cap`；
- 新 Agent 的权限/工具/技能声明不超过 Bot 上限；
- 创建请求带 `client_request_id`，host 在同一事务中检查 cap、写 `bot.agent.created` 与投影；
- `Ask` 的 Decision 一次性消费，批准后若 cap/allowlist 已变化必须重新校验，不能凭旧 Decision 强行创建；
- 创建、选择、拒绝和策略变更均进入审计事件；UI 只能展示但不能替代 host 校验。

`Auto` 不是「无限自治」：没有全局无上限 spawn，没有绕过 cap 的隐藏队列，没有由 Agent 自行扩大自己的工具或权限。

#### 4.3 Chat 参与者与权限

- V1 只有一个 Bot 参与者；创建 Chat 时写入 participant，之后切换 Agent 不改变参与者。
- 添加 Bot 参与者（未来群聊或迁移）必须校验 Bot active、项目成员资格（项目 Chat）和 Chat 状态；移除参与者必须结束其 active AgentSession。
- 项目成员关系不会因 Chat 创建而自动产生；Chat 创建要求已有 membership。迁移阶段的 membership 由证据推导，见 §7。
- Chat 的 Project 变更必须在没有 active AgentSession 时提交；否则先切换/结束 session，再写 `chat.project.changed`。这避免新 Project 范围被旧 session 的隐藏状态继承。

### 5. 记忆与上下文边界

#### 5.1 Bot 长期记忆

- 每个 Bot 只有一个长期记忆命名空间，建议落在 `state_dir/bots/<bot_id>/`（迁移完成后旧 `state_dir/agents/<agent_id>/` 只读）。`AGENTS.md` 一类的 persona/instructions 归 Bot；`MEMORY.md` 或结构化记忆条目归 Bot。
- 同一 Bot 的所有 Agent 共享同一份记忆，不存在 Agent 私有 `MEMORY.md`，也不存在「先复制一份再各自改」的行为。Agent 启动时由 host 注入有界摘要；Agent 不能直接改共享文件。
- 记忆写入必须经 host：`bot.memory.write.requested` → 权限/敏感内容检查 → 需要时生成 Decision → `bot.memory.write.committed` 或 `.denied`。每次提交记录 `bot_id`、发起 AgentSession/Agent、摘要/字数、内容哈希、审批 Decision（若有）和 diff Artifact 引用；不记录秘密原文。
- 记忆不是权限来源，也不会因为写在记忆里就获得工具、项目或审批权。记忆内容视为不可信用户内容，不能伪装系统指令。
- 独立长期人格必须建新 Bot。不能通过给两个 Agent 不同的记忆副本制造两个长期身份；也不能合并两个 Bot 的记忆来创造新人格。

#### 5.2 Agent 工作上下文与交接

- Agent 的长期可复用部分只有配置：固定 runtime binding、工具/技能声明、权限子集和 Bot 分配。Agent 的对话/工作上下文属于 AgentSession，默认随 session 结束而终止。
- AgentSession 可保留有界 transcript 引用、摘要、工具调用审计和 Artifact；这些都是执行上下文，不等同于 Chat 的用户可见 transcript。
- 新 AgentSession 只继承：当前 Chat 的 transcript/summary、Bot 长期记忆和当前 Project/Workspace 范围。它不继承旧 session 的隐藏 prompt、ACP 内存、临时文件、工具 token、未完成计划、旧审批或旧权限快照。
- 每次结束/切换 session 时，host 生成有界 summary 和 memory diff 引用；用户可在 Chat 交接边界看到「由哪个 Agent 执行、切换到哪个 Agent、权限是否重新评估」，但不能把旧 session 的内部上下文带入新 session。

### 6. 事件、投影与幂等

#### 6.1 事件信封与唯一权威

新对象不使用第二套事件表，也不新建第二套审批/审计队列。所有事件使用现有 `EventEnvelope`：

```text
id, org_id, type, ts, subject, seq,
causation_id, correlation_id, idempotency_key, payload
```

规则：

- `events` 表仍是 append-only 唯一事件日志；新对象的投影（`bots`、`agents`、`chats`、`chat_participants`、`agent_sessions`、`project_memberships`、`legacy_aliases`）只由事件重建。
- 事件与新投影在同一 SQLite 事务中提交；outbox 只在事务成功后发布。UI 的 WebSocket 推送只是加速，事件/投影才是权威。
- AgentSession 的 `seq` 使用其聚合 subject `chat/<chat_id>`，因此同一 Chat 的消息、参与者变化、session 开始/结束和交接边界有稳定的 Chat 流顺序；payload 必须包含 `agent_session_id`。Bot 的事件 subject 为 `bot/<bot_id>`；Project membership 的 subject 为 `project/<project_id>`；迁移事件 subject 为 `migration/<migration_run_id>`。
- 高容量 runtime 输出仍走既有 `agent.session.output`/bounded buffer，不把完整 stdout 复制进 Chat 投影；Chat message 只存用户可见内容或 Artifact 引用。

#### 6.2 事件目录

下表是必须注册的事件。payload 只列关键字段，实际实现可增加只读快照，但不得写秘密、完整 argv 或不受限正文。

| 事件 | subject | 触发 | 关键 payload | 幂等键/守卫 |
|---|---|---|---|---|
| `bot.created` | `bot/<bot_id>` | 创建 Bot | bot_id、org_id、persona_ref、memory_ref、permission_ceiling_hash、create_policy、actor、source(migration/manual) | `bot.create:<client_request_id>`；重复返回同一 Bot。 |
| `bot.updated` | `bot/<bot_id>` | 更新名称/persona/home 等 | changed_fields、version、actor | `bot.update:<bot_id>:<version>:<client_request_id>`；旧版本冲突。 |
| `bot.policy.changed` | `bot/<bot_id>` | 改 Off/Ask/Auto、cap、软件 allowlist | 旧/新策略、caps、allowlist hash、actor | `bot.policy:<bot_id>:<version>:<client_request_id>`。 |
| `bot.permissions.changed` | `bot/<bot_id>` | 改权限上限 | old/new ceiling hash、actor | 只允许缩小或显式审批的扩大；`bot.permissions:<bot_id>:<version>:<client_request_id>`。 |
| `bot.archived` | `bot/<bot_id>` | 归档 | reason、active_session_count、actor | `bot.archive:<bot_id>:<client_request_id>`；终端 V1。 |
| `bot.agent.created` | `bot/<bot_id>` | 创建 Agent | agent_id(`agw_`)、runtime_binding_hash、permission_scope_hash、create_policy、decision_id(若有)、actor、source | `agent.create:<bot_id>:<client_request_id>`；重复返回同一 Agent。 |
| `bot.agent.suspended` / `bot.agent.retired` | `bot/<bot_id>` | 暂停/退休 | agent_id、reason、actor | `agent.state:<agent_id>:<request_id>`；重复状态变化返回同一结果。 |
| `bot.agent.creation_denied` | `bot/<bot_id>` | 创建被 Off/Ask/限额/allowlist 拒绝 | requested_software、reason、policy_snapshot_hash、decision_id(若有)、actor | `agent.create.denied:<bot_id>:<client_request_id>`；只审计，不创建 Agent。 |
| `bot.memory.write.requested` | `bot/<bot_id>` | Agent 请求写共享记忆 | entry_id、agent_session_id、agent_id、digest、requested_scope、actor | `memory.write.request:<bot_id>:<client_request_id>`；只有通过权限/敏感内容检查后才可写 committed。 |
| `bot.memory.write.committed` | `bot/<bot_id>` | 记忆写入成功 | entry_id、agent_session_id、agent_id、bytes、digest、decision_id、artifact_id | `memory.write:<bot_id>:<entry_id>`；同一 entry 不重复写。 |
| `bot.memory.write.denied` | `bot/<bot_id>` | 记忆写入被拒 | reason、agent_session_id、digest、decision_id | `memory.write.denied:<bot_id>:<request_id>`。 |
| `chat.created` | `chat/<chat_id>` | 创建 Chat | chat_id、participant bot_ids、project_id(可空)、title、actor、source | `chat.create:<client_request_id>`；V1 必须有一个 Bot participant。 |
| `chat.participant.added` | `chat/<chat_id>` | 添加参与者 | bot_id、role、project_access_check、actor | `chat.participant.add:<chat_id>:<bot_id>:<client_request_id>`；V1 最终唯一 active。 |
| `chat.participant.removed` | `chat/<chat_id>` | 移除参与者 | bot_id、reason、active_session_ended、actor | `chat.participant.remove:<chat_id>:<bot_id>:<client_request_id>`。 |
| `chat.project.changed` | `chat/<chat_id>` | 设置/清除/替换项目 | old_project_id、new_project_id、membership_check、actor | `chat.project:<chat_id>:<version>:<client_request_id>`；要求无 active AgentSession。 |
| `chat.message.appended` | `chat/<chat_id>` | 用户/Agent 可见消息落盘 | message_id、role、agent_session_id(可空)、body_ref/digest、actor | `chat.message:<chat_id>:<message_id>`；重复 message 返回同一结果。 |
| `chat.agent.selected` | `chat/<chat_id>` | 初始选择 Agent（尚无 active session） | bot_id、agent_id、runtime_binding_hash、permission_snapshot_hash、actor、decision_id(若有) | `chat.agent.select:<chat_id>:<agent_id>:<client_request_id>`；若已有 active session 冲突。 |
| `chat.agent.switched` | `chat/<chat_id>` | 切换 Agent 并形成交接边界 | from_agent_id、to_agent_id、from_session_id、to_session_id、boundary_id、old/new permission_snapshot_hash、actor | `chat.agent.switch:<chat_id>:<from_session_id>:<to_agent_id>:<client_request_id>`；三事件同事务。 |
| `chat.agent.selection_denied` | `chat/<chat_id>` | 选择/切换被策略或项目权限拒绝 | requested_agent_id、reason、policy_snapshot_hash、actor | `chat.agent.select.denied:<chat_id>:<client_request_id>`；不改变状态。 |
| `chat.agent_session.started` | `chat/<chat_id>` | 开始 AgentSession | agent_session_id、agent_id、bot_id、runtime_binding_hash、range(project/workspace)、permission_snapshot_hash、inherited_summary_ref、started_at | `session.start:<chat_id>:<agent_id>:<client_request_id>`；V1 active 唯一约束。 |
| `chat.agent_session.updated` | `chat/<chat_id>` | active/waiting 等非终态更新 | agent_session_id、state、turn/decision counts、updated_at | `session.update:<session_id>:<state>:<request_id>`；终态不可回到 active。 |
| `chat.agent_session.ended` | `chat/<chat_id>` | 结束 AgentSession | agent_session_id、end_reason、summary_ref、ended_at、next_session_id(可空) | `session.end:<session_id>:<end_reason>:<client_request_id>`；只允许一次终态。 |
| `project.created` | `project/<project_id>` | 创建 Project（复用现有事件；P0 补幂等键） | project_id、name、repo、default_branch、verify、actor | `project.create:<client_request_id>`；重复返回同一 Project。 |
| `project.member.added` / `project.member.removed` | `project/<project_id>` | Project membership 变化 | bot_id、access、reason、actor | `project.member:<project_id>:<bot_id>:<client_request_id>`；唯一 active membership。 |
| `project.archived` | `project/<project_id>` | 归档 Project | reason、active_chat_count、actor | `project.archive:<project_id>:<client_request_id>`。 |
| `migration.started` | `migration/<run_id>` | 迁移开始 | manifest_digest、source_version、target_version、dry_run、actor | `migration:<run_id>:started`。 |
| `migration.phase.completed` | `migration/<run_id>` | Bot/Chat/session/alias 等阶段完成 | phase、counts、unresolved_count、phase_digest | `migration:<run_id>:<phase>`；可安全重跑。 |
| `migration.completed` | `migration/<run_id>` | 迁移完成/切换规范读写 | counts、alias_count、verification_digest、cutover_seq | `migration:<run_id>:completed`；重复返回同一结果。 |
| `migration.failed` | `migration/<run_id>` | 迁移中止 | phase、reason、counts、resume_allowed | `migration:<run_id>:<phase>:failed`；不删除已完成的幂等阶段。 |

#### 6.3 幂等、顺序与并发

- 现有 `events.idempotency_key` 是全局 UNIQUE；新事件沿用。所有 owner 写操作必须带 `client_request_id`，host 用确定性键写入；同一键重复请求返回既有事件/对象，不重复创建 Chat、Agent、participant、session 或 membership。
- 同一键但不同 payload 返回 `conflict`，不覆盖既有事件。状态迁移失败也返回 conflict，不能为了幂等而把非法迁移写成成功。
- `chat.agent_session.started` 在 V1 由 `(chat_id, nonterminal)` 唯一约束保证最多一个 active session；并发 start 只有一个成功，另一个返回 conflict/既有结果。
- 切换的三事件（ended/switched/started）在同一事务中；任何一步失败全部回滚。重试同一 `client_request_id` 返回同一三事件结果，不产生双重交接。
- participant、membership、alias 都使用 `UNIQUE` 守卫 active/alias 唯一性；重复移除/重复添加返回同一投影结果。
- 迁移事件按 `migration_run_id` 和阶段确定；重跑已提交阶段返回既有结果。迁移期间 host 进入排他迁移模式，普通写 RPC 返回 `migration_in_progress`，避免正常写入与迁移交错。
- 投影重建只读事件，不产生业务副作用；outbox 消费者按事件 id/幂等键去重，不能因 replay 重复发送通知或重复创建 Run。

### 7. 迁移：旧 Agent → Bot，旧 session → Chat + AgentSession

#### 7.1 映射原则

迁移必须显式、可审计、可恢复，且只由 host 执行。它遵守三条原则：

1. **不猜测**：旧 `agt_` 按字段/引用类型解析；无法判定类型、同一 alias 指向多个对象、或 runtime binding 不完整时，预检失败并阻断 cutover。
2. **不合并人格**：每个旧 `agent_id` 身份只映射为一个 Bot；不同旧身份不能合并成一个 Bot。一个旧身份如果跨过多个运行软件，在 Bot 下产生多个 Agent，而不是把某个 Agent 改成另一个人格。
3. **不做双写**：迁移是一次性复制/重建，完成后规范表唯一可写；旧表改为只读 legacy 快照/附件，不由触发器同步，也不允许任何服务同时写新旧两套。

#### 7.2 对象映射

| 旧对象 | 新对象 | 规则 |
|---|---|---|
| 旧 Agent identity（`agent_id`、home、AGENTS.md、MEMORY.md、权限、项目关系） | Bot | 每个不同旧 identity 一个 `bot_`。旧 home → `state_dir/bots/<bot_id>/`；AGENTS/persona → Bot instructions；MEMORY.md → Bot memory；旧权限集合 → Bot permission ceiling（只保持或收紧，不扩大）。 |
| 旧运行态 `AgentSessionRecord`（`agt_` session） | Chat + AgentSession + runtime session | 每个旧 session 生成一个 Chat、一个 AgentSession；Bot participant 由旧 `agent_id` 映射。旧 record 保留为内部 runtime 句柄，不重复写成 Chat。 |
| 旧 runtime 软件配置（mode/command/args/agent_name/profile） | Agent worker | 按固定的 `runtime_binding_hash` 去重；同一 Bot 下不同绑定产生不同 Agent。若同一旧 identity 在一个 Chat 内混用多个软件，按旧 session 分段产生对应 AgentSession/Agent；预检报告需 owner 确认。 |
| 旧 Project 关联（workspace/worktree → project） | Chat.project_id + ProjectMembership | 仅在能从现有 workspace/worktree/task 记录确定 Project 时写入；无法确定则 Chat 无 Project，只在 Bot 视图出现。不得凭空给 Bot 添加项目访问。 |
| 旧 Task/Run/Decision/Artifact | 保留原对象，增加新引用 | Task/Run 的旧 `session_id` 解析到 AgentSession；`agent_id` 旧值解析到 Bot；新投影增加 `bot_id`/`agent_id`(worker)/`chat_id`/`agent_session_id`。历史事件不重写成新事件。 |
| 旧 Agent-scope 技能绑定 | 新 Agent worker 的技能配置 | 旧 identity 的技能集合作为 Bot 权限/allowlist 的一部分；具体运行绑定落到该 Bot 下对应 Agent。若一个旧 identity 产生多个 Agent 且无法确定技能归属，预检标记需 owner 选择，不能静默扩散到所有 Agent。 |
| 旧 credential binding `(machine, agent_id, profile)` | 新 Agent worker 的 binding | 默认只迁移到对应旧运行时绑定的那个 Agent；如果一个 Bot 下有多个候选 Agent，必须 owner 选择或拆出绑定，禁止把一个旧绑定静默复制给所有 Agent。 |
| 旧 active 审批/Decision | 保留为旧 AgentSession 的 Decision | 迁移后仍可回答旧 session 的请求；切换/结束旧 AgentSession 后，审批不能转发给新 session，最多作为历史记录。 |

#### 7.3 旧 session → Chat + AgentSession

对每个旧 `AgentSessionRecord`：

1. 由 `agent_id` 解析 Bot；由 mode/command/args/agent_name/profile 计算 `runtime_binding_hash`，找到或创建该 Bot 下的 Agent；若无法得到固定绑定，预检阻断。
2. 新建 Chat `cht_`，写入一个 Bot participant；由 workspace/worktree 可确定的 Project 写入 `chat.project_id`，无法确定则为无项目 Chat。
3. 新建 AgentSession `asn_`，状态按旧 session 映射：旧 active/idle/running/waiting_decision → `starting`/`active`/`waiting`；旧 ended/stopped/exited → `ended`；旧 failed → `failed`；旧 lost/interrupted → `lost`。旧 active session 必须保留其 runtime 句柄，不能为了迁移重建进程。
4. 旧 session id（`agt_`）写入 `legacy_aliases(agent_session → asn_)`；旧 `agent_id` 写入 `legacy_aliases(agent_identity → bot_)`。如果旧 session id 还出现在旧运行态引用中，仍按 `agent_session` 解析。
5. Chat transcript 只导入原本用户可见的对话/摘要；旧 runtime stdout、工具中间态和隐藏 prompt 不直接升级为用户可见消息。需要展示的历史由有界 transcript/Artifact 引用承载，并带迁移边界说明。

一个旧 Chat 如果实际上对应多个旧 session，迁移不会把它们合并；先各自成为 Chat，后续由显式「合并/新 Chat」操作处理（不在本 ADR 范围）。反过来，一个旧 session 也不会被展开成多个 Chat。

#### 7.4 迁移步骤与事件

迁移必须支持 dry-run、断点恢复和单次 cutover：

1. **P0-preflight**：只读扫描旧库、事件游标、Agent identity、session、run、workspace/worktree、Project、skills、credentials、open Decisions。计算 counts、`agt_` 双语义冲突、runtime binding 指纹、缺失/歧义项。生成 `migration_manifest_digest`；有 unresolved 项则返回报告并停止。
2. **开始**：host 获取排他迁移租约，写 `migration.started`；进入迁移模式，普通写 RPC 拒绝，UI 只读。迁移模式不能启动第二个 host 迁移进程。
3. **Bot 阶段**：创建 Bot、迁移 home/memory/权限投影，写 `bot.created`（`source=migration`）和 `migration.phase.completed`。Bot 的 permission ceiling 只能取旧身份权限的交集/原值，不能扩大。
4. **Project membership 阶段**：按旧 Project/Workspace/Task/Run 证据写入 membership；无证据的不写。每个 membership 变化写 `project.member.added`，并记录来源证据。
5. **Chat/AgentSession 阶段**：按 §7.3 创建 Chat、participant、Agent、AgentSession；写 `chat.created`、`chat.agent_session.started/ended` 或迁移等价投影事件；事件使用确定性 migration 幂等键。
6. **Alias 与引用阶段**：写 `legacy_aliases`；回填 Task/Run/Decision/Artifact 的新引用；旧字段只保留在只读快照。任何 alias 冲突中止本阶段。
7. **验证与 cutover**：重建 `bots`/`agents`/`chats`/`chat_participants`/`agent_sessions`/`project_memberships` 投影；比较旧/新 counts、alias 数、活跃 session 数和项目 Chat 权限检查；通过后写 `migration.completed`，把旧表切换为只读 legacy 视图，规范表成为唯一可写面。
8. **失败/恢复**：写 `migration.failed` 并保留阶段幂等键；修复后从下一阶段重试。cutover 前失败可以丢弃规范临时行或恢复备份；cutover 后回滚必须恢复旧库/快照并停止新写入，不能靠双写反向同步。

#### 7.5 禁止双权威与双写

- 迁移完成后，旧 `agent_sessions`/旧 identity 数据只能作为 `_legacy` 只读快照或兼容投影；任何新 `agent.start`、`agent.send`、UI 写入、触发器、技能或 credential 操作都只写规范 Bot/Chat/AgentSession 表。
- 不允许数据库触发器把旧表变化镜像到新表，也不允许后台补偿器同时写两边。若出现差异，以规范事件日志重放/重新迁移修复，不以旧表为准。
- 节点上的 runtime session/进程状态不是 Chat/Bot 的权威；节点只保存执行句柄和有界运行态。主控离线时节点不能自行创建 Bot/Chat/AgentSession 或扩大权限。
- alias 只解析引用，不构成可写对象；修改 alias 指向必须由迁移/修复命令完成，并写审计。

#### 7.6 迁移风险

| 风险 | 处置 | 残余 |
|---|---|---|
| `agt_` 同时是旧身份和旧 session id | 按 `alias_kind` 分表；旧字段按引用类型解析；冲突预检阻断 | 外部未标注类型的裸 ID 无法安全迁移，需人工归类。 |
| 旧 identity 跨多个软件/模型 | Bot 下按固定 runtime binding 建多个 Agent；旧 session 分段绑定 | 旧命令/模型元数据不全时需 owner 在预检中确认，不能猜测。 |
| 旧 Agent 记忆合并成 Bot 后权限/隐私扩大 | 每个旧 identity 独立 Bot，绝不合并；旧 MEMORY 只进自己的 Bot；迁移报告逐项审核 | 同一旧 identity 的多个 Agent 共享记忆是模型要求，不是新增隐私边界。 |
| 旧 credential binding 扩散到多个新 Agent | 默认只绑定到对应运行软件；多候选阻断并要求 owner 选择 | 多软件 Bot 的凭据需重新规划绑定；不能静默复用。 |
| Project membership 从 workspace/worktree 推断 | 仅写有证据的关系；无证据不授予 | 历史关联缺失的项目可能需要 owner 手动补 membership。 |
| 旧 runtime transcript 变成 Chat message 导致隐藏上下文泄漏 | 只导入用户可见内容/摘要；内部 transcript 走 Artifact 引用 | 旧 session 的原始输出可能不完整；迁移 UI 必须标明“历史仅引用”。 |
| 旧 active 审批在切换后被错误复用 | Decision 作用域绑定旧 AgentSession；切换后新 session 重新评估 | 旧审批历史仍需保留给审计/Inbox。 |
| cutover 期间双写 | 排他迁移租约 + 迁移模式拒绝普通写 + 旧表只读 + 禁触发器 | 操作者绕过 host 直接改 SQLite 超出模型保护，必须视为运维事故。 |

### 8. UI / 信息架构

#### 8.1 导航与视图

- **Bots 是一等目的地**。Bot 页面展示该 Bot 的 Chat 列表，并提供按 Project 过滤；Bot 详情下展示 Agent 管理，不作为独立顶级页面，也不要求每条消息选择 Agent。
- **Project 页面展示该 Project 的 Chat 列表**，并提供按 Bot/参与者过滤。Bot 页和 Project 页都是同一 Chat 对象的索引/投影，不能各存一份 Chat 记录。
- **稳定深链**：`/chat/<chat_id>` 从 Bot 或 Project 进入都打开同一条线程；旧 session 深链解析为 AgentSession 后重定向到该 Chat，并保留 session boundary 锚点。
- **不增加第三个全局 Chats 目的地**。跨对象的聊天发现使用 Search 与 Inbox；Search 可以按 Bot、Project、Chat 标题和消息检索，Inbox 仍是全局审批/Decision 入口。
- **新建 Chat**：从 Bot 页发起时预填该 Bot；从 Project 页发起时预填该 Project，并让用户选择有权限的 Bot。两个方向都复用同一个 `chat.created` 命令，不创建两个 Chat。
- **无项目 Chat**：只出现在 Bot 视图；Project 视图不显示，避免误以为项目范围的会话没有项目约束。

#### 8.2 Chat 表面

- Chat header 显示参与者（V1 为 Bot）；active Agent/软件作为次级元数据展示，例如 `Auto · coding-agent`。这里的 `Auto` 是当前选择/创建策略的可读摘要，不替代权限或审计。
- Composer 面向 Bot，用户不需要每轮选 Agent。Agent 是执行元数据，不是 Chat 参与者。
- `switch Agent` 动作必须展示交接边界：旧 AgentSession 结束、新 AgentSession 在同一条 Chat 开始、权限重新评估、哪些上下文不会继承。它不能静默改 Agent 内部绑定。
- 历史消息/交接边界/Artifact 在时间线上有稳定引用；旧 runtime 输出如只以 Artifact/reference 展示，必须显式标记来源，不伪装成用户消息。

#### 8.3 Inbox 与关联卡片

- Inbox 仍是全局审批/Decision 表面；Task/Run/Artifact 卡片在有 Chat/AgentSession 关联时链接回 Chat，并定位到对应的 AgentSession/交接边界。
- 审批卡显示 Bot、Agent、AgentSession、项目范围和风险；回答只对当前 session 有效。切换后旧审批卡仍可查看历史，但不能授权新 session。
- Bot 页的 Chat 列表、Project 页的 Chat 列表和 Inbox 链接都使用 Chat 稳定 ID，避免用「当前选中 Bot/Project」的本地状态拼接不稳定 URL。

### 9. 分阶段实施计划

#### P0：ADR、领域契约与迁移

范围：

- 本 ADR 已接受；更新 `docs/architecture.md` 及旧 ADR 术语引用。
- 定义 Bot/Agent/Chat/AgentSession/ChatParticipant/ProjectMembership 契约、规范 ID、事件 schema、状态机和单写约束。
- 实现迁移 dry-run、alias 表、旧 API 适配器、投影重建和 cutover 排他模式；不实现 Bots UI。

验收：

- dry-run 能报告旧 identity/session 数、`agt_` 双语义冲突、runtime binding 与 credential 歧义；零 unresolved 才允许 cutover；
- 旧 `agent_id` 与旧 `session_id` 通过各自 alias 解析，旧深链能定位 Bot/Chat；
- 新表可在事件重放后与迁移结果一致；迁移重跑不产生重复 Bot/Chat/Agent/participant/alias；
- 迁移期间和 cutover 后不存在新旧双写；旧表只读；
- 原有 Task/Run/Decision/Artifact 数据和审批历史不丢失；docs-only 本任务不改产品代码。

#### P1：Bot + 单 Agent Chat + Bot/Project Chat 视图

范围：

- Bot 创建/查看、唯一 Bot participant、单 Agent、Chat transcript/summary、AgentSession 开始/结束；
- Bot 页 Chat 列表与 Project 过滤；Project 页 Chat 列表与 Bot/participant 过滤；稳定深链、Search/Inbox 入口；
- Agent 管理放在 Bot 详情；Chat header、composer 面向 Bot。

验收：

- 从 Bot 页和 Project 页打开同一 Chat 得到同一 `chat_id` 和同一线程；
- 不出现第三个全局 Chats 目的地；
- 无项目 Chat 只在 Bot 视图出现；项目 Chat 的所有参与者通过 membership 校验；
- V1 一个 Chat 恰好一个 Bot participant、最多一个 active AgentSession；重复 start 被幂等或 conflict 拒绝；
- 新 AgentSession 不继承旧隐藏上下文/审批，权限按当前 Bot/Agent/Project 重新评估。

#### P2：Agent 切换/交接 + 创建策略

范围：

- `chat.agent.switch` 三事件交接、可见边界、旧 session 终止和新 session 开始；
- Off/Ask/Auto、Agent 数量/并发 cap、软件 allowlist、Bot 权限上限、创建/选择审计；
- 新工具/权限提升仍走 Decision；项目成员撤销时的 active session 收敛。

验收：

- 同一 Chat 内切换 Agent 不新建 Chat，旧 AgentSession 结束且新 AgentSession 开始，边界可见；
- 同一 Agent 的 runtime binding 不可变；换软件只能选/建另一个 Agent；
- Off 拒绝创建；Ask 产生一次性 Decision；Auto 在有界 cap/allowlist 内创建并审计；
- 切换后旧审批/临时 token/工具状态不可用；项目权限撤销后新 turn/Run 被拒绝；
- 并发创建/start 不会突破 cap 或产生两个 active session。

#### P3：Task/Run/Artifact/Approval 集成

范围：

- Task/Run/Artifact 卡片关联 Chat/AgentSession；Run 的 session 句柄与新引用映射；
- Inbox 审批卡展示 Bot/Agent/AgentSession/Project；审批消费和决策作用域；
- 旧 session 的审批历史保留，切换后不可复用。

验收：

- Task/Run/Artifact 能从卡片回到正确 Chat 与 session boundary；
- 新 AgentSession 不获得旧审批；审批消费后重放不重复执行；
- 证据门、Artifact 和 Run 结算仍由 host 判定，Chat 只是关联视图。

#### P4：未来多 Bot 群聊

范围与约束：

- Chat participants 从 V1 的单 Bot 扩展到多个 Bot；每个 Bot 可以有独立 active AgentSession；
- 多 Agent participant 协议（谁在何时回复、发言顺序、共享/隔离上下文、冲突消解）另行设计；
- 现在只保证 schema/事件/participant 关系可扩展，不需要为未来群聊重写 Chat 对象或迁移 Chat ID。

验收：

- 单 Bot Chat 数据在增加第二参与者后仍可读，Chat ID/深链不变；
- 每个 Bot 的 active AgentSession 唯一性、项目访问和权限交集仍成立；
- 不把多 Bot 群聊实现偷偷塞进 V1；没有协议和审计前不开放。

### 10. 验收标准与明确的非目标

#### 10.1 ADR 级验收

- 文档只新增/修改 `docs/adr/0017-*.md` 与 `docs/adr/README.md`；不触碰 `apps/`、`packages/`、`services/`、`tests/`、`scripts/` 或产品代码。
- ADR 状态为 Accepted、日期 2026-11-27；README 索引指向本 ADR 并显示 Accepted。
- `git diff --check` 通过；README 相对链接与 ADR 文件存在；无生成物、临时文件或 vendor 变更。
- 明确覆盖 Bot/Agent/Chat/AgentSession/Project 的归属、不变量、规范 ID、旧 ID alias、状态迁移、权限继承、记忆边界、事件幂等和迁移单写要求。
- 明确覆盖 UI/IA：Bots 目的地、Bot/Project 双视图同一 Chat、稳定深链、无第三全局 Chats、Agent 管理在 Bot 详情、header/composer/Inbox 行为。
- 明确列出分阶段计划 P0–P4、每阶段验收、多 Bot 群聊/多 Agent 协议/无限 spawn/中会话软件变更/多租户等非目标。

#### 10.2 实现验收（P0–P3）

- 事件投影重放可重建所有 Bot/Chat/AgentSession/participant/membership；不存在只写投影不写事件的路径。
- 领域不变量有自动化测试：Agent 不能直接参与 Chat；项目 Chat 参与者必须有 Project membership；V1 单 Bot/单 active AgentSession；固定 runtime binding；权限取交集。
- 迁移 dry-run 无未解析冲突才能 cutover；旧 `agt_` identity/session 双语义通过 typed alias 正确分流；重复迁移幂等；cutover 后旧表只读、无双写。
- 记忆写入、Agent 创建/选择、切换、参与者变化、项目成员变化、迁移均产生可审计事件；重复请求不重复副作用。
- 旧深链/旧 session 引用能重定向到正确 Chat/AgentSession；旧审批不会被新 session 继承。
- UI 验收覆盖 Bot 页/Project 页/稳定深链/Search/Inbox；不要求用户为每条消息选择 Agent。

#### 10.3 明确的非目标

以下在本 ADR 与 V1 中明确不做，后续需要单独 ADR/计划：

- 多 Bot 群聊的实际交互协议、发言顺序、共享/隔离上下文和冲突消解；
- 多 Agent participant 协议（多个 Agent 在同一 Chat 同时作为参与者发言）；
- 无上限的自主 Agent spawn、自动扩容、绕过 cap/allowlist/审批的自治执行；
- 在同一个 Agent 或同一个 AgentSession 内静默变更软件/模型/CLI（中会话软件突变）；
- 多租户组织、跨组织 Bot/Chat/Project 共享或独立控制面；
- V1 第三个全局 Chats 目的地；
- 每个 Agent 独立的长期人格记忆或把 Bot 记忆复制给 Agent；
- 把 Chat 当作 Task/Run/Decision 的替代对象，或让 Bot 页/Project 页各写一份 Chat；
- 本任务改写产品代码、Bots UI、迁移实现或新增测试；本任务是 docs-only ADR 提案。

### 11. 后果、开放问题与评审门槛

#### 11.1 后果

- 正面：同一人格可在不破坏 Chat 历史的情况下换执行软件；权限和项目访问有清晰的交集模型；Bot/Project 两个视图不会产生重复 Chat；旧 session 的聊天历史可以用稳定 Chat ID 继续演进。
- 成本：必须做一次领域模型迁移；旧 `agt_` 语义冲突需要 typed alias 和预检；旧 per-Agent 记忆、技能、credential binding 和审批需要逐类映射；UI 需要把旧 Agents/Sessions 心智拆成 Bots + Chat + Agent 管理。
- 安全：Bot 权限上限、Project membership、固定 runtime binding 和审批作用域共同阻止「换 Agent 绕过审批」；迁移期间必须排他，不能为了平滑上线做双写。
- 文档：若本 ADR 接受，需更新 `docs/architecture.md` 的对象/关系/页面章节以及 ADR-0005、ADR-0007、ADR-0015 的旧 Agent 术语；在完成前，所有新设计必须注明 legacy Agent 与 new Agent worker 的区别。

#### 11.2 owner 已决事项（2026-11-27）

owner 已确认 Bot 是“人”、一个 Bot 可以有多个 Agent、Agent 切换后在同一 Chat 新开 AgentSession，并指示开始实现。以下问题按当前实现口径冻结：

1. **默认创建策略**：beta 默认 `Ask`；每个 Bot 的开关可设 `Off / Ask / Auto`。首次迁移不需要 owner 一次性 Decision；迁移走确定性预检和显式 cutover 确认，歧义项在预检中由 owner 逐项解决。
2. **旧 runtime binding 的推断边界**：只接受显式、唯一且一致的绑定证据。旧 `mode/command/args/agent_name/profile` 可以组合推断，但任一字段缺失、冲突或产生多个候选时，迁移标为 unresolved，由 owner 选择；不做默认猜测。
3. **旧 skill/credential 的 fan-out**：P0 提供迁移专用的显式绑定工具。旧 Agent-scope 绑定只能绑定到一个明确选定的新 Agent；禁止静默复制到同一 Bot 的所有 Agent。
4. **旧 transcript 导入**：只有旧记录中原本用户可见的消息/摘要可作为 Chat message；runtime stdout、工具中间态和隐藏 prompt 只能作为带来源标记的 Artifact/reference，迁移 UI 必须标明“历史引用，不是聊天原文”。
5. **Project membership 证据**：只有 workspace/worktree/task/run 与 Project 的直接、无歧义关联才可自动写入 membership，并写审计；多候选、间接或缺失证据一律要求 owner 确认，不能为方便迁移扩大访问范围。
6. **归档恢复**：Bot 在 V1 归档后为终端只读，不恢复；Project 与 Chat 允许显式恢复，恢复前重新校验成员、参与者和权限。需要恢复 Bot 时创建新 Bot，不复用归档身份。
7. **ID 命名**：冻结 `bot_`、`agw_`、`cht_`、`asn_`、`prj_` 作为 P0 规范前缀；`agt_`/`ses_` 只作为 legacy alias，不再生成。
8. **多 Bot 群聊**：V1 不实现实际群聊协议；participant/schema 留扩展点，发言顺序、共享/隔离上下文和冲突消解另立 ADR（P4）。

本 ADR 自 2026-11-27 起为 **Accepted**。P0 领域契约、host 命令、迁移预检与兼容适配器可以进入实现；Bots UI 按 P1 推进。
