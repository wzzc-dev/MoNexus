///|
fn desktop_usage() -> String {
  [
    "usage: monexus-desktop [--version] [--help]",
    "",
    "Opens the MoNexus window and connects to the host described by",
    "$MONEXUS_STATE_DIR/host.json (default $HOME/.monexus). Start or reuse a",
    "host first:",
    "  monexus start            # launcher: host + desktop",
    "  monexus start --headless # no display: host only",
    "",
    "The macOS entry uses AppKit through the MoUI macOS backend; a GUI login",
    "session is required for the window (SSH-only sessions should use",
    "`monexus start --headless`).",
  ].join("\n")
}

///|
/// macOS native entry. The host-link workers run beside the MoUI window task;
/// the task group cancels them when the window closes.
async fn main {
  let args = @env.args()
  let command = if args.length() > 1 { args[1] } else { "" }
  match command {
    "--version" | "version" | "-V" => {
      println(@contracts.product_version_line("monexus-desktop"))
      return
    }
    "--help" | "-h" | "help" => {
      println(desktop_usage())
      return
    }
    _ => ()
  }
  // Resolve the startup appearance before building the model: a saved
  // Settings choice wins over MONEXUS_THEME, which in turn beats the dark
  // default. A missing/corrupt file is reported on the Settings page, never a
  // startup failure.
  let startup_theme = @app.startup_theme()
  let startup_language = @app.startup_language()
  // Match the Linux entry's 1280x800 viewport so both desktop builds share the
  // same layout and screenshot baselines.
  let runtime = @runtime.new_program_with_dimensions(
    program=@app.program_with_preferences(startup_theme, startup_language),
    width=1280.0,
    height=800.0,
  )
  let window_task : async () -> Unit = async fn() {
    @apphost.run_app("MoNexus", runtime)
    .render_all(
      @render_skia.from_env(platform=@render_skia.NativeGpuPlatform::MacOS),
    )
    .backend(@platform_host.entry())
    .run_async_pump()
  }
  let worker_task : async () -> Unit = async fn() {
    @app.host_link_loop(@client.default_state_dir())
  }
  let machine_task : async () -> Unit = async fn() {
    @app.machine_command_loop(@client.default_state_dir())
  }
  let stream_task : async () -> Unit = async fn() {
    @app.agent_stream_loop(@client.default_state_dir())
  }
  let theme_task : async () -> Unit = async fn() {
    @app.theme_choice_loop()
  }
  let language_task : async () -> Unit = async fn() {
    @app.language_choice_loop()
  }
  let terminal_poll_task : async () -> Unit = async fn() {
    @app.terminal_poll_loop()
  }
  let chat_poll_task : async () -> Unit = async fn() {
    @app.chat_poll_loop()
  }
  @async.with_task_group(async fn(group) {
    group.spawn_bg(
      no_wait=true,
      allow_failure=true,
      worker_task,
    )
    group.spawn_bg(
      no_wait=true,
      allow_failure=true,
      machine_task,
    )
    group.spawn_bg(
      no_wait=true,
      allow_failure=true,
      stream_task,
    )
    group.spawn_bg(
      no_wait=true,
      allow_failure=true,
      theme_task,
    )
    group.spawn_bg(
      no_wait=true,
      allow_failure=true,
      language_task,
    )
    group.spawn_bg(
      no_wait=true,
      allow_failure=true,
      terminal_poll_task,
    )
    group.spawn_bg(
      no_wait=true,
      allow_failure=true,
      chat_poll_task,
    )
    window_task()
  })
}
