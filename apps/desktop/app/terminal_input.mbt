///|
/// Terminal command input with a plain Ctrl+C interrupt.
///
/// MoUI 0.10.2 maps unmodified Ctrl+C to `CommandIntent::Interrupt`, while
/// Cmd+C, Ctrl+Shift+C and Ctrl+Insert stay `Copy`. This wrapper keeps the
/// text field's editing, selection, clipboard and accessibility behavior, and
/// turns only Interrupt into `ProjectTerminalStop`. Copy always delegates to
/// the field, with or without a selection.
priv struct TerminalInputField {
  child : @core.View[Msg]
}

///|
impl @core.ViewNode for TerminalInputField with fn identity(self) {
  self.child.identity()
}

///|
impl @core.ViewNode for TerminalInputField with fn declaration(
  self,
) {
  self.child.declaration()
}

///|
impl @core.ViewNode for TerminalInputField with fn child_constraints(
  self,
  constraints,
) {
  self.child.child_constraints(constraints)
}

///|
impl @core.ViewNode for TerminalInputField with fn child_environment(
  self,
  environment,
) {
  self.child.child_environment(environment)
}

///|
impl @core.ViewNode for TerminalInputField with fn child_style(
  self,
  style,
) {
  self.child.child_style(style)
}

///|
impl @core.ViewNode for TerminalInputField with fn layout(
  self,
  context,
) {
  self.child.layout(context)
}

///|
impl @core.ViewNode for TerminalInputField with fn place_overlays(
  self,
  context,
) {
  self.child.place_overlays(context)
}

///|
impl @core.ViewNode for TerminalInputField with fn paint(
  self,
  context,
) {
  self.child.paint(context)
}

///|
impl @core.ViewNode for TerminalInputField with fn platform_views(
  self,
  context,
) {
  self.child.platform_views(context)
}

///|
impl @core.ViewNode for TerminalInputField with fn text_input_state(
  self,
  context,
) {
  self.child.text_input_state(context)
}

///|
impl @core.ViewNode for TerminalInputField with fn semantics(self) {
  self.child.semantics()
}

///|
impl @core.ViewNode for TerminalInputField with fn drag_declaration(
  self,
) {
  self.child.drag_declaration()
}

///|
impl @core.ViewNode for TerminalInputField with fn focusable(self) {
  self.child.accepts_focus()
}

///|
impl @core.ViewNode for TerminalInputField with fn focus_trap(self) {
  self.child.traps_focus()
}

///|
impl @core.ViewNode for TerminalInputField with fn keyboard_policy(
  self,
) {
  self.child.keyboard_policy()
}

///|
impl @core.ViewNode for TerminalInputField with fn flex_weight(self) {
  self.child.flex_weight()
}

///|
impl @core.ViewNode for TerminalInputField with fn pointer_cursor(
  self,
) {
  self.child.pointer_cursor()
}

///|
/// Forward every advertised semantics action to the wrapped text field, so
/// assistive input (set text, set selection, submit) keeps working.
fn terminal_input_semantics_actions(
  child : @core.View[Msg],
) -> Array[@core.ViewSemanticsActionHandler[Msg]] {
  let handlers : Array[@core.ViewSemanticsActionHandler[Msg]] = []
  for kind in child.semantics_action_kinds() {
    match kind {
      Activate =>
        handlers.push(
          @core.ViewSemanticsActionHandler::activate(context => {
            child.dispatch_semantics_action(
              context,
              @core.SemanticsAction::Activate,
            )
          }),
        )
      SetText =>
        handlers.push(
          @core.ViewSemanticsActionHandler::set_text((context, value) => {
            child.dispatch_semantics_action(
              context,
              @core.SemanticsAction::SetText(value),
            )
          }),
        )
      Submit =>
        handlers.push(
          @core.ViewSemanticsActionHandler::submit(context => {
            child.dispatch_semantics_action(
              context,
              @core.SemanticsAction::Submit,
            )
          }),
        )
      Scroll =>
        handlers.push(
          @core.ViewSemanticsActionHandler::scroll((context, direction) => {
            child.dispatch_semantics_action(
              context,
              @core.SemanticsAction::Scroll(direction),
            )
          }),
        )
      Select =>
        handlers.push(
          @core.ViewSemanticsActionHandler::select(context => {
            child.dispatch_semantics_action(
              context,
              @core.SemanticsAction::Select,
            )
          }),
        )
      Expand =>
        handlers.push(
          @core.ViewSemanticsActionHandler::expand(context => {
            child.dispatch_semantics_action(
              context,
              @core.SemanticsAction::Expand,
            )
          }),
        )
      Collapse =>
        handlers.push(
          @core.ViewSemanticsActionHandler::collapse(context => {
            child.dispatch_semantics_action(
              context,
              @core.SemanticsAction::Collapse,
            )
          }),
        )
      Dismiss =>
        handlers.push(
          @core.ViewSemanticsActionHandler::dismiss(context => {
            child.dispatch_semantics_action(
              context,
              @core.SemanticsAction::Dismiss,
            )
          }),
        )
      Increment =>
        handlers.push(
          @core.ViewSemanticsActionHandler::increment(context => {
            child.dispatch_semantics_action(
              context,
              @core.SemanticsAction::Increment,
            )
          }),
        )
      Decrement =>
        handlers.push(
          @core.ViewSemanticsActionHandler::decrement(context => {
            child.dispatch_semantics_action(
              context,
              @core.SemanticsAction::Decrement,
            )
          }),
        )
      SetNumericValue =>
        handlers.push(
          @core.ViewSemanticsActionHandler::set_numeric_value(
            (context, value) => {
              child.dispatch_semantics_action(
                context,
                @core.SemanticsAction::SetNumericValue(value),
              )
            },
          ),
        )
      SetSelection =>
        handlers.push(
          @core.ViewSemanticsActionHandler::set_selection((context, range) => {
            child.dispatch_semantics_action(
              context,
              @core.SemanticsAction::SetSelection(range),
            )
          }),
        )
      ShowMenu =>
        handlers.push(
          @core.ViewSemanticsActionHandler::show_menu(context => {
            child.dispatch_semantics_action(
              context,
              @core.SemanticsAction::ShowMenu,
            )
          }),
        )
      Focus => ()
    }
  }
  handlers
}

///|
fn terminal_input_field(
  child : @core.View[Msg],
) -> @core.View[Msg] {
  let node : TerminalInputField = { child, }
  @core.View::from_node(
    node,
    event=(node, context) => node.child.event(context),
    text_command=(node, context, intent, paste_text) => {
      match intent {
        @core.CommandIntent::Interrupt =>
          @core.ViewTextCommandResult::new(
            result=@core.TextCommandResult::handled(),
            messages=[ProjectTerminalStop],
          )
        _ => node.child.text_command_result(context, intent, paste_text~)
      }
    },
    semantics_actions=node => terminal_input_semantics_actions(node.child),
  )
}
