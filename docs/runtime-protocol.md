# MoNexus 远端 runtime 传输协议（A1.2 草案）

- 状态：**Draft，已按 A1.0 spike 结论修订（2026-11-26）**；本文是 A1.2 的实现依据，后续实现若与此冲突，以实际证据修订本文与 ADR-0012。
- 日期：2026-11-26
- 依据：`docs/adr/0012-paired-remote-runtime.md`、`docs/v0.2-plan.md` §2.1、`docs/architecture.md` §6–§8。
- 范围：primary（主控 host）与 node（`monexus-host --runtime`）之间的配对、认证、JSON-RPC 传输、幂等、重连与审批绑定。不包含 ACP 语义、UI、调度与多主控。

## 1. 传输与信任

### 1.1 方向与端点

- node 主动连接 primary 的 TLS 端点，不为 node 打开入站端口。
- primary 监听一个显式配置的 `host:port`；证书与私钥路径由配置提供，权限 0600/0700，启动时校验。
- 一个 node 同时只保留一条活动连接；重连前关闭旧连接。

### 1.2 TLS 与证书固定

- 使用 `moonbitlang/async/tls` 的 `Tls::server` / `Tls::client`（已在 0.22.7 Linux native 验证）。**Caveat：** `Tls::server` 被上游标记为 `#internal(..., "do not use, for internal testing only")`，不是受支持的 production surface。A1.2 必须取得上游公开的 TLS server API 或自持一层薄 FFI；doctor 必须检测并拒绝没有可用 TLS server 实现的平台。A1.0 不宣称该 API 为生产可用。
- node 只信任 primary 的证书：首次配对时由带外渠道（配对二维码/配对码页面）给出 primary 证书的 SHA-256 指纹，node 将其写入本地配置（0600）；连接时使用 `CustomPemFile` 固定根证书并再次比对 `get_peer_certificate` 的 SHA-256 指纹。不匹配、缺失或指纹变化一律拒绝连接，不静默回退到系统根证书。
- primary 不要求 node 提供客户端证书；node 的身份由 1.3 的机器凭据证明。若后续引入 node 证书，必须另写 ADR，不在 A1 追加。
- 证书轮换是显式操作：primary 发布新指纹，node 在 owner 确认后更新；旧指纹立即失效。轮换产生审计事件。

### 1.3 配对与机器凭据

- primary 生成一次性配对码：至少 128 位随机、TTL ≤ 10 分钟、单次使用、失败尝试限速；只保存哈希，不写日志/事件。
- node 在 TLS 连接上发送 `runtime.pair`：`pairing_code`、`runtime_id`（node 生成，稳定）、`protocol_version`、`capabilities`、`version`。
- primary 校验后签发机器凭据：32 字节随机 token，返回一次；primary 只保存 token 哈希与 runtime_id/能力/吊销状态，node 以 0600 保存 token。token 不进入 URL、argv、日志或事件。
- 重连用 `runtime.hello` 携带 token 与 runtime_id；primary 对 token 哈希查找、校验未吊销/未过期并绑定 runtime_id。
- 若 node 在 pairing 时声明 `auth.hmac-sha256`，primary 可改用 HMAC-SHA256 challenge-response：签发 30 秒单次挑战，node 对绑定 runtime_id、挑战与客户端 nonce 的 transcript 计算 HMAC；primary 保留 HMAC 验证密钥并常时比较。该模式仍是共享密钥，不是公钥证明。
- **与 ADR-0012 的偏差（已回写）**：MoonBit 0.22.7 未提供可用的非对称签名 API，因此 A1 不使用挑战签名，改用 pinned TLS + 高熵 bearer token（或上述 HMAC 模式）。安全边界仍为 TLS 机密性/完整性 + 可吊销的按机器凭据；token 泄露风险由 0600 存储、短 TTL/轮换与吊销事件缓解。A1.2 不得宣称 Ed25519 或 WSS。
- 错误统一为 `pairing_rejected`，不区分错码、过期、已用、已吊销，避免枚举。

### 1.4 帧格式

MoonBit 0.22.7 的 HTTP server 不能直接包 TLS，`websocket.Conn::from_http_server` 只接受 `http.ServerConnection`（其构造要求 TCP），因此 A1 不使用 WSS；改为在 TLS 流上使用长度前缀的 JSON-RPC 2.0 帧：

```text
4 字节大端无符号长度 N（1..65,536，即 64 KiB 上限）
N 字节 UTF-8 JSON（一个完整的 JSON-RPC 2.0 对象）
```

- 超过上限、长度为 0、非法 JSON、顶层不是对象、缺少 `jsonrpc: "2.0"` → 关闭连接并记录有界诊断；不尝试继续解析。
- 每条请求/响应/通知一帧；二进制数据用 base64，单帧内数组/字符串有上限。
- 队列与背压：每连接最多 64 个未完成请求，每流最多 1 MiB 待发送；超限返回 `busy` 或断开，不静默丢事件。
- 单帧上限固定为 64 KiB；超过即断开，不允许通过调高上限绕过。该帧格式提供与 WSS 等价的消息边界与有序性；若未来 MoonBit 提供可用的 TLS HTTP server，可在不改变方法面的前提下把 WSS 作为后续选项启用，并另写 ADR。**不存在明文回退路径。**

## 2. 握手、心跳与 drain

### 2.1 `runtime.hello`

node → primary（连接后的第一帧请求）：

```json
{
  "jsonrpc": "2.0", "id": "h1", "method": "runtime.hello",
  "params": {
    "runtime_id": "rt_...", "token": "<32-byte base64url>",
    "protocol_version": "1.0", "capabilities": ["exec", "pty", "fs", "git"],
    "last_ack_cursor": 1234
  }
}
```

primary 返回 `server_time`、`heartbeat_interval_ms`（默认 15000）、`max_frame_bytes`、`policy`（版本/哈希/是否 stale）和 `resume`（从 cursor 之后可补发的事件区间）。版本不兼容返回 `unsupported_version` 并关闭，不降级。

### 2.2 心跳与 drain

- node 每 `heartbeat_interval_ms` 发送 `runtime.heartbeat`；primary 连续 3 个周期未收到则关闭并标记连接断开，按 3.2 重连。
- primary 可发送 `runtime.drain`：node 停止接受新 Run，已有 Run 继续或按请求取消，完成后退出。drain 状态进入审计。
- 任何未知方法返回 `method_not_found`；任何未认证请求（hello 之前）返回 `unauthorized` 并关闭。

## 3. 方法面

所有变更方法都带 `client_request_id`（primary 生成，UUID/ULID）；同一 `(runtime_id, client_request_id)` 只执行一次，重复请求返回原结果或当前状态。

### 3.1 执行

- `runtime.exec.start`：`run_id`（primary 分配）、`argv`（字符串数组，不允许整串 shell）、`cwd`、`env`（显式 allowlist 的 name→value 映射，值不写入事件/日志，见 3.5）、`timeout_ms`、`risk_tier`、可选 `stdin`。
  返回 `{run_id, state, started_at, cursor}`。重复键返回已有 run，不创建第二个进程。
- `runtime.exec.cancel`：`run_id`；终止进程树或记录无法回收的 PID；被取消的 run 绝不结算为成功。
- `runtime.exec.status`：`run_id` → 当前状态、退出码/信号、最后 seq、cursor。
- `runtime.pty.open` / `resize` / `input` / `close`：稳定 `session_id`，语义同 exec；输出走事件与有界日志。
- `runtime.process.open` / `write` / `close`：通用双工字节流，供 A1.4 的 AgentRuntime 承载 ACP；协议不理解 ACP 类型，只保证有序字节、背压和生命周期。A1 不承诺跨连接 reattach。
- `runtime.fs.read|write|list|stat`、`runtime.git.status|diff|log|show|worktree_add|worktree_remove`：cwd/路径必须落在 primary 登记的 workspace root 内；真实路径解析后拒绝 `..`、绝对逃逸和符号链接逃逸；写文件用临时文件 + 原子 rename。

### 3.2 事件与 cursor

node → primary：

```json
{"jsonrpc":"2.0","method":"runtime.event","params":{
  "runtime_id":"rt_...","run_id":"run_...","seq":42,
  "kind":"stdout|stderr|lifecycle|pty|fs|git",
  "payload":{},"hash":"sha256:..."}}
```

- `seq` 对每个 `(runtime_id, run_id)` 单调递增，从 1 开始；事件先落本地 outbox 再发送。
- primary 以 `(runtime_id, run_id, seq)` 去重，并向 node 发送 `runtime.ack {cursor}`；cursor 是已持久确认的最大全局序号。
- 重连后 node 从 `last_ack_cursor` 之后重放；若 primary 的 cursor 早于 outbox 最早序号（outbox 被清理或节点换机），返回 `cursor_gap`，对应 run 标为 `lost` 并进入 reconcile，不补造事件。
- 终态事件：`exited {code, signal}`、`cancelled`、`timed_out`、`lost`；只有显式终态才能结算。断线、超时、缺少退出码都不是成功。

### 3.3 重连

- 断线后 node 以指数退避重连：1s→2s→4s→…→60s，带抖动与上限；禁止 busy loop。
- 重连成功后先 hello，再用 `resume` + outbox 补发；在补发完成前不接新 Run。
- token 被吊销 → primary 返回 `revoked` 并关闭；node 停止重试，等待重新配对，不自动换 token。
- node 重启：本地持久化未完成 run 记录，hello 时报告；primary 将其标为 `lost` 或按同一 `client_request_id` 重试，已结算结果不回滚。

### 3.4 错误码

标准 JSON-RPC 错误码（-32700/-32600/-32601/-32602/-32603）之外，使用：

| code | 含义 |
|---|---|
| 1001 | unauthorized / 未认证 |
| 1002 | unsupported_version |
| 1003 | revoked |
| 1004 | busy（队列/背压超限） |
| 1005 | cursor_gap |
| 1006 | policy_stale |
| 1007 | approval_required |
| 1008 | approval_invalid（摘要/版本/nonce/过期不匹配） |
| 1009 | path_denied（根目录逃逸） |

错误消息不得包含 token、命令中的密钥值或完整环境变量。

### 3.5 环境与机密

- `env` 只允许白名单中的变量；值经 TLS 传输，但不写入事件/日志/argv，也不回显。A5 前不得通过 `env` 传密钥或长期凭据；机密由后续账户托管注入。
- token、配对码、审批 nonce 不出现在日志/事件/argv；redaction 测试覆盖。
- node state 目录 `~/.monexus/runtime/<runtime_id>/` 0700；outbox、日志、token 均 0600。

## 4. 策略与审批绑定

- `runtime.hello` 返回 policy 版本/哈希；node 在执行前用同一份策略判定。策略缺失、哈希不匹配或标记 stale 时，高风险请求返回 `policy_stale`/`unverifiable`，不按默认放行。
- 高风险（安装、宿主挂载、删除、提权、任意 `sh -c`）返回 `approval_required`，primary 创建现有 Decision，owner 回答后下发一次性 grant：

```json
{"run_id":"run_...","command_digest":"sha256:...","policy_version":"...",
 "nonce":"...","issued_at":"...","expires_at":"..."}
```

- node 只在 run、命令摘要、策略版本、有效期和 nonce 全部匹配时执行一次；nonce 重放/过期/跨 run 复用返回 `approval_invalid`。
- primary 不可达时高风险只能等待或最终 `unverifiable`；node 不能自行批准。
- 审批、拒绝、过期、策略版本变化全部进 primary 审计；node 不建第二套审批状态机。

## 5. 版本与兼容

- `protocol_version` 采用 `major.minor`；major 不同直接拒绝，minor 向前兼容（未知字段忽略、未知方法报错）。
- 帧格式、方法名、错误码变更必须走 ADR 与迁移说明；不允许静默降级到明文或旧协议。

## 6. 验证映射

| ADR-0012 验证项 | 本协议测试 |
|---|---|
| 正确/过期/错误/重放配对码 | loopback TLS + 临时证书，断言统一拒绝 |
| 证书指纹变化 | 固定旧指纹连接新证书，握手/校验失败 |
| 吊销与重连 | 删除 token 哈希后 hello 返回 revoked，node 不重试 |
| 断线补发/去重 | 断连、重连、resume + outbox，断言 seq 连续且无重复 |
| 幂等 start | 同一 client_request_id 不出现第二个进程 |
| 超时/取消 | 终态为 timed_out/cancelled，不结算成功 |
| 审批绑定 | 摘要/版本/nonce/过期/跨 run 全部拒绝 |
| 路径逃逸 | 根目录、`..`、绝对路径、符号链接拒绝 |

**A1.0 spike 已验证**：pinned TLS 固定（`CustomPemFile` + `get_peer_certificate` 指纹复核）、token/HMAC 重连、心跳与帧边界在 Linux native 的实际行为；错误指纹与不受信任 CA 均 fail closed，明文客户端得不到 JSON 响应。**剩余前置**：A1.2 必须先解决 `Tls::server` 的上游公开 API 或自有薄 FFI，否则不进入执行面接线。
