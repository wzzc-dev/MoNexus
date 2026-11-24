# ADR-0004：数据模型与事件日志

- 状态：Accepted
- 日期：2026-11-25
- 依据：`docs/architecture.md` r5 §3、§5、§12

## 背景

多机器、多 Agent 并行会产生大量状态；如果用可变的「当前值」做权威，崩溃后无法判断哪些 Run 真实存在，也无法审计审批。

## 决策

1. **ID**：`前缀 + ULID`（`org_ agt_ mch_ wsp_ prj_ wt_ tsk_ dec_ run_ ses_ art_ evt_`），跨对象只存 ID。
2. **事件信封**：`id/org_id/type/ts/subject/seq/causation_id/correlation_id/idempotency_key/payload`；`seq` 按 subject 单调；事件不可变，修正用补偿事件。
3. **投影**：`events` append-only + `projections_*` + `cursor` + `outbox`；状态迁移与事件同事务；投影可由重放重建。
4. **对象**：Worktree 一等（`wt_`），Run 绑定 Worktree；Decision 一等（`dec_`），审批与 Agent 提问共用。
5. **保留**：状态事件 90 天；会话输出有界缓冲 + 落盘引用，回收前写 Artifact 引用。
6. **删除**：tombstone 事件，不做物理级联删除。
7. **检索**：SQLite FTS5 索引会话与决策文本；若绑定缺 FTS5，退化为 LIKE + 时间索引。

## 后果

- 恢复逻辑以「事件 + 幂等键」判断重复派发与重复结算。
- 高容量 `agent.session.output` 不进投影，避免事件表膨胀。
- 任何新对象（Message/Trigger）必须先注册事件 schema；V0.1 不预留空表。
