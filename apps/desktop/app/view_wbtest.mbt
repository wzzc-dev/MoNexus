///|
fn sidebar_test_chat(
  id : String,
  bot_id : String,
  updated_at : String,
) -> ChatProjection {
  {
    id,
    bot_id,
    title: id,
    state: "idle",
    updated_at,
    project_id: "",
    agent_session_id: "",
  }
}

///|
test "the sidebar keeps the active Chat and Bot beyond the recency cut" {
  let bots = [
    @contracts.BotRecord::new(
      id="bot_0",
      org_id="org_1",
      name="Ada",
      created_at="2026-01-01T00:00:00Z",
    ),
    @contracts.BotRecord::new(
      id="bot_1",
      org_id="org_1",
      name="Ben",
      created_at="2026-01-01T00:00:00Z",
    ),
    @contracts.BotRecord::new(
      id="bot_2",
      org_id="org_1",
      name="Cy",
      created_at="2026-01-01T00:00:00Z",
    ),
    @contracts.BotRecord::new(
      id="bot_3",
      org_id="org_1",
      name="Di",
      created_at="2026-01-01T00:00:00Z",
    ),
  ]
  let chats = [
    sidebar_test_chat("chat_3", "bot_0", "2026-01-04T00:00:00Z"),
    sidebar_test_chat("chat_2", "bot_0", "2026-01-03T00:00:00Z"),
    sidebar_test_chat("chat_1", "bot_0", "2026-01-02T00:00:00Z"),
    sidebar_test_chat("chat_0", "bot_0", "2026-01-01T00:00:00Z"),
  ]
  let model = update(
    update(Model::new(), BotsLoaded(bots)),
    ChatsLoaded(chats),
  )
  let model = update(model, SelectChat("chat_0"))
  let model = update(model, OpenBotDetail("bot_3"))
  let chat_rows = sidebar_chat_projection_rows(model)
  assert_eq(chat_rows.length(), 3)
  assert_true(chat_rows.any(row => row.id == "chat_0"))
  assert_true(chat_rows.any(row => row.id == "chat_3"))
  assert_false(chat_rows.any(row => row.id == "chat_1"))
  let bot_rows = sidebar_bot_projection_rows(model)
  assert_eq(bot_rows.length(), 3)
  assert_true(bot_rows.any(row => row.id == "bot_3"))
  assert_true(bot_rows.any(row => row.id == "bot_0"))
  assert_false(bot_rows.any(row => row.id == "bot_2"))
}
