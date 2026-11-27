# ADR-0007：UI 与 MoUI 边界

- 状态：Accepted
- 日期：2026-11-25
- 修订：2026-11-25 依赖升级到 MoUI 0.9.2（`moui_skia_renderer` 0.4.0 → 0.9.2）
- 修订：2026-11-27 依赖升级到 MoUI 0.10.1（输入光标行盒修复，MoUI #53）
- 依据：`docs/architecture.md` r5 §10、§15、MoUI `docs/vendor-workflow.md`

## 背景

桌面端用 MoUI 0.10.1；框架缺能力时不能 fork，也不能让 vendor 覆盖进入提交。

## 决策

1. **独立仓库消费发布版**：`wzzc-dev/moui@0.10.1` 及子包；`apps/desktop` 用 `moui new` 结构，平台入口只做薄接线。
2. **TEA 结构**：`Model = HostProjection + UiState`；RPC 是 Effect，事件订阅是 Subscription；UI 不直接碰 ssh/文件/模型。
3. **MoUI 缺能力走官方 vendor 流程**：clone 到 `vendor/MoUI`（gitignored）、在 `moon.work` 做本地覆盖、验证并跑 MoUI gate、向上游提 PR；上游发布后 bump 版本并移除覆盖。禁止提交 `vendor/`，禁止孤儿补丁。
4. **页面**：Home（收件箱 + 全局任务）、Machines、Projects/Workspaces/Worktrees、Agents/Sessions、Tasks、Activity、Search、Settings。
5. **复用**：orca-moui 仅参考信息架构与视觉，确认许可前不复制代码；MoSpace（Apache-2.0）可复用交互模式并注明来源。
6. **V0.1 不做**：完整代码编辑器、插件市场、嵌入式浏览器、AI 操作 UI。

## 后果

- CI 只用注册表版本；vendor 覆盖只在本地开发时启用。
- UI 可在 host 不可用时显示最后投影并提示重连。
