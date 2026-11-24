# ADR-0001：总体架构——桌面、host、Provider 三层

- 状态：Accepted
- 日期：2026-11-25
- 依据：`docs/architecture.md` r5 §2、§4、§6

## 背景

MoNexus V0.1 是「AI Organization Workspace」的第一个可交付形态：在本机与远程机器上管理 Workspace、Worktree 与 Agent 会话。UI、执行、状态三者若混在一起，会出现双权威、远程能力泄漏进 UI、恢复困难。

## 决策

1. 三个可分离的运行时部件：
   - **桌面端**（MoUI 应用）：只读投影 + 意图提交；不直接碰 ssh、文件系统或模型 API。
   - **`monexus-host`**（MoonBit 可执行）：唯一业务状态权威；任务/Run 状态机、事件日志、调度、策略、审批、工作树、检索。
   - **Provider 适配层**：`MachineProvider` / `WorkspaceProvider` / `AgentRuntimeProvider`，由 host 调用，Provider 之间不互相调用。
2. 状态权威见 §4：组织、任务、审批/决策、工作树、机器注册、项目/Workspace、Run/事件均由 host 可写；Agent 会话内容归 runtime。
3. 事件先行：所有状态迁移写事件 + 投影（同一事务）；投影可由事件重放重建。
4. V0.1 不引入外部组织/机器控制面，也不保留第二套可写状态机。

## 后果

- 桌面端可崩溃、可重连，host 与远端 tmux/会话继续运行。
- 任何新能力先落到 Provider 契约，再由 host 编排；避免 UI 里长第二套逻辑。
- 远程执行、模型账户、环境配方都可以在不改权威模型的前提下演进（见 ADR-0003、ADR-0008）。
- 代价：多一个本地守护进程与 RPC 层；用单实例锁、端口文件与 token 控制复杂度。

## 不采纳

- UI 直连 ssh/文件系统（难以审计、无法恢复）。
- 外部控制面（Paperclip/OpenClaw 已从计划移除）。
- 在 V0.1 做多用户/多租户（留给后续版本）。
