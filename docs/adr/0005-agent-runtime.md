# ADR-0005：Agent 运行时——ACP 优先

- 状态：Accepted
- 日期：2026-11-25
- 依据：`docs/architecture.md` r5 §6.3、§9、§14 M0

## 背景

Agent CLI 协议不统一；MoUI `examples/mo_workbench` 已有 ACP stdio 传输，但只接了 macOS。M0 需要验证 Linux 入口与真实 Agent 的可接性。

## 决策

1. **ACP stdio 优先**：`AgentRuntimeProvider` 以 ACP 为首个实现；不支持 ACP 的 CLI 用逐行 stdout 降级，退出码决定结果。
2. **会话所有权**：Adapter 拥有进程；host 拥有元数据、心跳、取消、恢复；桌面端只是观察者。
3. **权限请求**：ACP `session/request_permission` 不直接弹 UI，统一转成 Decision，与审批同通道。
4. **记忆**：每 Agent 有 `home`；启动时注入 `AGENTS.md` / `MEMORY.md` 摘要（体积上限），`AGENTS.md` 会话只读，`MEMORY.md` 写入走审计/审批；Run 结束快照 diff 落 Artifact。
5. **就绪**：启动前 `probe(agent)` 检查 CLI/版本/登录；失败写 `agent.readiness.failed` 并生成 Decision。
6. **用量**：`usage(handle)` 拿 token/费用，未知则空；V0.2 再做预算与账户托管。
7. **并发隔离**：同一 Worktree 同时最多一个活跃 Run；并发必须各自 Worktree。

## 后果

- 真实 Agent 缺 ACP 时，M4 需要适配器（例如 claude-code-acp / codex-acp）或降级 stdout；M0 报告给出具体方案。
- 不解析模型输出语义；结构化事件由 ACP 提供，降级模式只有文本与退出码。
