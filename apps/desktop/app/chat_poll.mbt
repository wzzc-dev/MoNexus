///|
/// The Chat surface polls `chat.messages` and `chat.read` on the same 250ms
/// cadence as the project terminal. The subscription is model-driven, so a
/// route change or a new-Chat draft cancels the timer instead of leaking host
/// reads into another page.
let chat_poll_interval_ms : Int32 = 250

///|
let chat_poll_dispatch : Ref[((Msg) -> Unit)?] = Ref(None)

///|
let chat_poll_generation : Ref[Int32] = Ref(0)

///|
fn chat_should_poll(model : Model) -> Bool {
  model.page == Workroom &&
  !model.composing_new_chat &&
  model.selected_chat != "" &&
  model.chat_messages_chat == model.selected_chat &&
  model.chat_get_chat == "" &&
  model.chat_messages_loaded
}

///|
pub async fn chat_poll_loop() -> Unit {
  for ;; {
    @async.sleep(chat_poll_interval_ms)
    match chat_poll_dispatch.val {
      Some(dispatch) => dispatch(ChatPoll)
      None => ()
    }
  }
}

///|
fn chat_poll_subscription(model : Model) -> @moui.Subscription[Msg] {
  if !chat_should_poll(model) {
    return @moui.Subscription::none()
  }
  @moui.Subscription::timer(
    key="chat-cursor-poll",
    label="Poll selected Chat transcript",
    start=dispatch => {
      let generation = chat_poll_generation.val + 1
      chat_poll_generation.val = generation
      chat_poll_dispatch.val = Some(dispatch)
      Some(fn() {
        // A stale unmount must not clear the dispatch owned by the next Chat.
        if chat_poll_generation.val == generation {
          chat_poll_dispatch.val = None
        }
      })
    },
  )
}
