# ADR-0019：Chat transcript 恢复与续聊上下文

- 状态：Accepted（2026-11-28，M1a-1 实现）
- 日期：2026-11-28
- 依据：ADR-0017（Bot / Chat / AgentSession 领域模型）、ADR-0005（Agent 运行时）、`packages/contracts/bots.mbt`、`packages/machines/bots_store.mbt`、`services/host/bots.mbt`、`services/host/agents.mbt`、`apps/desktop/app/workroom_view.mbt`
- 范围：只定义 Chat 的会话恢复、transcript 持久化与续聊上下文；不改变 Bot 长期记忆、Run/Decision 语义或 remote runtime 持久化。

## 背景

ADR-0017 已确定 ChatMessage 是用户可见对话的唯一权威，runtime transcript
只是执行/审计缓存。M1a-1 之前，host 重启会丢掉内存中的 runtime transcript：

- `chat.send` 先写 ChatMessage，再把用户原文发给 runtime；
- `chat.read` 只读内存 runtime transcript，runtime 缺失时返回 `text=""`，
  且不改变 client cursor；
- 重启后 Chat AgentSession 仍可能停在 `active`/`waiting`，却没有对应 runtime；
- 新 AgentSession 没有同一 Chat 的 handoff 指针，也没有可证明的一次性续聊
  上下文。

如果把持久 transcript 直接接进 `chat.read` 的可见文本，桌面端会把已经由
ChatMessage 渲染的历史再追加一次，造成重复。因此恢复能力必须分成两个平面：

- **用户可见平面**：ChatMessage（含 host 写入的 system 边界）；
- **执行/审计平面**：按 Chat AgentSession 持久化的有界 transcript。

## 决策

### 1. ChatMessage 是唯一用户可见历史

- `ChatMessage.body` 只保存用户原始输入或用户可见的 assistant/system 文本。
- `chat.read` 的返回形状、cursor 单位和语义不变：cursor 仍是 runtime
  transcript 的绝对结束位置；runtime 缺失时 `text=""`、cursor 不回退。
- 持久 transcript 永远不作为 `chat.read` 的 UI 回放来源。

### 2. 持久 transcript

- 存储在 SQLite 的 `chat_transcripts` 表，主键是 **Chat AgentSession**
  的规范 id（`asn_`），不是 runtime id。
- 字段：`session_id`、`base`、`text`、`context_injected`、`updated_at`。
- 保留 128 KiB 上限和头部裁剪：`base` 是 `text[0]` 的绝对 cursor；
  裁剪推进 `base`，不重置 cursor。实现沿用现有 code-unit 计数，因此上限
  是 131072 个 MoonBit code unit（ASCII 时等于 128 KiB）。
- 每次 runtime 输出增量后持久化最后状态；session 结束时再写一次最终快照。
- 缺失、不可读或损坏（例如负 `base`）时安全降级为 `None`，不阻断
  `chat.read` 或 host 启动。
- 该表只用于执行/审计、故障排查和后续内存功能；不是 UI 历史来源，也不
  会被 Chat/Bot 事件投影 replay 清空。

### 3. 启动 reconcile

host 启动时对每个 Chat AgentSession 执行幂等 reconcile：

1. `starting|active|waiting|ending` 收束为 `ending -> ended`；
2. `end_reason=host_restarted`；
3. 该 session 的 pending Decision 过期；
4. 为该 session 写一条 `role=system`、`actor="host"`、
   `agent_session_id=<asn_>` 的 ChatMessage 边界；
5. 同一边界按 `(chat_id, agent_session_id, role=system)` 检查，重复
   reconcile 或上一轮部分失败都不会写第二条。

边界文案明确「运行时已中断，记录已保留」，它是普通 ChatMessage，不是
隐藏上下文。legacy runtime session 的 `host_restart` 保持兼容；Chat
AgentSession 使用新的 `host_restarted` 值，避免把两套 session 混淆。

reconcile 后不得留下没有 runtime 的 ghost active session；新 session 只能
由 owner 在同一 Chat 显式启动。

### 4. Handoff 与首次 send 的隐藏前缀

- 同一 Chat 新建 AgentSession 时，`handoff_from_session_id` 指向该 Chat
  最近的既有 session（按 `started_at, id` 排序）；没有既有 session 时为空。
- 新 session 的**第一次** `chat.send` 注入最近的可见历史：
  - 只取 `role=user|assistant`；
  - 排除 system 边界、Decision/审批内容和当前这条 user 消息；
  - 从最近消息向过去取，渲染时保持时间顺序；
  - 整个前缀（含 wrapper）不超过 8192 个 UTF-8 字节；单条最新消息超大时
    从其尾部按 UTF-8 code point 安全截断；
  - 通过 durable one-time claim（`context_injected`）保证只注入一次，
    第二次及之后的 send 只发送用户原文。
- 隐藏前缀只进入发给 runtime 的 prompt；不得进入 ChatMessage.body、
  持久 transcript 或事件正文。
- runtime 启动参数仍保持 `prompt=""`、`memory_limit=0`。Bot memory 注入
  与 `memory_digest` 属于 M1b，不在本 ADR 范围内。

### 5. UI

- Chat 时间线继续渲染普通 system ChatMessage，因此恢复边界可见。
- 无 active session 时保留「启动智能体会话」入口；存在 host 恢复边界时
  文案改为「继续智能体会话 / Continue Agent session」，让 owner 知道这是
  同一 Chat 的中断续聊，而不是新 Chat。

## 后果与限制

- 恢复的是可见历史与一次性续聊上下文，**不是** ACP 进程或模型会话本身；
  不承诺自动续接未完成 turn。
- 新 session 的 runtime transcript 从 cursor 0 重新开始；持久 transcript
  按 session 分开保存，不能跨 session 复用 runtime cursor。
- 每个有 runtime 输出的 Chat AgentSession 会保留一份有界审计缓存；清理
  策略沿用 session/DB 生命周期，不在本 ADR 引入额外 GC。
- transcript 上限按现有 code-unit 语义保留；含多字节 UTF-8 时实际字节数
  可能高于 128 KiB。若未来需要严格字节上限，必须同时定义 cursor 单位与
  迁移方式，不能静默改变现有 cursor。
- 旧 `host_restart` 记录仍可读；新 Chat 恢复只写 `host_restarted`。

## 验证

- 启动 reconcile：active/waiting/starting → ended(host_restarted)，pending
  Decision 过期，重复 reconcile 只有一条边界。
- `chat.read` 在 runtime 缺失且持久 transcript 存在时仍返回空文本、cursor
  不变。
- 首次 send 的隐藏前缀 ≤8192 UTF-8 bytes，排除 system/当前消息，第二次
  send 不再注入；前缀不出现在 ChatMessage、持久 transcript、事件 payload。
- transcript reopen 后仍能读到最后的 base/text/claim 状态；损坏行降级为
  空；头部裁剪推进 base。
- 桌面 widget 测试覆盖 system 边界和「继续智能体会话」入口。
