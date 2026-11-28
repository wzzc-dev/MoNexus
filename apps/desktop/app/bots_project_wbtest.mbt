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
fn wb_membership(
  project_id : String,
  bot_id : String,
  state : String,
) -> @contracts.ProjectMembership {
  @contracts.ProjectMembership::new(
    project_id~,
    bot_id~,
    added_at="2026-01-01T00:00:00Z",
    access=[],
    state~,
  )
}

///|
fn wb_project(id : String, name : String) -> @contracts.ProjectRecord {
  @contracts.ProjectRecord::new(
    id~,
    name~,
    repo_url="",
    default_branch="main",
    verify=[],
    created_at="2026-01-01T00:00:00Z",
  )
}

///|
test "project filters use active membership, not Chat participants" {
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
  // A Project Chat participant is not membership evidence.
  assert_true(bots_in_project(model, "prj_1").is_empty())
  assert_true(bots_in_project(model, "prj_2").is_empty())
  let model = update(
    model,
    ProjectMembershipsLoaded([
      wb_membership("prj_1", "bot_b", @contracts.MEMBERSHIP_STATE_ACTIVE),
      wb_membership("prj_2", "bot_b", @contracts.MEMBERSHIP_STATE_ACTIVE),
      wb_membership("prj_1", "bot_a", @contracts.MEMBERSHIP_STATE_REMOVED),
    ]),
  )
  let chats = project_chats_filtered(model, "prj_1", "")
  assert_eq(chats.length(), 1)
  assert_eq(chats[0].id, "chat_p1")
  assert_eq(project_chats_filtered(model, "prj_1", "bot_b").length(), 0)
  assert_eq(project_chats_filtered(model, "prj_1", "bot_a").length(), 1)
  let members = bots_in_project(model, "prj_1")
  assert_eq(members.length(), 1)
  assert_eq(members[0].id, "bot_b")
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
test "Project membership add and remove reconcile the New Chat draft by name" {
  let bot_a = wb_bot("bot_a", "Ada")
  let bot_b = wb_bot("bot_b", "Beta")
  let project = wb_project("prj_1", "Release")
  let model = update(Model::new(), BotsLoaded([bot_a, bot_b]))
  let model = update(model, ProjectCatalogLoaded([project]))
  let model = update(model, SelectProject("prj_1"))
  let model = update(model, ProjectMembershipsLoaded([]))
  let before = update(model, NewChat)
  assert_eq(before.chat_draft.bot_id, "")
  assert_true(before.chat_draft.message.contains("no Bot members"))
  assert_false(before.chat_draft.message.contains("membership evidence"))
  let (drafting, add_commands) = update_full(
    before,
    AddProjectMembership("prj_1", "bot_a"),
  )
  assert_eq(drafting.project_membership_message, "")
  match add_commands {
    [ProjectMembershipAdd(project_id, bot_id)] => {
      assert_eq(project_id, "prj_1")
      assert_eq(bot_id, "bot_a")
    }
    _ => fail("expected one ProjectMembershipAdd command")
  }
  let added = update(
    drafting,
    ProjectMembershipAdded(
      wb_membership("prj_1", "bot_a", @contracts.MEMBERSHIP_STATE_ACTIVE),
    ),
  )
  assert_eq(added.chat_draft.bot_id, "bot_a")
  assert_eq(added.project_membership_message.contains("Ada"), true)
  assert_eq(added.project_membership_message.contains("Release"), true)
  assert_eq(added.project_membership_message.contains("bot_a"), false)
  assert_eq(bots_in_project(added, "prj_1")[0].id, "bot_a")
  let (revoking, remove_commands) = update_full(
    added,
    RemoveProjectMembership("prj_1", "bot_a"),
  )
  match remove_commands {
    [ProjectMembershipRemove(project_id, bot_id, reason)] => {
      assert_eq(project_id, "prj_1")
      assert_eq(bot_id, "bot_a")
      assert_eq(reason, "owner request")
    }
    _ => fail("expected one ProjectMembershipRemove command")
  }
  let removed = update(
    revoking,
    ProjectMembershipRemoved(
      wb_membership("prj_1", "bot_a", @contracts.MEMBERSHIP_STATE_REMOVED),
    ),
  )
  assert_true(bots_in_project(removed, "prj_1").is_empty())
  assert_eq(removed.chat_draft.bot_id, "")
  assert_true(removed.chat_draft.message.contains("no Bot members"))
  assert_eq(removed.project_membership_message.contains("Ada"), true)
  assert_eq(removed.project_membership_message.contains("bot_a"), false)
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
