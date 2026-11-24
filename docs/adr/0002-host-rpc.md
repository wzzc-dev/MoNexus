# ADR-0002：monexus-host 的语言与 RPC

- 状态：Accepted
- 日期：2026-11-25
- 依据：`docs/architecture.md` r5 §7、D1、D2

## 背景

host 需要文件、PTY、ssh 子进程、并发与 SQLite；桌面端用 MoonBit（MoUI）。D1/D2 已由 owner 定为 MoonBit + WebSocket JSON-RPC。

## 决策

1. **语言**：`monexus-host` 用 MoonBit；与桌面端共享 `domain`/`contracts` 类型。Node 只在接入上游生态（如 ACP 适配器、测试脚本）时出现，不进产品关键路径。
2. **RPC**：WebSocket JSON-RPC 2.0，监听 `127.0.0.1` 随机端口；启动写 `~/.monexus/host.json`（0600，含 port/token）。桌面端用 token 连接。
3. **幂等**：所有写方法带 `client_request_id`；host 以幂等键去重，重复请求返回既有结果。
4. **事件推送**：订阅用 `events.subscribe(since)`；桌面端先补拉（`last_event_id`）再收 notification；游标过期用快照 + 全量重建。
5. **生命周期**：单实例锁；桌面端退出后 host 继续（`keepAlive`）；长任务与 Agent 会话落到 tmux/独立子进程，host 重启按 `run_id` 重连。

## 方法面（V0.1）

`host.status`、`machine.add/probe/remove/list`、`workspace.open/list/read/write`、`worktree.create/remove/list`、`session.start/send/stop/read`、`run.start/cancel`、`task.create/list`、`decision.respond`、`search.sessions`、`events.subscribe`。

## 后果

- stdio 只作调试；多窗口/重连由 WS 承担。
- RPC 全部在 host 内做策略与状态校验，桌面端不能绕过。
- host.json 是本地信任边界：0600、仅回环、随机端口；不提供局域网监听。
