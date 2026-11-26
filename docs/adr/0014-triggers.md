# ADR-0014：触发器（A3）——事件、日程与 webhook 只创建 Task

- 状态：Accepted（2026-11-26，按 owner /goal 推荐推进；D8 边界已定）
- 日期：2026-11-26
- 依据：`docs/architecture.md` §3.1、§5、§11、§13、§18/D8；`docs/v0.2-plan.md` §2.3；ADR-0004（数据模型与事件）、ADR-0006（权限模型）、ADR-0009（ops Agent）、ADR-0012（配对远端 runtime）；`packages/contracts/events.mbt`、`packages/contracts/task.mbt`、`packages/contracts/policy.mbt`、`services/host/`
- 关系：本 ADR 把 A3 细化到可实现；复用现有事件日志、Task/Run 状态机、Decision 与审计，不引入第二套调度器、审批队列或事件存储。日程时区与 webhook 传输边界依赖 A1.0 已验证的结论（无 TLS HTTP server；HMAC-SHA256 可用）。

## 背景

V0.1 已有可用的自动化底座：append-only 的 `events` 表与 `EventEnvelope`、Task/Run 状态机、风险策略（`evaluate_command_policy`）、Decision/审批、证据门与 `audit.recorded`。`docs/architecture.md` §18.1 已把「事件/日程/webhook 触发器」列为 V0.2 采纳项，`docs/v0.2-plan.md` §2.3 给出 A3 的范围与五条验收标准。

A3 要回答的不是「能不能定时/收 HTTP」，而是四个边界问题：

1. **第二控制面**：如果 Trigger 自带调度器、审批队列、事件存储或独立的重试状态机，就会与 host 的组织/Task/Decision/事件模型重复，冲突时没有唯一权威。
2. **重复执行**：事件会被重放（host 重启、游标补偿）、webhook 会被重试、日程会因为停机积累欠账。任何一个路径都可能把「一次触发」变成多个 Task/Run。
3. **时间语义**：时区、DST、错过窗口、抖动与恢复后的补跑，如果没有显式规则，就会在维护窗口后制造触发风暴。
4. **不可信外部输入**：webhook 可被伪造、重放、灌流量；payload 若被当作命令、路径或策略输入，就等于把外部系统变成 host 的执行面。

D8 已固定「主控是唯一控制面、远端只执行」；A1 已确认当前依赖栈没有 TLS HTTP server、但 `moonbitlang/x/crypto` 的 HMAC-SHA256 与 `moonbitlang/x/time` 的 TZif 时区可用。A3 在此前提下把触发器做成 host 内建对象：**只创建 Task（可选经既有路径排队一个 Run），不执行、不审批、不写 Workspace、不成为第二个权威**。

## 决策

### 1. 定位：host 内建对象，复用唯一控制面

- **Trigger 是 host 的领域对象**，与 Task/Decision/Run 同库同事务（`~/.monexus/monexus.db`）。触发器的配置、触发记录、游标、webhook 密钥元数据都在主控 host；不存在节点侧触发器、第二个数据库或第二套事件日志。
- **单组织**：`org_id` 固定为 `org_local`。A3 不支持跨组织、跨主控或跨 runtime 的触发器；一个 trigger 只属于当前组织与当前 host。
- **唯一执行通路**：触发器的产出只有 Task（可选再经现有 `run.create` 核心排一个 Run）。它没有自己的执行器、命令通道、文件写入、审批结论或证据门；Task/Run 之后的调度、策略、审批、证据、恢复全部走 `services/host/tasks.mbt` 与 `services/host/recovery.mbt` 的既有代码。
- **唯一事件存储**：触发器订阅既有 `events` 表，自身事件也写同一张表；`trigger_fires` 只是去重/审计账本（dedupe projection），不是事件日志，不参与状态权威。
- **唯一调度器**：日程触发由 host 内一个 dispatcher 循环驱动，它只决定「何时创建一个 Task」，不决定 Run 的 placement/并发；Run 仍由现有 `dispatch_queued` 与每机器 `max_parallel` 队列调度。
- **唯一审批队列**：触发器不能创建 Decision、不能回答 Decision、不能授予审批。触发的 Run 若被策略判定为 `ask`，仍进入现有 `decision.requested` → 收件箱流程。
- **功能开关**：配置 `trigger.enabled` 控制整个 A3 面（默认 **false**；A3.2 验收通过后由 owner 显式开启，首个版本不默认开启）。关闭时 `trigger.*` RPC 返回 `unsupported`，webhook 路由统一 401，既有 Task/Run/事件行为完全不变。

#### 1.1 对象字段

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `id` | string | 是 | `trg_<ULID>`，host 分配；字典序即时间序 |
| `org_id` | string | 是 | 固定 `org_local` |
| `name` | string | 是 | `[a-z0-9][a-z0-9_-]{0,63}`，组织内唯一；仅用于展示与查找 |
| `type` | enum | 是 | `event` / `schedule` / `webhook`；**创建后不可改**，改类型等于新建 |
| `enabled` | bool | 是 | 默认 true；false 立即停止产生新 Task |
| `expires_at` | string | 否 | RFC3339 UTC；空表示不过期。到点后不再产生新 Task |
| `target` | object | 是 | Task 模板，见 §1.2；不含 command/argv/env/secret |
| `source` | object | 是 | 按 `type` 的匹配/日程/签名配置，见 §2–§4 |
| `version` | int | 是 | 从 1 开始，每次 update +1；用于乐观并发与审计 |
| `config_hash` | string | 是 | 对 canonical 配置（不含任何秘密）做 SHA-256；用于审计与重复检测 |
| `created_by` | string | 是 | `owner` 或经认证的本地 RPC 调用者标识；A3 只有 owner 能创建 |
| `created_at` / `updated_at` | string | 是 | RFC3339 UTC |
| `state` | enum | 派生 | `active` / `disabled` / `expired`，由 `enabled` 与 `expires_at` 计算，不单独作为可写字段 |
| `expired_at` | string | 否 | 内部字段：首次观察到过期的时刻；保证 `trigger.expired` 只发一次 |
| `active_from_seq` | int64 | 是 | 该触发器开始匹配事件的全局 `events.seq`；创建/重新启用时设为当前 seq |
| `next_fire_at` | string | 否 | 仅日程触发器：下一次应触发的 UTC 时刻；持久化 |
| `last_fired_at` | string | 否 | 最近一次成功创建 Task 的时刻（投影字段） |
| `dedupe_hits` | int | 是 | 被去重丢弃的触发次数（饱和计数，用于诊断，不逐次写事件） |

#### 1.2 `target`（Task 模板）

| 字段 | 类型 | 说明 |
|---|---|---|
| `title_template` | string | 有界模板，≤200 字符；渲染结果作为 Task title |
| `goal_template` | string | 有界模板，≤4000 字符；渲染结果作为 Task goal / Agent prompt |
| `agent_id` | string | `start_run=true` 时必填（现有 `run.create` 要求 Agent Run 必须有 agent_id）；必须匹配现有 `valid_agent_id` 规则（`services/host/agents.mbt`；字母数字 `.-_`，≤64） |
| `workspace_id` | string | `start_run=true` 时必填；必须是已登记 Workspace |
| `project_id` | string | 可选；必须是已登记 Project；缺省时任务不继承 project verify |
| `verify` | array | 可选；**只能为空或 `project.verify` 的子集**（逐项精确匹配），否则拒绝 |
| `start_run` | bool | 默认 false；true 时在 Task 创建后经现有 `run.create` 核心排一个 `mode=agent` 的 Run |

**不存在的字段（刻意）**：`command`、`argv`、`env`、`shell`、`machine_id`、`worktree_id`、`policy`、`approval`、任何密钥值。触发器不能指定命令、不能选机器、不能携带秘密、不能声明审批豁免。A3 的触发器 Run 一律是 Agent Run；命令 Run 只能由 owner 显式 `run.create`。

#### 1.3 状态与版本

- **active**：`enabled=true` 且未过期；dispatcher 会处理。
- **disabled**：`enabled=false`；立即不产生新 Task，但**不取消**已创建的 Task/Run，也不删除触发记录。
- **expired**：`expires_at` 已过（或 sweep 已标记 `expired_at`）。`trigger.expired` 只发一次；owner 把 `expires_at` 更新到未来后恢复 active，并写 `trigger.updated`。
- **disable/expire 都是幂等的**：重复 disable 返回同一记录，不重复发 `trigger.disabled`；重复过期 sweep 不重复发 `trigger.expired`。
- **版本**：`trigger.update` 必须带 `expected_version`，不匹配返回 `conflict`；更新与事件在同一事务内提交，避免 UI 覆盖并发修改。
- **不物理删除**：A3 只有 disable/expire；tombstone 与 GC 留给后续版本（ADR-0004 R4）。

### 2. 事件触发

#### 2.1 订阅源：既有事件日志，不是内存环

- 事件触发读取 **`events` 表**（append-only，已有 `seq` 全局主键），通过现有 `MachineStore::load_events_since(since, limit)` 分页拉取（limit 已被夹到 1..2000）。**不使用** `HostState.ring`（容量 256，只服务 UI 重放），也不新建订阅进程或第二份事件副本。
- 现有 host 的 `seq` 由 `HostState::next_envelope` 全局单调分配并写入 `events.seq`；A3 直接把它当作游标，不新造序号体系。
- 持久化游标：`meta` 表键 `trigger.event_cursor`（int64）。dispatcher 每处理完一批、且相关 Task 已提交后，才推进游标。

#### 2.2 匹配规则（有界，不是表达式语言）

| 字段 | 规则 |
|---|---|
| `event_type` | 精确匹配（`run.failed`）或**仅允许尾缀 `.*` 的前缀匹配**（`run.*`、`machine.*`）；不接受其他通配符、正则或布尔表达式 |
| `subject_prefix` | 可选，≤64 字符，按字符串前缀匹配（现有 subject 形如 `run_...`、`machine/mch_...`、`audit/aud_...`） |
| `correlation_id` | 可选，精确匹配；用于把触发限定到某个 Task/host 关联链 |
| `ignore_self` | 默认 true；跳过本触发器创建出来的 Task/Run 所产生的事件（见 §2.4） |

**事件类型黑名单**（无论配置如何都不匹配，避免噪音与自放大）：`host.heartbeat`、`audit.recorded`、`trigger.*`、`run.progress`、`run.heartbeat`、`agent.session.output`、`agent.session.updated`。这些是高容量或元事件，进入触发器只会制造无意义 Task 与日志风暴。新事件类型默认可以精确匹配；若未来需要前缀匹配高容量事件，必须另写 ADR 加白名单。

#### 2.3 去重与「恰好一次 Task」

- 去重键：**`(trigger_id, event_id)`**，写入 `trigger_fires` 表的 `UNIQUE(trigger_id, fire_key)`，其中事件触发的 `fire_key = "event:<event_id>"`。
- 创建 Task 的同一个 SQLite 事务里：插入 `trigger_fires` 行 → 写 `task.created` 事件与投影 → 写 `trigger.fired` 事件。若唯一键冲突，事务不创建第二个 Task，`dedupe_hits += 1`，不写重复事件。
- 事件本身的 `idempotency_key` 唯一约束（`events.idempotency_key`）仍生效；触发产生的 Task 事件使用确定性键 `trigger/<trigger_id>/<fire_key>/task`，重复 append 会被数据库直接丢弃，作为第二道保险。
- **语义是 at-least-once 扫描 + 幂等提交 = 恰好一次 Task**：dispatcher 可以重复看到同一事件，但 Task 只会存在一个。

#### 2.4 自触发与级联上限

- 触发器创建的 Task 在 `origin` 中记录 `trigger_id`、`fire_key`、`root_trigger_id`、`depth`。事件的 payload 携带同一 `origin`。
- `ignore_self=true`（默认）跳过 `origin.trigger_id == 自己` 的事件，避免「自己创建 Task → Task 事件 → 再创建 Task」的紧循环。
- **级联深度上限**：`depth > 8` 时不再创建 Task，写 `trigger.rejected`（`reason=cascade_depth`）。这覆盖 A、B 两个触发器互相触发的间接循环；深度与根触发器随 Task 传递，不需要全局图分析。
- 即便有深度上限，仍叠加 §6 的每触发器与全局速率限制。

#### 2.5 host 重启与历史缺口

| 场景 | 行为 |
|---|---|
| host 在 Task 提交后、游标推进前崩溃 | 重启后重放该事件；`(trigger_id, event_id)` 已存在 → 不重复创建 Task |
| host 在游标推进后崩溃 | 正常从新游标继续；已提交的 Task 不受影响 |
| 触发器在 disabled 期间产生的事件 | 不补跑：重新启用时把 `active_from_seq` 设为当前 seq，只匹配之后的事件 |
| 事件保留期已越过游标（history gap） | 不静默补历史：对每个受影响的 event 触发器写一条 `trigger.rejected`（`reason=history_gap`，含 `cursor`、`oldest_seq`），把游标推进到当前最大 seq，然后继续 |
| 触发器创建前的事件 | 不匹配（`active_from_seq` 是创建时的 seq） |
| 数据库不可读 | dispatcher 退避重试并写可读日志，不阻塞事件写入与既有 Task/Run；恢复后从旧游标继续，靠去重收敛 |

dispatcher 是独立 host 任务（与 `heartbeat_loop` 同级），不挂在 `append_event` 路径上：事件写入永不被触发器拖慢。每批最多处理 500 个事件，批间让出；落后时按固定小间隔追赶，不无限占用 mutex。

### 3. 日程触发

#### 3.1 最小语法（不用通用 cron）

| `kind` | 字段 | 示例 | 语义 |
|---|---|---|---|
| `every` | `interval_minutes`（1..1440） | `{"kind":"every","interval_minutes":15}` | 从创建时刻的整分锚点开始，每 N 分钟一个 slot；`timezone` 必须省略或为 `UTC`，因为纯间隔不涉本地时刻 |
| `daily` | `at`（`HH:MM`） | `{"kind":"daily","at":"09:00"}` | 每天该本地时刻 |
| `weekly` | `weekday`（ISO 1=周一..7=周日）+ `at` | `{"kind":"weekly","weekday":1,"at":"08:30"}` | 每周指定日期的该时刻 |

- **不接受** cron 字符串、秒级字段、月份/年份字段、多 weekday 列表、`/step` 或 `L`/`W` 等扩展；含未知字段或非法值直接 `invalid`。
- `every` 的锚点 `anchor_at` 在创建时固定（UTC 毫秒，按分钟截断），`scheduled_for = anchor_at + n * interval`。锚点持久化，重启不漂移。
- 日程计算是 `packages/contracts` 中的纯函数（输入 `now_ms` 与配置，输出 slot/下一次时刻），可注入时钟做单元测试，不依赖 `sleep` 实测。

#### 3.2 时区

| `timezone` | 行为 |
|---|---|
| `UTC` | 显式 UTC，默认值 |
| `+HH:MM` / `-HH:MM` | 固定偏移（范围 −12:00..+14:00），不涉 DST |
| `Area/City`（IANA） | 从系统 tzdata 读取 TZif，使用 `@time.Zone::from_tzif`（`moonbitlang/x/time` 已提供；A3.0 验证 native 构建） |
| `local` | 创建时把宿主机的本地时区**解析为具体 IANA 名并固化**到配置中；之后机器时区改变不会静默移动日程，需要显式 update |

- tzdata 搜索路径：`$MONEXUS_TZDATA_DIR`，否则 `/usr/share/zoneinfo`（macOS 同一路径）；读不到、名字非法或 TZif 解析失败时**拒绝创建**（`unsupported`，可读原因），**不静默当作 UTC**。
- DST 规则（显式且可测试）：不存在的本地时刻（春季跳变）取跳变后的第一个有效时刻；重复的本地时刻（秋季回拨）取较早的那一次（fold=0）。`every` 直接按 UTC 毫秒推进，不受 DST 影响。
- 持久化：保存原始 `timezone` 字符串与 `resolved_tz`（`local` 时区固化的 IANA 名 / 固定偏移）；`next_fire_at` 一律存 UTC。

#### 3.3 `next_fire_at`、slot 与抢占

- 每个日程触发器持久化 `next_fire_at`（UTC）。dispatcher 每 **1 秒**扫描一次 `next_fire_at <= now` 的 active 日程触发器，最多 100 个/次。
- **抢占事务**：在同一事务内
  1. 以 `(id, expected_next_fire_at)` 为条件更新 `next_fire_at` 到下一个 slot（CAS）；
  2. 插入 `trigger_fires`，`fire_key = "slot:<scheduled_for_ms>"`，唯一约束；
  3. 创建 Task、写 `trigger.fired`。
  条件更新失败或唯一键冲突都表示另一个 tick/实例已处理，**不创建第二个 Task**。
- **slot 键稳定**：去重键用 `scheduled_for`（slot 的原始 UTC 毫秒），不是实际执行时刻；抖动或延迟不改变去重身份。
- **抖动**：`jitter_s` 0..300，默认 0；实际执行延迟为 `scheduled_for + deterministic_jitter(trigger_id, scheduled_for)`（由触发器 id 与 slot 派生，重启后一致），只影响延迟，不影响 slot 键。抖动用于错开同一时刻的大量日程，不用于掩盖欠账。

#### 3.4 错过窗口与停机

| `missed` | 行为 |
|---|---|
| `skip`（默认） | 停机/卡顿跨过任意多个 slot 时，只把 `next_fire_at` 推进到 `now` 之后的第一个 slot；写 `trigger.rejected`（`reason=missed_window`，含 `missed_count`），**不创建 Task** |
| `coalesce_once` | 只为**最近一个**已错过的 slot 创建一次 Task（`coalesced=true`，`scheduled_for` 为该 slot），然后推进到下一个未来 slot；无论错过多少个，**最多补一次** |

- 硬约束：**任何一次 missed 处理最多为最近一个 slot 补跑一次**，不会为每个错过的 slot 各建一个 Task；`scheduled_for` 早于去重账本保留期（90 天）的 slot 一律按 `skip` 处理，绝不回放。
- 停机恢复流程：host 启动 → `reconcile_trigger_projection()` 重建触发器与 `next_fire_at` → 对每个日程触发器应用一次 missed 策略 → 再启动 1s dispatcher。没有「逐个 slot 补跑」的路径。
- 时钟回拨：dispatcher 持久化 `meta.trigger.last_tick_ms`（每个 tick 更新）；若本次 `now` 比上次 tick 早 5 分钟以上，判定为墙钟回拨：写 `trigger.rejected`（`reason=clock_skew`），把 `next_fire_at` 夹到 `now + jitter`，跳过本次 tick，不按回拨后的时间重复触发。

### 4. Webhook 触发

#### 4.1 端点与传输边界

- 端点：**`POST /hooks/<trigger_id>`**，挂在 host 现有的 loopback HTTP 服务上（`127.0.0.1:<random>`）。不新开监听端口、不新增服务器、不新建第二个 HTTP 栈。
- 现有 `handle_connection` 只认 `/ws`：非 `/ws` 直接 404，然后才对 `/ws` 做 Bearer 校验（`services/host/handlers.mbt`）。A3.1 必须在 404 之前**按路径分流**：`/ws` 走现有 Bearer，`/hooks/*` 走 HMAC，其余路径 404。Bearer token 不能用于 webhook，HMAC 头也不能用于 `/ws`。
- **默认只绑定 loopback**（现有 `@socket.Addr::parse("127.0.0.1:...")` 不变），A3 不增加对外 bind 选项。
- **外部暴露必须由 owner 自建 TLS 反向代理**（nginx/caddy 等）终结 TLS 后转发到 `127.0.0.1`。当前依赖 `moonbitlang/async@0.22.7` 的 `@http.Server` 没有 TLS 变体（A1.0 已在 `spikes/a1-pairing` 验证），因此 A3 **不宣称** host 能直接提供 HTTPS，也不提供明文公网监听。代理要求：不重写 body、保持 `Content-Length`、不缓存、不透传未认证的 `X-Forwarded-For` 作为身份依据（A3 不信任任何转发头）。
- 方法只允许 `POST`；其他方法 405。`Content-Type` 必须是 `application/json`。不响应 CORS 预检（webhook 是服务器间调用，不是浏览器 API）。

#### 4.2 签名与请求头

| 头 | 必填 | 说明 |
|---|---|---|
| `X-Monexus-Key-Id` | 是 | 每来源一个 `whk_<ULID>`；限定到一个 trigger |
| `X-Monexus-Timestamp` | 是 | Unix 毫秒（也接受 RFC3339 UTC）；新鲜度窗口默认 ±300s |
| `X-Monexus-Nonce` | 是 | 每次投递随机，`[A-Za-z0-9_-]{16,64}`；重试必须复用 |
| `X-Monexus-Delivery-Id` | 否 | 稳定投递 id（`[A-Za-z0-9._-]{1,64}`）；发送方在新鲜度窗口内换时间戳/新 nonce 重试时用它去重（窗口外的请求会先被时间戳拒绝） |
| `X-Monexus-Signature` | 是 | `v1=<hex>`，HMAC-SHA256 |

**待签字符串**（逐字节，UTF-8；body 取原始字节，不做 JSON 规范化）：

```text
monexus-webhook-v1\n
<key_id>\n
<trigger_id>\n
<timestamp>\n
<nonce>\n
<raw_body>
```

- MAC 用 `moonbitlang/x/crypto` 的 HMAC-SHA256（A1.0 已验证可用；spike 的 `hmac_sha256_text` 是参考实现），密钥为对应来源的 256 位 secret。
- 比较使用**常时比较**（复用 A1.0 的 `constant_time_hex_eq` 模式并在生产代码重写 + 单测）；长度不符直接拒绝，不做逐字符提前返回。
- 待签串绑定 `key_id` 与 `trigger_id`：一个来源的签名不能平移到另一个触发器，也不能把不同来源的密钥混用。
- 失败一律返回统一的 **401**（未知触发器、禁用、未知/吊销 key、坏签名、过期、重放都同形），不泄漏哪一步失败；内部写 `trigger.rejected`（`reason` 细分）供审计。

#### 4.3 密钥与来源 allowlist

- 密钥对象 `whk_<ULID>` 绑定**一个** trigger（`webhook_keys(key_id PRIMARY KEY, trigger_id, name, secret_path, enabled, created_at, revoked_at)`）；一个 trigger 的 allowlist 就是它启用的 key 集合，天然实现「每来源一 key」。
- secret **不写数据库、不进事件、不进日志**：由 `trigger.source.add` 生成 256 位随机值，写入 `~/.monexus/secrets/webhook/<key_id>.key`（目录 0700、文件 0600），只向 owner 的本地认证 RPC 返回一次；之后任何 `list/get` 只返回 `key_id` 与状态。审计 detail 经 `redact_secrets`。
- 轮换：先 `trigger.source.add` 新 key → `trigger.update` allowlist 加入新 key → `trigger.source.revoke` 旧 key。吊销立即生效（已签名的重放也拒绝），但已创建的 Task 不受影响。
- **来源 allowlist** 的权威是 key allowlist。可选 `allowed_cidrs` 只对**直连**连接生效（默认即 127.0.0.1/32）；在反向代理后面所有直连地址都是 loopback，IP 过滤无意义，必须在代理层完成。A3 不读取、不信任 `X-Forwarded-For`。

#### 4.4 新鲜度、重放与重复投递

- 时间戳窗口默认 ±300s（可配上限 ±900s）；超出即 401。窗口用于限制被截获请求的重放时间，不替代 nonce 缓存。
- **nonce 缓存**：表 `webhook_nonces(key_id, nonce, body_sha256, first_seen_ms, expires_at)`，`UNIQUE(key_id, nonce)`；TTL = 新鲜度窗口 + 120s，周期清理。同 key 同 nonce：
  - body hash 相同 → 视为**同一投递的重试**，返回 202 + 既有 `task_id`（`duplicate=true`），不创建第二个 Task；
  - body hash 不同 → 401（nonce 复用/篡改），写 `trigger.rejected`（`reason=nonce_reuse`）。
- **投递去重键**：若带 `X-Monexus-Delivery-Id`，`fire_key = "delivery:<id>"`；否则 `fire_key = "nonce:<nonce>"`。`(trigger_id, fire_key)` 唯一，保证发送方在窗口内换新时间戳/新 nonce 重试时也不会产生第二个 Task。
- nonce 缓存持久化在 SQLite，host 重启后仍能拒绝窗口内的重放；TTL 到期的 nonce 被清理，超出窗口的请求本来就会被时间戳拒绝。

#### 4.5 体积、速率与响应

| 限制 | 默认 | 上限 |
|---|---|---|
| body 大小 | 64 KiB | 256 KiB（`Content-Length` 与实际读取双重检查，超限 413） |
| JSON 形状 | 顶层 object，标量值或 ≤3 层嵌套；键 ≤64 字符 | 超出 400 |
| 每 trigger 请求速率 | 60/min，burst 20 | 600/min |
| 每 key 请求速率 | 120/min | 1200/min |
| 全局 webhook 速率 | 300/min | 3000/min |
| 单 trigger 并发处理 | 8 | — |
| 请求读取超时 | 5s | 10s |

- 速率用进程内 token bucket（每 trigger / 每 key / 全局），超限 429 + `Retry-After`，并写**合并后**的 `trigger.rejected`（`reason=rate_limited`，每分钟最多一条，带 `suppressed_count`），避免拒绝本身制造事件风暴。重启会重置 bucket，这是有意的残余（见 §9）。
- 响应：成功 **202** `{"accepted":true,"trigger_id":"...","task_id":"...","duplicate":false}`；重复投递 202 + 既有 task_id；认证/时间/重放失败 401；格式错误 400；过大 413；限流 429；禁用/过期触发器同样 401，不泄漏状态。响应不回显 body，不含内部路径或配置。
- 限流、认证、解析都发生在**创建 Task 之前**；任何拒绝都不产生 Task/Run。

#### 4.6 payload 是不可信数据

- body 只按严格 JSON 解析；未知字段允许但总大小受限；不执行、不反序列化为命令/路径/环境变量/argv。
- 模板替换只发生在 `title_template` / `goal_template`，且只允许配置里声明的字段（`payload_fields[]`，最多 8 个点路径、深度 ≤2、单值 ≤512 字符）；单次替换，不递归、不求值、不做 shell 插值。
- payload **不能**指定 `command`、`agent_id`、`workspace_id`、`project_id`、`verify`、`machine_id`、审批选项或策略字段；这些只能来自触发器配置。payload 不能把 `start_run` 从 false 改成 true。
- 渲染结果按不可信文本处理：有界截断 + `redact_secrets` 后再持久化；原文 body 不落库，只在拒绝审计里保留长度、body hash 与 reason。
- Agent 的 goal 来自模板 + 已声明字段，仍可能包含提示注入内容；防线不是「过滤文本」，而是：模板固定、payload 不能改工具/权限/审批、Agent 的所有工具调用继续受 ACP 权限与现有 Decision 约束（§5、§9）。

### 5. Task 创建与审批：只能创建 Task，不能授权

- 触发器只做两件事：**创建 Task**；`start_run=true` 时**经现有 `run.create` 核心排一个 `mode=agent` 的 Run**。它不能写文件、不能执行命令、不能创建或回答 Decision、不能修改策略、不能授予自己审批。
- 复用而不是复制：A3.0 把 `task.create` 与 `run.create` 的校验/写入逻辑抽成 host 内部核心函数（`create_task_core` / `create_run_core`），RPC 与触发器调用同一份代码。这避免出现「触发器专用 Task 路径」这种第二状态机。
- **Task 状态**：`start_run=false` 时创建 `planned`；`start_run=true` 时创建 `ready` 并立即排 Run。触发器只能在 `planned` 与 `ready` 之间选择初始状态（由 `start_run` 决定），不能设置其他状态，也不能绕过 `ready → running` 的状态机。
- **verify 不引入新命令**：现有 `run_verification` 直接执行 `task.verify`，不再过一次策略；因此触发器模板的 `verify[]` 只允许为空或 `project.verify` 的**逐项子集**，且没有 `project_id` 时只能为空。触发器不能借 verify 注入新命令。
- **命令 Run 不可用**：`target` 没有 `command`/`argv` 字段；触发器不会创建命令 Run。写操作只能发生在 Agent Run 内，并照常经过风险策略/ACP permission → Decision（§11、ADR-0006）。
- **审批不可绕过**：若 Run 被判定 `ask`，它进入现有 `waiting_approval` 与 `decision.requested`；触发器不会收到或回答该 Decision。触发器禁用/过期不改变已存在 Run 的审批状态。
- **幂等排 Run**：`run.create` 的 `idempotency_key = "trigger:<trigger_id>:<fire_key>"`，复用 `find_run_by_idempotency`；Task 已提交但 Run 未提交时重试，得到同一个 Run，不重复执行。
- **秘密不进入配置**：`target`/`source` 没有秘密字段；webhook secret 只以 `key_id` 引用，值在 0600 文件里（§4.3）。模板渲染结果在落库前 redaction；事件/日志/Decision detail 沿用现有 redaction 规则。

### 6. 限额、审计与停用

#### 6.1 限额

| 限额 | 默认 | 说明 |
|---|---|---|
| 组织内 active triggers | 128 | 硬上限 512；创建时检查，超限 `conflict` |
| 每事件触发器触发速率 | 30/min，burst 10 | 超限 `trigger.rejected`（`rate_limited`），不建 Task |
| 每 webhook 触发器 | 60/min，burst 20 | 见 §4.5 |
| 全局触发速率 | 300 fires/min | 保护 Task/Run 队列与事件表 |
| 事件扫描批大小 | 500 事件/批 | dispatcher 落后时不无限占用 mutex |
| 级联深度 | 8 | §2.4 |
| 去重账本保留 | 90 天 | 与状态事件保留期一致；每日清理 |
| nonce TTL | 新鲜度窗口 + 120s | §4.4 |
| 模板渲染 | title ≤200 / goal ≤4000 字符 | 超出截断并审计 |

去重窗口与保留期一致：只要事件还能被游标看到，它的 `(trigger_id, event_id)` 就还在账本里；保留期之外不再补历史（§2.5）。日程 slot 去重行同样保留 90 天，早于保留期的 slot 不补跑。

#### 6.2 事件与审计

所有触发器事件进现有 `events` 表，subject 为 `trigger/<trg_id>`，payload 经 redaction：

| 事件 | 触发时机 | 关键字段 |
|---|---|---|
| `trigger.created` | 创建成功 | `trigger_id`、`type`、`name`、`config_hash`、`created_by`、`version` |
| `trigger.updated` | 更新成功（含重新启用） | `trigger_id`、`version`、`changed[]`、`created_by`、`config_hash` |
| `trigger.disabled` | 显式 disable | `trigger_id`、`actor`、`reason` |
| `trigger.expired` | 首次观察到过期（sweep 或触发前检查） | `trigger_id`、`expires_at` |
| `trigger.fired` | **已创建 Task** | `trigger_id`、`source`（`event`/`schedule`/`webhook`/`manual`）、`fire_key`、`event_id`?、`scheduled_for`?、`key_id`?、`task_id`、`run_id`?、`coalesced`、`depth` |
| `trigger.rejected` | **未创建 Task** | `trigger_id`、`source`、`reason`、`detail`（redacted）、`key_id`?、`event_id`?、`delivery_id`?、`suppressed_count`? |

`reason` 枚举（稳定，便于查询）：`disabled`、`expired`、`rate_limited`、`cascade_depth`、`missed_window`、`history_gap`、`clock_skew`、`invalid_target`、`policy_denied`、`invalid_signature`、`unknown_key`、`stale_timestamp`、`nonce_reuse`、`source_denied`、`payload_too_large`、`unsupported`。

- 去重丢弃（`dedupe_hits`）**不逐次发事件**：重放/重启时的重复是预期行为，逐次写事件会制造二次风暴；只更新饱和计数并在 `trigger.get` 中暴露。
- 审计不新增存储：触发器生命周期由上述事件承担；策略判定仍写既有 `audit.recorded`（`policy.verdict` / `policy.deny`），Run/Decision 审计不变。
- payload 不含：webhook body 原文、密钥、完整命令/日志、文件路径（路径只出现在既有 Run/Workspace 事件里）。

#### 6.3 停用与过期语义

- **立即生效**：disable 或过期后，dispatcher 在创建 Task 之前检查 `enabled`/`expires_at`；**fire 事务内会再次读取这两个字段**，若在提交前被停用/过期则不写 Task（webhook 返回 401，日程/事件写 `trigger.rejected`）。检查与 Task 写入同一事务，停用不存在「已经检查过所以放行」的窗口。
- **不取消既有工作**：已创建的 Task/Run 继续按现有状态机执行；disable 不是 `task.cancel`，也不回滚已发生的触发。
- **幂等**：重复 disable/expire 返回同一状态、不重复发事件；`trigger.update` 恢复 active 需显式把 `enabled=true`（若已过期还需把 `expires_at` 改到未来）。
- **不删除历史**：`trigger_fires` 与事件保留供审计；A3 不做物理删除或级联删除。

### 7. RPC/API

新增 `packages/contracts/trigger.mbt`（方法使用新的 `trigger.*` 命名空间；全部要求 `client_request_id`，与现有 RPC 一样幂等，且只有本地认证 WS 的 owner 能调用）：

| 方法 | 参数 | 结果 | 主要错误 |
|---|---|---|---|
| `trigger.create` | `name`、`type`、`target`、`source`、`enabled?`、`expires_at?` | `{trigger}` | `invalid`、`conflict`（重名/超限）、`unsupported`（tz/类型）、`not_found`（引用的 workspace/project 不存在） |
| `trigger.list` | `state?`、`type?`、`limit?` | `{triggers:[...]}` | `invalid` |
| `trigger.get` | `trigger_id` | `{trigger, recent_fires?}`（不含 secret） | `not_found` |
| `trigger.update` | `trigger_id`、`expected_version`、可改字段（`name`、`target`、`source`、`enabled`、`expires_at`） | `{trigger}` | `invalid`、`not_found`、`conflict`（版本/重名）、`unsupported` |
| `trigger.disable` | `trigger_id` | `{trigger}`（幂等） | `not_found` |
| `trigger.fire` | `trigger_id`、`note?` | `{task_id, run_id?, duplicate}` | `not_found`、`conflict`（disabled/expired）、`rate_limited` |
| `trigger.source.add` | `trigger_id`、`name` | `{key_id, secret}`（secret 只返回一次） | `not_found`、`conflict`（密钥数上限） |
| `trigger.source.revoke` | `key_id` | `{key_id, revoked:true}`（幂等） | `not_found` |

- `trigger.fire` 是 owner 的手动测试通道：`source=manual`，仍然经过 §6.1 限额与 §5 的全部策略/审批，**不是**绕过策略的「立即执行」。
- 不提供 `trigger.exec`、`trigger.script`、`trigger.runCommand` 或任何通用脚本方法；没有「payload → argv」的 API 形状。
- 错误码沿用 `ERR_HOST`（-32000）+ `data.kind`（`invalid/not_found/conflict/unsupported/rate_limited/unauthorized`），与现有 `workspace_error` 风格一致；错误 message 与 detail 均 redaction 后再返回。
- 触发器配置只在主控 host；ADR-0012 的 `runtime.*` 命名空间不新增 `runtime.trigger.*`，节点不持有触发器状态。

### 8. 实施顺序与 v0.2 §2.3 验收映射

| 阶段 | 内容 | 对应 `docs/v0.2-plan.md` §2.3 |
|---|---|---|
| **A3.0 核心** | 契约（`trigger.mbt`）、迁移（`triggers` / `trigger_fires` / `migrate` 增量）、record/投影/reconcile、事件触发器、游标、去重事务、`trigger.create/list/get/update/disable`、审计事件、功能开关（默认 false）、纯函数单测 | 验收 1（可创建/停用/过期；事件只产生一次 Task；幂等键与去重窗口）、验收 5 的一部分（审计含来源/幂等键/Task 关联；停用后不再产生新 Run） |
| **A3.1 日程 + webhook** | 日程计算与时区（TZif）、`next_fire_at` 抢占、missed/jitter、1s dispatcher、`/hooks/<trigger_id>` 路由、HMAC/时间戳/nonce/allowlist/体积/限流、密钥文件、`trigger.source.*`、反向代理文档 | 验收 2（时区/错过窗口策略）、验收 3（签名/allowlist/重放/过期/限流有界） |
| **A3.2 集成与验收** | 触发器 Task → Agent Run → ACP permission → Decision 的完整链路；重启重放、webhook 重试、日程停机、风暴与级联测试；`scripts/trigger_smoke.sh`；agent/SSH smoke 与 acceptance 回归 | 验收 4（写操作仍走 §11 审批；触发器不能绕过 Decision）、验收 5（完整审计与停用语义）、回归 |

- 每个阶段独立可停用：`trigger.enabled=false` 时行为与不含 A3 的 host 完全一致；A3.2 验收通过后由 owner 显式开启。
- A3.0/A3.1 不依赖 A1 runtime；A3 的 Run 仍是现有本地/SSH Task/Run 路径。A1 的远端 runtime 上线后，触发器无需改动即可复用（Run 的 placement 仍由现有调度器决定）。

### 9. 威胁与残余风险

| 威胁 | 缓解 | 残余风险 |
|---|---|---|
| **伪造 webhook** | HMAC-SHA256 + 每来源 key + 常时比较；key 只存在 0600 文件；统一 401 不泄漏细节 | 宿主机同用户进程可读 0600 文件与 host token，本地同用户攻陷不在 A3 威胁模型内；反向代理配置错误（明文外露）需 owner 按文档自检 |
| **重放 webhook** | 时间戳窗口 + nonce 缓存（持久化）+ delivery id 去重 + body hash 校验 | 窗口内被截获且 nonce/body 完全相同的重放会得到 202 与既有 task_id（幂等结果，不产生新 Task）；这是可接受的可用性折中 |
| **webhook 灌流量 / 触发器垃圾 Task** | 每 trigger/key/全局 token bucket、body 上限、并发上限、`trigger.enabled` 总开关、拒绝审计合并 | 合法来源的洪泛仍能消耗 Task 队列；全局 300/min 只是有界，不是零成本 |
| **日程风暴 / 停机补跑** | 默认 `skip`；`coalesce_once` 最多补一次；slot 唯一键；确定性抖动；1s 单 dispatcher；时钟回拨保护 | 跨 DST 的边界时刻按固定规则处理，但极端 tzdata/时钟跳变仍需运维核对；`every` 以 UTC 计不受 DST 影响 |
| **事件重放导致重复 Task** | `(trigger_id, event_id)` 唯一 + Task/事件同一事务 + 游标后推 + 确定性事件幂等键 | 重放仍会消耗 dispatcher 工作与一次唯一键冲突；`history_gap` 时无法补历史，只能记录拒绝事件 |
| **触发器级联循环** | `ignore_self` + 级联深度 8 + 速率限制 | 两个触发器在深度内仍可能来回创建有限次 Task；需要 owner 审计 `trigger.fired` 发现异常配置 |
| **秘密进入 payload/日志** | 配置无秘密字段；secret refs；0600 文件；渲染后 redaction；不持久化 webhook 原文 | 外部发送方可能在 body 里自带密钥文本，渲染进 goal 时会被 redaction 兜底但可能过度脱敏；不在 A3 承诺 DLP |
| **审批绕过** | 触发器无 command/argv/审批字段；命令 Run 不可用；verify 只允许 project 子集；Agent 工具调用仍走 ACP permission/Decision | 外部 payload 可对 Agent 形成提示注入，诱导其在既有权限内做不期望的操作；防线是模板固定 + 权限/审批不变，残余属 Agent 治理范畴 |
| **触发器被 Agent 滥用** | A3 只有 owner 的本地认证 RPC 能创建/更新；Agent 工具面无 `trigger.*`；`ops` 若未来需要，必须经 Decision | 后续若开放 Agent 创建触发器，需要新的 ADR 明确审批与配额；A3 不做 |
| **事件表膨胀** | 只订阅状态事件、黑名单高容量事件、批大小上限、去重账本 90 天、nonce 定期清理 | 事件保留策略本身仍沿用现有 90 天设计；A3 不改变全局事件 GC |

## 契约与数据模型增量

| 位置 | 增量 |
|---|---|
| `packages/contracts/trigger.mbt`（新增） | `TRIGGER_TYPE_EVENT/SCHEDULE/WEBHOOK`；`TRIGGER_STATE_*`；`TRIGGER_SOURCE_*`；`TRIGGER_REJECT_*`；方法常量 `trigger.create/list/get/update/disable/fire/source.add/source.revoke`；事件常量 `trigger.created/updated/disabled/expired/fired/rejected`；`TriggerRecord`、`TriggerTarget`、`TriggerSource`、`TriggerFire`、`WebhookKeyRecord`；参数/结果 helpers；纯函数 `schedule_next_slot`、`schedule_is_due`、`render_template`、`match_event_trigger` 及单测 |
| `packages/contracts/task.mbt` | `TaskRecord` 增加可选 `origin`（`{kind:"trigger", trigger_id, fire_key, root_trigger_id, depth, source}`）；旧记录缺省为空；`task_from_json` 忽略未知字段保持兼容 |
| `packages/contracts/events.mbt` | 不改信封；新增事件类型只在 `trigger.mbt` 注册（架构附录 A：新增事件必须注册 schema，旧事件只增字段） |
| `packages/machines/trigger_store.mbt`（新增） | 迁移 `triggers`、`trigger_fires`、`webhook_keys`、`webhook_nonces`；`record_trigger_event`、`record_trigger_task_event`（同一事务：fire 行 + Task 事件/投影 + `trigger.fired`）、`get/list/update_trigger`、`claim_schedule_slot`、`event_cursor_get/set`、`nonce_get/put/prune`、`reconcile_trigger_projection` |
| `services/host/triggers.mbt`（新增） | RPC handlers；事件 dispatcher loop；日程 loop；`/hooks/<trigger_id>` 处理；匹配/模板/限额；启动 reconcile；不在持有 `HostState.mutex` 时做阻塞 I/O |
| `services/host/handlers.mbt` | 注册 8 个 `trigger.*` 方法；`handle_connection` 先按路径分流（`/ws` Bearer、`/hooks/*` HMAC、其他 404）；webhook body 有界读取 |
| `services/host/serve.mbt` | 启动时 `reconcile_trigger_projection()`；与 `heartbeat_loop` 同级 spawn `trigger_loop`；`trigger.enabled` 开关；TLS 断言在 doctor/文档中保持「仅 loopback」 |
| `services/host/tasks.mbt` | 抽出 `create_task_core` / `create_run_core`，RPC 与触发器共用；不改现有策略/证据/审批顺序 |
| 依赖 | `services/host/moon.mod` + `moon.pkg` 增加 `moonbitlang/x@0.5.6`（`crypto`、`time`）；CI 只用 registry 版本，符合 §15 约束；A3.0 先验证 native 构建与 TZif 读取 |
| 脚本/CI | 新增 `scripts/trigger_smoke.sh`（事件/日程/webhook/重放/停用/审批链路），CI 的 smoke 列表加入该项；`acceptance.sh` 增加一次触发器端到端行 |
| 文档 | `docs/usage.md` / `docs/troubleshooting.md` 增加触发器配置、webhook 反向代理与 tzdata 诊断；本文 ADR 为权威 |

**实现前必须解决的契约缺口**（A3.0/A3.1 一并处理）：

1. `TaskRecord` 目前没有 `origin`/`created_by`，需要增量迁移；投影重放必须能容忍旧 payload 缺该字段。
2. `events` 表目前没有触发器专用的 `trigger.event_cursor` 元数据访问；现有 `meta` 表只有 `last_seq` 的专用读写（`read_meta_raw`，无通用 setter），A3.0 需增加通用的 `meta_get/meta_set`（或等价访问器）。
3. `run.create` / `task.create` 的校验逻辑嵌在 RPC handler 内；A3.0 抽核心函数，确保触发器和 owner 走同一路径，避免行为分叉。
4. `handle_connection` 目前对非 `/ws` 一律 404，且 Bearer 校验只覆盖 `/ws`；A3.1 要在 404 之前加入 `/hooks/*` 分支，并确保两条认证路径互不通用。
5. `run_verification` 直接执行 verify，不经过 `evaluate_command_policy`；因此触发器 verify 只允许 project 子集（§5），不新增命令面。
6. `@http.Server` 无 TLS 变体；A3 的外部暴露只能是 owner 反向代理，host 侧不新增 bind/明文选项。
7. webhook 的 HMAC/常时比较/随机 secret 需要在生产代码重写（spike 的 `hmac_sha256_text`、`constant_time_hex_eq` 只作参考），并用单测覆盖签名绑定与重放。
8. `trigger.enabled` 关闭时 `trigger.*` 必须返回 `unsupported` 而不是 `method not found`，以便 UI 区分「未启用」与「版本不支持」。

## 备选方案

- **独立触发器服务/第二个调度器**：拒绝。会复制事件订阅、重试与审计状态，冲突时无唯一权威；A3 用 host 内 dispatcher，复用同一数据库与状态机。
- **通用 cron 解析器**：拒绝。解析器、时区与 DST 组合是不可信输入与测试负担；A3 只做 `every/daily/weekly` 三种可穷举验证的语法。
- **把所有错过 slot 逐个补跑**：拒绝。停机后会产生触发风暴与重复工作；A3 默认 skip，最多 coalesce 一次。
- **webhook 直接开放公网/明文 HTTP**：拒绝。当前栈没有 TLS server，A3 明确要求 owner 反向代理终结 TLS，host 只绑 loopback。
- **在触发器里内嵌命令/脚本**：拒绝。等价于任意脚本执行，且绕过策略/审批；A3 只有 Agent Run，命令只能由 owner 显式发起。
- **把 Secret 存进 trigger 配置或数据库**：拒绝。密钥走 0600 文件 + `key_id` 引用；事件/日志/DB 不出现明文。
- **让 Agent 直接创建触发器**：A3 拒绝。自动化创建是权限放大器，后续若需要必须另写 ADR 并走审批与配额。
- **把 payload 当作 Agent 指令或 argv**：拒绝。payload 只能填充声明的模板字段，不能改工具/权限/目标。
- **用内存环做事件订阅**：拒绝。容量 256 且重启丢失；A3 用持久化 `events.seq` 游标。
- **触发器本地缓存/节点侧状态**：拒绝。违反主控唯一权威与 ADR-0012；节点不持有触发器。

## 非目标

- 可视化工作流编辑器、拖拽节点、多步编排与条件分支。
- 任意 cron/表达式语言、跨触发器变量、循环/重试图。
- 跨组织、跨主控、跨 runtime 的触发器或共享触发器。
- 触发器直接执行命令/脚本、写 Workspace、改策略、批准 Decision。
- 触发器创建命令 Run（A3 只创建 Agent Run）；机器选择与 worktree 由既有调度器决定。
- 公网明文监听、host 内置 TLS、mTLS、webhook 转发代理。
- Agent 创建/修改触发器，触发器市场/模板市场。
- 外部对象存储、第二个事件存储或触发器专用审批队列。
- 触发器级联重试/自动恢复；失败只记录 `trigger.rejected`，不自动重试。

## 验证计划

A3 的验收按 `docs/v0.2-plan.md` §2.3，测试可离线重复运行：

1. **事件触发恰好一次**：写入匹配事件 → 一个 Task；重复投递同一 `event_id`、host 重启后重放、游标回退 → 仍只有一个 Task；`trigger.fired` 含 `event_id`/`task_id`；`dedupe_hits` 增加；不产生第二次 `task.created`。
2. **事件匹配与黑名单**：精确/前缀匹配、subject/correlation 过滤、`ignore_self`、级联深度、`host.heartbeat`/`run.progress`/`agent.session.output`/`agent.session.updated` 不匹配；非法通配符/正则被拒绝。
3. **日程**：`every`/`daily`/`weekly` 的下一 slot 与 DST 边界（不存在/重复本地时刻）用固定时钟单测；UTC/固定偏移/IANA/`local` 解析；tzdata 缺失时 `unsupported`；停机后 `skip` 不补跑、`coalesce_once` 最多补一次；slot 唯一键在并发 tick/重启下不重复；抖动不影响 slot 键。
4. **webhook 安全**：正确签名 202 + Task；坏签名/未知 key/吊销 key/过期时间戳/窗口外重放/nonce 复用（不同 body）401；同 nonce 同 body 重试 202 + 同一 task_id；窗口内带 delivery id 的重试去重；body 超限 413；限流 429；`/ws` 不接受 HMAC，`/hooks` 不接受 Bearer；未知触发器与禁用触发器同形 401；日志/事件/DB 无 secret。
5. **不可信 payload**：payload 尝试注入 `command`/`agent_id`/`workspace_id`/`verify`/审批字段被忽略或 400；模板字段白名单之外的值不进入 goal；渲染结果截断/redaction；原文 body 不落库。
6. **审批不绕过**：触发器创建 Agent Run → Agent 发起高风险操作 → 仍生成 `decision.requested`，拒绝/过期时 Run 不成功；触发器无任何 API 能回答 Decision；`trigger.disable` 不取消已存在 Run。
7. **停用/过期**：disable 后新事件/webhook/`trigger.fire` 均不产生 Task；重复 disable 幂等；过期后 `trigger.expired` 只发一次；恢复 active 需显式 update；既有 Task/Run 继续。
8. **限额与审计**：超过每 trigger/全局速率得到 `trigger.rejected`（合并计数），不产生 Task；审计含 source、key_id、fire_key、Task/Run 关联；事件 payload 无秘密。
9. **回归**：`trigger.enabled=false` 时行为与未引入 A3 的 host 一致；`moon build --target native`、`moon test --target native`、`scripts/agent_smoke.sh`、`scripts/agent_ssh_smoke.sh`、`scripts/acceptance.sh` 全部保持绿色；新增 `scripts/trigger_smoke.sh` 通过。
10. **真实 webhook 部署**：用本地 nginx/caddy（测试内生成自签证书）验证「TLS 终结 + 转发到 127.0.0.1」；确认 host 本身无非 loopback 监听，文档给出代理配置与故障诊断。

## 实施顺序（A3.0–A3.2）

- **A3.0 核心对象 + 事件触发 + 去重**：契约、迁移、投影/reconcile、事件 dispatcher、游标、事务去重、RPC、审计、开关与单测。对应验收 1、5 的基础部分。
- **A3.1 日程 + webhook**：时区/TZif、slot 抢占、missed/jitter、webhook 路由/HMAC/nonce/限流/密钥文件、反向代理文档。对应验收 2、3。
- **A3.2 集成/测试**：Task→Run→ACP→Decision 全链路、重启/重放/停机/风暴矩阵、`trigger_smoke.sh`、回归与 CI。对应验收 4、5 与整体回归。
- 每个阶段可独立启用/停用；A3.2 通过后才把 `trigger.enabled` 交给 owner 开启。

## A3.2 实施记录（2026-11-26）

A3.0/A3.1 合入后完成 A3.2 集成与验收；A3 仍保持 **默认关闭**，由 owner 在验收签署后显式开启。本次只做集成、端到端测试、smoke 脚本与文档，未新增触发器功能，未改动 runtime/policy/pty/git/transport/providers/desktop。

集成修复（均由验收测试复现）：

1. **`start_run=true` 落地**：Task 提交后经既有 `run.create` 排一个 `mode=agent` Run，幂等键 `trigger:<trigger_id>:<fire_key>`；`trigger_fires.run_id` 回填，另写 `trigger.run.start` 审计（source、fire_key、task_id、run_id）。事件/日程/webhook/manual 四条路径都在提交后走同一函数；`serve()` 在 `reconcile_runs` 之后补跑 `trigger_start_pending_runs`，修复「Task 已提交、Run 未提交」的崩溃窗口，且不重复执行。
2. **Permission Decision 关联 Run**：`record_permission_decision` 通过 `run.session_id` 反查非终态 Run 并写入 `run_id`（独立 session 保持为空），使审计、取消与过期能关联到 Run。
3. **审批等待与拒绝语义**：`run_agent_step` 不再在 session 进入 `waiting_decision` 时立即失败；它等待 owner 应答，拒绝选项、已过期 Decision 或未送达的 answer 使 Run `failed`，允许后继续到 ACP 会话结束。此前实现会在 owner 应答前就结束 Run，属测试证明的缺陷。

验收覆盖：`scripts/trigger_smoke.sh`（Linux native）覆盖功能开关、创建/停用/过期、事件恰好一次（重复投递、游标回退、重启）、`ignore_self`、级联深度 8 与 ping-pong 有界、日程首 slot/重复 tick/停机 skip 与 coalesce、webhook 签名成功/重放/nonce 复用/过期/坏签名 401/429 限流与合并审计、密钥 0600 与 secret 不进入事件/日志/DB、Task→Agent Run→ACP permission→Decision→拒绝后 Run 不成功、审计关联 source/fire_key/Task/Run。脚本使用临时 HOME/state/workspace 与 loopback host，不需要特权或宿主机改动；因真实等待 125 s 停机窗口，运行时间约 3–4 分钟。

已知残余：

- `trigger.fired` 与 Task 在同一事务提交，此时 Run 尚未创建，事件 payload 的 `run_id` 为空；权威关联是 `trigger_fires.run_id` 与 `trigger.run.start` 审计。启动补跑可能在此后回填该列。
- webhook 速率桶与「每分钟合并审计」状态在进程内，host 重启后重置；ADR §9 已列为有意残余。
- ACP 会话本身不跨 host 重启持久化，触发器 Run 与其他 Run 一样受既有 recovery 语义约束。
- 时区仅在本次 Linux native/CI 验证；macOS 与其他平台的 tzdata 尚未实测，named IANA zone 需先确认 TZif 可读，UTC/固定偏移不受影响。

## 回退与停用

- **功能开关**：`trigger.enabled=false`（默认）时 `trigger.*` 返回 `unsupported`，webhook 路由统一 401；既有 Task/Run/Decision/事件完全不受影响。
- **停用全部触发器**：对每个 trigger 调 `trigger.disable`（幂等），不删除记录、不取消既有 Run；需要清理未来日程时同时把 `expires_at` 设为过去。
- **回退 host 版本**：新表为增量迁移，旧事件保留；旧 host 不识别 `trigger.*` 事件，但事件表兼容（只增字段/新类型），不影响 Task/Run 投影。必要时按 `triggers` 表手动 disable 后回退。
- **密钥清理**：`trigger.source.revoke` 吊销 key；删除 `~/.monexus/secrets/webhook/<key_id>.key`；确认无未完成的 webhook 重试。

## 开放问题（实施前确认）

1. `trigger.enabled` 的首个发布默认值：本文定为 false，A3.2 验收后由 owner 显式开启；是否在后续小版本改为 true，需要观察一轮真实使用。
2. macOS 的 tzdata 路径与 `moonbitlang/x/time` 的 TZif 兼容性：A3.0 在 CI 的 Linux 与本地 macOS 各验证一次；不可用时 IANA 名称拒绝、仍支持 UTC/固定偏移。
3. webhook payload 的最大嵌套与字段白名单是否需要按来源类型分档；A3 统一 3 层 + 8 个模板字段。
4. 反向代理是否需要在 A3 提供示例配置（nginx/caddy）并纳入 doctor；A3.1 文档先给出最小片段，doctor 不自动探测代理。
5. 事件模板未来是否允许声明式 payload 字段（当前只允许事件元数据，防止把日志/命令放大为指令）；若需要，按附录 A 增量加字段并补测试。
