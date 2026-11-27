///|
fn wb_bot(id : String, name : String) -> @contracts.BotRecord {
  @contracts.BotRecord::new(
    id~,
    org_id="org_1",
    name~,
    created_at="2026-01-01T00:00:00Z",
  )
}

///|
fn wb_chat(
  id : String,
  bot_id : String,
  title : String,
  project_id : String,
  updated_at : String,
) -> @contracts.ChatDetail {
  let chat = @contracts.ChatRecord::new(
    id~,
    org_id="org_1",
    title~,
    created_at="2026-01-01T00:00:00Z",
    project_id~,
  )
  @contracts.ChatDetail::new(
    chat={ ..chat, updated_at },
    participants=[
      @contracts.ChatParticipant::new(
        chat_id=id,
        bot_id~,
        added_at="2026-01-01T00:00:00Z",
      ),
    ],
  )
}

///|
test "project Chat filters exclude no-project Chats and unknown Bot membership" {
  let bot_a = wb_bot("bot_a", "Ada")
  let bot_b = wb_bot("bot_b", "Beta")
  let project_chat = wb_chat(
    "chat_p1",
    "bot_a",
    "Release chat",
    "prj_1",
    "2026-01-02T00:00:00Z",
  )
  let other_project = wb_chat(
    "chat_p2",
    "bot_b",
    "Other project chat",
    "prj_2",
    "2026-01-03T00:00:00Z",
  )
  let no_project = wb_chat(
    "chat_none",
    "bot_a",
    "Scratch chat",
    "",
    "2026-01-04T00:00:00Z",
  )
  let model = update(Model::new(), BotsLoaded([bot_a, bot_b]))
  let model = update(
    model,
    ChatsLoaded([project_chat, other_project, no_project]),
  )
  let chats = project_chats_filtered(model, "prj_1", "")
  assert_eq(chats.length(), 1)
  assert_eq(chats[0].id, "chat_p1")
  assert_eq(project_chats_filtered(model, "prj_1", "bot_b").length(), 0)
  assert_eq(project_chats_filtered(model, "prj_1", "bot_a").length(), 1)
  let members = bots_in_project(model, "prj_1")
  assert_eq(members.length(), 1)
  assert_eq(members[0].id, "bot_a")
  assert_eq(bots_in_project(model, "prj_2")[0].id, "bot_b")
  let no_project_members = bots_in_project(model, PROJECT_FILTER_NONE)
  assert_eq(no_project_members.length(), 1)
  assert_eq(no_project_members[0].id, "bot_a")
  let no_project_chats = project_chats_filtered(model, "prj_1", "")
  for chat in no_project_chats {
    assert_true(chat.project_id != "")
  }
  assert_true(chat_matches_project_filter(
    chat_projection_from_detail(no_project),
    PROJECT_FILTER_NONE,
  ))
  assert_false(chat_matches_project_filter(
    chat_projection_from_detail(no_project),
    "prj_1",
  ))
}

///|
test "pending Chat decision label keeps the raw Decision id out of the UI" {
  let model = {
    ..Model::new(),
    chat_pending_decision: "dec_1",
  }
  let label = chat_pending_label(model)
  assert_true(label.contains("Owner Decision required"))
  assert_false(label.contains("dec_1"))
}
