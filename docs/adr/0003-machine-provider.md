# ADR-0003：MachineProvider——SSH 先行，runtime 预留

- 状态：Accepted
- 日期：2026-11-25
- 依据：`docs/architecture.md` r5 §6.1、§8、D8

## 背景

V0.1 必须在本机与远程 Ubuntu 上执行命令、开 PTY、跑 Agent。远程接入有两条路：SSH 直连，或在远端运行 host 并以配对码接入（Orca environments 模式）。

## 决策

1. **V0.1 唯一实现 `kind=ssh`**：复用系统 `ssh`（模式来自 MoSpace `services/remote`），远端只假定 POSIX shell。
2. **接口预留 `kind=runtime`**：V0.2 在远端运行 `monexus-host`，用配对码接入；执行、会话与策略在远端 host 侧完成，SSH 只作传输/引导。
3. `CommandSpec` 只接受 argv 数组，不接受整串 shell；需要管道/重定向时显式 `sh -c` 并标为高风险。
4. `probe` 无副作用；`readiness(target, agent)` 检查 CLI 是否存在、版本、登录状态；失败生成 Decision，不反复重试。
5. 策略双侧执行：host 生成受限 argv；远端执行包装器按机器策略表复核。
6. `MachineProfile` 带 `arch/os/shell/toolchains/has_docker/has_gui/max_parallel`；RISC-V 不假设 Docker/GUI。

## 后果

- 远程能力（run、PTY、tmux、日志）全部经 Provider，不泄漏到 UI。
- NAT/弱网、主动注册、一次性环境在 V0.2 通过 runtime/环境配方解决，不推翻 V0.1。
- SSH 的局限（无节点侧策略、依赖系统 OpenSSH）记录在风险表，Windows 走 OpenSSH 或 V0.3 自研节点。
