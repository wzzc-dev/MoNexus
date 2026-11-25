# ADR-0013：环境配方（A2）——Docker 作为 WorkspaceProvider 的一种实现

- 状态：Proposed（A2 设计；A1 验收后实施；待 owner 评审）
- 日期：2026-11-26
- 依据：`docs/architecture.md` §6.2、§6.5、§11、§13、§18/D8；`docs/v0.2-plan.md` §1.1 第 6 条、§2.2；ADR-0003（MachineProvider）、ADR-0006（权限模型）、ADR-0008（SSH 接入）、ADR-0012（配对远端 runtime）；`packages/contracts/workspace.mbt`、`packages/providers/workspace/workspace.mbt`
- 关系：本 ADR 把 D8 的 A2 细化到可实现；不改变 A1 的权威、配对、策略与回退边界，也不假设 ADR-0012 之外的 A1 API。V0.2 只做 Docker 一个后端。

## 背景

V0.1 的 Workspace 只有 `local` 与 `ssh` 两种形态：目录、文件、git、终端都绑定在一个长期存在的宿主目录上。V0.2 A2 要引入「一次性工作环境」：按配方创建容器，在其中读写代码、跑 git、执行命令与 Agent，用完销毁。`docs/architecture.md` §6.2 已为 `WorkspaceProvider` 预留 `createEnvironment` / `destroyEnvironment`，§18 也确认环境配方是 V0.2 的采纳项。

A2 的风险不在「能不能跑容器」，而在边界：

1. **第二控制面**：如果配方有自己的注册表、审批队列、调度器与清理状态，就会与主控 host 的组织/任务/Decision 模型重复，冲突时没有唯一权威。
2. **放错层**：如果把配方塞进 `MachineProvider`，执行传输（ssh/runtime）就会和 Workspace 生命周期、租约、审批混在一起，破坏 §2.3 的三轴边界。
3. **信任面**：配方携带镜像、宿主机挂载、生命周期脚本与 `privileged` 选项，等价于可执行的供应链输入；不签名、不审计、不限制挂载就会把 A2 变成宿主机 root 的快捷方式。
4. **泄漏与孤儿**：容器、临时目录、env-file 与运行中的 exec 在失败、取消、宿主崩溃后最容易残留；V0.2 的验收标准明确要求三种失败场景都不留孤儿。
5. **远端重复**：A1 之后同一配方要能在配对节点上运行；若节点自建审批/调度状态，就会重新引入「两套真相」。

本 ADR 因此先固定：配方是 WorkspaceProvider 的一种实现；模板与信任模型可审计；生命周期有确定句柄、幂等键与统一清理；高风险步骤只走主控既有 Decision 通路；远端只执行，不成为第二权威。

## 决策

### 1. 定位：WorkspaceProvider 的新能力，不是第二控制面

- **环境是既有 Workspace 的一种执行形态**：`environment` 是 WorkspaceProvider 的新 capability（`backend = "docker"`），绑定一个已登记的 Workspace 或其 Worktree，复用同一个 `workspace_id` / `worktree_id`、同一套文件/git/终端/Run 通路。**不新增平行的 Workspace 记录**，也不新增第二套状态机；环境自身只有一条 `env_` 记录（生命周期状态 + 句柄）。
- **实现分层**：`packages/providers/workspace` 增加 Docker 变体；docker 参数构造、inspect 解析与 env-file 处理放在新的 `packages/providers/docker`。它**组合**现有 MachineProvider 执行命令（本机进程、`ssh`、A1 的 `runtime.exec.*`），不自己开传输、不自己持有机器凭据。`MachineProvider` 接口不变：它只看到 docker argv 与退出码，永远看不到 recipe、env id、挂载或审批。
- **主控 host 是唯一权威**：配方记录、环境记录、租约、Decision、审计与事件都在主控 SQLite 与事件日志中；容器上的 Docker 标签只是恢复用的执行事实，不是状态权威。没有第二套调度器、审批队列或事件存储。
- **只做 Docker**：V0.2 不实现 VM、云沙箱、K8s、Coder/Terraform；`backend` 字段存在只是为了让未来的后端需要另写 ADR，不在 A2 里预建抽象。
- **能力探测决定可调度性**：现有 `has_docker` 只表示 CLI 存在（`packages/providers/ssh/ssh_probe.mbt` 已注明「daemon 未检查」）。A2 增加 daemon 探测：`docker info`（有界超时）、server 版本、rootless、cgroup v2、所需 flag 支持。探测失败或不可用的机器不参与环境调度，也不做「退化为宿主机直接执行」。
- **本地、SSH、runtime 三者同构**：配方本身不感知传输；同一 recipe 在本机、SSH 机器与 A1 节点上走同一生命周期，差别只在执行 docker 命令的通道。A2.1 先覆盖本机 + SSH，A2.2 接 runtime。
- **基本不变量**：同一 Workspace/Worktree 同时最多一个**活跃**环境；环境活跃期间持有该目标的租约，其他 Run 不能绕过租约直接使用同一目标。A2 不做嵌套环境或一目标多环境并行。
- **执行分流固定**：环境活跃时，原始文件读写/stat/watch 走宿主侧 bind mount 路径（与容器内是同一份字节，保留临时文件 + 原子 rename 规则）；git、终端、Run/exec、Agent 一律走容器内执行（使用镜像工具链）。A2.0 把这张 dispatch 表写进契约，避免“有时在宿主机、有时在容器”的歧义。

### 2. 配方对象、版本与信任

#### 2.1 字段

配方是不可变的版本化对象（`rcp_`），身份为 `name@version`，内容以 `content_hash` 为准：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `schema_version` | int | 是 | A2 固定为 `1`；未知版本拒绝 |
| `name` | string | 是 | `[a-z0-9][a-z0-9-]{0,63}`，不含路径分隔符 |
| `version` | string | 是 | semver 字符串；同一 `name@version` 只允许一个 hash |
| `image` | `{ref, digest}` | 是 | `digest` 必须是 `sha256:...`，**按 digest 拉取**；`tag` 只作展示，缺 digest 直接拒绝 |
| `workdir` | string | 否 | 容器内绝对路径，默认 `/workspace`；不得逃出挂载目标 |
| `user` | string | 否 | 默认镜像用户；允许 `uid:gid`；`root` 允许但进计划风险 |
| `mounts` | array | 是 | 每项 `{source, target, mode}`；`source` 只能是 `workspace`（绑定的 Workspace/Worktree 根）或 `scratch`（本环境专属目录），**配方不能声明任意宿主机路径** |
| `env_allowlist` | array[string] | 否 | **只有变量名，没有值**；名字需匹配 `[A-Za-z_][A-Za-z0-9_]*` |
| `limits` | object | 否 | `cpu_millis`、`memory_mb`、`pids`，带默认值与上限；缺省也强制套用默认限额 |
| `network` | string | 否 | `none`（默认）或 `bridge`；`host`、端口发布、egress allowlist 在 A2 不支持，声明即拒绝 |
| `lifecycle` | object | 是 | `prepare` / `start` / `stop` 三个钩子；每个是 `{argv[], timeout_s}` 或 `{script, timeout_s}`（二者互斥） |
| `doctor` | object | 否 | `{argv[], timeout_s}`，容器内只读诊断命令；宿主侧结构化 doctor 始终可用 |
| `source` | object | 是 | 来源：`kind=local_file`、路径、作者、`created_at`；A2 只支持本地文件导入，没有市场/远端仓库 |
| `signature` | object | 是 | `{key_id, alg="ed25519", sig}`，覆盖 canonical 内容 hash |

`argv` 按位置参数传递，宿主/容器内都使用固定 `sh -c 'exec "$@"'` 包装（与 ADR-0011 的远端命令模式一致），配方字符串永远不进宿主 shell。`script` 以 `/bin/sh -c` 在容器内执行，自动归为高风险（见 §4）。

#### 2.2 不可信输入

**所有配方都是不可信数据，签名只证明作者，不证明安全。** 明确按不可信输入处理、必须逐项校验再用的字段：

- `lifecycle.*.argv` / `lifecycle.*.script`、`doctor.argv`：任意命令内容；只做 schema 校验与风险分级，不做「看起来安全」的启发式放行。
- `image.ref`：解析为 registry/repo；只允许合法引用字符，digest 必须存在并在拉取后复核。
- `mounts[].target`：必须是绝对、规范化后的容器路径，拒绝 `..`、空段、控制字符；不映射到宿主路径。
- `env_allowlist[]`：只接受合法变量名；值永远不来自配方。
- `workdir`、`user`、`name`、`version`、`source`、`limits`、`network`：按 schema 严格解析，未知字段、越界数值、非法枚举一律拒绝，不静默忽略。
- 配方文本（日志、doctor 输出、来源元数据）按不可信文本处理：有界长度、进入日志前 redaction，不作为指令执行。

#### 2.3 签名、版本与拒绝策略

- **信任库**：主控保存 owner 的 Ed25519 公钥表 `recipe_trust(key_id, public_key, added_at, revoked_at)`；只允许 owner 通过配置/CLI 添加，配方自身不能引入或替换密钥。
- **规范化与签名**：去掉 `signature` 后的字段做 canonical JSON（键排序、UTF-8、无多余空白），`sha256` 得 `content_hash`；签名覆盖该 hash。导入时验签、复算 hash、校验 schema。
- **拒绝（refuse）而非降级**：未签名、签名密钥未知或已吊销、hash 不匹配、schema 不合法、缺 image digest、同一 `name@version` 内容不同、含 A2 不支持的字段（`network=host`、端口发布、磁盘配额等）——全部拒绝导入，写 `recipe.refused` 事件（含原因与来源，不含任何秘密），不产生可用的 `rcp_` 记录。
- **用前复验**：`environment.create` 从库中取出原始 canonical 字节重新计算 hash 并比对；数据库/磁盘被篡改时拒绝并审计。
- **版本化与审计**：内容任何变化必须升 `version`；`recipe.imported`、`recipe.revoked`、`recipe.used`（`name@version+hash+key_id`）都进事件日志。owner 可吊销密钥或单个配方版本：新的 create 被拒绝，已有环境仍可 `destroy`（避免把容器困死）。
- **没有 TOFU**：未知密钥不会因第一次使用而被记住。
- **密码学实现**：A2.0 复用 A1.0 对 MoonBit 签名/TLS 的 spike 结论；若 MoonBit 侧没有可验证的 Ed25519，则使用系统 `ssh-keygen -Y`/`minisign` 作为显式、带版本检查的验签依赖，缺失时一律拒绝，不手写密码学、不降级为「未签名也放行」。

### 3. 生命周期、句柄、幂等与所有权

#### 3.1 对象、方法与句柄

在 `WorkspaceProvider` 的既有形状上增加：

```text
createEnvironment(workspace_or_worktree, recipe_ref, spec) -> EnvironmentHandle
startEnvironment(handle) -> Unit                            // 停止后恢复
execEnvironment(handle, CommandSpec, exec_id) -> ExecResult // 在容器内执行
stopEnvironment(handle) -> Unit                             // 停止但保留容器
destroyEnvironment(handle) -> Unit                          // 停止 + 删除容器与临时目录
doctorEnvironment(handle) -> DoctorReport                   // 只读诊断
```

`EnvironmentSpec`（create 的输入）至少包含：目标（`workspace_id`，可选 `worktree_id`）、`machine_id`、显式 env 名与值、额外挂载请求（必须是已登记的根）、`ephemeral`、可选 `ttl_s`、`client_request_id`。**配方本身不能指定宿主路径**；宿主路径只从注册表解析。

- **确定性句柄**：`EnvironmentHandle { environment_id, workspace_id, worktree_id?, container_name, machine_id, state, recipe_hash, created_at }`。
  - `environment_id` = `env_<ULID>`，由主控分配。
  - `container_name = "monexus-env-" + environment_id`，由 id 唯一派生。
  - 临时目录固定为执行机上的 `~/.monexus/environments/<environment_id>/`（0700），只放 env-file、生命周期日志等宿主侧暂存；不含密钥残留。
  - 容器标签固定：`monexus.managed=true`、`monexus.primary_id`、`monexus.environment_id`、`monexus.workspace_id`、`monexus.recipe_hash`。**对账只认这几个标签，绝不触碰其他容器。**
- **所有权**：主控 host 拥有记录与编排；环境持有绑定目标的租约，同一环境同一时间最多一个活跃 Run；Agent 不能通过工具直接创建/销毁环境（只有 host RPC；`ops` 的请求同样进审批）。`ephemeral=true` 的环境由 Run 终结器在终态销毁，无论成功、失败或取消。

#### 3.2 create 的顺序（可恢复、先意图后变更）

1. 取配方并复验 hash；探测目标机器 daemon 能力；解析绑定的 Workspace/Worktree 根并取得租约。
2. 计算 **plan digest**：`hash(recipe_hash + machine_id + 目标 id + 解析后的挂载 + env 名 + limits + network + user + 策略版本 + create 参数（不含秘密值）)`；按 §4 做风险判定，必要时生成 Decision。
3. 在任何 Docker 变更之前落 **意图记录**（`state=creating`，含 plan digest、container_name、临时目录、审批引用）；崩溃后据此对账。
4. 按 digest 拉取镜像（已存在则跳过），拉取后复核 digest。
5. `docker create`：确定性名称、标签、绑定挂载、`--env-file`、限额、network、user、`--init`、`--restart=no`、**不加 `--rm`**（保留 inspect 供恢复与清理）。
6. `docker start`；有界等待进入 running；执行 `prepare`（已审批的计划内，带 timeout）。
7. 标记 `running`、写 `environment.created`、删除 env-file。
8. 任一步失败：反向清理（取消 exec → stop → `rm -f` → 删临时目录），标记 `environment.failed` 并记录 cleanup 结果；Docker 不可达时标记 `orphan_suspected` 并给出精确容器名与 doctor 操作。

**幂等**：`environment.create` 带 `client_request_id`；重复请求返回同一环境记录，不重复创建。并发重复由 host 锁串行化。若同名容器已存在：inspect 标签与 plan（镜像 digest、挂载、env 名、limits、network、user）全部一致则**收养**；不一致则拒绝 `conflict`，绝不删除不属于本环境的容器。收养后仍需通过 doctor 检查，检查失败则清理并只重建一次，再次失败标记 `error`。

#### 3.3 start / exec / stop / destroy 语义

- **start**：容器存在且停止 → `docker start`；`lifecycle.start` 视为高风险，若本次动作尚未获审批则返回 `approval_required`，不静默跳过也不静默执行；已 running → 幂等成功。写 `environment.started`。
- **exec**：只接受 `CommandSpec` 的 argv，拒绝整串 shell（沿用 §6.1）。容器内用固定包装启动并写 PID 文件（`/run/monexus/exec-<exec_id>.pid`），stdout/stderr 分流、有界缓冲、退出码结算；每次 exec 有 `exec_id` 与幂等键，重复结算丢弃。
  - **取消**：对进程组发 TERM，有界等待后 KILL；容器保持运行；结果记 `cancelled`，绝不记成功。若无法确认进程已终止，向 Run 暴露 `unverifiable`/`lost`，不假装取消成功。
- **stop**：先按上面语义取消活跃 exec，再执行 `lifecycle.stop`（中风险，宿主发起的清理路径，不经审批但写审计；有界），`docker stop` 带超时，写 `environment.stopped`；容器保留以便再次 start，磁盘仍占用（由 TTL/owner 决定何时 destroy）。
- **destroy**：取消 exec → stop → `docker rm -f` → 删临时目录 → 释放租约 → 写 `environment.destroyed` 墓碑。容器已不存在时仍算成功（幂等）；任一步失败则保留记录并标记 cleanup 细节，供重试与 doctor。
- **idle/TTL**：A2 默认关闭自动 stop；`ephemeral` 环境在 Run 终态销毁；长期环境由 owner 或 TTL 显式 stop/destroy。stop 不等于 destroy，避免把「暂停」误当「清理完成」。

#### 3.4 失败、取消与崩溃的清理矩阵

**约束：每个终态路径都必须尝试清理（成功、失败、取消、崩溃恢复），并把 cleanup 结果写进事件；清理不能确认时如实标记，不制造成功。**

| 场景 | 期望行为 |
|---|---|
| `prepare` / 安装失败 | 取消 exec → stop → `rm -f` → 删临时目录；`environment.failed`，无容器残留；安装错误可读 |
| 计划审批被拒 / 过期 | 在拉取和创建之前终止，不产生容器；写拒绝审计，无临时目录 |
| 拉取超时 / 镜像不存在 | 无容器；`environment.failed`；镜像缓存保留不算泄漏，doctor 说明 |
| create 中 docker 不可达 | 意图记录保留，`orphan_suspected`（附容器名）；doctor 给出恢复/清理命令；不假装失败已清理 |
| exec 被取消 | 进程组 TERM→KILL，容器继续 running；exec 记 `cancelled`，Run 不成功 |
| host 在 create 中被 SIGKILL | 启动时 reconcile 按标签对账：create 意图超时则销毁；容器已完整且 inspect 通过则收养 |
| host 在环境 running 时崩溃 | 容器独立存活；reconcile 依据标签恢复 `running`；记录与容器不一致时以 doctor 报告为准，不静默改历史 |
| docker daemon 重启 | `--restart=no`，容器不会自行复活；reconcile 观察到 exited → `stopped`，可显式 start |
| destroy 中途崩溃 | 下次 reconcile 继续销毁（幂等）；残留临时目录按记录清除 |
| 临时目录删除失败 | `environment.failed` 附 residual 路径；doctor 给出可读操作；不阻塞其他清理 |
| A1 节点断线 / 崩溃（A2.2） | 主控标 `disconnected`，不销毁；重连后对账；节点确认丢失则 `orphan_suspected`，容器可能仍在节点上，doctor 说明 |

清理实现规则：

- 只操作带 `monexus.managed=true` 且 `monexus.primary_id` 匹配的容器；**永不执行 `docker system prune`**，永不删除未标记容器。
- 临时目录删除只发生在 `~/.monexus/environments/` 下，且路径由 id 派生、不做字符串拼接删除。
- 清理有界超时（默认 30s）与有限重试；Docker 不可达时保留意图记录供后台 reconcile 继续，不放弃但不假装完成。
- `reconcile` 在 host 启动时执行一次，此后每 60s 一次；只读扫描 + 按记录收敛，不创建新环境。

#### 3.5 doctor

`environment.doctor` 返回结构化、可读的诊断，不修改任何状态：

- Docker：daemon 可达性、server 版本、rootless、cgroup v2、所需 flag 支持。
- 镜像：本地是否存在、digest 是否与配方一致、RepoDigest 核对结果。
- 容器：存在/状态、标签、镜像 ID、挂载源与目标、只读标志、env 名（不含值）、limits、network、user、`--init`。
- 记录一致性：环境状态 vs 容器状态、plan digest、租约与活跃 Run、临时目录、残留 PID。
- 配方：信任状态、签名 key、是否已吊销；最近一次 cleanup 的结果与错误。
- 建议动作：重试 destroy、收养、重新创建、联系 owner，均给出精确命令/参数；不暴露秘密值。

配方内的 `doctor` 命令在容器内运行，归为低风险、有界超时、只读约定（无法强制，故输出按不可信文本处理并 redaction）。宿主侧 doctor 不依赖配方命令也能工作。

### 4. 安全与审批

#### 4.1 风险映射

| 输入 / 步骤 | 默认风险 | 处理 |
|---|---|---|
| 配方导入/校验 | 不执行 | 静态校验；未签名/未知 key 直接拒绝 |
| create 基础计划（绑定 workspace 根 rw、local/ssh 执行） | medium | Workspace 授权内允许；计划仍进审计 |
| `prepare`（含安装、下载、变更） | high | **进入主控 Decision**；一个计划一次审批（见 §4.2） |
| `lifecycle.start` | high | 每次 start 都需审批；未批返回 `approval_required` |
| `lifecycle.stop`（清理路径） | medium | 宿主发起，不经审批但写审计；有界执行 |
| `doctor` 命令 | low | 有界超时；输出按不可信文本处理 |
| 额外挂载另一个已登记 workspace 根（ro） | medium | 计划内允许，审计 |
| 额外挂载 workspace 根（rw） | high | Decision |
| 任何不在已登记根内的宿主路径、`~/.ssh`、`~/.monexus`、`/`、docker socket | critical | **A2 一律拒绝，不可审批**（无代码路径） |
| `privileged=true`、host PID/IPC、设备直通、`network=host` | critical | 默认 deny；`privileged` 只能由 owner 对具体计划做一次性授权；其余在 A2 直接拒绝 |
| `network=bridge`（可出网） | high | Decision；默认 `none` |
| `user=root`（容器内 root） | medium | 计划内标注，审计；不等于宿主机 root |
| exec 任意命令 | 沿用既有分级 | `sh -c` 仍为 high；环境不改变 §11 的规则 |

#### 4.2 审批边界

- **只有一条通道**：计划审批走现有 `Decision`（`decision.requested`），在 Inbox 中由 owner 回答；不新建审批队列，不在节点/容器内放行。
- **按计划审批，不是按字段弹窗**：一个 create 生成一个 Decision，绑定 plan digest（recipe hash、machine、目标、挂载、network、privileged、user、环境 id、策略版本、nonce、过期时间）。任一字段变化都会改变 digest，需要新的 Decision。
- **一次性、短时有效**：审批在创建尝试前消费；被拒/过期则不执行任何 Docker 变更。远端（A2.2）由主控下发绑定请求摘要的短期凭据，节点校验摘要与有效期后执行一次；不能复用到另一环境或另一命令。重试需要重新审批，避免「批过一次就永久放行」。
- **默认拒绝**：`privileged` 的计划即使 owner 选择 `allow_once`，也只对本次计划生效；没有长期策略例外、没有按配方永久白名单。策略版本过期或哈希不匹配时高风险步骤等待或 `unverifiable`，不按默认放行。
- **脚本可审计**：`script` 内容按 canonical 字节存为 Artifact（含 hash、bounded preview、redaction），Decision 里展示 hash + 预览；`argv` 同样记录。执行输出进有界日志，secret 规则不豁免。

#### 4.3 挂载、凭据与网络

- **挂载白名单**：只允许 (a) 绑定的 Workspace/Worktree 根、(b) 本环境 `scratch` 目录、(c) create 显式请求且已登记的其他 Workspace 根。解析 `realpath` 后必须仍位于已登记根内，拒绝 `..`、绝对路径逃逸、符号链接逃逸与跨 Workspace。`rw` 要求本环境持有该目标的租约。
- **环境变量**：配方只声明名字；值在 create/exec 时显式提供（后续 A5 由托管账户提供），**不写数据库、不进事件、不进日志、不进 Artifact、不进 doctor**。传递用 0600 env-file 或 stdin，绝不放进 argv（`docker run -e NAME=value` 会把值暴露在宿主进程列表）；容器启动后立即删除 env-file。`is_secret_key_name` 的 redaction 只作最后兜底，不能作为「值可以入库」的理由。日志按 `NAME=value` 模式统一脱敏。
- **不继承宿主机凭据**：容器只拿到 allowlist 里的显式变量，不继承 host 进程环境；不挂载 `~/.ssh`、`~/.aws`、keychain、`~/.monexus` 或 docker socket；`HOME` 指向容器内路径；默认用镜像非 root 用户，需 root 时按 §4.1 标注。
- **镜像供应链**：只按 digest 拉取并复核；镜像 tag 不参与运行决策；registry 凭据沿用宿主 docker 自己的配置，**不复制进容器/Workspace/事件**。镜像内容本身的签名/attestation（cosign 等）不在 A2 范围，作为残余风险记录。
- **网络与资源**：默认 `network=none`，A2 不发布端口（不做预览代理）；limits 始终生效（缺省也给默认值），`pids` 防 fork 炸弹，不允许 `--oom-kill-disable`；不允许 `--privileged` 之外的额外 capability 扩张（A2 直接拒绝 `cap-add`）。

### 5. 远端 runtime（A1 之后）

- **同一配方、同一计划、同一审批**：A2.2 只把 docker 命令的执行通道换成 A1 的 `runtime.exec.*` / `runtime.fs.*`（ADR-0012 §3），不新增 `runtime.environment.*` RPC，不在节点建配方库、环境表或审批状态。
- **主控唯一权威**：环境记录、plan digest、Decision、审计只在主控；节点只执行 docker 命令、回传 stdout/stderr/退出码与 inspect 结果，节点本地状态按 A1 视为可丢弃缓存。
- **没有第二套审批**：节点侧只做 ADR-0012 §5 的同一条策略快照检查；需要人工时回主控 Decision。主控不可达时高风险 create/exec 等待或 `unverifiable`，不离线放行，节点不能自批。
- **恢复语义**：容器标签仍是恢复键。节点断线时主控标 `disconnected`，不销毁；重连后经 `runtime.exec` 做 inspect/reconcile；节点不可恢复时标 `orphan_suspected`，doctor 给出节点上的清理说明，不谎报已销毁。
- **调度不新增状态**：仍按机器能力（docker daemon + 现有 `max_parallel`）匹配，placement 写入 Run 后不变；runtime 与 ssh 环境互不污染，SSH 仍是基线与回退。
- **依赖范围**：A2 只依赖 ADR-0012 已写明的方法（exec/fs/pty、心跳、策略快照、绑定审批）；A1 若调整这些接口，A2 的远端适配随之调整，不假设更多。

### 6. 契约与数据模型增量（A2 实现时随代码落地）

以下是本 ADR 对 `packages/contracts` / `packages/domain` / host 的增量提案；当前仓库只有预留位置，没有这些定义：

| 位置 | 增量 |
|---|---|
| `packages/contracts`（新增 `environment.mbt` 或并入 `workspace.mbt`） | `ENVIRONMENT_BACKEND_DOCKER`；错误 kind：`untrusted_recipe`、`unsupported`、`docker_unavailable`、`cleanup_failed`、`approval_required`；方法 `recipe.import/list/show/revoke`、`environment.create/start/stop/destroy/exec/doctor` |
| 记录 | `RecipeRecord`（name、version、content_hash、signer_key_id、source、state）、`EnvironmentRecord`（id、workspace_id、worktree_id?、machine_id、state、recipe_hash、container_name、backend、timestamps）、`EnvironmentHandle`、`EnvironmentDoctorReport` |
| 运行上下文 | Run/工作区上下文增加可选 `environment_id`：原始文件读写/stat/watch 走宿主 bind mount，git/终端/Run/Agent 在环境活跃时经容器执行；`WorkspaceRecord` 本身不改 kind，避免重复记录与租约歧义 |
| 事件 | `recipe.imported` / `recipe.refused` / `recipe.revoked` / `recipe.used`；`environment.created` / `started` / `stopped` / `destroyed` / `failed` / `orphan_suspected`。exec 复用 `run.*`，文件/git 复用 `workspace.*`，不新增平行事件族 |
| Decision | 新 kind `environment_approval` 与绑定字段（`plan_digest`、`machine_id`、`recipe_hash`、`nonce`、`expires_at`）；Inbox 分桶复用现有规则 |
| 机器 profile | `has_docker` 之外增加 daemon 可用、server 版本、rootless、cgroup v2、mount/flag 支持 |
| 存储 | `recipes`、`recipe_trust`、`environments` 表；新增迁移，向后兼容旧 Workspace 记录 |
| Artifact | `recipe_bundle`、`recipe_script`、`environment_cleanup_log` |

**实现前必须解决的契约缺口**（A2.0 一并处理，见 §12）：

1. 当前 `packages/providers/workspace/workspace.mbt` 的 `WorkspaceProvider` 是 `Local`/`Ssh` 枚举，不是 trait；A2 加 Docker 变体与 dispatch，且 Docker 变体需要“绑定宿主机根 + 容器执行”的双通道，现有 `root()` 假设要扩展。
2. `MACHINE_KIND_RUNTIME`、`runtime.*` 类型尚不存在（A1 落地时才有）；A2.2 只按 ADR-0012 的方法名适配，不提前定义 A1 类型。
3. 没有任何 docker daemon 探测；`has_docker` 仅是 CLI 存在。
4. `docker exec --env-file` 的最低 Docker 版本需在 A2.0 验证；若目标版本不支持，改为 create 时一次性 env-file + exec 只继承容器已设变量（exec 额外变量需另设方案），并把结论写入 ADR 实施记录。
5. 现有 `Decision` 没有 `environment_approval` 的绑定/一次性消费字段。
6. 文件/git/终端/Run 的 host 路径目前直接走 workspace provider，没有“同一 root、容器内执行”的上下文切换；A2.0 按 §1 的分流表实现：原始文件操作走宿主 bind mount，git/终端/Run/Agent 在环境活跃时走容器，其余情况行为不变。
7. 事件注册表与投影没有 environment 行；UI 需要最小只读投影（环境状态与 doctor 状态），详细 UI 不在 A2 范围。

### 7. 备选方案

- **独立的环境服务/第二控制面**：拒绝。会复制审批、状态、清理与审计，冲突时无唯一权威，违反 D8 边界。
- **把 environment 放进 MachineProvider**：拒绝。MachineProvider 只有 probe/exec/pty/心跳，没有 recipe、租约、Workspace 与审批概念；放进去会破坏三轴边界。
- **把环境做成新的 Workspace 记录（`kind=environment`）**：拒绝。同一 root 会出现两条 Workspace 记录与两套租约，UI 与 Run 解析都要处理重复身份；环境作为既有 Workspace/Worktree 的执行形态更简单，也避免第二套投影。
- **先做 VM/云沙箱**：拒绝。运维、镜像、网络与成本都超出 V0.2 最小集；Docker 已能覆盖一次性工作环境。
- **宿主机直接执行（chroot/nix/临时用户）**：拒绝。不是 V0.2 承诺的隔离级别，清理与资源限制都更难。
- **允许未签名配方 + 「开发模式」**：拒绝。开发也必须使用本地信任库中的 key；否则无法区分开发与供应链攻击。
- **允许任意宿主机路径挂载**：拒绝。等同把宿主机文件系统交给不可信配方；A2 只允许已登记根与专属 scratch。
- **compose/devcontainer 作为配方格式**：A2 不做。A2 的 create 语义是显式 docker 参数，compose 解析会再引入一层不可信输入与生命周期。
- **在节点本地缓存配方/审批结果**：拒绝。违反主控唯一权威与 ADR-0012 §5。

### 8. 后果与风险

| 风险 | 影响 | 对策 |
|---|---|---|
| 容器/临时目录泄漏 | 磁盘、资源与隐私 | 确定性命名 + 标签 + 启动/周期 reconcile + 清理矩阵 + doctor；Docker 不可达时显式 `orphan_suspected`，不假装清理 |
| 宿主机挂载逃逸 | 读写宿主机任意文件 | 只允许已登记根与 scratch；realpath + 根包含检查；禁止 socket/家目录/`/`；`rw` 需租约 |
| 镜像供应链 | 恶意镜像执行 | digest 固定 + 拉取复核；配方签名防篡改；镜像 attestation 不在 A2（记录残余风险）；registry 凭据不进容器 |
| privileged / 内核逃逸 | 宿主机 root | 默认 deny；仅 owner 对具体计划一次性授权；A2 拒绝 host namespace、设备、socket；Docker 共享内核的逃逸风险保留，VM 隔离是后续版本 |
| Docker 不可用 | 环境创建失败 | 能力探测 + `docker_unavailable` 可读错误 + doctor；不退化到宿主机执行 |
| 生命周期脚本不可复现/联网下载 | 环境漂移、隐式供应链 | 默认 `network=none`；bridge 需审批；记录 image digest、脚本 hash；建议 prepare 可离线 |
| 秘密进入日志/事件 | 凭据泄漏 | 配方只存名字；值走 0600 env-file/stdin；启动后删除；全量 redaction；测试扫描 DB/事件/日志/Artifact |
| 审批疲劳 | owner 被频繁打断 | 按计划一次审批，而不是每字段弹窗；常见只读步骤走低风险；ephemeral 环境自动销毁 |
| 平台差异（macOS Docker Desktop） | 挂载/权限行为不同 | A2 首发只对 Linux 本机 + Linux SSH 机器给出一等支持；macOS 作为未验证平台记录，不声称等价 |
| 并发/命名冲突 | 误删或串环境 | 一目标一活跃环境一租约；同名容器按标签收养或 `conflict` 拒绝，绝不删除他人容器 |
| 供应链策略缺失 | 配方来源不可控 | A2 只支持本地导入 + owner 信任库；没有市场/自动更新 |

### 9. 非目标

- 配方市场、远端配方仓库、自动更新/自动信任。
- VM、云沙箱、K8s、Coder、Terraform、Firecracker 等后端。
- 预览代理、端口发布、任意服务暴露。
- GPU/设备直通、host network、任意 `cap-add`、docker socket 挂载。
- 镜像构建（A2 只消费预构建镜像，不在 create 里跑 Dockerfile build）。
- 多租户配额、跨组织共享配方、计费与成本预算。
- Windows 容器、macOS 一等支持（记录为未验证）。
- 完整的容器内 seccomp/AppArmor 自管策略（沿用 Docker 默认，作为后续安全加固项）。
- 嵌套环境、一目标多环境并行、跨机器迁移运行中的环境。

### 10. 验证计划

A2 的验收按 `docs/v0.2-plan.md` §2.2，测试必须可重复，且能离线运行（不依赖公网 registry）：

1. **Docker e2e（本机 + SSH）**：用测试内构建的最小 fixture 镜像与测试密钥签名的 fixture 配方，依次验证 create → 文件读写 → git status/diff/commit → exec 构建/测试 → 终端 → stop/start → destroy；断言容器、临时目录、env-file 全部消失，git 状态符合预期；同一 recipe 在 SSH（loopback sshd）机器上重复通过。
2. **清理矩阵**：逐项覆盖 §3.4 的 11 个场景（prepare 失败、审批拒绝、拉取失败、docker 不可达、exec 取消、create 中 SIGKILL、running 时 SIGKILL、daemon 重启、destroy 中断、temp dir 删除失败、节点断线），断言终态事件、`docker ps -a` 中带本环境标签的容器数为 0（或 doctor 明确报告 residual）、临时目录存在性与 cleanup 记录一致。
3. **拒绝策略**：未签名、未知 key、吊销 key、hash 篡改、tag 无 digest、未知字段、同名同版本不同 hash、privileged 无授权、挂载越界、docker socket 挂载、`network=host`、不支持的 disk 字段——逐项得到可读错误与 `recipe.refused`，且不产生任何容器。
4. **审批路径**：含安装脚本的 prepare 生成 `environment_approval` Decision；拒绝时无 Docker 变更；批准后只执行一次；同一审批复用到另一环境/另一 plan digest 被拒；过期与重放被拒；`start` 未批返回 `approval_required`；A2.2 验证节点只接受主控绑定审批，主控不可达时等待/`unverifiable`。
5. **秘密与继承**：env 值不出现在 DB、事件、日志、doctor、Artifact 与宿主进程 argv；env-file 启动后删除；容器只有 allowlist 变量；无宿主环境继承；redaction 扫描通过。
6. **回归**：`scripts/workspace_smoke.sh`、`host_smoke.sh`、`task_smoke.sh`、`recovery_smoke.sh`、`acceptance.sh` 与 SSH agent smoke 全部保持绿色；本机/SSH Workspace 在环境创建前后行为一致；关闭环境功能时行为与 V0.1 完全相同；同一机器上 SSH Workspace 与环境并存互不影响。
7. **Docker 不可用**：`environment.create` 返回 `docker_unavailable`/`unsupported` 可读错误，doctor 说明原因，不发生宿主机执行。
8. **单元测试**：配方 schema/规范化/hash/签名校验、plan digest、风险映射、状态与事件映射、清理顺序、doctor 报告字段；`moon test` 内不依赖 Docker。
9. **CI**：GitHub Actions 的 Linux runner 有 Docker 时跑 e2e；无 Docker 时明确 `skipped` 而不是静默通过，并在有 Docker 的 job 中至少断言一次真实 e2e 执行。A2 不改变现有 CI 的 build/test 门槛。

### 11. 实施顺序（A2.0–A2.2）

- **A2.0 契约 + schema + 信任（无 Docker 副作用）**：`packages/contracts` 新方法/记录/事件/错误；配方 schema、canonical JSON、hash、Ed25519 验签与信任库；plan digest、风险映射、Decision 绑定；配方导入/拒绝/吊销；环境上下文 dispatch 规则；单元测试。功能开关默认关闭。
- **A2.1 Docker 后端（本机 + SSH）**：create/start/exec/stop/destroy、env-file 与 secret 处理、确定性句柄、幂等与收养、清理矩阵、reconcile、doctor；fixture e2e、拒绝与审批测试、回归。此时 A2 可独立验收（不依赖 A1 实现）。
- **A2.2 远端 + 审批 + 全量 e2e**：通过 ADR-0012 的 `runtime.exec.*`/`fs.*` 适配节点执行；节点侧审批凭据校验；断线/崩溃矩阵；两台真实机器 e2e；SSH 回归；运维/迁移/回退文档。
- 每个阶段都可单独启用/停用，且不改变 V0.1 的 local/ssh 路径。

### 12. 回退与停用

- **功能开关**：配置 `environment.enabled=false`（或环境变量）时，`environment.create/start/exec` 返回 `unsupported`，不创建新容器；`environment.doctor` 与 `environment.destroy` 保留可用，避免已有环境变成无法清理的孤儿。关闭后 local/ssh Workspace 行为不变。
- **移除后端**：回退到不含 docker backend 的 host 构建后，已有 environment 记录进入 `error` 并给出可读说明；用上一版二进制或手动步骤 destroy。
- **手动清理**：按标签列出本主控的容器
  `docker ps -a --filter label=monexus.managed=true --filter label=monexus.primary_id=<id>`，
  逐个 `docker rm -f`；删除 `~/.monexus/environments/<environment_id>/`；**不做全局 prune**。清理后用 doctor/脚本确认无残留。
- **信任回退**：吊销配方或密钥只阻止新的 create，不阻断已有环境的 destroy 与数据读取。
- **数据回退**：新增表/列使用增量迁移；停用功能不需要回滚 schema；事件保留，审计可回放。

### 13. 开放问题（实施前定稿）

1. MoonBit Ed25519 是否可用（复用 A1.0 spike）；不可用时系统验签工具的最低版本与缺失行为。
2. `docker exec --env-file` 的最低 Docker 版本与不支持时的替代方案（见 §6 缺口 4）。
3. macOS Docker Desktop 是否列入 A2.1 验收；当前默认不承诺。
4. `privileged` 的一次性授权是否需要额外的 owner 二次确认；A2 默认只按计划 Decision + `allow_once`。
5. environment 的最小桌面投影范围（状态与 doctor）；详细管理 UI 不在 A2。
