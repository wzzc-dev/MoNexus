///|
/// Dispatch captured during init so the host-link worker can feed messages
/// into the TEA loop from a background async task. The desktop is a single
/// window per process, so one module-level cell is sufficient for M1.
let dispatch_cell : Ref[((Msg) -> Unit)?] = Ref(None)

///|
pub fn dispatch_ready() -> Bool {
  match dispatch_cell.val {
    Some(_) => true
    None => false
  }
}

///|
pub fn program() -> @moui.Program[Model, Msg] {
  @moui.Program::new(
    init=() => {
      (
        Model::new(),
        @moui.Effect::run(
          key="host-link-dispatch",
          kind="host-link",
          label="Capture UI dispatch for the host link",
          run=dispatch => dispatch_cell.val = Some(dispatch),
        ),
      )
    },
    update=(model, msg) => {
      let (next, commands) = update_full(model, msg)
      let effect = if commands.is_empty() {
        @moui.Effect::none()
      } else {
        @moui.Effect::run(
          key="machine-commands",
          kind="machine-command",
          label="Queue machine command",
          run= _dispatch => {
            for command in commands {
              enqueue_machine_command(command)
            }
          },
        )
      }
      (next, effect)
    },
    view~,
    subscriptions=_model => @moui.Subscription::none(),
  )
}
