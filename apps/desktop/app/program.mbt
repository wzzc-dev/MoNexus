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
/// Program built from environment preferences only. Tests and screenshot
/// scenes use this; the desktop entry point uses `program_with_preferences`
/// with the resolved saved choices.
pub fn program() -> @moui.Program[Model, Msg] {
  program_with_preferences(
    startup_theme_from_env(),
    startup_language_from_env(),
  )
}

///|
pub fn program_with_startup(startup : StartupTheme) -> @moui.Program[Model, Msg] {
  program_with_preferences(startup, startup_language_from_env())
}

///|
pub fn program_with_preferences(
  startup : StartupTheme,
  language : StartupLanguage,
) -> @moui.Program[Model, Msg] {
  @moui.Program::new_with_environment(
    init=() => {
      (
        Model::new_with_preferences(startup, language),
        @moui.Effect::batch([
          @moui.Effect::run(
            key="host-link-dispatch",
            kind="host-link",
            label="Capture UI dispatch for the host link",
            run=dispatch => dispatch_cell.val = Some(dispatch),
          ),
          @moui.Effect::run(
            key="float-workspace-restore",
            kind="float-workspace",
            label="Restore the floating workspace notes",
            run=dispatch => float_capture_dispatch(dispatch),
          ),
        ]),
      )
    },
    update=(model, msg) => {
      let (next, commands) = update_full(model, msg)
      let effects : Array[@moui.Effect[Msg]] = []
      if !commands.is_empty() {
        effects.push(
          @moui.Effect::run(
            key="machine-commands",
            kind="machine-command",
            label="Queue machine command",
            run= _dispatch => {
              for command in commands {
                enqueue_machine_command(command)
              }
            },
          ),
        )
      }
      match msg {
        SetTheme(mode) =>
          effects.push(
            @moui.Effect::run(
              key="theme-preference",
              kind="theme-preference",
              label="Persist appearance choice",
              run= _dispatch => enqueue_theme_choice(mode),
            ),
          )
        SetLanguage(lang) =>
          effects.push(
            @moui.Effect::run(
              key="language-preference",
              kind="language-preference",
              label="Persist language choice",
              run= _dispatch => enqueue_language_choice(lang),
            ),
          )
        FloatNoteContentDraft(_) | FloatNoteTitleDraft(_) | FloatNewNote |
        ToggleFloatWorkspace | CloseFloatWorkspace | FloatSelectTab(_) |
        FloatCloseTab(_) | FloatNewAgent | FloatNewTerminal | FloatMenu(_) |
        FloatHeaderDrag(_, _, _) | FloatResizeDrag(_, _, _) => {
          let requests = float_persist_requests(next.float, msg)
          if !requests.is_empty() {
            effects.push(
              @moui.Effect::run(
                key="float-workspace-persist",
                kind="float-workspace",
                label="Persist floating workspace state",
                run= _dispatch => {
                  for request in requests {
                    match request {
                      FloatNoteRequest(write) => enqueue_float_note(write)
                      FloatStateRequest(text) => enqueue_float_state(text)
                      FloatRestoreRequest => enqueue_float_restore()
                    }
                  }
                },
              ),
            )
          }
        }
        _ => ()
      }
      let effect = if effects.is_empty() {
        @moui.Effect::none()
      } else if effects.length() == 1 {
        effects[0]
      } else {
        @moui.Effect::batch(effects)
      }
      (next, effect)
    },
    view=(model, environment) => view(model, environment),
    subscriptions=fn(model) {
      @moui.Subscription::batch([
        terminal_poll_subscription(model),
        chat_poll_subscription(model),
      ])
    },
  ).with_commands(commands=model => {
    [
      @core.ProgramCommand::new(
        command=@core.ActionCommand::new(
          intent=@core.Copy,
          label=tr(model.lang, "Interrupt terminal", "中断终端"),
          shortcut=Some(
            @core.KeyboardShortcut::new(
              key="c",
              modifiers=@core.KeyModifiers::new(control=true, shift=true),
            ),
          ),
          description=tr(
            model.lang,
            "Send Ctrl+C to the focused terminal.",
            "向当前终端发送 Ctrl+C。",
          ),
        ),
        message=ProjectTerminalStop,
      ),
      @core.ProgramCommand::new(
        command=@core.ActionCommand::new(
          intent=@core.Copy,
          label=tr(model.lang, "Interrupt terminal", "中断终端"),
          shortcut=Some(
            @core.KeyboardShortcut::new(
              key="C",
              modifiers=@core.KeyModifiers::new(control=true, shift=true),
            ),
          ),
          description=tr(
            model.lang,
            "Send Ctrl+C to the focused terminal.",
            "向当前终端发送 Ctrl+C。",
          ),
        ),
        message=ProjectTerminalStop,
      ),
    ]
  })
}
