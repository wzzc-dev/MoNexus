# ADR-0018：冒烟测试：原生 MoonBit harness 与 shell OS 边界

- 状态：Proposed（试点，待 owner 决定是否推广）
- 日期：2026-11-28
- 依据：`scripts/workspace_smoke.sh`、`services/smoke-harness/`、`packages/host-client/`、`packages/contracts/`、ADR-0002（host RPC）、ADR-0003（MachineProvider）、ADR-0004（领域与事件）
- 范围：只针对 CI e2e 冒烟脚本的断言/RPC 层。生产 host、桌面和 contracts 语义不变。

## 背景

`scripts/workspace_smoke.sh` 原来是一个 546 行的单体 shell 脚本，同时承担两类职责：

1. OS fixture：临时 `HOME`/state、fixture 仓库、临时 sshd、密钥、known_hosts、host 进程启停和清理。
2. 测试逻辑：107 个 workspace/worktree/lease/terminal/SSH 检查，用 `jq` 解析 RPC JSON，用 shell 字符串比较断言，并手写 terminal 轮询。

这带来几个可复现的问题：

- RPC 结果没有类型检查；字段名拼写、错误分支和 JSON 形状只能靠 `jq -r` 在运行时发现。
- shell 转义、命令替换尾换行和 `jq` 版本差异会改变断言语义，失败定位依赖 `--- output ---` 文本。
- `jq` 不是产品依赖，却是 CI 冒烟的隐式依赖；解析逻辑和 `host-client` 已有的 typed RPC 客户端重复。
- 随着 machine/task/agent/trigger 等 smoke 增长，复制 polling、JSON 断言和错误分类的成本会继续上升。

本 ADR 只做一个试点：把 workspace smoke 的 RPC 与断言层迁到原生 MoonBit executable，shell 继续负责 OS glue。CI 入口保持 `bash scripts/workspace_smoke.sh`。

## 决策

### 1. 采用原生 MoonBit harness，而不是 `.mbtx`

新增 `services/smoke-harness` native executable，提供 `workspace` 子命令。选择原生目标而不是 `.mbtx` 的理由：

- **真实 OS 语义**：这套 smoke 要覆盖真实 PTY、`ssh -tt`、tmux、进程重启和 terminal resize。原生进程/信号/PTY 行为是检查对象；解释器或 WASM 形态无法在同等条件下证明这些边界。
- **复用现有 typed client**：`packages/host-client` 提供 native WebSocket RPC，`packages/contracts` 提供 workspace/machine/terminal/event 的 JSON codec。harness 直接复用，避免再维护一套 JSON 解析。
- **稳定性与 CI 适配**：单一 native executable 与现有 `scripts/native_packages.sh` 的 native build/test 流程一致；去掉 `jq` 依赖和大量 shell 引号拼接，失败时保留 typed error 与 PASS/FAIL 标签。
- **可测试性**：report 计数、size 解析和 polling 可在 harness 内做白盒测试；shell 不再承载断言库。

当前 harness 输出保持原契约：

```text
PASS  <label>
FAIL  <label> (expected: ...)
SKIP  <label>
SUMMARY  passed=N failed=N skipped=N
```

非零失败退出由 harness 传播给 wrapper；CI 不需要新的结果格式。

### 2. shell 与 harness 的边界

| 职责 | 归属 | 说明 |
|---|---|---|
| 临时 `HOME`、state dir、fixture git 仓库 | shell | `mktemp -d`；fixture 内容和初始 commit 由 shell 建立 |
| 临时 sshd、host/client 密钥、authorized_keys、known_hosts | shell | 随机 loopback 端口；显式临时文件，不碰真实 `~/.ssh` |
| host 启动、停止、`--restart-host` | shell | pidfile 作为唯一进程句柄；harness 只调用 wrapper 的 restart 模式 |
| 环境变量导出 | shell | `MONEXUS_SMOKE_*`：work/state/repo/remote root、host binary、pidfile、ssh 端口/用户/身份/known_hosts |
| 清理 | shell | `trap cleanup EXIT` 删除 temp work、kill sshd 和当前 host |
| RPC 调用、JSON 解码、PASS/FAIL/SKIP、轮询/超时 | MoonBit harness | 全部通过 `host-client` + `contracts`，不调用 `jq` |
| `~/.ssh` 前后快照 | harness | 直接读取真实 `~/.ssh` 的普通文件 `name/size/mtime` 并比较 |

边界规则：shell 不解释 RPC JSON；harness 不创建 temp fixture、不启动 sshd、不管理 host 生命周期。任何需要 shell 的步骤都通过 wrapper 子命令或已导出的环境变量表达。

### 3. 试点范围与迁移计划

本次只迁移 `scripts/workspace_smoke.sh`，作为决策证据：

1. 保持 shell wrapper 的 fixture/sshd/restart 逻辑和 CI 命令不变。
2. 将 workspace 的 107 个检查分批映射到 typed helpers：workspace、worktree、lease、terminal、events、machine/SSH。
3. 每次迁移保持检查数量不下降、PASS/FAIL/SKIP 标签和 summary 契约不变，并至少跑一次 Linux CI。
4. 若本 ADR 接受，按 machine → task/agent_ssh → agent/trigger 的顺序逐个迁移。每个脚本先保留 shell fixture，只替换断言/RPC 层；旧 shell 断言在对应 CI 连续 green 后再删除。
5. 共享部分优先抽成 native smoke library（report、RPC facade、polling），而不是复制到每个 executable；fixture 契约继续由各 wrapper 明确导出并记录在 ADR 中。

暂不迁移 desktop UI、acceptance 和 packaging 类脚本；它们的主要风险不是 RPC/JSON 断言，或需要不同的进程/GUI 边界。

## 试点指标

本地 Linux（base `c6d9035`）实测：

| 指标 | 迁移前 | 迁移后 |
|---|---|---|
| workspace smoke 检查数 | 107 passed / 0 failed / 0 skipped | 107 passed / 0 failed / 0 skipped |
| workspace smoke 墙钟时间 | 29.42s | 20.68s（同一环境单次实测） |
| shell 脚本行数 | 546 | 218 |
| 新 harness 行数（`.mbt`，含 47 行白盒测试） | 0 | 2,202 |
| 新增 module manifest 行数 | 0 | 29 |
| 代码总行数变化（shell + `.mbt`，不含 manifest） | 546 | 2,420（净 +1,874） |
| `jq` 参与行数 | 约 108 | 0 |
| shell 断言/检查行数 | 约 121 | 0（迁入 harness） |

结论：LOC 净增明显，但 shell 从 546 行降到 218 行，107 个检查全部由 typed RPC 执行；耗时没有回退，单次实测约快 30%。LOC 不是唯一指标，关键收益是去掉了 `jq`、shell JSON 解析和重复 polling，并把失败定位变成 typed error + 稳定标签。

## 风险与缓解

- **环境变量契约重复**：shell 导出的 `MONEXUS_SMOKE_*` 是新边界；任一侧改名会造成启动失败。缓解：help 中列出变量，wrapper 启动前检查 host/harness 可执行文件，CI 每次跑完整 smoke。
- **sshd/`ss` 可移植性**：临时非 root sshd 依赖 `ss` 检测监听端口；Linux 已验证，macOS 仍以当前基线判断。缓解：`MONEXUS_SMOKE_SSH_AVAILABLE`/`_SSH_READY` 显式表达可用性；不可用时 harness 打印 SKIP，而不是静默通过。
- **native 构建产物路径**：harness 默认路径依赖 MoonBit build layout。缓解：支持 `SMOKE_HARNESS_BIN` 覆盖；CI 先按 `native_packages.sh` 构建再跑 smoke；缺失时给出直接构建命令。
- **host 重启/孤儿进程**：main shell 的 host 与 restart 子进程启动的 host 不是同一父进程；cleanup 依赖 pidfile 而不是局部 `$!`。缓解：stop 轮询退出、超时后强制 kill，并在 trap 中删除 temp work。
- **检查标签漂移**：从 shell 迁到 harness 时可能改变可读标签。缓解：本次保留原 107 个标签的语义与 summary 格式；后续迁移逐脚本对比基线。
- **async/fs API 版本**：harness 使用 `moonbitlang/async` 0.22.7 的 native API；升级时需要同时更新 process/fs 调用点。缓解：集中封装在 `workspace_rpc.mbt`/`workspace_flow.mbt`，并有 focused whitebox tests。
- **harness 规模**：首次迁移增加约 1.8k 行。缓解：只对 RPC/JSON/polling 重的 smoke 推广；UI/packaging smoke 继续用现有方式。

## 备选方案

1. **保留 shell + `jq`**：改动最小，但继续承担 JSON 形状、转义和 `jq` 依赖；不解决重复断言库问题。
2. **`.mbtx` / WASM harness**：可减少 native 构建产物，但不能在真实进程/PTY/ssh 语义下验证；与 native host-client 的复用也受限。
3. **通用 JSON 断言 DSL**：可以让 shell 配置化，但仍需自建 JSON 解析/类型层，且无法复用 contracts。
4. **外部测试框架（例如独立 e2e 进程）**：引入新工具链和 CI 依赖，对当前仓库的 native MoonBit 构建没有直接收益。

## 待决定

- 是否接受本试点并把 machine/task/agent_ssh/agent/trigger smoke 按上述顺序迁移。
- 是否将 harness 的 report/RPC/polling 抽成共享 native library，以及是否给 CI 增加“新 smoke 不得引入 jq 解析”的静态检查。
