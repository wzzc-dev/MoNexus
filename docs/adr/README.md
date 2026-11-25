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
| [0012](0012-paired-remote-runtime.md) | 配对远端 runtime（A1）：控制面在主控，执行面下沉 | Proposed |
