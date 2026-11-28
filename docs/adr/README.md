# 架构决策记录（ADR）

每个重大依赖/边界变化先写 ADR；Accepted 的决策与 `docs/architecture.md` 保持一致，冲突时以 ADR 为准并回改架构文档。

| 编号 | 主题 | 状态 |
|---|---|---|
| [0001](0001-overall-architecture.md) | 总体架构：桌面、host、Provider 三层 | Accepted |
| [0002](0002-host-rpc.md) | host 语言与 RPC（MoonBit + WebSocket JSON-RPC） | Accepted |
| [0003](0003-machine-provider.md) | MachineProvider：SSH 先行，runtime 预留 | Accepted |
| [0004](0004-domain-and-events.md) | 数据模型与事件日志 | Accepted |
| [0005](0005-agent-runtime.md) | Agent 运行时：ACP 优先 | Accepted |
| [0006](0006-permission-model.md) | 权限模型与审批 | Accepted |
| [0007](0007-ui-and-moui.md) | UI 与 MoUI 边界（vendor 流程） | Accepted |
| [0008](0008-ssh-access.md) | SSH 接入与远端执行 | Accepted |
| [0009](0009-ops-agent.md) | 机管 Agent（`ops`）作为 V0.1 种子角色 | Accepted |
| [0010](0010-m7-launcher-packaging.md) | M7 启动器、打包、首次运行与验收 | Accepted |
| [0011](0011-agent-over-ssh.md) | Agent over SSH：ACP over `ssh -T` stdio（PoC 先行） | Accepted |
| [0012](0012-paired-remote-runtime.md) | 配对远端 runtime（A1）：控制面在主控，执行面下沉 | Accepted |
| [0013](0013-environment-recipes.md) | 环境配方（A2）：Docker 后端的 WorkspaceProvider 实现 | Proposed |
| [0014](0014-triggers.md) | 触发器（A3）：事件、日程与 webhook 只创建 Task | Accepted |
| [0015](0015-skill-packs.md) | 技能包（A4）：声明式技能、按 Agent/Task 启用与审计 | Proposed |
| [0016](0016-account-hosting.md) | 账户托管（A5）：平台凭据存储、按机器/Agent 绑定与本地代理注入 | Proposed |
| [0017](0017-bot-chat-agent-session.md) | Bot/Chat/AgentSession 模型：身份、执行与迁移 | Accepted |
| [0018](0018-smoke-harness.md) | 冒烟测试：原生 MoonBit harness 与 shell OS 边界 | Proposed |
| [0019](0019-chat-transcript-recovery.md) | Chat transcript 恢复与续聊上下文 | Accepted |
