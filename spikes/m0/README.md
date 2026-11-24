# MoNexus M0 spike

只验证四条关键路径，不是 V0.1 实现：没有 UI，不接入 MoUI 应用，不改 MoUI /
MoSpace 仓库。完整证据、阻塞项与 M1–M4 建议见
[`docs/spikes/m0.md`](../../docs/spikes/m0.md)。

## 结论（本机实测）

| 路径 | 结果 | 说明 |
|---|---|---|
| MoonBit native 可执行 | **PASS** | `moon build --target native` 可重复构建，`host.exe` 打印版本并退出 0 |
| 本地 PTY | **PASS** | 启动 `sh`，写入一条命令，收到输出，拿到退出码 7（Linux x86_64） |
| SSH 远程执行 | **PASS（loopback）** | 真实 sshd/ssh 走通 probe + 远程命令 + 退出码；argv 注入探针全部按字面传递 |
| ACP stdio 会话 | **PASS（真实 agent）** | `@zed-industries/claude-code-acp@0.16.2` 完成 initialize → session/new → prompt → 流式 update → `end_turn`；mock agent 另测权限请求 |

“真实 agent”是本机安装的 ACP adapter（Node，测试依赖），不是 MoNexus 的产品依赖；
产品关键路径仍是 MoonBit host。

## 环境

- Linux x86_64，内核 `6.8.0-147-generic`（Ubuntu 24.04）
- MoonBit `moon 0.1.20261119 (738607b 2026-11-19)`
- OpenSSH `9.6p1`（sshd 与 ssh 均在本机）
- Node `v26.13.0`：**仅测试用**（mock ACP agent 与真实 ACP adapter）
- 系统 `python3`：**仅测试用**（让内核挑一个空闲 loopback 端口）

## 目录

> M1 moved the reusable PTY/SSH code to `packages/providers/{pty,ssh}`.
> The tree below records the M0 spike layout before that move.

```text
moon.work                         # workspace 根配置（提交）
spikes/m0/
├── moon.mod                      # module monexus/m0
├── services/host/                # 唯一可执行：子命令分发
├── services/pty_spike/           # PTY 包装（复用 moonbit-community/pty）
├── services/ssh_probe/           # Target / ssh argv / probe / run
├── services/acp_client/          # ACP stdio JSON-RPC 客户端
└── tests/
    ├── mock_acp_agent.mjs        # 最小 mock ACP agent（仅测试）
    └── run_all.sh                # 本机可重复检查脚本（仅测试）
```

## 构建与运行

在仓库根目录（本 worktree 根目录）执行：

```sh
export PATH="$HOME/.moon/bin:$PATH"
moon build --target native
```

产物：

```text
_build/native/debug/build/services/host/host.exe
```

```sh
HOST=./_build/native/debug/build/services/host/host.exe
"$HOST" version
# monexus-host 0.0.1-m0 (M0 spike)

"$HOST" pty-check --shell sh --cmd "printf 'M0_PTY_OK\n'; exit 7"
# M0_PTY_EXIT=7，M0_PTY_OUTPUT_* 之间包含 M0_PTY_OK

"$HOST" --help   # 或直接运行，查看全部子命令
```

SSH 子命令需要一个显式的 target（不从 `~/.ssh/config` 读取隐式配置）：

```sh
"$HOST" ssh-probe --ssh-host 127.0.0.1 --ssh-port 2222 \
  --identity /path/to/key --timeout 10
"$HOST" ssh-run --ssh-host 127.0.0.1 --ssh-port 2222 \
  --identity /path/to/key --cwd /tmp -- sh -c 'echo hi; exit 3'
```

`ssh-run` 的 argv 必须放在 `--` 之后；每个元素单独传递，不会被拼进一条 shell
字符串。`ssh-probe` 输出 `os/arch/kernel/shell` 与固定工具列表（git/gcc/clang/
cmake/moon）的 `command -v` 结果。

ACP（mock，无需网络）：

```sh
export PATH="$HOME/.nvm/versions/node/v26.13.0/bin:$PATH"
"$HOST" acp --command node \
  --arg "$PWD/spikes/m0/tests/mock_acp_agent.mjs" \
  --workspace "$PWD" --cwd "$PWD" --prompt 'say hi' --timeout 30
```

## 一键检查

```sh
bash spikes/m0/tests/run_all.sh
```

会依次做：构建（两次）、`moon test`、版本、PTY、临时 sshd 上的 SSH probe/
run/注入探针、mock ACP（普通 + 权限请求）。脚本自建临时 sshd 并在退出时清理，
不读写用户的 `~/.ssh/config` 或全局 `known_hosts`。

真实 ACP agent 是可选步骤（会使用调用方的模型凭据与网络）：

```sh
M0_REAL_ACP=1 bash spikes/m0/tests/run_all.sh
```

单独跑真实 agent：

```sh
env -u CLAUDECODE "$HOST" acp \
  --command "$PWD/spikes/m0/.testdeps/node_modules/.bin/claude-code-acp" \
  --workspace "$PWD" --cwd "$PWD" \
  --prompt 'Reply with exactly M0_ACP_REAL_OK and nothing else.' --timeout 170
```

`env -u CLAUDECODE` 是必要的：从 Claude Code 会话里再启动 Claude Code 会被
它的嵌套会话保护拒绝（adapter 报 “cannot be launched inside another Claude
Code session”）。

### 安装真实 ACP adapter（仅测试依赖）

```sh
mkdir -p spikes/m0/.testdeps
npm install --prefix spikes/m0/.testdeps --no-audit --no-fund \
  @zed-industries/claude-code-acp@0.16.2
```

`.testdeps/` 已被 `.gitignore` 忽略，不得进入产品依赖或发布物。`codex-acp`
也可装在 `.testdeps` 里，但本机未登录 Codex，实际返回
`Authentication required`，因此只作为失败路径记录，不计入 PASS。

## 实现要点

- **PTY**：直接使用 `moonbit-community/pty@0.4.4`（Apache-2.0），与 MoSpace
  `services/terminal` 同一个包；没有拷贝 MoUI 的 C 源。写命令后补一个换行，
  `read_all` 到 EOF 后 `wait` 拿退出码。
- **SSH argv 安全**：`ssh` 参数带 `BatchMode=yes` / `ConnectTimeout=`。远程命令
  不是把 argv 拼成字符串，而是固定的 `sh -c 'cd -- "$1" && shift && exec "$@"'
  monexus-run <cwd> <argv...>`，每个位置参数都经过单引号转义；注入探针验证
  `;`、`$()`、单引号、`--flag` 都保持字面。
- **临时 sshd**：临时 host/client key、临时 `AuthorizedKeysFile`、`UsePAM no`、
  `StrictModes no`、`127.0.0.1` 随机端口、`BatchMode=yes` +
  `StrictHostKeyChecking=accept-new` + 临时 `UserKnownHostsFile`。只证明本机
  loopback 传输；真实跨机网络/NAT/认证策略尚未验证。
- **ACP**：newline-delimited JSON-RPC 2.0；顺序请求（M0 只验证传输）。收到
  `session/update` 的 `agent_message_chunk` 时回调打印；`agent_thought_chunk`
  加 `[thought]`。`session/request_permission` 目前回复 `cancelled`——M0 还没有
  Decision/收件箱通道，不能静默同意用户没看过的权限。

## 来源与许可

- `moonbit-community/pty@0.4.4`，Apache-2.0：PTY 绑定。
- MoSpace `services/remote`（Apache-2.0）：`Target`、`ssh_argv`、`shell_quote`
  的结构与单引号转义规则；本目录为 spike 重写并加注释，未拷贝整个文件。
- MoUI `examples/mo_workbench/acp_native_transport`（Apache-2.0）：ACP 传输层
  形状参考；M0 客户端按其消息序列重写，未拷贝代码。
- `@zed-industries/claude-code-acp` / `codex-acp`：仅本地测试依赖，不随产品发布。
- mock ACP agent 与 `run_all.sh` 为本次 spike 新增，仅测试用。

## 已知限制

- 只在 Linux x86_64 实测；没有真实外部机器（loopback 之外未验证）。
- `ssh-probe` 看到的远程 `PATH` 是非登录 shell 的 `PATH`，因此本机 `moon`
  （在 `~/.moon/bin`）显示 `<missing>`；这是如实结果，不是探测 bug。
- ACP 客户端一次只有一个请求在途，没有 `session/load` 恢复、取消队列、
  bounded buffer、Decision 回传；这些属于 M4。
- Node 与 Python 只在测试脚本里出现；host/PTY/SSH/ACP 协议实现均为 MoonBit。
