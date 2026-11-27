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
    "A display server is required for the window (Wayland or X11).",
  ].join("\n")
}

///|
/// Linux native entry. The host-link worker runs beside the MoUI window task;
/// the task group cancels the worker when the window closes.
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
  let has_display = match @env.get_env_var("DISPLAY") {
    Some(value) if value != "" => true
    _ =>
      match @env.get_env_var("WAYLAND_DISPLAY") {
        Some(value) if value != "" => true
        _ => false
      }
  }
  if !has_display {
    println(
      "monexus-desktop: no display server found (DISPLAY and WAYLAND_DISPLAY are unset).\n" +
      "Run `monexus start --headless` on this machine, or open the window under a\n" +
      "display server (for example `xvfb-run -a monexus-desktop`).\n" +
      "Build/test headless checks: moon test --target native -p monexus/desktop/app",
    )
    @env.exit(3)
  }
  // Resolve the startup appearance before building the model: a saved
  // Settings choice wins over MONEXUS_THEME, which in turn beats the dark
  // default. A missing/corrupt file is reported on the Settings page, never a
  // startup failure.
  let startup_theme = @app.startup_theme()
  let startup_language = @app.startup_language()
  // 1280x800 keeps the Tasks/Inbox/Agents bodies and buttons on screen; long
  // pages scroll inside the shell viewport (see app/view.mbt).
  let runtime = @runtime.new_program_with_dimensions(
    program=@app.program_with_preferences(startup_theme, startup_language),
    width=1280.0,
    height=800.0,
  )
  let window_task : async () -> Unit = async fn() {
    @apphost.run_app("MoNexus", runtime)
    .render_all(
      @render_skia.from_env(platform=@render_skia.NativeGpuPlatform::Linux),
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
    window_task()
  })
}
