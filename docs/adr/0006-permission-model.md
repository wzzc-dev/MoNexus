# ADR-0006：权限模型与审批

- 状态：Accepted
- 日期：2026-11-25
- 依据：`docs/architecture.md` r5 §11、§6.5

## 背景

Agent 可以发起写文件、装依赖、删目录、重启机器等操作；只在 UI 弹窗无法防止绕过，尤其在远程机器上。

## 决策

1. **风险分级**：低（读、git status）allow；中（写文件、测试、构建）allow 于 Workspace 授权内；高（批量删除、系统配置、装依赖）ask；极高（root、部署、密钥、网络策略）deny，除非一次性授权。
2. **判定点**：host `evaluate(CommandSpec, target, agent)`；`ask` 生成 Decision（`decision.requested`）；桌面端只是应答通道。
3. **双侧执行**：host 生成受限 argv；远端包装器按机器策略表复核后才执行。
4. **审计**：每次判定写事件（谁、什么、为何、结果）；Decision 记录回答人、时间、选项。
5. **密钥**：只进系统 keychain/0600 文件；不进日志/事件 payload；V0.1 模型凭据由机器上已登录的 Agent 账户提供，host 不复制密钥进 Workspace；账户代理 V0.2。
6. **证据门**：Run 结算只认 host 签发的 verify 结果或显式豁免 Decision。

## 后果

- 审批与 Agent 提问共用注意力队列，避免多套弹窗。
- 静默失败/无法确认不触发自动恢复，转 Decision 由 owner 定夺。
