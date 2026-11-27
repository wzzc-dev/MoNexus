# ADR-0010：M7 启动器、打包与首次运行

- 状态：Accepted（2026-11-27 增补 macOS 支持）
- 日期：2026-11-25
- 依据：`docs/architecture.md` §7.2、§10、§14；M7 目标“干净机器一键启动”

## 背景

M1–M6 已经提供 host、桌面、机器/Workspace、Agent 与 Task/Run/恢复能力，但
第一次使用的用户需要自己拼出 host 启动、host.json 读取、桌面启动和状态目录
初始化；也没有固定产物路径、版本输出和可校验的安装包。M7 要求一个
`monexus` 命令完成启动/复用与桌面拉起，提供带校验和的发布包，首次运行自动
初始化状态目录与示例 Workspace，并把使用、故障排查和验收写成可执行的文档。

架构 §7.2 原本写的是“host 由桌面端启动并看护（单实例锁 + 端口文件），桌面
退出后 host 继续运行（keepAlive）”。M7 的实现与其中“由桌面端启动”一句存在
偏差，需要记录。

## 决策

1. **host-first 启动器，保留 keepAlive 与单实例语义。**
   `scripts/monexus.sh`（安装后 `bin/monexus`）是唯一入口：
   `monexus [start]` 先通过 `host.status` 判断是否已有 host；有则复用，无则
   `nohup monexus-host serve` 分离启动并等待 `host.json`，随后才启动桌面。
   `host.lock` 的 flock 仍是最终的单实例权威；桌面退出默认不停止 host
   （§7.2 keepAlive），`--no-keep-alive` 只停止本次启动的 host。
   **偏差**：host 由启动器而非桌面启动。理由是无显示环境必须能一键启动
   host（`--headless`），且桌面重启不应重新决定 host 生命周期；单一入口也让
   `status/stop/version/host` 子命令共享同一状态目录解析。

2. **本地机器是加法式协议扩展，不改 M1–M6 语义。**
   `machine.add` 新增可选 `kind`（`ssh` 默认，`local`）。`kind=local` 的记录
   使用进程内本地 Provider 和本地能力 profile，不需要 `ssh`；SSH 记录与
   现有字段/默认值完全不变。host 的 Agent/Workspace 判断从
   `machine_id == ""` 改为 `machine_is_local(machine_id)`（空或 local 记录），
   因此注册的本地机器可以承载 Agent 与 Workspace，而不把本地执行伪装成
   SSH。

3. **首次运行布局由 host 建立。**
   host 在发布 `host.json` 之前创建 `<state>/agents`、`artifacts`、`logs`、
   `monexus.db` 与 `examples/hello-workspace`（README.md、AGENTS.md，git
   可用时 best-effort init/commit）。已存在文件永不覆盖；缺少 git 只损失
   示例仓库初始化，不阻止 host 启动。`host.json` 仍以临时文件 + rename、
   0600 发布。

4. **打包布局与版本。**
   仓库根 `VERSION` 与 `packages/contracts/version.mbt::PRODUCT_VERSION`
   必须一致（0.1.0）；`scripts/package.sh` 校验后构建
   `moon build --target native --release`，产物固定为
   `_build/native/release/build/monexus/host/host.exe` 与
   `.../desktop/linux_skia/linux_skia.exe`。安装布局为：

   ```
   bin/monexus  bin/monexus-host  bin/monexus-desktop
   share/monexus/{VERSION,README.md,docs/,examples/workspace/}
   ```

   发布物是 `dist/monexus-0.1.0-<os>-<arch>.tar.gz` 与同名 `.sha256`；脚本在
   打包前验证暂存目录中的 launcher、host、desktop `--version` 均可运行。
   `monexus version` 输出 `monexus 0.1.0` 与两个组件的版本行。Linux x86_64
   是 V0.1 验证平台；脚本的 OS/ARCH 识别不构成 macOS 产品验证。

5. **设置页只显示 token 状态。**
   桌面 Settings 显示连接状态、host 地址、token 是否存在、版本、数据目录、
   host id 与最后错误；token 值只留在 `host.json`（0600），launcher、日志、
   事件与验收输出都不打印它。

6. **验收以安装产物为准，环境替代显式标注。**
   `scripts/acceptance.sh` 在临时 `HOME` 下构建并解包发布包，用安装后的
   `bin/monexus*` 跑 P0 + 八项 V0.1 流程。无真实远端时使用一次性 loopback
   sshd（临时 host/client key、临时 known_hosts，真实 `~/.ssh` 不被修改）；
   不可达 SSH 用可切换断线的 fake `ssh`；桌面重连在无物理显示时用
   `xvfb-run` 跑真实窗口。真实 ACP 仅在 `M7_REAL_ACP=1` 时探测，未登录则
   记为 SKIP，不伪装为通过。脚本输出 PASS/FAIL/SKIP 表与非零失败码。

## 后果

- 正面：无显示/纯 host 场景有单一入口；复用 host 不需要桌面；打包与版本
  可重复；首次运行可立即打开示例 Workspace；验收在干净 HOME 下端到端
  可执行，并且不接触外部机器。
- 代价/边界：启动器是 POSIX shell，只验证 Linux；host-first 与 §7.2 原文
  不一致，因此本 ADR 高于该句描述，keepAlive/单实例/`host.json` 契约不变。
  `kind` 是新增字段，旧 SSH 记录与默认行为保持兼容；本地记录的 profile
  不是远端探测结果。打包不含 auto-update、签名或 macOS 验证。
- 后续：若把 host 生命周期改回桌面托管，需要同时保留 headless 入口和
  `--no-keep-alive` 语义，并另写 ADR 替换本决策。

## 补充（2026-11-27）：macOS 支持

决策 4 与“只验证 Linux”的边界按以下方式扩展，原决策其余内容不变：

- `apps/desktop/macos_skia/` 是 macOS 原生入口，使用 MoUI `backend/macos`、
  `NativeGpuPlatform::MacOS` 与 AppKit；不链接 Vulkan/X11/Wayland。
  `scripts/monexus.sh` 按 `uname -s` 选择 `linux_skia` 或 `macos_skia`，
  `scripts/package.sh` 的固定产物路径相应参数化。
- 发布物仍为 `dist/monexus-0.1.0-<os>-<arch>.tar.gz`，macOS 使用
  `shasum -a 256` 生成/校验 `.sha256`，并在 tar 时设置
  `COPYFILE_DISABLE=1` 避免 AppleDouble 元数据。安装布局与 `--version`
  自检不变。
- 已验证：macOS 26.3 / aarch64 上 debug/release 构建、`moon test --target
  native` 524/524、`scripts/package.sh`、`scripts/host_smoke.sh`、安装后
  launcher 的 `start --headless`/`status`/`stop`。macOS x86_64 未单独验证。
  macOS 窗口需要登录的 GUI session；CI runner 无 GUI，只构建不启动窗口。
  `scripts/acceptance.sh` 的 loopback sshd + `xvfb-run` 路径仍只适用于
  Linux。
- 打包仍不含 auto-update、签名或公证（notarization）。
