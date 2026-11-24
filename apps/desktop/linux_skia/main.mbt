///|
/// Linux native entry. The host-link worker runs beside the MoUI window task;
/// the task group cancels the worker when the window closes.
async fn main {
  let runtime = @runtime.new_program_with_dimensions(
    program=@app.program(),
    width=920.0,
    height=560.0,
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
  @async.with_task_group(async fn(group) {
    group.spawn_bg(
      no_wait=true,
      allow_failure=true,
      worker_task,
    )
    window_task()
  })
}
