///|
/// ADR-0017 P0.2 Bot / Agent / Chat / AgentSession / ProjectMembership
/// persistence.
///
/// Every row is a projection with cheap filter columns plus the complete
/// contract record as JSON. The append-only `events` table remains the single
/// authority: domain commands append one event and its projection in one
/// transaction, and startup replay rebuilds the tables from the log alone.
///
/// `agent_sessions` is shared with the legacy M4 runtime-session table. Canonical
/// ADR-0017 rows carry `record_kind='chat_agent_session'`; legacy rows keep the
/// default `runtime` value, so the old `agent.start/send/read` session queries
/// and the new Bot/Chat session queries never observe each other.

// ---------------------------------------------------------------------------
// Public constants and helper types
// ---------------------------------------------------------------------------

///|
pub const LEGACY_ALIAS_AGENT_IDENTITY : String = "agent_identity"

///|
pub const LEGACY_ALIAS_AGENT_SESSION : String = "agent_session"

///|
pub const LEGACY_ALIAS_ARCHITECTURE_SESSION : String = "architecture_session"

///|
pub const LEGACY_CANONICAL_BOT : String = "bot"

///|
pub const LEGACY_CANONICAL_AGENT_SESSION : String = "agent_session"

///|
pub const BOT_SESSION_RECORD_KIND : String = "chat_agent_session"

///|
pub const LEGACY_RUNTIME_RECORD_KIND : String = "runtime"

///|
pub(all) struct LegacyAliasTarget {
  canonical_kind : String
  canonical_id : String
}

///|
pub(all) struct BotsReconcileCounts {
  bots : Int
  agents : Int
  chats : Int
  participants : Int
  sessions : Int
  memberships : Int
}

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

///|
fn bots_store_add_column(
  conn : @sqlite3.Connection,
  table : String,
  column : String,
  decl : String,
) -> Unit raise @sqlite3.SqliteError {
  let _ = try {
    exec_raise(
      conn,
      "ALTER TABLE " + table + " ADD COLUMN " + column + " " + decl,
    )
  } catch {
    _ => ()
  }
}

///|
fn bots_store_migrate(
  conn : @sqlite3.Connection,
) -> Unit raise @sqlite3.SqliteError {
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS bots (" +
    "id TEXT PRIMARY KEY, " +
    "org_id TEXT NOT NULL, " +
    "name TEXT NOT NULL, " +
    "persona_ref TEXT NOT NULL DEFAULT '', " +
    "instructions_ref TEXT NOT NULL DEFAULT '', " +
    "memory_ref TEXT NOT NULL DEFAULT '', " +
    "home TEXT NOT NULL DEFAULT '', " +
    "permission_ceiling_json TEXT NOT NULL DEFAULT '[]', " +
    "create_policy TEXT NOT NULL DEFAULT 'ask', " +
    "agent_count_cap INTEGER NOT NULL DEFAULT 8, " +
    "agent_concurrency_cap INTEGER NOT NULL DEFAULT 1, " +
    "software_allowlist_json TEXT NOT NULL DEFAULT '[]', " +
    "state TEXT NOT NULL, " +
    "record_json TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE UNIQUE INDEX IF NOT EXISTS bots_org_name_idx " +
    "ON bots(org_id,name)",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS bots_state_idx ON bots(state)",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS agents (" +
    "id TEXT PRIMARY KEY, " +
    "org_id TEXT NOT NULL, " +
    "bot_id TEXT NOT NULL, " +
    "name TEXT NOT NULL, " +
    "specialty TEXT NOT NULL DEFAULT '', " +
    "tags_json TEXT NOT NULL DEFAULT '[]', " +
    "runtime_binding_json TEXT NOT NULL, " +
    "runtime_binding_hash TEXT NOT NULL, " +
    "permission_scope_json TEXT NOT NULL DEFAULT '[]', " +
    "state TEXT NOT NULL, " +
    "record_json TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL, " +
    "retired_at TEXT NOT NULL DEFAULT ''" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS agents_bot_idx ON agents(bot_id)",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS agents_state_idx ON agents(state)",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS chats (" +
    "id TEXT PRIMARY KEY, " +
    "org_id TEXT NOT NULL, " +
    "title TEXT NOT NULL, " +
    "project_id TEXT NOT NULL DEFAULT '', " +
    "summary_ref TEXT NOT NULL DEFAULT '', " +
    "state TEXT NOT NULL, " +
    "record_json TEXT NOT NULL, " +
    "created_at TEXT NOT NULL, " +
    "updated_at TEXT NOT NULL, " +
    "archived_at TEXT NOT NULL DEFAULT ''" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS chats_project_idx ON chats(project_id)",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS chats_state_idx ON chats(state)",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS chat_participants (" +
    "chat_id TEXT NOT NULL, " +
    "bot_id TEXT NOT NULL, " +
    "role TEXT NOT NULL, " +
    "state TEXT NOT NULL, " +
    "added_at TEXT NOT NULL, " +
    "removed_at TEXT NOT NULL DEFAULT '', " +
    "record_json TEXT NOT NULL, " +
    "PRIMARY KEY(chat_id,bot_id)" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS chat_participants_bot_idx " +
    "ON chat_participants(bot_id)",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS chat_participants_state_idx " +
    "ON chat_participants(state)",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS project_memberships (" +
    "project_id TEXT NOT NULL, " +
    "bot_id TEXT NOT NULL, " +
    "state TEXT NOT NULL, " +
    "access_json TEXT NOT NULL DEFAULT '[]', " +
    "reason TEXT NOT NULL DEFAULT '', " +
    "added_at TEXT NOT NULL, " +
    "removed_at TEXT NOT NULL DEFAULT '', " +
    "record_json TEXT NOT NULL, " +
    "PRIMARY KEY(project_id,bot_id)" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS project_memberships_bot_idx " +
    "ON project_memberships(bot_id)",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS project_memberships_state_idx " +
    "ON project_memberships(state)",
  )
  exec_raise(
    conn,
    "CREATE TABLE IF NOT EXISTS legacy_aliases (" +
    "alias_kind TEXT NOT NULL, " +
    "alias_value TEXT NOT NULL, " +
    "canonical_kind TEXT NOT NULL, " +
    "canonical_id TEXT NOT NULL, " +
    "migration_run_id TEXT NOT NULL DEFAULT '', " +
    "created_at TEXT NOT NULL, " +
    "PRIMARY KEY(alias_kind,alias_value)" +
    ")",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS legacy_aliases_canonical_idx " +
    "ON legacy_aliases(canonical_kind,canonical_id)",
  )
  // The canonical AgentSession projection is additive on the legacy M4 table.
  // Older databases get the columns here; fresh databases already created the
  // table in `agent_store_migrate`.
  bots_store_add_column(
    conn,
    "agent_sessions",
    "chat_id",
    "TEXT NOT NULL DEFAULT ''",
  )
  bots_store_add_column(
    conn,
    "agent_sessions",
    "runtime_session_id",
    "TEXT NOT NULL DEFAULT ''",
  )
  bots_store_add_column(
    conn,
    "agent_sessions",
    "permission_snapshot_hash",
    "TEXT NOT NULL DEFAULT ''",
  )
  bots_store_add_column(
    conn,
    "agent_sessions",
    "handoff_from_session_id",
    "TEXT NOT NULL DEFAULT ''",
  )
  bots_store_add_column(
    conn,
    "agent_sessions",
    "record_kind",
    "TEXT NOT NULL DEFAULT 'runtime'",
  )
  exec_raise(
    conn,
    "CREATE INDEX IF NOT EXISTS agent_sessions_chat_idx " +
    "ON agent_sessions(chat_id)",
  )
  exec_raise(
    conn,
    "CREATE UNIQUE INDEX IF NOT EXISTS agent_sessions_active_chat_idx " +
    "ON agent_sessions(chat_id) " +
    "WHERE record_kind='chat_agent_session' AND chat_id<>'' " +
    "AND state IN ('starting','active','waiting','ending')",
  )
}

// ---------------------------------------------------------------------------
// Projection row writers
// ---------------------------------------------------------------------------

///|
fn bot_put_raw(
  conn : @sqlite3.Connection,
  record : @contracts.BotRecord,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO bots (id,org_id,name,persona_ref,instructions_ref,memory_ref," +
    "home,permission_ceiling_json,create_policy,agent_count_cap," +
    "agent_concurrency_cap,software_allowlist_json,state,record_json," +
    "created_at,updated_at) VALUES " +
    "(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16) " +
    "ON CONFLICT(id) DO UPDATE SET org_id=excluded.org_id," +
    "name=excluded.name,persona_ref=excluded.persona_ref," +
    "instructions_ref=excluded.instructions_ref," +
    "memory_ref=excluded.memory_ref,home=excluded.home," +
    "permission_ceiling_json=excluded.permission_ceiling_json," +
    "create_policy=excluded.create_policy," +
    "agent_count_cap=excluded.agent_count_cap," +
    "agent_concurrency_cap=excluded.agent_concurrency_cap," +
    "software_allowlist_json=excluded.software_allowlist_json," +
    "state=excluded.state,record_json=excluded.record_json," +
    "created_at=excluded.created_at,updated_at=excluded.updated_at",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.org_id)
  stmt.bind(index=3, record.name)
  stmt.bind(index=4, record.persona_ref)
  stmt.bind(index=5, record.instructions_ref)
  stmt.bind(index=6, record.memory_ref)
  stmt.bind(index=7, record.home)
  stmt.bind(
    index=8,
    @contracts.json_string_array(record.permission_ceiling).stringify(),
  )
  stmt.bind(index=9, record.create_policy)
  stmt.bind(index=10, record.agent_count_cap.to_int64())
  stmt.bind(index=11, record.agent_concurrency_cap.to_int64())
  stmt.bind(
    index=12,
    @contracts.json_string_array(record.software_allowlist).stringify(),
  )
  stmt.bind(index=13, record.state)
  stmt.bind(index=14, record.to_json().stringify())
  stmt.bind(index=15, record.created_at)
  stmt.bind(index=16, record.updated_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn agent_put_raw(
  conn : @sqlite3.Connection,
  record : @contracts.AgentRecord,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO agents (id,org_id,bot_id,name,specialty,tags_json," +
    "runtime_binding_json,runtime_binding_hash,permission_scope_json,state," +
    "record_json,created_at,updated_at,retired_at) VALUES " +
    "(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14) " +
    "ON CONFLICT(id) DO UPDATE SET org_id=excluded.org_id," +
    "bot_id=excluded.bot_id,name=excluded.name," +
    "specialty=excluded.specialty,tags_json=excluded.tags_json," +
    "runtime_binding_json=excluded.runtime_binding_json," +
    "runtime_binding_hash=excluded.runtime_binding_hash," +
    "permission_scope_json=excluded.permission_scope_json," +
    "state=excluded.state,record_json=excluded.record_json," +
    "created_at=excluded.created_at,updated_at=excluded.updated_at," +
    "retired_at=excluded.retired_at",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.org_id)
  stmt.bind(index=3, record.bot_id)
  stmt.bind(index=4, record.name)
  stmt.bind(index=5, record.specialty)
  stmt.bind(index=6, @contracts.json_string_array(record.tags).stringify())
  stmt.bind(index=7, record.runtime_binding.to_json().stringify())
  stmt.bind(index=8, record.runtime_binding.hash)
  stmt.bind(
    index=9,
    @contracts.json_string_array(record.permission_scope).stringify(),
  )
  stmt.bind(index=10, record.state)
  stmt.bind(index=11, record.to_json().stringify())
  stmt.bind(index=12, record.created_at)
  stmt.bind(index=13, record.updated_at)
  stmt.bind(index=14, record.retired_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn chat_put_raw(
  conn : @sqlite3.Connection,
  record : @contracts.ChatRecord,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO chats (id,org_id,title,project_id,summary_ref,state," +
    "record_json,created_at,updated_at,archived_at) VALUES " +
    "(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10) " +
    "ON CONFLICT(id) DO UPDATE SET org_id=excluded.org_id," +
    "title=excluded.title,project_id=excluded.project_id," +
    "summary_ref=excluded.summary_ref,state=excluded.state," +
    "record_json=excluded.record_json,created_at=excluded.created_at," +
    "updated_at=excluded.updated_at,archived_at=excluded.archived_at",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.org_id)
  stmt.bind(index=3, record.title)
  stmt.bind(index=4, record.project_id)
  stmt.bind(index=5, record.summary_ref)
  stmt.bind(index=6, record.state)
  stmt.bind(index=7, record.to_json().stringify())
  stmt.bind(index=8, record.created_at)
  stmt.bind(index=9, record.updated_at)
  stmt.bind(index=10, record.archived_at)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn chat_participant_put_raw(
  conn : @sqlite3.Connection,
  record : @contracts.ChatParticipant,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO chat_participants (chat_id,bot_id,role,state,added_at," +
    "removed_at,record_json) VALUES (?1,?2,?3,?4,?5,?6,?7) " +
    "ON CONFLICT(chat_id,bot_id) DO UPDATE SET role=excluded.role," +
    "state=excluded.state,added_at=excluded.added_at," +
    "removed_at=excluded.removed_at,record_json=excluded.record_json",
  )
  stmt.bind(index=1, record.chat_id)
  stmt.bind(index=2, record.bot_id)
  stmt.bind(index=3, record.role)
  stmt.bind(index=4, record.state)
  stmt.bind(index=5, record.added_at)
  stmt.bind(index=6, record.removed_at)
  stmt.bind(index=7, record.to_json().stringify())
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn bot_session_put_raw(
  conn : @sqlite3.Connection,
  record : @contracts.AgentSession,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO agent_sessions (id,agent_id,mode,workspace_id,worktree_id," +
    "cwd,state,record_json,started_at,updated_at,chat_id," +
    "runtime_session_id,permission_snapshot_hash,handoff_from_session_id," +
    "record_kind) VALUES " +
    "(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15) " +
    "ON CONFLICT(id) DO UPDATE SET agent_id=excluded.agent_id," +
    "mode=excluded.mode,workspace_id=excluded.workspace_id," +
    "worktree_id=excluded.worktree_id,cwd=excluded.cwd," +
    "state=excluded.state,record_json=excluded.record_json," +
    "started_at=excluded.started_at,updated_at=excluded.updated_at," +
    "chat_id=excluded.chat_id," +
    "runtime_session_id=excluded.runtime_session_id," +
    "permission_snapshot_hash=excluded.permission_snapshot_hash," +
    "handoff_from_session_id=excluded.handoff_from_session_id," +
    "record_kind=excluded.record_kind",
  )
  stmt.bind(index=1, record.id)
  stmt.bind(index=2, record.agent_id)
  stmt.bind(index=3, "")
  stmt.bind(index=4, record.workspace_id)
  stmt.bind(index=5, "")
  stmt.bind(index=6, record.workspace_root)
  stmt.bind(index=7, record.state)
  stmt.bind(index=8, record.to_json().stringify())
  stmt.bind(index=9, record.started_at)
  stmt.bind(index=10, record.updated_at)
  stmt.bind(index=11, record.chat_id)
  stmt.bind(index=12, record.runtime_session_id)
  stmt.bind(index=13, record.permission_snapshot_hash)
  stmt.bind(index=14, record.handoff_from_session_id)
  stmt.bind(index=15, BOT_SESSION_RECORD_KIND)
  let _ = stmt.step()
  stmt.finalize()
}

///|
fn project_membership_put_raw(
  conn : @sqlite3.Connection,
  record : @contracts.ProjectMembership,
) -> Unit raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "INSERT INTO project_memberships (project_id,bot_id,state,access_json," +
    "reason,added_at,removed_at,record_json) VALUES " +
    "(?1,?2,?3,?4,?5,?6,?7,?8) " +
    "ON CONFLICT(project_id,bot_id) DO UPDATE SET state=excluded.state," +
    "access_json=excluded.access_json,reason=excluded.reason," +
    "added_at=excluded.added_at,removed_at=excluded.removed_at," +
    "record_json=excluded.record_json",
  )
  stmt.bind(index=1, record.project_id)
  stmt.bind(index=2, record.bot_id)
  stmt.bind(index=3, record.state)
  stmt.bind(index=4, @contracts.json_string_array(record.access).stringify())
  stmt.bind(index=5, record.reason)
  stmt.bind(index=6, record.added_at)
  stmt.bind(index=7, record.removed_at)
  stmt.bind(index=8, record.to_json().stringify())
  let _ = stmt.step()
  stmt.finalize()
}

// ---------------------------------------------------------------------------
// Projection readers
// ---------------------------------------------------------------------------

///|
fn bots_parse_json(text : String) -> @json.Json {
  @json.parse(text) catch { _ => @json.Json::null() }
}

///|
pub fn MachineStore::get_bot(
  self : MachineStore,
  bot_id : String,
) -> Result[@contracts.BotRecord?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM bots WHERE id=?1",
    )
    stmt.bind(index=1, bot_id)
    let mut found : @contracts.BotRecord? = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      found = @contracts.bot_from_json(bots_parse_json(text))
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_bots(
  self : MachineStore,
) -> Result[Array[@contracts.BotRecord], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM bots ORDER BY created_at ASC, id ASC",
    )
    let out : Array[@contracts.BotRecord] = []
    while stmt.step() {
      let text : String = stmt.column(index=0)
      match @contracts.bot_from_json(bots_parse_json(text)) {
        Some(record) => out.push(record)
        None => ()
      }
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::get_agent(
  self : MachineStore,
  agent_id : String,
) -> Result[@contracts.AgentRecord?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM agents WHERE id=?1",
    )
    stmt.bind(index=1, agent_id)
    let mut found : @contracts.AgentRecord? = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      found = @contracts.agent_from_json(bots_parse_json(text))
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_agents(
  self : MachineStore,
  bot_id : String,
) -> Result[Array[@contracts.AgentRecord], String] {
  try {
    let stmt = if bot_id == "" {
      self.conn.prepare(
        "SELECT record_json FROM agents ORDER BY created_at ASC, id ASC",
      )
    } else {
      let prepared = self.conn.prepare(
        "SELECT record_json FROM agents WHERE bot_id=?1 " +
        "ORDER BY created_at ASC, id ASC",
      )
      prepared.bind(index=1, bot_id)
      prepared
    }
    let out : Array[@contracts.AgentRecord] = []
    while stmt.step() {
      let text : String = stmt.column(index=0)
      match @contracts.agent_from_json(bots_parse_json(text)) {
        Some(record) => out.push(record)
        None => ()
      }
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::get_chat(
  self : MachineStore,
  chat_id : String,
) -> Result[@contracts.ChatRecord?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM chats WHERE id=?1",
    )
    stmt.bind(index=1, chat_id)
    let mut found : @contracts.ChatRecord? = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      found = @contracts.chat_from_json(bots_parse_json(text))
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_chats(
  self : MachineStore,
  project_id : String,
) -> Result[Array[@contracts.ChatRecord], String] {
  try {
    let stmt = if project_id == "" {
      self.conn.prepare(
        "SELECT record_json FROM chats ORDER BY created_at ASC, id ASC",
      )
    } else {
      let prepared = self.conn.prepare(
        "SELECT record_json FROM chats WHERE project_id=?1 " +
        "ORDER BY created_at ASC, id ASC",
      )
      prepared.bind(index=1, project_id)
      prepared
    }
    let out : Array[@contracts.ChatRecord] = []
    while stmt.step() {
      let text : String = stmt.column(index=0)
      match @contracts.chat_from_json(bots_parse_json(text)) {
        Some(record) => out.push(record)
        None => ()
      }
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::get_chat_participant(
  self : MachineStore,
  chat_id : String,
  bot_id : String,
) -> Result[@contracts.ChatParticipant?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM chat_participants " +
      "WHERE chat_id=?1 AND bot_id=?2",
    )
    stmt.bind(index=1, chat_id)
    stmt.bind(index=2, bot_id)
    let mut found : @contracts.ChatParticipant? = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      found = @contracts.chat_participant_from_json(bots_parse_json(text))
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_chat_participants(
  self : MachineStore,
  chat_id : String,
) -> Result[Array[@contracts.ChatParticipant], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM chat_participants WHERE chat_id=?1 " +
      "ORDER BY added_at ASC, bot_id ASC",
    )
    stmt.bind(index=1, chat_id)
    let out : Array[@contracts.ChatParticipant] = []
    while stmt.step() {
      let text : String = stmt.column(index=0)
      match @contracts.chat_participant_from_json(bots_parse_json(text)) {
        Some(record) => out.push(record)
        None => ()
      }
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::get_bot_agent_session(
  self : MachineStore,
  session_id : String,
) -> Result[@contracts.AgentSession?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM agent_sessions " +
      "WHERE id=?1 AND record_kind=?2",
    )
    stmt.bind(index=1, session_id)
    stmt.bind(index=2, BOT_SESSION_RECORD_KIND)
    let mut found : @contracts.AgentSession? = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      found = @contracts.chat_agent_session_from_json(bots_parse_json(text))
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
fn MachineStore::list_bot_sessions_where(
  self : MachineStore,
  sql : String,
  key : String,
) -> Result[Array[@contracts.AgentSession], String] {
  try {
    let stmt = self.conn.prepare(sql)
    stmt.bind(index=1, key)
    let out : Array[@contracts.AgentSession] = []
    while stmt.step() {
      let text : String = stmt.column(index=0)
      match @contracts.chat_agent_session_from_json(bots_parse_json(text)) {
        Some(record) => out.push(record)
        None => ()
      }
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_chat_agent_sessions(
  self : MachineStore,
  chat_id : String,
) -> Result[Array[@contracts.AgentSession], String] {
  self.list_bot_sessions_where(
    "SELECT record_json FROM agent_sessions " +
    "WHERE record_kind='chat_agent_session' AND chat_id=?1 " +
    "ORDER BY started_at ASC, id ASC",
    chat_id,
  )
}

///|
pub fn MachineStore::list_agent_bot_sessions(
  self : MachineStore,
  agent_id : String,
) -> Result[Array[@contracts.AgentSession], String] {
  self.list_bot_sessions_where(
    "SELECT record_json FROM agent_sessions " +
    "WHERE record_kind='chat_agent_session' AND agent_id=?1 " +
    "ORDER BY started_at ASC, id ASC",
    agent_id,
  )
}

///|
pub fn MachineStore::list_all_bot_agent_sessions(
  self : MachineStore,
) -> Result[Array[@contracts.AgentSession], String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM agent_sessions " +
      "WHERE record_kind='chat_agent_session' " +
      "ORDER BY started_at ASC, id ASC",
    )
    let out : Array[@contracts.AgentSession] = []
    while stmt.step() {
      let text : String = stmt.column(index=0)
      match @contracts.chat_agent_session_from_json(bots_parse_json(text)) {
        Some(record) => out.push(record)
        None => ()
      }
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::get_project_membership(
  self : MachineStore,
  project_id : String,
  bot_id : String,
) -> Result[@contracts.ProjectMembership?, String] {
  try {
    let stmt = self.conn.prepare(
      "SELECT record_json FROM project_memberships " +
      "WHERE project_id=?1 AND bot_id=?2",
    )
    stmt.bind(index=1, project_id)
    stmt.bind(index=2, bot_id)
    let mut found : @contracts.ProjectMembership? = None
    if stmt.step() {
      let text : String = stmt.column(index=0)
      found = @contracts.project_membership_from_json(bots_parse_json(text))
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
pub fn MachineStore::list_project_memberships(
  self : MachineStore,
  project_id : String,
) -> Result[Array[@contracts.ProjectMembership], String] {
  try {
    let stmt = if project_id == "" {
      self.conn.prepare(
        "SELECT record_json FROM project_memberships " +
        "ORDER BY added_at ASC, bot_id ASC",
      )
    } else {
      let prepared = self.conn.prepare(
        "SELECT record_json FROM project_memberships WHERE project_id=?1 " +
        "ORDER BY added_at ASC, bot_id ASC",
      )
      prepared.bind(index=1, project_id)
      prepared
    }
    let out : Array[@contracts.ProjectMembership] = []
    while stmt.step() {
      let text : String = stmt.column(index=0)
      match @contracts.project_membership_from_json(bots_parse_json(text)) {
        Some(record) => out.push(record)
        None => ()
      }
    }
    stmt.finalize()
    Ok(out)
  } catch {
    error => Err(sqlite_text(error))
  }
}

// ---------------------------------------------------------------------------
// Event application and replay
// ---------------------------------------------------------------------------

///|
fn apply_bots_event_raw(
  conn : @sqlite3.Connection,
  event : @contracts.EventEnvelope,
) -> String? raise @sqlite3.SqliteError {
  let event_type = event.event_type
  if event_type == @contracts.EVENT_BOT_CREATED ||
    event_type == @contracts.EVENT_BOT_UPDATED ||
    event_type == @contracts.EVENT_BOT_POLICY_CHANGED ||
    event_type == @contracts.EVENT_BOT_PERMISSIONS_CHANGED ||
    event_type == @contracts.EVENT_BOT_ARCHIVED {
    match @contracts.bot_updated_record(event.payload) {
      Some(record) => bot_put_raw(conn, record)
      None => return Some(event_type + " payload has no complete Bot record")
    }
  } else if event_type == @contracts.EVENT_BOT_AGENT_CREATED ||
    event_type == @contracts.EVENT_BOT_AGENT_SUSPENDED ||
    event_type == @contracts.EVENT_BOT_AGENT_RETIRED ||
    event_type == @contracts.EVENT_BOT_AGENT_UPDATED {
    match @contracts.bot_agent_updated_record(event.payload) {
      Some(record) => agent_put_raw(conn, record)
      None => return Some(
        event_type + " payload has no complete Agent record",
      )
    }
  } else if event_type == @contracts.EVENT_CHAT_CREATED {
    match @contracts.chat_created_record(event.payload) {
      Some(record) => chat_put_raw(conn, record)
      None => return Some("chat.created payload has no complete Chat record")
    }
    for participant in @contracts.chat_created_participants(event.payload) {
      chat_participant_put_raw(conn, participant)
    }
  } else if event_type == @contracts.EVENT_CHAT_PARTICIPANT_ADDED ||
    event_type == @contracts.EVENT_CHAT_PARTICIPANT_REMOVED {
    match @contracts.chat_participant_added_record(event.payload) {
      Some(record) => chat_participant_put_raw(conn, record)
      None => return Some(
        event_type + " payload has no complete participant record",
      )
    }
  } else if event_type == @contracts.EVENT_CHAT_PROJECT_CHANGED ||
    event_type == @contracts.EVENT_CHAT_AGENT_SWITCHED {
    match @contracts.chat_agent_switched_record(event.payload) {
      Some(record) => chat_put_raw(conn, record)
      None => return Some(event_type + " payload has no complete Chat record")
    }
  } else if event_type == @contracts.EVENT_CHAT_AGENT_SESSION_STARTED ||
    event_type == @contracts.EVENT_CHAT_AGENT_SESSION_UPDATED ||
    event_type == @contracts.EVENT_CHAT_AGENT_SESSION_ENDED {
    match @contracts.chat_agent_session_updated_record(event.payload) {
      Some(record) => bot_session_put_raw(conn, record)
      None => return Some(
        event_type + " payload has no complete AgentSession record",
      )
    }
  } else if event_type == @contracts.EVENT_PROJECT_MEMBER_ADDED ||
    event_type == @contracts.EVENT_PROJECT_MEMBER_REMOVED {
    match @contracts.project_member_added_record(event.payload) {
      Some(record) => project_membership_put_raw(conn, record)
      None => return Some(
        event_type + " payload has no complete membership record",
      )
    }
  }
  None
}

///|
/// Append one Bot/Chat/Project event and apply its projection in the same
/// transaction. A malformed record rolls the event back too, so the log can
/// never contain an event the projection cannot reconstruct.
pub fn MachineStore::append_bot_event(
  self : MachineStore,
  event : @contracts.EventEnvelope,
) -> Result[Unit, String] {
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    bump_last_seq_raw(self.conn, event.seq)
    insert_event_raw(self.conn, event)
    match apply_bots_event_raw(self.conn, event) {
      Some(message) => {
        exec_raise(self.conn, "ROLLBACK")
        return Err(message)
      }
      None => ()
    }
    exec_raise(self.conn, "COMMIT")
    Ok(())
  } catch {
    error => {
      let _ = try {
        exec_raise(self.conn, "ROLLBACK")
      } catch {
        _ => ()
      }
      Err(sqlite_text(error))
    }
  }
}

///|
/// Allocate the next event envelope and append its projection atomically.
pub fn MachineStore::append_bots_event(
  self : MachineStore,
  event_type : String,
  subject : String,
  payload : @json.Json,
  now : String,
  org_id : String,
) -> Result[@contracts.EventEnvelope, String] {
  let seq = match self.last_seq() {
    Ok(value) => value + 1L
    Err(message) => return Err(message)
  }
  let event = @contracts.EventEnvelope::new(
    id=@contracts.new_id("evt", seq),
    org_id~,
    event_type~,
    ts=now,
    subject~,
    seq~,
    payload~,
    causation_id="",
    correlation_id="",
    idempotency_key="evt/" + seq.to_string(),
  )
  match self.append_bot_event(event) {
    Ok(_) => Ok(event)
    Err(message) => Err(message)
  }
}

///|
fn load_bots_events(
  conn : @sqlite3.Connection,
) -> Array[@contracts.EventEnvelope] raise @sqlite3.SqliteError {
  let stmt = conn.prepare(
    "SELECT seq,id,org_id,type,subject,ts,causation_id,correlation_id," +
    "idempotency_key,payload_json FROM events WHERE " +
    "type LIKE 'bot.%' OR type LIKE 'chat.%' OR type LIKE 'project.member.%' " +
    "ORDER BY seq ASC",
  )
  let out : Array[@contracts.EventEnvelope] = []
  while stmt.step() {
    let seq : Int64 = stmt.column(index=0)
    let id : String = stmt.column(index=1)
    let org_id : String = stmt.column(index=2)
    let event_type : String = stmt.column(index=3)
    let subject : String = stmt.column(index=4)
    let ts : String = stmt.column(index=5)
    let causation_id : String = stmt.column(index=6)
    let correlation_id : String = stmt.column(index=7)
    let idempotency_key : String = stmt.column(index=8)
    let payload_json : String = stmt.column(index=9)
    out.push(
      @contracts.EventEnvelope::new(
        id~,
        org_id~,
        event_type~,
        ts~,
        subject~,
        seq~,
        payload=bots_parse_json(payload_json),
        causation_id~,
        correlation_id~,
        idempotency_key~,
      ),
    )
  }
  stmt.finalize()
  out
}

///|
fn bots_count_rows(
  conn : @sqlite3.Connection,
  sql : String,
) -> Int raise @sqlite3.SqliteError {
  let stmt = conn.prepare(sql)
  let mut count = 0
  if stmt.step() {
    let value : Int64 = stmt.column(index=0)
    count = value.to_int()
  }
  stmt.finalize()
  count
}

///|
/// Rebuild every Bot/Chat/AgentSession/membership projection from the event
/// log. The legacy runtime rows in `agent_sessions` are deliberately kept.
pub fn MachineStore::reconcile_bots_projection(
  self : MachineStore,
) -> Result[BotsReconcileCounts, String] {
  let events = try {
    load_bots_events(self.conn)
  } catch {
    error => return Err(sqlite_text(error))
  }
  try {
    exec_raise(self.conn, "BEGIN IMMEDIATE")
    exec_raise(self.conn, "DELETE FROM chat_participants")
    exec_raise(
      self.conn,
      "DELETE FROM agent_sessions WHERE record_kind='chat_agent_session'",
    )
    exec_raise(self.conn, "DELETE FROM project_memberships")
    exec_raise(self.conn, "DELETE FROM chats")
    exec_raise(self.conn, "DELETE FROM agents")
    exec_raise(self.conn, "DELETE FROM bots")
    for event in events {
      match apply_bots_event_raw(self.conn, event) {
        Some(message) => {
          exec_raise(self.conn, "ROLLBACK")
          return Err(message)
        }
        None => ()
      }
    }
    exec_raise(self.conn, "COMMIT")
    Ok({
      bots: bots_count_rows(self.conn, "SELECT COUNT(*) FROM bots"),
      agents: bots_count_rows(self.conn, "SELECT COUNT(*) FROM agents"),
      chats: bots_count_rows(self.conn, "SELECT COUNT(*) FROM chats"),
      participants: bots_count_rows(
        self.conn,
        "SELECT COUNT(*) FROM chat_participants",
      ),
      sessions: bots_count_rows(
        self.conn,
        "SELECT COUNT(*) FROM agent_sessions " +
        "WHERE record_kind='chat_agent_session'",
      ),
      memberships: bots_count_rows(
        self.conn,
        "SELECT COUNT(*) FROM project_memberships",
      ),
    })
  } catch {
    error => {
      let _ = try {
        exec_raise(self.conn, "ROLLBACK")
      } catch {
        _ => ()
      }
      Err(sqlite_text(error))
    }
  }
}

// ---------------------------------------------------------------------------
// Typed legacy aliases
// ---------------------------------------------------------------------------

///|
fn legacy_alias_canonical_kind(kind : String) -> String? {
  match kind {
    "agent_identity" => Some(LEGACY_CANONICAL_BOT)
    "agent_session" => Some(LEGACY_CANONICAL_AGENT_SESSION)
    "architecture_session" => Some(LEGACY_CANONICAL_AGENT_SESSION)
    _ => None
  }
}

///|
fn legacy_alias_canonical_id_valid(
  canonical_kind : String,
  canonical_id : String,
) -> Bool {
  match canonical_kind {
    "bot" => @contracts.is_bot_id(canonical_id)
    "agent_session" => @contracts.is_agent_session_id(canonical_id)
    _ => false
  }
}

///|
/// Resolve a legacy reference by its explicit reference kind. Untyped and
/// unknown kinds fail instead of guessing; the same alias value can legally
/// point at a Bot under one kind and an AgentSession under another.
pub fn MachineStore::resolve_legacy_alias(
  self : MachineStore,
  kind : String,
  value : String,
) -> Result[LegacyAliasTarget?, String] {
  let expected = match legacy_alias_canonical_kind(kind) {
    Some(canonical_kind) => canonical_kind
    None => return Err("unknown or untyped legacy alias kind: " + kind)
  }
  if value == "" {
    return Err("legacy alias value is required")
  }
  try {
    let stmt = self.conn.prepare(
      "SELECT canonical_kind,canonical_id FROM legacy_aliases " +
      "WHERE alias_kind=?1 AND alias_value=?2",
    )
    stmt.bind(index=1, kind)
    stmt.bind(index=2, value)
    let mut found : LegacyAliasTarget? = None
    if stmt.step() {
      let canonical_kind : String = stmt.column(index=0)
      let canonical_id : String = stmt.column(index=1)
      if canonical_kind != expected {
        stmt.finalize()
        return Err(
          "legacy alias kind mismatch: " +
          kind +
          " cannot resolve to " +
          canonical_kind,
        )
      }
      found = Some({ canonical_kind, canonical_id })
    }
    stmt.finalize()
    Ok(found)
  } catch {
    error => Err(sqlite_text(error))
  }
}

///|
/// Migration-only alias writer. No domain command calls this; aliases are
/// accepted only when the caller states both the reference kind and canonical
/// target kind. Re-writing the same alias with the same target is idempotent.
pub fn MachineStore::put_legacy_alias(
  self : MachineStore,
  kind : String,
  value : String,
  canonical_kind : String,
  canonical_id : String,
  migration_run_id : String,
  created_at : String,
) -> Result[Unit, String] {
  let expected = match legacy_alias_canonical_kind(kind) {
    Some(canonical_kind) => canonical_kind
    None => return Err("unknown or untyped legacy alias kind: " + kind)
  }
  if canonical_kind != expected {
    return Err(
      "legacy alias " + kind + " must point to a " + expected,
    )
  }
  if value == "" || !legacy_alias_canonical_id_valid(canonical_kind, canonical_id) {
    return Err("legacy alias value or canonical id is invalid")
  }
  try {
    let existing = self.conn.prepare(
      "SELECT canonical_kind,canonical_id FROM legacy_aliases " +
      "WHERE alias_kind=?1 AND alias_value=?2",
    )
    existing.bind(index=1, kind)
    existing.bind(index=2, value)
    if existing.step() {
      let old_kind : String = existing.column(index=0)
      let old_id : String = existing.column(index=1)
      existing.finalize()
      if old_kind == canonical_kind && old_id == canonical_id {
        return Ok(())
      }
      return Err("legacy alias already points to a different object")
    }
    existing.finalize()
    let stmt = self.conn.prepare(
      "INSERT INTO legacy_aliases (alias_kind,alias_value,canonical_kind," +
      "canonical_id,migration_run_id,created_at) " +
      "VALUES (?1,?2,?3,?4,?5,?6)",
    )
    stmt.bind(index=1, kind)
    stmt.bind(index=2, value)
    stmt.bind(index=3, canonical_kind)
    stmt.bind(index=4, canonical_id)
    stmt.bind(index=5, migration_run_id)
    stmt.bind(index=6, created_at)
    let _ = stmt.step()
    stmt.finalize()
    Ok(())
  } catch {
    error => Err(sqlite_text(error))
  }
}

// ---------------------------------------------------------------------------
// Domain commands
// ---------------------------------------------------------------------------

///|
fn bots_permission_subset(
  subset : Array[String],
  superset : Array[String],
) -> Bool {
  for value in subset {
    if !superset.contains(value) {
      return false
    }
  }
  true
}

///|
fn bots_create_policy_known(value : String) -> Bool {
  value == @contracts.BOT_CREATE_POLICY_OFF ||
  value == @contracts.BOT_CREATE_POLICY_ASK ||
  value == @contracts.BOT_CREATE_POLICY_AUTO
}

///|
fn bots_end_reason_known(value : String) -> Bool {
  value == @contracts.AGENT_SESSION_END_REASON_TURN_END ||
  value == @contracts.AGENT_SESSION_END_REASON_CANCELLED ||
  value == @contracts.AGENT_SESSION_END_REASON_ERROR ||
  value == @contracts.AGENT_SESSION_END_REASON_EXITED ||
  value == @contracts.AGENT_SESSION_END_REASON_HOST_RESTART ||
  value == @contracts.AGENT_SESSION_END_REASON_LOST ||
  value == @contracts.AGENT_SESSION_END_REASON_INTERRUPTED ||
  value == @contracts.AGENT_SESSION_END_REASON_AGENT_SWITCH ||
  value == @contracts.AGENT_SESSION_END_REASON_PROJECT_ACCESS_REVOKED ||
  value == @contracts.AGENT_SESSION_END_REASON_CHAT_ARCHIVED
}

///|
fn bots_count_sql1(
  conn : @sqlite3.Connection,
  sql : String,
  first : String,
) -> Int raise @sqlite3.SqliteError {
  let stmt = conn.prepare(sql)
  stmt.bind(index=1, first)
  let mut count = 0
  if stmt.step() {
    let value : Int64 = stmt.column(index=0)
    count = value.to_int()
  }
  stmt.finalize()
  count
}

///|
fn bots_count_sql2(
  conn : @sqlite3.Connection,
  sql : String,
  first : String,
  second : String,
) -> Int raise @sqlite3.SqliteError {
  let stmt = conn.prepare(sql)
  stmt.bind(index=1, first)
  stmt.bind(index=2, second)
  let mut count = 0
  if stmt.step() {
    let value : Int64 = stmt.column(index=0)
    count = value.to_int()
  }
  stmt.finalize()
  count
}

///|
fn bot_live_agent_count(
  conn : @sqlite3.Connection,
  bot_id : String,
) -> Int raise @sqlite3.SqliteError {
  bots_count_sql1(
    conn,
    "SELECT COUNT(*) FROM agents WHERE bot_id=?1 AND state<>'retired'",
    bot_id,
  )
}

///|
fn bot_nonterminal_session_count(
  conn : @sqlite3.Connection,
  bot_id : String,
) -> Int raise @sqlite3.SqliteError {
  bots_count_sql1(
    conn,
    "SELECT COUNT(*) FROM agent_sessions s JOIN agents a ON a.id=s.agent_id " +
    "WHERE a.bot_id=?1 AND s.record_kind='chat_agent_session' " +
    "AND s.state IN ('starting','active','waiting','ending')",
    bot_id,
  )
}

///|
fn project_bot_nonterminal_session_count(
  conn : @sqlite3.Connection,
  project_id : String,
  bot_id : String,
) -> Int raise @sqlite3.SqliteError {
  bots_count_sql2(
    conn,
    "SELECT COUNT(*) FROM agent_sessions s " +
    "JOIN agents a ON a.id=s.agent_id " +
    "JOIN chats c ON c.id=s.chat_id " +
    "WHERE c.project_id=?1 AND a.bot_id=?2 " +
    "AND s.record_kind='chat_agent_session' " +
    "AND s.state IN ('starting','active','waiting','ending')",
    project_id,
    bot_id,
  )
}

///|
fn bots_normalized_bot(
  bot : @contracts.BotRecord,
  now : String,
) -> @contracts.BotRecord {
  let created_at = if bot.created_at == "" { now } else { bot.created_at }
  { ..bot, created_at: created_at, updated_at: now }
}

///|
fn bots_normalized_agent(
  agent : @contracts.AgentRecord,
  now : String,
) -> @contracts.AgentRecord {
  let created_at = if agent.created_at == "" { now } else { agent.created_at }
  { ..agent, created_at: created_at, updated_at: now }
}

///|
fn bots_normalized_chat(
  chat : @contracts.ChatRecord,
  now : String,
) -> @contracts.ChatRecord {
  let created_at = if chat.created_at == "" { now } else { chat.created_at }
  { ..chat, created_at: created_at, updated_at: now }
}

///|
/// Create a Bot. The permission ceiling is the upper bound Agents and Chat
/// sessions can never exceed; it is stored on the same record as the create
/// policy and software allowlist.
pub fn MachineStore::create_bot(
  self : MachineStore,
  bot : @contracts.BotRecord,
  actor : String,
  source : String,
  now : String,
) -> Result[@contracts.BotRecord, String] {
  if !@contracts.is_bot_id(bot.id) {
    return Err("Bot id is not canonical: " + bot.id)
  }
  match self.get_bot(bot.id) {
    Ok(Some(_)) => return Err("Bot already exists: " + bot.id)
    Ok(None) => ()
    Err(message) => return Err(message)
  }
  if bot.org_id == "" {
    return Err("Bot org_id is required")
  }
  if bot.name == "" {
    return Err("Bot name is required")
  }
  if bot.state != @contracts.BOT_STATE_ACTIVE {
    return Err("a new Bot must be active")
  }
  if !bots_create_policy_known(bot.create_policy) {
    return Err("unknown Bot create policy: " + bot.create_policy)
  }
  if bot.agent_count_cap < 0 || bot.agent_concurrency_cap < 0 {
    return Err("Bot caps must not be negative")
  }
  let record = bots_normalized_bot(bot, now)
  let payload = @contracts.bot_created_payload(
    record,
    @contracts.bots_permission_set_hash(record.permission_ceiling),
    actor,
    source,
  )
  match
    self.append_bots_event(
      @contracts.EVENT_BOT_CREATED,
      @contracts.bot_event_subject(record.id),
      payload,
      now,
      record.org_id,
    ) {
    Ok(_) => Ok(record)
    Err(message) => Err(message)
  }
}

///|
/// Update Bot naming/persona/home metadata. Policy and permission changes have
/// their own audit events and commands.
pub fn MachineStore::update_bot(
  self : MachineStore,
  updated : @contracts.BotRecord,
  changed_fields : Array[String],
  version : Int,
  now : String,
  actor : String,
) -> Result[@contracts.BotRecord, String] {
  let current = match self.get_bot(updated.id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("Bot not found: " + updated.id)
    Err(message) => return Err(message)
  }
  if current.state == @contracts.BOT_STATE_ARCHIVED {
    return Err("archived Bot is read-only")
  }
  if updated.org_id != current.org_id ||
    updated.created_at != current.created_at ||
    updated.state != current.state {
    return Err("Bot identity and lifecycle fields are immutable here")
  }
  if updated.name == "" {
    return Err("Bot name is required")
  }
  if updated.permission_ceiling != current.permission_ceiling {
    return Err("use update_bot_permissions to change the permission ceiling")
  }
  if updated.create_policy != current.create_policy ||
    updated.agent_count_cap != current.agent_count_cap ||
    updated.agent_concurrency_cap != current.agent_concurrency_cap ||
    updated.software_allowlist != current.software_allowlist {
    return Err("use update_bot_policy to change creation policy fields")
  }
  if changed_fields.length() == 0 {
    return Err("Bot update has no changed fields")
  }
  let record = { ..updated, updated_at: now }
  let payload = @contracts.bot_updated_payload(
    record,
    changed_fields,
    version,
    actor,
  )
  match
    self.append_bots_event(
      @contracts.EVENT_BOT_UPDATED,
      @contracts.bot_event_subject(record.id),
      payload,
      now,
      record.org_id,
    ) {
    Ok(_) => Ok(record)
    Err(message) => Err(message)
  }
}

///|
/// Change the Off/Ask/Auto policy, Agent caps and software allowlist.
pub fn MachineStore::update_bot_policy(
  self : MachineStore,
  bot_id : String,
  create_policy : String,
  agent_count_cap : Int,
  agent_concurrency_cap : Int,
  software_allowlist : Array[String],
  now : String,
  actor : String,
) -> Result[@contracts.BotRecord, String] {
  let current = match self.get_bot(bot_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("Bot not found: " + bot_id)
    Err(message) => return Err(message)
  }
  if current.state == @contracts.BOT_STATE_ARCHIVED {
    return Err("archived Bot is read-only")
  }
  if !bots_create_policy_known(create_policy) {
    return Err("unknown Bot create policy: " + create_policy)
  }
  if agent_count_cap < 0 || agent_concurrency_cap < 0 {
    return Err("Bot caps must not be negative")
  }
  let record = {
    ..current,
    create_policy,
    agent_count_cap,
    agent_concurrency_cap,
    software_allowlist,
    updated_at: now,
  }
  let payload = @contracts.bot_policy_changed_payload(
    record,
    current.create_policy,
    create_policy,
    @contracts.bots_permission_set_hash(software_allowlist),
    actor,
  )
  match
    self.append_bots_event(
      @contracts.EVENT_BOT_POLICY_CHANGED,
      @contracts.bot_event_subject(record.id),
      payload,
      now,
      record.org_id,
    ) {
    Ok(_) => Ok(record)
    Err(message) => Err(message)
  }
}

///|
/// Change the Bot permission ceiling. Shrinking is always allowed; widening
/// requires an explicit owner-approved expansion flag.
pub fn MachineStore::update_bot_permissions(
  self : MachineStore,
  bot_id : String,
  permission_ceiling : Array[String],
  allow_widening : Bool,
  now : String,
  actor : String,
) -> Result[@contracts.BotRecord, String] {
  let current = match self.get_bot(bot_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("Bot not found: " + bot_id)
    Err(message) => return Err(message)
  }
  if current.state == @contracts.BOT_STATE_ARCHIVED {
    return Err("archived Bot is read-only")
  }
  if !bots_permission_subset(permission_ceiling, current.permission_ceiling) &&
    !allow_widening {
    return Err(
      "Bot permission ceiling cannot widen without explicit approval",
    )
  }
  let record = { ..current, permission_ceiling, updated_at: now }
  let payload = @contracts.bot_permissions_changed_payload(
    record,
    @contracts.bots_permission_set_hash(current.permission_ceiling),
    @contracts.bots_permission_set_hash(permission_ceiling),
    actor,
  )
  match
    self.append_bots_event(
      @contracts.EVENT_BOT_PERMISSIONS_CHANGED,
      @contracts.bot_event_subject(record.id),
      payload,
      now,
      record.org_id,
    ) {
    Ok(_) => Ok(record)
    Err(message) => Err(message)
  }
}

///|
/// Archive a Bot. V1 archived Bots are terminal and never restored.
pub fn MachineStore::archive_bot(
  self : MachineStore,
  bot_id : String,
  reason : String,
  now : String,
  actor : String,
) -> Result[@contracts.BotRecord, String] {
  let current = match self.get_bot(bot_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("Bot not found: " + bot_id)
    Err(message) => return Err(message)
  }
  let agents = match self.list_agents(bot_id) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let all_sessions = match self.list_all_bot_agent_sessions() {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let sessions : Array[@contracts.AgentSession] = []
  let mut active_sessions = 0
  for session in all_sessions {
    for agent in agents {
      if session.agent_id == agent.id {
        sessions.push(session)
        if @bots.agent_session_is_nonterminal(session.state) {
          active_sessions = active_sessions + 1
        }
      }
    }
  }
  match @bots.validate_bot_archive(current, agents, sessions) {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  let record = {
    ..current,
    state: @contracts.BOT_STATE_ARCHIVED,
    updated_at: now,
  }
  let payload = @contracts.bot_archived_payload(
    record,
    reason,
    active_sessions,
    actor,
  )
  match
    self.append_bots_event(
      @contracts.EVENT_BOT_ARCHIVED,
      @contracts.bot_event_subject(record.id),
      payload,
      now,
      record.org_id,
    ) {
    Ok(_) => Ok(record)
    Err(message) => Err(message)
  }
}

///|
/// Create an Agent under exactly one Bot. Off rejects; Ask requires an owner
/// Decision id; Auto must stay within the Bot caps, allowlist and permission
/// ceiling.
pub fn MachineStore::create_agent(
  self : MachineStore,
  agent : @contracts.AgentRecord,
  decision_id : String,
  actor : String,
  source : String,
  now : String,
) -> Result[@contracts.AgentRecord, String] {
  if !@contracts.is_agent_id(agent.id) {
    return Err("Agent id is not canonical: " + agent.id)
  }
  match self.get_agent(agent.id) {
    Ok(Some(_)) => return Err("Agent already exists: " + agent.id)
    Ok(None) => ()
    Err(message) => return Err(message)
  }
  let bot = match self.get_bot(agent.bot_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("Agent Bot not found: " + agent.bot_id)
    Err(message) => return Err(message)
  }
  if bot.state == @contracts.BOT_STATE_ARCHIVED {
    return Err("archived Bot is read-only")
  }
  if agent.name == "" {
    return Err("Agent name is required")
  }
  if agent.org_id != "" && agent.org_id != bot.org_id {
    return Err("Agent org_id does not match its Bot")
  }
  if agent.runtime_binding.software_id == "" ||
    agent.runtime_binding.hash == "" {
    return Err("Agent runtime binding is incomplete")
  }
  if bot.software_allowlist.length() > 0 &&
    !bot.software_allowlist.contains(agent.runtime_binding.software_id) {
    return Err(
      "Agent software is not in the Bot allowlist: " +
      agent.runtime_binding.software_id,
    )
  }
  if !bots_permission_subset(agent.permission_scope, bot.permission_ceiling) {
    return Err("Agent permission scope exceeds the Bot ceiling")
  }
  let live_agents = try {
    bot_live_agent_count(self.conn, bot.id)
  } catch {
    error => return Err(sqlite_text(error))
  }
  if live_agents >= bot.agent_count_cap {
    return Err("Bot Agent count cap reached")
  }
  let active_sessions = try {
    bot_nonterminal_session_count(self.conn, bot.id)
  } catch {
    error => return Err(sqlite_text(error))
  }
  if active_sessions >= bot.agent_concurrency_cap {
    return Err("Bot Agent concurrency cap reached")
  }
  match bot.create_policy {
    "off" => return Err("Bot create policy is off")
    "ask" =>
      if decision_id == "" {
        return Err("Bot create policy ask requires an owner Decision")
      }
    "auto" => ()
    _ => return Err("unknown Bot create policy: " + bot.create_policy)
  }
  let record = bots_normalized_agent(agent, now)
  let payload = @contracts.bot_agent_created_payload(
    bot.id,
    record,
    @contracts.bots_permission_set_hash(record.permission_scope),
    bot.create_policy,
    decision_id,
    actor,
    source,
  )
  match
    self.append_bots_event(
      @contracts.EVENT_BOT_AGENT_CREATED,
      @contracts.bot_event_subject(bot.id),
      payload,
      now,
      bot.org_id,
    ) {
    Ok(_) => Ok(record)
    Err(message) => Err(message)
  }
}

///|
/// Update Agent metadata without touching the runtime binding. The binding is
/// compared structurally, including its hash, and any difference is rejected.
pub fn MachineStore::update_agent(
  self : MachineStore,
  updated : @contracts.AgentRecord,
  changed_fields : Array[String],
  now : String,
  actor : String,
) -> Result[@contracts.AgentRecord, String] {
  let current = match self.get_agent(updated.id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("Agent not found: " + updated.id)
    Err(message) => return Err(message)
  }
  if current.state == @contracts.AGENT_LIFECYCLE_RETIRED {
    return Err("retired Agent is read-only")
  }
  if updated.bot_id != current.bot_id {
    return Err("Agent belongs to a different Bot")
  }
  if updated.org_id != current.org_id ||
    updated.created_at != current.created_at ||
    updated.state != current.state {
    return Err("Agent identity and lifecycle fields are immutable here")
  }
  match
    @bots.validate_runtime_binding_update(
      current.runtime_binding,
      updated.runtime_binding,
    ) {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  let bot = match self.get_bot(current.bot_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("Agent Bot not found: " + current.bot_id)
    Err(message) => return Err(message)
  }
  if bot.state == @contracts.BOT_STATE_ARCHIVED {
    return Err("archived Bot is read-only")
  }
  if !bots_permission_subset(updated.permission_scope, bot.permission_ceiling) {
    return Err("Agent permission scope exceeds the Bot ceiling")
  }
  if updated.name == "" {
    return Err("Agent name is required")
  }
  if changed_fields.length() == 0 {
    return Err("Agent update has no changed fields")
  }
  let record = { ..updated, updated_at: now }
  let payload = @contracts.bot_agent_updated_payload(
    record,
    changed_fields,
    actor,
  )
  match
    self.append_bots_event(
      @contracts.EVENT_BOT_AGENT_UPDATED,
      @contracts.bot_event_subject(bot.id),
      payload,
      now,
      bot.org_id,
    ) {
    Ok(_) => Ok(record)
    Err(message) => Err(message)
  }
}

///|
/// Suspend an active Agent. Suspended Agents can be restored only through a
/// later explicit lifecycle command; the runtime binding stays fixed.
pub fn MachineStore::suspend_agent(
  self : MachineStore,
  agent_id : String,
  reason : String,
  now : String,
  actor : String,
) -> Result[@contracts.AgentRecord, String] {
  let current = match self.get_agent(agent_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("Agent not found: " + agent_id)
    Err(message) => return Err(message)
  }
  if !@bots.agent_transition_allowed(
    current.state,
    @contracts.AGENT_LIFECYCLE_SUSPENDED,
  ) {
    return Err("Agent cannot be suspended from state " + current.state)
  }
  let record = {
    ..current,
    state: @contracts.AGENT_LIFECYCLE_SUSPENDED,
    updated_at: now,
  }
  let payload = @contracts.bot_agent_suspended_payload(
    current.bot_id,
    record,
    reason,
    actor,
  )
  match
    self.append_bots_event(
      @contracts.EVENT_BOT_AGENT_SUSPENDED,
      @contracts.bot_event_subject(current.bot_id),
      payload,
      now,
      current.org_id,
    ) {
    Ok(_) => Ok(record)
    Err(message) => Err(message)
  }
}

///|
/// Retire an Agent. Any non-terminal AgentSession must end first. Retirement is
/// terminal for the runtime binding; use another Agent to change software.
pub fn MachineStore::retire_agent(
  self : MachineStore,
  agent_id : String,
  reason : String,
  now : String,
  actor : String,
) -> Result[@contracts.AgentRecord, String] {
  let current = match self.get_agent(agent_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("Agent not found: " + agent_id)
    Err(message) => return Err(message)
  }
  let sessions = match self.list_agent_bot_sessions(agent_id) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  match @bots.validate_agent_retirement(current, sessions) {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  let record = {
    ..current,
    state: @contracts.AGENT_LIFECYCLE_RETIRED,
    retired_at: now,
    updated_at: now,
  }
  let payload = @contracts.bot_agent_retired_payload(
    current.bot_id,
    record,
    reason,
    actor,
  )
  match
    self.append_bots_event(
      @contracts.EVENT_BOT_AGENT_RETIRED,
      @contracts.bot_event_subject(current.bot_id),
      payload,
      now,
      current.org_id,
    ) {
    Ok(_) => Ok(record)
    Err(message) => Err(message)
  }
}

///|
/// Create a Chat with exactly one active Bot participant. Project-scoped Chats
/// additionally require an active ProjectMembership for every participant.
pub fn MachineStore::create_chat(
  self : MachineStore,
  chat : @contracts.ChatRecord,
  participant_bot_ids : Array[String],
  actor : String,
  source : String,
  now : String,
) -> Result[@contracts.ChatRecord, String] {
  if !@contracts.is_chat_id(chat.id) {
    return Err("Chat id is not canonical: " + chat.id)
  }
  match self.get_chat(chat.id) {
    Ok(Some(_)) => return Err("Chat already exists: " + chat.id)
    Ok(None) => ()
    Err(message) => return Err(message)
  }
  if chat.org_id == "" {
    return Err("Chat org_id is required")
  }
  if chat.title == "" {
    return Err("Chat title is required")
  }
  if chat.state != @contracts.CHAT_STATE_ACTIVE {
    return Err("a new Chat must be active")
  }
  if chat.project_id != "" && !@contracts.is_project_id(chat.project_id) {
    return Err("Chat project_id is not canonical: " + chat.project_id)
  }
  let participants : Array[@contracts.ChatParticipant] = []
  for bot_id in participant_bot_ids {
    match self.get_bot(bot_id) {
      Ok(Some(bot)) =>
        if bot.state == @contracts.BOT_STATE_ARCHIVED {
          return Err("archived Bot cannot join a Chat: " + bot_id)
        }
      Ok(None) => return Err("Chat participant Bot not found: " + bot_id)
      Err(message) => return Err(message)
    }
    participants.push(
      @contracts.ChatParticipant::new(
        chat_id=chat.id,
        bot_id~,
        added_at=now,
      ),
    )
  }
  let memberships = if chat.project_id == "" {
    []
  } else {
    match self.list_project_memberships(chat.project_id) {
      Ok(value) => value
      Err(message) => return Err(message)
    }
  }
  let record = bots_normalized_chat(chat, now)
  match @bots.validate_v1_chat(record, participants, [], [], memberships) {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  let payload = @contracts.chat_created_payload(
    record,
    participants,
    actor,
    source,
  )
  match
    self.append_bots_event(
      @contracts.EVENT_CHAT_CREATED,
      @contracts.chat_event_subject(record.id),
      payload,
      now,
      record.org_id,
    ) {
    Ok(_) => Ok(record)
    Err(message) => Err(message)
  }
}

///|
/// Start the one non-terminal AgentSession allowed in a V1 Chat.
pub fn MachineStore::start_chat_agent_session(
  self : MachineStore,
  session : @contracts.AgentSession,
  actor : String,
  now : String,
) -> Result[@contracts.AgentSession, String] {
  if !@contracts.is_agent_session_id(session.id) {
    return Err("AgentSession id is not canonical: " + session.id)
  }
  match self.get_bot_agent_session(session.id) {
    Ok(Some(_)) => return Err("AgentSession already exists: " + session.id)
    Ok(None) => ()
    Err(message) => return Err(message)
  }
  let chat = match self.get_chat(session.chat_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("Chat not found: " + session.chat_id)
    Err(message) => return Err(message)
  }
  let agent = match self.get_agent(session.agent_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("Agent not found: " + session.agent_id)
    Err(message) => return Err(message)
  }
  let bot = match self.get_bot(agent.bot_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("Agent Bot not found: " + agent.bot_id)
    Err(message) => return Err(message)
  }
  if bot.state == @contracts.BOT_STATE_ARCHIVED {
    return Err("archived Bot is read-only")
  }
  let participants = match self.list_chat_participants(chat.id) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let memberships = if chat.project_id == "" {
    []
  } else {
    match self.list_project_memberships(chat.project_id) {
      Ok(value) => value
      Err(message) => return Err(message)
    }
  }
  let existing = match self.list_chat_agent_sessions(chat.id) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  match
    @bots.validate_agent_session_start(
      chat,
      agent,
      session,
      participants,
      memberships,
      existing,
    ) {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  let record = if session.updated_at == "" {
    { ..session, updated_at: now }
  } else {
    session
  }
  let payload = @contracts.chat_agent_session_started_payload(
    record,
    agent.bot_id,
    agent.runtime_binding.hash,
    chat.summary_ref,
  )
  match
    self.append_bots_event(
      @contracts.EVENT_CHAT_AGENT_SESSION_STARTED,
      @contracts.chat_event_subject(chat.id),
      payload,
      now,
      chat.org_id,
    ) {
    Ok(_) => Ok(record)
    Err(message) => Err(message)
  }
}

///|
/// Move an AgentSession between non-terminal states. Terminal transitions are
/// explicit and go through `end_chat_agent_session`.
pub fn MachineStore::update_chat_agent_session(
  self : MachineStore,
  session_id : String,
  state : String,
  runtime_session_id : String,
  summary_ref : String,
  turns : Int,
  decisions : Int,
  now : String,
) -> Result[@contracts.AgentSession, String] {
  let current = match self.get_bot_agent_session(session_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("AgentSession not found: " + session_id)
    Err(message) => return Err(message)
  }
  if @bots.agent_session_is_terminal(state) {
    return Err("terminal AgentSession state must use end_chat_agent_session")
  }
  if !@bots.agent_session_transition_allowed(current.state, state) {
    return Err(
      "invalid AgentSession transition: " + current.state + " -> " + state,
    )
  }
  if runtime_session_id != "" &&
    current.runtime_session_id != "" &&
    runtime_session_id != current.runtime_session_id {
    return Err("runtime session id is immutable once assigned")
  }
  let next_runtime_session_id = if runtime_session_id == "" {
    current.runtime_session_id
  } else {
    runtime_session_id
  }
  let next_summary_ref = if summary_ref == "" {
    current.summary_ref
  } else {
    summary_ref
  }
  let chat = match self.get_chat(current.chat_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("Chat not found: " + current.chat_id)
    Err(message) => return Err(message)
  }
  let record = {
    ..current,
    state,
    runtime_session_id: next_runtime_session_id,
    summary_ref: next_summary_ref,
    updated_at: now,
  }
  let payload = @contracts.chat_agent_session_updated_payload(
    record,
    turns,
    decisions,
  )
  match
    self.append_bots_event(
      @contracts.EVENT_CHAT_AGENT_SESSION_UPDATED,
      @contracts.chat_event_subject(current.chat_id),
      payload,
      now,
      chat.org_id,
    ) {
    Ok(_) => Ok(record)
    Err(message) => Err(message)
  }
}

///|
/// End an AgentSession with an explicit terminal state and reason.
pub fn MachineStore::end_chat_agent_session(
  self : MachineStore,
  session_id : String,
  state : String,
  end_reason : String,
  summary_ref : String,
  next_session_id : String,
  now : String,
) -> Result[@contracts.AgentSession, String] {
  let current = match self.get_bot_agent_session(session_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("AgentSession not found: " + session_id)
    Err(message) => return Err(message)
  }
  if !@bots.agent_session_is_terminal(state) {
    return Err("AgentSession end requires a terminal state")
  }
  if !@bots.agent_session_transition_allowed(current.state, state) {
    return Err(
      "invalid AgentSession end transition: " +
      current.state +
      " -> " +
      state,
    )
  }
  if !bots_end_reason_known(end_reason) {
    return Err("unknown AgentSession end reason: " + end_reason)
  }
  let chat = match self.get_chat(current.chat_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("Chat not found: " + current.chat_id)
    Err(message) => return Err(message)
  }
  let next_summary_ref = if summary_ref == "" {
    current.summary_ref
  } else {
    summary_ref
  }
  let record = {
    ..current,
    state,
    end_reason,
    summary_ref: next_summary_ref,
    ended_at: now,
    updated_at: now,
  }
  let payload = @contracts.chat_agent_session_ended_payload(
    record,
    next_session_id,
  )
  match
    self.append_bots_event(
      @contracts.EVENT_CHAT_AGENT_SESSION_ENDED,
      @contracts.chat_event_subject(chat.id),
      payload,
      now,
      chat.org_id,
    ) {
    Ok(_) => Ok(record)
    Err(message) => Err(message)
  }
}

///|
/// Grant a Bot active access to a Project. Re-adding the same active membership
/// is idempotent and does not emit a duplicate event.
pub fn MachineStore::add_project_membership(
  self : MachineStore,
  membership : @contracts.ProjectMembership,
  actor : String,
  now : String,
) -> Result[@contracts.ProjectMembership, String] {
  if !@contracts.is_project_id(membership.project_id) ||
    !@contracts.is_bot_id(membership.bot_id) {
    return Err("ProjectMembership ids are not canonical")
  }
  if membership.state != @contracts.MEMBERSHIP_STATE_ACTIVE {
    return Err("a new ProjectMembership must be active")
  }
  let bot = match self.get_bot(membership.bot_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("Bot not found: " + membership.bot_id)
    Err(message) => return Err(message)
  }
  if bot.state == @contracts.BOT_STATE_ARCHIVED {
    return Err("archived Bot is read-only")
  }
  let existing = match
    self.get_project_membership(membership.project_id, membership.bot_id) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  match existing {
    Some(current) =>
      if current.state == @contracts.MEMBERSHIP_STATE_ACTIVE {
        return Ok(current)
      } else {
        if !@bots.membership_transition_allowed(
          current.state,
          @contracts.MEMBERSHIP_STATE_ACTIVE,
        ) {
          return Err("ProjectMembership cannot be restored from " + current.state)
        }
        let record = {
          ..membership,
          added_at: now,
          removed_at: "",
        }
        self.append_membership_added(record, actor, now, bot.org_id)
      }
    None => {
      let added_at = if membership.added_at == "" { now } else { membership.added_at }
      let record = { ..membership, added_at }
      self.append_membership_added(record, actor, now, bot.org_id)
    }
  }
}

///|
fn append_membership_added(
  self : MachineStore,
  record : @contracts.ProjectMembership,
  actor : String,
  now : String,
  org_id : String,
) -> Result[@contracts.ProjectMembership, String] {
  let payload = @contracts.project_member_added_payload(record, actor)
  match
    self.append_bots_event(
      @contracts.EVENT_PROJECT_MEMBER_ADDED,
      @contracts.project_event_subject(record.project_id),
      payload,
      now,
      org_id,
    ) {
    Ok(_) => Ok(record)
    Err(message) => Err(message)
  }
}

///|
/// Remove a Bot's Project access. A project Chat cannot lose access while that
/// Bot still has a non-terminal AgentSession in it.
pub fn MachineStore::remove_project_membership(
  self : MachineStore,
  project_id : String,
  bot_id : String,
  reason : String,
  actor : String,
  now : String,
) -> Result[@contracts.ProjectMembership, String] {
  if !@contracts.is_project_id(project_id) || !@contracts.is_bot_id(bot_id) {
    return Err("ProjectMembership ids are not canonical")
  }
  let current = match self.get_project_membership(project_id, bot_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("ProjectMembership not found")
    Err(message) => return Err(message)
  }
  if current.state != @contracts.MEMBERSHIP_STATE_ACTIVE {
    return Err("ProjectMembership is not active")
  }
  let active_sessions = try {
    project_bot_nonterminal_session_count(self.conn, project_id, bot_id)
  } catch {
    error => return Err(sqlite_text(error))
  }
  if active_sessions > 0 {
    return Err(
      "ProjectMembership cannot be removed while the Bot has a non-terminal AgentSession",
    )
  }
  if !@bots.membership_transition_allowed(
    current.state,
    @contracts.MEMBERSHIP_STATE_REMOVED,
  ) {
    return Err("ProjectMembership cannot transition to removed")
  }
  let record = {
    ..current,
    state: @contracts.MEMBERSHIP_STATE_REMOVED,
    reason,
    removed_at: now,
  }
  let payload = @contracts.project_member_removed_payload(record, actor)
  match
    self.append_bots_event(
      @contracts.EVENT_PROJECT_MEMBER_REMOVED,
      @contracts.project_event_subject(project_id),
      payload,
      now,
      @contracts.ORG_LOCAL,
    ) {
    Ok(_) => Ok(record)
    Err(message) => Err(message)
  }
}

