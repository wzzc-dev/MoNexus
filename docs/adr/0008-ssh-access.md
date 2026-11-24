# ADR-0008：SSH 接入与远端执行

- 状态：Accepted
- 日期：2026-11-25
- 依据：`docs/architecture.md` r5 §8、§13

## 背景

V0.1 的远程机器只有 SSH；MoSpace 已验证系统 `ssh` + 转义 + async worker 的最小路径。无人值守任务需要可预测的身份与失败语义。

## 决策

1. **基线复用**：`Target{host,port,identity,timeout_seconds}`、`ssh_argv`（`BatchMode=yes`、`ConnectTimeout`）、`shell_quote`（单引号 + `'\''`）；复用 `~/.ssh/config`、agent、跳板机；不引入 sftp。
2. **显式优先**：主机/用户/端口/身份文件存 host 数据库；`~/.ssh/config` 继承作为显式开关（默认开），记录 `ssh -G` 生效值。
3. **执行**：`probe` = `uname -srm` + `command -v git gcc clang cmake moon`；`run` = `ssh target -- sh -lc <quoted argv>` 或 `ssh -tt ... tmux new-session -d`。
4. **持久化**：远端 `tmux` + `pipe-pane` 日志；host 增量 `tail`；结束标记 `__MONEXUS_DONE__<code>` 决定状态，不把日志当状态。
5. **恢复**：`tmux has-session` 重连；`capture-pane` 补输出；心跳缺失标 `disconnected`，不因短断线失败。
6. **测试**：M0 用 127.0.0.1 回环 sshd，临时 `UserKnownHostsFile` + `StrictHostKeyChecking=accept-new`；不改用户 `~/.ssh/config` 或全局 known_hosts。
7. **演进**：V0.2 远端 runtime（配对码）+ 环境配方；SSH 保留为传输与引导。

## 后果

- 远端只假定 POSIX shell；Windows 走 OpenSSH 或 V0.3 自研节点。
- 弱网/NAT 由 V0.2 runtime 解决；V0.1 明确记录该限制。
