# ADR-0016：账户托管（A5）——平台凭据存储、按机器/Agent 绑定与本地代理注入

- 状态：Proposed（A5 设计；A1/策略/readiness 稳定后实施；待 owner 评审）
- 日期：2026-11-26
- 依据：`docs/v0.2-plan.md` §1.1（D8）、§1.2（D9）、§2.5（A5）、§3；`docs/architecture.md` §3.1、§6.1、§6.3、§11、§12、§13、§18；ADR-0005（Agent 运行时）、ADR-0006（权限模型）、ADR-0012（配对远端 runtime）、ADR-0011（Agent over SSH）；`packages/contracts/policy.mbt`、`services/host/agents.mbt`、`packages/providers/agent/agent.mbt`、`services/runtime/spec.mbt`、`services/runtime-transport/`
- 关系：本 ADR 把 A5 的「host 托管账户/模型凭据」细化到可实现；复用现有 readiness/Decision/审计/redaction/配对通道，不改变 A1 的权威与回退边界，不引入第二控制面。A1.3b 正在并行修正，本文只引用「策略快照、审批授予、配对通道」的概念，不固化其摘要载荷或 ack 记账细节。

## 背景

V0.1 的基线是「Agent 使用所在机器自己的登录/账户」：SSH 会话沿用远端登录环境，本地会话沿用本机环境；host 不把模型凭据复制到 Workspace，`agent_env` 中的秘密命名变量在 Run 持久化前被 redaction。A5 要在此之上提供**由 host 托管的模型账户/凭据**，满足五条验收：

1. 凭据只存在 keychain 或 `0600` 文件；事件、日志、Artifact、Decision、会话记录无明文；redaction 测试扩展覆盖；
2. 按机器与 Agent 绑定授权；未授权 Agent/机器拿不到；吊销/轮换后旧凭据立即失效；
3. 远端 runtime 通过托管通道访问，Workspace 内不可见、不可复制；子进程继承受控；
4. readiness 启动前检查账户可用；失败生成可读 Decision，不反复重试；
5. 真实模型调用 e2e 通过，token 不出现在任何持久化面；撤销后同一调用失败关闭。

四个边界问题必须先答：

- **密钥放哪**：keychain 还是 `0600` 文件？在 macOS、Linux、远端节点上如何一致地选择与失败关闭？
- **怎么给 Agent**：把真实密钥放进环境变量，还是本地代理 + 短期能力 token？前者会被子进程、`/proc`、日志和崩溃转储放大，且吊销只能等进程重启。
- **远端怎么送**：主控如何把密钥交给节点而不经过 Workspace、事件、日志或用户可见的复制面？节点离线时还能用多久？
- **怎么吊销**：轮换/撤销如何对新请求立即生效？飞行中的请求、节点失联、会话 token 泄漏如何界定？

本 ADR 的结论：**平台存储（macOS Keychain 优先，Linux `0600`；显式降级需审计）+ 按 `(machine, agent, profile)` 的绑定 + Agent 进程所在机器上的本地代理 + 每会话短期能力 token + 配对通道按需交付 + 失败关闭的就绪门**。真实密钥从不进入 Agent 环境、子进程、Workspace、事件、日志、Artifact、Decision 或会话记录。

## 决策

### 1. 定位与权威

- **主控是唯一权威**：凭据元数据、绑定、授权、轮换/吊销、审计与 Decision 都在主控 SQLite/事件日志。节点只保存**本机所需的密钥副本**并执行本地代理；它没有独立绑定/审批/组织，不能自行授权跨机使用。
- **A5 不是第二控制面**：没有第二套账户注册表、审批队列或事件日志；`credential.*` 事件写既有事件表，Decision 走既有收件箱。
- **不新增 Provider 轴**：凭据代理属于 AgentRuntime/host 的本地执行面，不是 `MachineProvider` 的能力。`MachineProvider` 仍只 probe/readiness/exec/pty；ACP 仍在 `AgentRuntime` 内；`WorkspaceProvider` 仍为 Local/SSH。远端节点上的代理由节点 host 运行，主控不通过 Workspace 文件系统注入。
- **基线不变**：没有绑定的 Agent 继续使用所在机器自己的登录/环境（V0.1 行为）；A5 是显式 opt-in，不强制所有 Agent 使用托管凭据。
- **功能开关**：`credential.enabled` 默认 **false**。关闭时 `credential.*` RPC 返回 `unsupported`，`agent.start` 不使用代理，readiness 不检查托管账户，既有行为与事件 schema 不变；A5.1 验收后由 owner 显式开启。
- **真实模型调用是验收的一部分**，但 CI 默认不持有真实密钥；e2e 以显式环境变量/本地 owner 存储提供，缺失时标记为 **skipped（不可宣称通过）**，不能静默伪造成功。

### 2. 存储选择与格式

#### 2.1 平台选择

| 平台 | 默认存储 | 失败行为 |
|---|---|---|
| macOS | Keychain（`service=monexus.credential`，`account=<credential_id>`） | Keychain 不可用/锁定且无法非交互访问 → readiness 失败；**不静默**降级 |
| Linux | `state_dir/credentials/` 目录 `0700` + 每凭据文件 `0600` | 目录/文件权限不符 → 拒绝使用，不修复后继续 |
| 远端节点 | 同平台规则，存节点自己的 `state_dir/credentials/` | 同上；节点不读取主控 store |
| Windows | V1 不支持 | 明确 `unsupported_platform`；不用未加密文件替代 |

- **macOS 显式降级**：headless/CI 若无法使用 Keychain，owner 可显式设置 `credential.storage=file`；host 必须写 `credential.storage.degraded` 审计并在 UI/`credential.status` 标记。默认绝不自动回退。
- **存储抽象**：`CredentialStore` 只有 `put/get/delete/describe`，按 `credential_id` 寻址；Keychain 与 file 两种后端实现同一语义。上层不感知平台差异。
- **Keychain 访问**：优先使用不把 secret 放进 argv 的原生/API 路径；若只能通过 `security` CLI 且命令行会暴露 secret，则该平台路径视为不可用（open question §18.1）。A5.0 必须先验证此点，不能把 secret 写入 `ps` 可见的 argv。

#### 2.2 文件格式与权限

`state_dir/credentials/<credential_id>.json`（`0600`，父目录 `0700`）：

```json
{
  "format": "monexus.credential.v1",
  "format_version": 1,
  "credential_id": "crd_...",
  "kind": "api_key",
  "secret": "<opaque>",
  "version": 3,
  "created_at": "2026-11-26T10:00:00Z"
}
```

- `kind` 固定 `api_key`/`bearer_token`（V1 只支持静态凭据，不支持 OAuth refresh/device flow）。字符串长度/字符集校验；拒绝控制字符。
- 写入使用同目录临时文件 `0600` + `rename` 原子替换；读取前检查 `stat` 的 owner/mode 与 `O_NOFOLLOW` 语义（实现允许时），拒绝符号链接。TOCTOU 在同用户模型下不能完全消除，见 §10。
- **SQLite 只存元数据**：`credential_id`、`kind`、`storage`、`version`、`state`、`created_at`、`rotated_at`、**fingerprint**（`sha256("monexus.credential.fingerprint.v1\n"+secret)`，只用于重复检测/完整性，不是密钥）；**任何表、事件、日志、Artifact、Decision、会话记录都不存 `secret`**。
- Keychain 项只存 secret 值（account=`credential_id`），元数据在 SQLite；file 后端存完整 envelope。两种后端的 `get` 都只返回内存中的 secret；调用方不得记录返回值。
- **删除**：撤销先标记 `revoked` 并让代理失败关闭，再删除 store 项；删除失败时保持 `revoked` 且 doctor 报告残留，代理仍拒绝；不能因为删除失败而恢复可用。
- **不落 Workspace/Agent home**：凭据目录不属于 Workspace，也不在 `agents/<id>/` 下；Agent 不能通过技能/材料化路径获得。

### 3. 绑定：按机器与 Agent

#### 3.1 记录

| 字段 | 说明 |
|---|---|
| `credential_id` | `crd_<ULID>`；一次注册的密钥；V1 一个凭据只允许一个绑定 |
| `binding_id` | `crb_<ULID>`；授权单元 |
| `machine_id` | 绑定的机器；本地主控或 A1 节点 |
| `agent_id` | 绑定的 Agent |
| `profile` | 凭据用途/上游 profile（owner 配置：upstream host/path、auth header、env 映射），不含 secret |
| `state` | `active` / `revoked` / `revocation_pending` / `deleted` |
| `version` | 每次轮换递增；代理与交付按版本比较 |
| `unique(machine_id, agent_id, profile)` | 一个 Agent 在一个机器上的一个 profile 只有一条活跃绑定 |

- **授权解析**：`agent.start` 以 `(machine_id, agent_id, profile)` 解析绑定；没有活跃绑定 → 使用机器自身账户（基线），或在强制托管模式下 readiness 失败。**绝不回退到另一条绑定/另一台机器的凭据**。
- **一凭据一绑定**：V1 拒绝把同一 `credential_id`（或同一 fingerprint）绑定到第二个 `(machine, agent, profile)`，返回 `credential_reused`，要求为该绑定单独注册。这样吊销/轮换的爆炸半径是单个 Agent/机器，直接覆盖「跨机器凭据复用」。若 owner 确有共享需求，走 §18.5 决策，不在 V1 默认放开。
- **只有 owner 能注册/绑定/轮换/吊销**：`credential.enroll`/`binding.create`/`rotate`/`revoke` 需要 owner 授权。Agent、Task、触发器、技能和记忆都不能创建/修改绑定；触发器只能使用现有绑定（若其 Task 模板选中了该 Agent），不能新建或扩大授权。
- **多凭据**：同一 Agent/profile 只保留一个 active 绑定；历史 `revoked` 记录不参与选择。若迁移/异常产生多个 active 候选，readiness 失败而不是任选。V1 不做候选优先级。
- **未授权**：未绑定的 Agent/机器不获得 session token，不获得代理坐标，不读取任何密钥；`credential.proxy.denied` 记录原因（不 echo 凭据）。

#### 3.2 生命周期

- `enroll`：owner 在 host 本地 UI/CLI 输入 secret；host 立即写平台 store，SQLite 只写元数据/fingerprint，写 `credential.enrolled`；RPC 请求/响应不得回显 secret，也不得写请求日志。
- `bind`：选择 credential/machine/agent/profile，写 `credential.bound`；绑定后不复制 secret 到 Agent home。
- `rotate`：owner 提供同一凭据的新 secret → 同一 binding `version+1`；旧 secret 在新版本提交后立即不可用；代理会拒绝旧 generation。
- `revoke`：`active → revoked`，关闭代理与 session token，删除 store 项；节点收到撤销/租约失效；写 `credential.revoked`。
- `delete`：仅在 `revoked` 且无引用后删除元数据；审计保留（不含 secret）。
- **过期**：V1 不做自动过期；owner 显式轮换/吊销。代理 token 有会话 TTL（见 §4）。

### 4. 注入：本地代理 + 会话能力 token

#### 4.1 为什么不是真实密钥环境变量

把真实密钥写入 Agent 的 `env` 会立即扩散到：Agent 子进程、`/proc/<pid>/environ`（同用户可读）、崩溃转储、Agent 自己打印的环境、日志与快照；而且吊销只能等进程退出。A5 采用：

- **真实密钥只存在于 host/节点进程内存与平台 store**；Agent 环境只得到：
  - `MONEXUS_CREDENTIAL_PROXY_URL=http://127.0.0.1:<port>`（或 profile 声明的等价变量）；
  - `MONEXUS_CREDENTIAL_PROXY_TOKEN=mxp_<random>`（每会话能力 token，非真实密钥）；
  - profile 需要的非秘密配置（模型名、超时等）。
- **代理在 Agent 进程所在机器上**：本地会话由主控 host 启动；远端会话由节点 host 启动。代理只绑定 `127.0.0.1`（不监听外部接口），随机端口；每会话一个监听器，会话结束关闭。
- **代理语义**：只转发到 profile 固定的 upstream host/path 前缀；校验 `Authorization: Bearer mxp_...` 或 profile 声明的位置；校验绑定/session/版本/状态；删除客户端自带的认证头，替换为该 profile 的真实认证；限制方法、请求体/响应体大小、并发、超时与速率；不跟随跨 host 重定向；不记录 header/body；上游 TLS 使用系统根证书校验。
- **token 绑定**：随机 32 字节、`mxp_` 前缀；绑定 `(binding_id, credential_id, agent_id, machine_id, session_id, credential_version, expires_at)`；只在内存保存其哈希/引用；会话结束或吊销立即失效；不得写事件/日志/Artifact/Decision/会话记录。
- **profile 兼容性**：只有能接受本地 HTTP base URL 与 bearer/token 头的 Agent CLI 才可使用代理；不接受者 → `credential.proxy_unsupported` readiness 失败，不退回真实密钥注入。V1 的 e2e 使用一个真实/兼容客户端证明端到端调用；具体 CLI 兼容性由 owner 确认（§18.2）。
- **写路径**：代理对模型请求是透明转发，不解析业务 JSON；它不授予工具权限，不影响 §11 的 ACP permission/Decision。代理只解决「模型调用认证」，不替代策略。

#### 4.2 子进程继承边界

当前本地 Agent 启动使用 `inherit_env=true`（`packages/providers/agent/agent.mbt`），远端使用节点自身环境。A5 必须收紧：

- 本地 Agent 改为 `inherit_env=false` + **显式基础 allowlist**（`PATH`、`HOME`、`LANG`、`TERM`、临时目录等），再追加代理坐标/session token / profile 非秘密变量。
- **移除 secret 命名变量**：任何名称命中 `is_secret_key_name` 的继承变量都不进入 Agent env；host 自身的真实密钥（若有）不得被继承。
- 远端节点同理：Agent 仍使用节点自身环境/登录作为基线，但托管凭据只通过代理坐标注入；节点不把主控的密钥写进 Agent env。
- 子进程（Agent 再 spawn）最多继承 session token；token 短 TTL、绑定会话、可吊销；真实密钥永不进入任何子进程。`services/runtime/spec.mbt` 的 `env`/`inherit_env` 校验继续拒绝空秘密值/凭据型继承名。
- Workspace 内不出现密钥文件；代理坐标/token 可能被 Agent 写入 Workspace（这是能力 token，不是真实密钥），会话结束失效；e2e 仍扫描真实密钥。

### 5. 远端交付：配对通道按需拉取

- **拓扑**：远端 Agent 进程在节点上运行，节点 host 运行代理。主控不把 secret 经 Workspace、文件同步、事件或日志传给节点；节点通过既有配对通道（ADR-0012 的 pinned TLS JSON-RPC）**按需拉取**。
- **认证与绑定**：节点用已有的机器凭据/会话认证；请求携带 `runtime_id`、`binding_id`、`credential_version` 与请求 nonce。主控校验：绑定 `machine_id == runtime_id`、`state=active`、版本匹配、节点身份有效；不匹配 → 固定错误，不回退到其他绑定。
- **返回**：secret 只在认证通道的响应体中返回一次（或按 A1.3b 的 sealed/lease 机制），不作为事件/outbox 持久化；节点 ack 只带 `binding_id/version/hash` 之类的非秘密确认。主控的 `credential_deliveries` 只记录投递/确认元数据，不写 secret。
- **节点本地**：节点把 secret 写入自己的平台 store（§2），代理从内存/Store 读取；节点状态快照、事件、日志、outbox 只含 binding/version/lease，不含 secret。节点不把 secret 放入 Workspace、Agent home 或 shell 历史。
- **幂等/重放**：按 `(binding_id, credential_version, request_id)` 幂等；重复拉取返回同一版本或 `not_modified`，不重复落盘；节点不能把旧版本用于新会话；重放由机器认证 + nonce/A1.3b 机制约束。
- **离线/租约**：投递带 `lease_expires_at`（默认 15 分钟；可在不改变语义的前提下收紧）。主控可达时每次心跳/续租延长；不可达且租约过期 → 节点代理**失败关闭**（不发起新请求，不新开会话）。主动 `credential.revoke` 在节点可达时立即删除并断开；不可达时最多等到租约到期。**这是「立即吊销」的边界，必须在 UI/文档中明确。**
- **A1.3b 依赖**：本轮 A1.3b 正在修正策略快照/审批的载荷与 ack 记账；A5 不固化交付帧的具体字段、摘要算法或 ack 账本，只要求：认证、绑定机校验、幂等、不进事件、可撤销、可租约。最终方法名/帧形状在 A5.0 与 A1.3b 收口后确定（§18.3）。

### 6. 启动前 readiness、可读 Decision 与不重试风暴

#### 6.1 检查项

`agent.start`/Run 启动前，在 Agent 将运行的机器上检查：

1. 绑定存在且 `active`，`(machine, agent, profile)` 精确匹配；
2. store 可用（Keychain 可访问或 `0600` 文件权限正确），secret 可读且版本匹配；
3. 代理能绑定 `127.0.0.1`，profile upstream/host 配置有效，session token 可生成；
4. 远端：节点可达、交付/租约有效、节点代理已启动；
5. Agent profile 兼容代理注入（base URL/env 映射）。

失败 → `agent.readiness.failed`（既有事件）+ `DECISION_KIND_READINESS` Decision；`AgentReadiness.auth` 使用固定 reason 码：

| reason | 含义 |
|---|---|
| `credential_missing` | 没有绑定或 store 无该项 |
| `credential_revoked` | 绑定/凭据已撤销 |
| `credential_locked` | Keychain 锁定/不可访问 |
| `credential_store_bad_permissions` | 文件/目录权限不符 |
| `credential_proxy_unavailable` | 代理无法启动/端口失败 |
| `credential_proxy_unsupported` | Agent 客户端不接受代理坐标 |
| `credential_delivery_failed` | 远端交付失败/节点不可达 |
| `credential_lease_expired` | 节点租约过期 |
| `credential_reused` | 跨绑定复用被拒 |

#### 6.2 Decision 可读性与去重

- Decision 标题/详情只含 `agent_id`、`machine_id`、`binding_id`、固定 reason 与**修复动作**（注册/轮换/检查 Keychain/重试节点），绝不含 secret、fingerprint 或 token。
- **一个打开中的 readiness Decision 覆盖同一 `(agent, machine, binding, version)`**：后续失败复用该 Decision（追加 `credential.readiness.suppressed` 计数审计），不重复创建收件箱项。现有 `record_readiness` 每次失败都建 Decision，A5.0 必须加去重查询/映射。
- **不自动重试**：自动 Run 重试遇到 credential readiness 失败时停在 `waiting_input`/`unverifiable`，不进入指数退避风暴；owner 通过 Decision 的 `retry`（修复后单次重查）或修改绑定/凭据后清除门禁。冷却窗口默认 10 分钟，可在配置中收紧；被抑制次数写审计。
- 远端节点离线时，主控不反复下发交付；按退避与租约状态只保留一个待处理项；节点恢复后重新检查一次，仍失败则复用 Decision。
- readiness 失败不得被当作成功、不得回退到机器基线（除非 owner 显式把该 Agent 配置为「非托管」）；强制托管模式必须 fail closed。

### 7. 吊销、轮换与飞行中请求

- **本地撤销**：`credential.revoke` 在提交后立即 (a) 标记 `revoked`，(b) 关闭该 binding 的所有代理监听器与 session token，(c) 删除 store 项（失败则保持 `revocation_pending` 但拒绝使用），(d) 对新请求返回 401/固定错误。新会话 readiness 失败。
- **远端撤销**：主控在同一认证通道发送 revoke（或更新租约状态）；节点收到后立即关代理/删 store/清 token；节点不可达时最多到 `lease_expires_at`。节点重连后先同步撤销，再接受新会话。
- **飞行中请求**：撤销提交后，已经转发到上游的一个请求可能完成（无法撤回已发出的网络请求）；代理在新请求前检查状态，会话 token 立即失效。文档/测试必须明确「立即对新请求生效；最多一个已开始的飞行中请求可能完成」。
- **轮换**：新 secret 写入 → `version+1` → 旧代理/token 立即失效 → 节点按需拉取新版本（或主控主动通知）→ 成功后删除旧 secret（失败则标记待删但拒绝旧版本）。轮换不改变 binding 身份，不产生新授权。
- **会话**：撤销/轮换默认**不自动杀死**正在进行的 Agent 会话，但后续模型调用失败关闭，UI 显示可读原因；owner 可显式停止会话。V1 不做「已建立连接无限期继续」。
- **审计**：`credential.revoked` 记录 `binding_id`、旧版本、受影响会话数、节点是否在线、是否进入租约等待；不记录 secret。

### 8. Redaction 与持久化面

必须保证以下持久化面不含真实 secret（以及 session token）：

| 面 | 规则 |
|---|---|
| 事件/`events` | 只写 credential/binding/version/lease/reason；不写 secret/token；`credential.delivered` 只写元数据 |
| 日志（host/节点/代理） | 代理不记录 header/body；host 只记录方法/路径类别/状态码/耗时；错误固定文本，不回显输入 |
| Artifact | 既有 Artifact 写入调用 `redact_secrets`；A5 扩展 `mxp_`/`mxs_` 等 token 模式，捕获真实 secret 形值 |
| Decision | 标题/详情/选项不含 secret；reason 固定；修复动作只引用 binding id |
| 会话记录/transcript | stderr 已经 redaction；stdout/transcript 在落盘或返回前应用扩展 redaction；真实密钥不可能进入 Agent，session token 视为秘密 |
| SQLite | `credentials.fingerprint` 只是不可逆摘要；无 secret 列；`credential_deliveries` 无 secret |
| 节点状态/outbox | 无 secret；凭据 store 是单独 `0600`/Keychain 项；状态快照不包含它 |
| Workspace | 不写 secret 文件；e2e 扫描 Workspace/Worktree 与 Agent home；session token 若被 Agent 写入，会话结束吊销，仍不当作真实密钥 |
| 崩溃/诊断 | 不启用 core dump 采集 secret；不把 env/header 打进错误；doctor 只显示权限/状态/version，不显示值 |

- `redact_secrets` 增加对 `mxp_<...>`、`mxs_<...>`、`Bearer mxp_...`、`Authorization: ...` 与 profile 自定义头的覆盖；现有 `sk-`、`KEY=value`、私钥块规则保留。redaction 宁可过度。
- **真实密钥不在 Agent 环境**，所以 Agent 无法把真实密钥写进 Workspace/Artifact/回复；session token 可能被 Agent 读取/写入，但它是短期能力 token，随会话结束或撤销失效，仍按秘密处理并测试扫描。
- 真实模型调用 e2e 必须扫描：SQLite 文件、事件流、host/节点 stderr/stdout、Artifact、Decision、会话记录、Workspace/Worktree、Agent home、runtime state dir（**排除按设计存放 secret 的 credential store 本身**）。扫描真实 secret 与 session token，均不得出现在上述非 store 面。

### 9. 审计事件

| 事件 | 触发 | 关键字段（无 secret） |
|---|---|---|
| `credential.enrolled` | 注册 | credential_id、kind、storage、actor |
| `credential.bound` / `credential.unbound` | 绑定/解绑 | binding_id、credential_id、machine_id、agent_id、profile |
| `credential.rotated` | 轮换 | binding_id、old_version、new_version、actor |
| `credential.revoked` | 吊销 | binding_id、credential_id、reason、sessions_closed、node_online |
| `credential.delivered` | 节点获得/续租 | binding_id、version、runtime_id、lease_expires_at、request_id |
| `credential.delivery_failed` | 投递失败 | binding_id、version、runtime_id、固定 reason |
| `credential.proxy.opened` / `.closed` | 会话代理 | binding_id、session_id、port（不写 token） |
| `credential.proxy.denied` | 代理拒绝 | session_id、固定 reason、计数（限流合并） |
| `credential.readiness.failed` | 启动前失败 | agent/machine/binding/reason、decision_id |
| `credential.readiness.suppressed` | 去重抑制 | 同上、coalesced_count |
| `credential.lease.expired` | 节点离线到期 | binding_id、runtime_id、lease_expires_at |

- 关键闸门同时写 `audit.recorded`（`action=credential.*`），`detail` 经 `redact_secrets`；不新建事件日志、不把 secret 放进 `decision_id` 之外的自由文本。
- owner 操作需要 `client_request_id` 幂等；重复撤销/轮换返回同一结果，不重复副作用。
- 不记录每次模型请求的完整 URL 查询串/正文；只记录 profile 类别、状态码、字节数（若需要计费/诊断）。

### 10. 威胁模型与残余风险

| 威胁 | 处置 | 残余 |
|---|---|---|
| 本地同用户访问 | Keychain/`0600`；目录/文件 owner/mode 校验；代理不在 argv/env 暴露真实密钥；不写 Workspace | 同用户恶意进程仍可能读 `0600` 文件、Keychain 项或调试 host；A5 不声称 OS 隔离，建议高威胁场景用独立用户/VM（§18.7） |
| 被攻陷的 Agent 子进程 | 真实密钥不在 env/子进程；只有短期 session token；token 绑定会话、可吊销、限流；代理固定 upstream；真实密钥不进入 Agent 日志/Workspace | 被攻陷的 Agent 可用 token 发起模型调用（这是其用途），可耗尽配额；同用户仍可能读 store；需配额/隔离（后续） |
| 日志/Artifact/Decision 泄漏 | 代理不记录 body/header；redaction 扩展；固定错误；测试扫描 | 第三方库/上游错误可能回显请求头；代理/客户端需避免把上游错误原文写入持久面 |
| 凭据重放 | session token 短 TTL + 绑定 session/version；交付认证+幂等+nonce；旧版本拒绝 | 会话存活期内 token 可被 Agent/同用户复用；按 TTL/撤销/限流缓解 |
| 跨机器凭据复用 | 一个 credential 只允许一个 binding；`(machine,agent,profile)` 唯一；节点只接受本机 binding | owner 显式共享/供应商只发一把密钥时需另定策略（§18.5） |
| 飞行中请求/撤销竞态 | 新请求先查状态；token 失效；节点租约 | 一个已开始的请求可能完成（无法撤回已发出的网络调用） |
| 代理 SSRF/重定向 | 固定 upstream host/path；禁止跨 host 重定向；TLS 校验；方法/大小限制 | profile 配置错误仍可能指向错误 upstream；owner 评审 profile |
| 代理 DoS/资源耗尽 | 并发/速率/body/超时上限；每会话监听器；限流审计 | 大量合法调用仍消耗上游配额；配额/计费不在 A5 |
| 节点离线 | 租约默认 15 分钟；过期失败关闭；重连先同步撤销 | 离线窗口内旧密钥可用；必须向 owner 明示 |
| Keychain 不可用/锁定 | 明确 readiness 失败；显式 file 降级需审计 | 显式降级降低静态保护；headless CI 需 owner 决策 |
| 本机 core dump/诊断 | 不采集 env/header；错误固定文本 | 宿主级调试/root 用户可读进程内存；超出 A5 |

### 11. 与固定架构的一致性

- **三轴**：Machine / Workspace / Agent Runtime 不变；A5 的代理在 AgentRuntime/host 本地执行面，不是 `MachineProvider` 的 read/exec/pty 之外的第四种能力；`WorkspaceProvider` 仍 Local/SSH。
- **ACP**：仅在 `AgentRuntime` 内；代理是模型访问通道，不是 ACP 工具，不影响 ACP permission→Decision。
- **远端**：节点使用自己的环境/登录作为基线；托管凭据只在节点本地 store + 本地代理；主控不把密钥复制到 Workspace；节点只验证主控授权/策略快照，不自行授予。
- **「Host 不复制模型密钥」与 A5 的边界**：默认远端 Agent 仍使用节点自身环境/登录，A5 不改变这一点；只有 owner 显式绑定并开启托管时，主控才按需把**该绑定的节点专用副本**交付到节点自己的 store，由节点本地代理使用。主控不把密钥写入 Workspace/工作树/事件/日志/Artifact/Decision/会话记录或节点状态快照，也不让主控成为 Agent 的运行时数据面。若架构 owner 把「Host 不复制模型密钥」解释为「主控完全不得持有/转发模型密钥」，A5 远端必须改为节点本地注册（交付通道只传授权/绑定，不传 secret）；这是实施前必须确认的架构解释（§18.11）。
- **审批权威**：主控是唯一 Decision 权威；节点只执行策略快照/授予。A5 不新增审批通道。
- **回退**：未绑定/开关关闭/代理不可用时，按机器自身账户或明确失败关闭；不回退到不安全的明文注入。

### 12. RPC、契约与数据模型增量

| 类别 | 增量 |
|---|---|
| RPC | `credential.enroll`、`credential.binding.create`、`credential.binding.list`、`credential.rotate`、`credential.revoke`、`credential.delete`、`credential.status`、`credential.doctor`（owner 授权；请求/响应不回显 secret） |
| Agent | `agent.start` 增加 profile/credential 解析与 readiness `auth` reason；`AgentSessionRecord` 增加 `credential_binding_id`、`credential_version`（无 secret/token）；session token 只在 host/节点内存 |
| 契约 | `CredentialKind`、`CredentialBinding`、`CredentialStatus`、`CredentialProfile`、`CredentialError` 固定 reason、`EVENT_CREDENTIAL_*`；`AgentSpec.env` 的基础 allowlist 契约（`inherit_env` 收紧）；代理坐标/token 的 env 键名（profile 映射） |
| 表 | `credentials`（元数据/fingerprint/state/version）、`credential_bindings`（唯一键）、`credential_deliveries`（投递/lease/ack，元数据）、`credential_profiles`（upstream/auth/env 映射，无 secret）；事件仍只写 `events` |
| 节点（A5.2） | `runtime.credential.pull` / `runtime.credential.ack` / `runtime.credential.revoke` 的概念接口；secret 只在认证响应体/内存，节点 store 独立；具体帧/ack 随 A1.3b 定 |
| 配置 | `credential.enabled=false`；`credential.storage=keychain / file`；`credential.lease_ttl=15m`；代理限流/超时；基础 env allowlist；readiness 冷却 |
| 运行态 | 代理坐标/token 随 AgentSpec/运行态 env 传递；`agent_env` 的 redaction 只作用于持久化投影，不能改写实际 spawn env；A5.1 必须加测试，避免 token 在持久化前被替换导致代理不可用 |
| 现有代码调整 | `services/host/agents.mbt` 的 readiness 去重；`packages/providers/agent/agent.mbt` 本地 `inherit_env` 收紧；`services/runtime/spec.mbt` 的 env 校验复用；`redact_secrets`/`is_secret_key_name` 扩展；`services/host/state.mbt` 增加代理/凭据运行态（不持久化 secret） |

任何迁移不得把既有 `agent_env`/run 日志升级为明文凭据；`credential` 表无 secret 列；事件 schema 增量必须向后兼容。

### 13. 实施顺序与验收映射

| 阶段 | 内容 | 对应验收 |
|---|---|---|
| A5.0 | 契约/存储抽象/平台探测/`0600`/Keychain 语义；binding 唯一性；readiness 去重/cooldown；redaction 扩展；关闭开关 | 第 1、2、4 条的基础 |
| A5.1 | 本地代理 + session token + env 基础 allowlist/`inherit_env` 收紧；本地真实模型 e2e；本地撤销/轮换 | 第 1、2、3（本地）、5 条 |
| A5.2 | 远端按需交付 + 节点 store/代理 + 租约/撤销；Workspace 不可见；跨机拒绝；两台机器 e2e | 第 2、3（远端）、5 条 |
| A5.3 | 审计/doctor/文档/CI/回归；macOS Keychain 非交互验证 | 全部回归与运维 |

| A5 验收（§2.5） | 本 ADR 决策 | 验证 |
|---|---|---|
| 只在 keychain/0600；事件/日志/Artifact/Decision/会话记录无明文；redaction 扩展 | §2、§8、§9 | 权限/格式测试；全持久面扫描；redaction 用例 |
| 按机器/Agent 绑定；未授权拿不到；吊销/轮换立即失效 | §3、§4、§7 | 绑定解析/拒绝、跨机复用拒绝、撤销后 401、轮换旧版本拒绝 |
| 远端托管通道；Workspace 不可见不可复制；子进程受控 | §4、§5 | 节点交付/租约；Workspace/Agent home 扫描；env/子进程检查 |
| 启动前 readiness；可读 Decision；不反复重试 | §6 | 缺失/撤销/锁定/离线场景；Decision 去重；自动重试抑制 |
| 真实模型调用 e2e；无 token 持久化；撤销后失败关闭 | §4、§8、§16 | 显式 key 的真实调用；扫描；撤销后同一调用 401/失败 |

### 14. 备选方案（未采用）

| 方案 | 不采用原因 |
|---|---|
| 把真实密钥放进 `env`（供应商前缀变量等） | 子进程/`/proc`/崩溃/日志泄漏；吊销需重启；无法绑定单会话 |
| 只做 `0600` 文件，所有平台 | macOS 失去 Keychain 的静态保护；Keychain 可用时明显更好；显式 file 降级已保留 |
| 主控集中代理，远端 Agent 回连主控 | 远端到主控的额外暴露/延迟/NAT 依赖；节点本地代理更符合「远端使用本机环境」；主控只交付凭据 |
| 把密钥复制到 Workspace/挂载 | 直接违反 A5 不可见/不可复制；会进 Artifact/git/日志 |
| 明文密钥写 SQLite/事件 | 违反验收；备份/审计泄漏面大 |
| OAuth refresh/device flow + 账户池 | 需要 token 刷新、账户池、并发租约、第二调度；A5 非目标 |
| Vault/云 secret manager | 新外部依赖/信任面；V1 不引入，未来可替换 `CredentialStore` |
| 代理解析/改写模型 JSON | 与供应商协议耦合、易错；透明转发 + 固定 upstream 足够 |
| 仅内存保存、不落盘 | 重启/重连无法恢复；节点需重新交付；可作为高安全选项（§18.9） |

### 15. 非目标

- 账户池、OAuth refresh/device flow、自动续期、跨组织共享、多租户。
- 任意 API 代理、通用网络出口、DLP/内容检查、计费/配额管理（V1 只做基本限流）。
- 独立 OS 用户/容器隔离、TPM、HSM、硬件密钥；这些是后续安全增强，不假装由 A5 提供。
- Windows、Keychain 生物识别 UX、远程 Keychain 共享。
- 把 A5 做成第二审批/调度/事件控制面；密钥不上 Workspace、不入事件/日志的边界不可放宽。

### 16. 验证计划（A5.1/A5.2 必须）

1. **存储**：Linux 目录 `0700`/文件 `0600`；权限错误拒绝；macOS Keychain 路径（可用时）不把 secret 放 argv；SQLite/events 无 secret；撤销删除失败仍失败关闭。
2. **绑定**：`(machine, agent, profile)` 唯一；未绑定/错误 machine/错误 agent 均拒绝；同一 credential 第二绑定返回 `credential_reused`；多候选冲突 readiness 失败。
3. **本地注入/子进程**：真实密钥不在 Agent env；session token 存在；Agent 子进程（`sh -c env`）无真实密钥；`/proc/<pid>/environ`（Linux）无真实密钥；Workspace/Agent home 扫描无真实密钥。
4. **代理**：只接受 session token；替换认证头；拒绝其他 host/path/重定向；超限/超时/限流；代理日志无 header/body；401 不带 secret。
5. **撤销/轮换**：撤销后新请求 401、readiness 失败；轮换后旧版本 401、新版本工作；飞行中请求的边界与审计符合 §7；重启后状态仍失败关闭。
6. **远端**：两台机器；节点按需拉取；secret 不出现在事件/日志/outbox/Workspace/节点状态快照；Workspace 内不可见；跨机绑定拒绝；节点离线租约到期失败关闭；重连先同步撤销。
7. **readiness/Decision**：缺失/锁定/代理不可用/交付失败各自产生固定 reason；同一问题只保留一个打开 Decision；自动重试不产生风暴；修复后 owner retry 成功。
8. **真实模型调用 e2e**：使用显式真实 key（CI 缺失则 skip 并标记），通过代理完成一次真实调用；扫描全部持久面（除 credential store）无真实 secret/session token；撤销后同一调用失败关闭。
9. **redaction**：`mxp_`/`mxs_`、`Bearer`、`sk-`、`KEY=value`、私钥块、profile 头均在 Audit/Decision/Artifact/会话记录中脱敏；`redact_secrets` 单测覆盖。
10. **交付安全**：未认证节点/错误 machine/旧版本/重放被拒；重复拉取幂等；`credential.delivered` 无 secret；节点状态快照不含 secret。
11. **回归**：`credential.enabled=false` 时既有 Agent/Run/SSH/runtime 行为、事件 schema、readiness、`agent_env` redaction 不变；`moon test --target native` 全绿。

### 17. 回退与停用

- `credential.enabled=false`：新会话不使用代理/托管账户，按机器自身登录；既有代理监听器在关闭时停止，session token 失效；凭据元数据保留供审计，不删除证据。
- 紧急回退：`credential.revoke` 全部绑定 → 删除 host/节点 store 项 → 关闭开关；节点离线则等待租约到期并标记待清理；不重新启用旧版本。
- 回退验证：关闭后 `agent.start` 行为与 V0.1 一致（无 credential RPC/事件、无代理 env、readiness 不检查托管账户）；重新开启只允许重新注册/绑定的凭据，旧撤销项不可复活。
- 不把回退实现成「明文注入」或「忽略权限」的降级路径。

### 18. 开放问题（实施前确认）

1. **macOS Keychain 非交互路径**：`security` CLI 是否会把 secret 放 argv？是否有可用的原生 helper/API？若没有，headless macOS 是否接受显式 `storage=file` 降级（需审计）？
2. **Agent CLI 兼容性**：哪些真实 Agent CLI 接受本地 HTTP base URL + bearer/token 头？如果不兼容，A5 的真实模型 e2e 用哪种客户端？是否需要 ACP adapter 侧的代理支持？
3. **A1.3b 交付接口**：远端交付是 pull 还是 push？方法名、ack/nonce、租约刷新与撤销的最终形状？A5 只依赖认证/幂等/不进事件，需与 A1.3b 收口。
4. **离线租约窗口**：默认 15 分钟是否可接受？「吊销立即失效」是否要求节点离线时也必须立即（那就需要主控始终可达或额外机制）？
5. **一凭据一绑定**：V1 拒绝同一 secret 跨机器/跨 Agent 复用。owner 是否接受为每个绑定单独注册？若供应商只发一把 key，是否走例外流程并承担复用风险？
6. **多凭据选择**：同一 Agent/profile 是否允许多个 active 候选？当前方案冲突即失败；owner 是否需要显式优先级？
7. **同用户隔离**：A5 不解决同用户读 `0600`/Keychain/进程内存。是否要在 A5 之外要求独立 OS 用户/容器/VM 作为默认？这会影响 D9 与 A1 的部署模型。
8. **CI 真实密钥**：真实模型 e2e 在 CI 中如何提供 key（受保护的 secret store/环境），并保证不落日志/缓存？缺失时 skip 是否满足「e2e 通过」的验收口径？
9. **节点持久化**：节点是否允许把 secret 持久化到本地 store（默认是，支持重启/重连），还是要求仅内存 + 每次交付？后者更安全但更依赖主控可达。
10. **代理范围**：是否需要对模型请求体做 DLP/字段白名单，还是透明转发 + 固定 upstream 足够？是否允许流式响应透传？
11. **固定架构解释**：`docs/architecture.md` §11 的「Host 不复制模型密钥」与 A5 的远端托管交付如何统一？若按最严格解释（主控完全不持有/转发密钥），是否接受「远端只在节点本地注册、主控只存绑定元数据」的替代方案？
