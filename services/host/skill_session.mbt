///|
/// Session resolution and materialisation (ADR-0015 §4, §6.1).
///
/// Bindings are unioned by skill name across agent, task and explicit session
/// scopes. A differing version/hash for the same name is a conflict, never an
/// implicit "latest". The resolved tuple is frozen into the session record and
/// the capability map before the ACP session receives any prompt; disabling a
/// binding later only affects new sessions because the gateway rechecks the
/// persisted binding row and refuses new calls.

///|
pub struct SkillSessionEntry {
  snapshot : @contracts.SkillSnapshotEntry
  bundle : @skills.SkillBundle
  scope : String
  scope_ref : String
  mode : String
  /// Materialised directory (entry + resources). Empty for `available`
  /// entries and for remote sessions, which are declarative only.
  resource_root : String
}

///|
pub struct SkillSessionSetup {
  entries : Array[SkillSessionEntry]
  injection : @skills.SkillInjection
  token : String
  loaded : Int
  available : Int
}

///|
pub type SkillSetupResult = Result[SkillSessionSetup, @skills.SkillFault]

///|
struct SkillChoice {
  name : String
  version : String
  content_hash : String
  mode : String
  scope : String
  scope_ref : String
}

///|
fn skill_scope_rank(scope : String) -> Int {
  if scope == @contracts.SKILL_SCOPE_SESSION {
    3
  } else if scope == @contracts.SKILL_SCOPE_TASK {
    2
  } else {
    1
  }
}

///|
fn skill_merge_choice(
  chosen : Map[String, SkillChoice],
  binding : @contracts.SkillBinding,
  scope : String,
  scope_ref : String,
) -> @skills.SkillFault? {
  match chosen.get(binding.name) {
    None => {
      chosen.set(
        binding.name,
        {
          name: binding.name,
          version: binding.version,
          content_hash: binding.content_hash,
          mode: binding.mode,
          scope,
          scope_ref,
        },
      )
      None
    }
    Some(existing) => {
      if existing.version != binding.version ||
        existing.content_hash != binding.content_hash {
        return Some(
          @skills.SkillFault::new(
            @contracts.SKILL_ERR_CONFLICT,
            "conflicting tuple for skill " + binding.name,
          ),
        )
      }
      let mode = if existing.mode == @contracts.SKILL_MODE_LOADED ||
        binding.mode == @contracts.SKILL_MODE_LOADED {
        @contracts.SKILL_MODE_LOADED
      } else {
        @contracts.SKILL_MODE_AVAILABLE
      }
      let replace_scope = skill_scope_rank(scope) > skill_scope_rank(existing.scope)
      let updated : SkillChoice = {
        ..existing,
        mode,
        scope: if replace_scope { scope } else { existing.scope },
        scope_ref: if replace_scope { scope_ref } else { existing.scope_ref },
      }
      chosen.set(binding.name, updated)
      None
    }
  }
}

///|
async fn skill_session_cleanup_dirs(session_skills_dir : String) -> Unit {
  @fs.rmdir(session_skills_dir, recursive=true) catch { _ => () }
}

///|
/// Resolve and freeze the skill set for one new session. Must be called before
/// the ACP session is created; every failure refuses `agent.start` and leaves
/// no materialised copy behind.
pub async fn setup_skill_session(
  state : HostState,
  agent_id : String,
  session_id : String,
  task_id : String,
  home : String,
  cwd : String,
  workspace_id : String,
  remote : Bool,
  explicit : Array[@contracts.SkillBinding],
) -> SkillSetupResult {
  if !state.skill_enabled {
    return Ok({
      entries: [],
      injection: @skills.build_skill_injection([], invocable=false),
      token: "",
      loaded: 0,
      available: 0,
    })
  }
  let chosen : Map[String, SkillChoice] = Map([])
  // Session-explicit bindings are the most specific. They are accepted only
  // when the exact tuple is imported, allowlisted and unrevoked.
  for binding in explicit {
    match skill_merge_choice(chosen, binding, @contracts.SKILL_SCOPE_SESSION, session_id) {
      Some(fault) => return Err(fault)
      None => ()
    }
  }
  state.mutex.acquire()
  let task_bindings = if task_id != "" {
    state.store.list_skill_bindings(@contracts.SKILL_SCOPE_TASK, task_id)
  } else {
    Ok([])
  }
  let task_record = if task_id != "" {
    state.store.get_task(task_id)
  } else {
    Ok(None)
  }
  let agent_bindings = state.store.list_skill_bindings(
    @contracts.SKILL_SCOPE_AGENT,
    agent_id,
  )
  let ceiling = match state.store.get_agent_skill_permissions(agent_id) {
    Ok(Some(value)) => value
    Ok(None) => @contracts.default_skill_permissions()
    Err(message) => {
      state.mutex.release()
      return Err(@skills.SkillFault::new("store_error", message))
    }
  }
  state.mutex.release()
  let task_rows = match task_bindings {
    Ok(value) => value
    Err(message) => return Err(@skills.SkillFault::new("store_error", message))
  }
  // A Task declares exact tuple bindings in its own record. They have the same
  // rank as task-scope bindings set through `skill.enable`, and both are
  // unioned by name; a differing tuple for one name is a conflict.
  let record_task_skills = match task_record {
    Ok(Some(record)) => record.skills
    Ok(None) => []
    Err(message) => return Err(@skills.SkillFault::new("store_error", message))
  }
  for binding in record_task_skills {
    match skill_merge_choice(chosen, binding, @contracts.SKILL_SCOPE_TASK, task_id) {
      Some(fault) => return Err(fault)
      None => ()
    }
  }
  for row in task_rows {
    let binding = @contracts.SkillBinding::new(
      name=row.name,
      version=row.version,
      content_hash=row.content_hash,
      mode=row.mode,
    )
    match skill_merge_choice(chosen, binding, @contracts.SKILL_SCOPE_TASK, task_id) {
      Some(fault) => return Err(fault)
      None => ()
    }
  }
  let agent_rows = match agent_bindings {
    Ok(value) => value
    Err(message) => return Err(@skills.SkillFault::new("store_error", message))
  }
  for row in agent_rows {
    let binding = @contracts.SkillBinding::new(
      name=row.name,
      version=row.version,
      content_hash=row.content_hash,
      mode=row.mode,
    )
    match skill_merge_choice(chosen, binding, @contracts.SKILL_SCOPE_AGENT, agent_id) {
      Some(fault) => return Err(fault)
      None => ()
    }
  }
  let choices : Array[SkillChoice] = []
  let mut loaded_count = 0
  let mut available_count = 0
  for _name, choice in chosen {
    choices.push(choice)
    if choice.mode == @contracts.SKILL_MODE_LOADED {
      loaded_count = loaded_count + 1
    } else {
      available_count = available_count + 1
    }
  }
  if loaded_count > @skills.SKILL_MAX_LOADED {
    return Err(
      @skills.SkillFault::new(
        @contracts.SKILL_ERR_LIMIT_EXCEEDED,
        "at most " + @skills.SKILL_MAX_LOADED.to_string() + " loaded skills per session",
      ),
    )
  }
  if available_count > @skills.SKILL_MAX_AVAILABLE {
    return Err(
      @skills.SkillFault::new(
        @contracts.SKILL_ERR_LIMIT_EXCEEDED,
        "at most " + @skills.SKILL_MAX_AVAILABLE.to_string() + " available skills per session",
      ),
    )
  }
  // Deterministic order makes the injected block and the snapshot stable.
  choices.sort_by(fn(left : SkillChoice, right : SkillChoice) -> Int32 {
    @recipes.compare_utf8(left.name, right.name)
  })
  let keys = skill_key_snapshot(state)
  let session_skills_dir = home + "/sessions/" + session_id + "/skills"
  let loaded_bundles : Array[@skills.SkillBundle] = []
  let entries : Array[SkillSessionEntry] = []
  let loaded_entry_ids : Array[String] = []
  let mut verify_error : @skills.SkillFault? = None
  for choice in choices {
    state.mutex.acquire()
    let tuple = skill_tuple_allowed(
      state,
      choice.name,
      choice.version,
      choice.content_hash,
    )
    let row = state.store.get_skill_row(
      choice.name,
      choice.version,
      choice.content_hash,
    )
    state.mutex.release()
    match tuple {
      Ok(_) => ()
      Err(error) => {
        verify_error = Some(
          @skills.SkillFault::new(@contracts.SKILL_ERR_NOT_ALLOWLISTED, error.message),
        )
        break
      }
    }
    match row {
      Ok(Some(value)) => {
        let manifest_row = match @skills.parse_skill_manifest(value.manifest_json) {
          Ok(parsed) => Ok(parsed)
          Err(fault) => Err(fault)
        }
        let manifest = match manifest_row {
          Ok(value) => value
          Err(fault) => {
            verify_error = Some(fault)
            break
          }
        }
        if manifest.name != choice.name || manifest.version != choice.version ||
          manifest.content_hash != choice.content_hash {
          verify_error = Some(
            @skills.SkillFault::new(
              @contracts.SKILL_ERR_HASH_MISMATCH,
              "stored manifest does not match its index tuple",
            ),
          )
          break
        }
        if !@skills.skill_permissions_subset(manifest.permissions, ceiling) {
          verify_error = Some(
            @skills.SkillFault::new(
              @contracts.SKILL_ERR_PERMISSION_DENIED,
              "skill permissions exceed the agent ceiling: " +
              choice.name,
            ),
          )
          break
        }
        if choice.mode == @contracts.SKILL_MODE_LOADED {
          for command in manifest.commands {
            let mut duplicate = false
            for existing in loaded_entry_ids {
              if existing == command.id {
                duplicate = true
              }
            }
            if duplicate {
              verify_error = Some(
                @skills.SkillFault::new(
                  @contracts.SKILL_ERR_CONFLICT,
                  "duplicate entry_id across loaded skills: " + command.id,
                ),
              )
              break
            }
            loaded_entry_ids.push(command.id)
          }
          if verify_error is Some(_) {
            break
          }
        }
        let store_path = @skills.skill_store_path(state.state_dir, manifest)
        let loaded = @skills.load_stored_skill(store_path, keys, state.verifier)
        let bundle = match loaded {
          Ok(value) => value
          Err(fault) => {
            verify_error = Some(fault)
            break
          }
        }
        // Dependency readiness is checked per session: a missing binary means
        // the session refuses to load the skill (the enable path owns the
        // readable readiness Decision).
        let deps = skill_verify_dependencies(state, manifest, agent_id, session_id)
        match deps {
          Ok(_) => ()
          Err(error) => {
            verify_error = Some(
              @skills.SkillFault::new(@contracts.SKILL_ERR_DEPENDENCY_MISSING, error.message),
            )
            break
          }
        }
        if choice.mode == @contracts.SKILL_MODE_LOADED {
          loaded_bundles.push(bundle)
        }
        let entry_ids : Array[String] = []
        for command in manifest.commands {
          entry_ids.push(command.id)
        }
        entries.push({
          snapshot: {
            name: manifest.name,
            version: manifest.version,
            content_hash: manifest.content_hash,
            scope: choice.scope,
            mode: choice.mode,
            entry_sha256: @skills.sha256_file_hex(bundle.entry_text),
            entry_ids,
          },
          bundle,
          scope: choice.scope,
          scope_ref: choice.scope_ref,
          mode: choice.mode,
          resource_root: "",
        })
      }
      Ok(None) => {
        verify_error = Some(
          @skills.SkillFault::new(
            @contracts.SKILL_ERR_NOT_ALLOWLISTED,
            "skill bundle is not imported: " + choice.name,
          ),
        )
        break
      }
      Err(message) => {
        verify_error = Some(@skills.SkillFault::new("store_error", message))
        break
      }
    }
  }
  match verify_error {
    Some(fault) => return Err(fault)
    None => ()
  }
  // Materialise loaded entries for local sessions only. Remote sessions are
  // declarative: no copy lands on this host and the gateway is unavailable.
  let mut materialized : Array[SkillSessionEntry] = []
  if !remote {
    let mut dirs_ready = false
    for entry in entries {
      if entry.mode == @contracts.SKILL_MODE_LOADED {
        if !dirs_ready {
          @fs.mkdir(session_skills_dir, permission=0o700, recursive=true, allow_exist=true) catch {
            _ => {
              skill_session_cleanup_dirs(session_skills_dir)
              return Err(
                @skills.SkillFault::new(
                  @contracts.SKILL_ERR_INVALID_PATH,
                  "cannot create session skill directory",
                ),
              )
            }
          }
          dirs_ready = true
        }
        let target = match
          @skills.materialize_skill(session_skills_dir, entry.bundle) {
          Ok(value) => value
          Err(fault) => {
            skill_session_cleanup_dirs(session_skills_dir)
            return Err(fault)
          }
        }
        materialized.push({ ..entry, resource_root: target })
      } else {
        materialized.push(entry)
      }
    }
  } else {
    materialized = entries
  }
  let injection_entries : Array[@skills.SkillInjectionEntry] = []
  for entry in materialized {
    injection_entries.push({
      name: entry.snapshot.name,
      version: entry.snapshot.version,
      content_hash: entry.snapshot.content_hash,
      scope: entry.scope,
      mode: entry.mode,
      entry_text: entry.bundle.entry_text,
      entry_ids: entry.snapshot.entry_ids,
      resource_root: entry.resource_root,
    })
  }
  let injection = @skills.build_skill_injection(
    injection_entries,
    invocable=!remote,
  )
  let mut token = ""
  if !remote && injection.loaded_count > 0 {
    token = random_token()
  }
  if token != "" {
    let capability_entries : Map[String, SkillCapabilityEntry] = Map([])
    for entry in materialized {
      if entry.mode != @contracts.SKILL_MODE_LOADED {
        continue
      }
      for entry_id in entry.snapshot.entry_ids {
        capability_entries.set(
          entry_id,
          {
            name: entry.snapshot.name,
            version: entry.snapshot.version,
            content_hash: entry.snapshot.content_hash,
            scope: entry.scope,
            scope_ref: entry.scope_ref,
            mode: entry.mode,
            entry_ids: entry.snapshot.entry_ids,
            resource_root: entry.resource_root,
          },
        )
      }
    }
    let capability : SkillCapability = {
      token,
      session_id,
      agent_id,
      cwd,
      workspace_id,
      home: session_skills_dir,
      remote,
      entries: capability_entries,
    }
    state.mutex.acquire()
    state.skill_capabilities.set(token, capability)
    state.mutex.release()
  }
  Ok({
    entries: materialized,
    injection,
    token,
    loaded: injection.loaded_count,
    available: injection.available_count,
  })
}

///|
/// Drop the capability and remove the session's materialised skill copies.
/// Session memory artifacts and logs live elsewhere and are untouched.
pub async fn finalize_skill_session(
  state : HostState,
  token : String,
  session_id : String,
  home : String,
) -> Unit {
  if token != "" {
    state.mutex.acquire()
    state.skill_capabilities.remove(token)
    state.mutex.release()
  }
  if session_id != "" {
    skill_session_cleanup_dirs(home + "/sessions/" + session_id + "/skills")
  }
  skill_gc_pending_uninstalls(state)
}

///|
/// Snapshot metadata for the session record. Bodies are never included.
pub fn skill_session_snapshot(
  entries : Array[SkillSessionEntry],
) -> Array[@contracts.SkillSnapshotEntry] {
  entries.map(fn(entry) { entry.snapshot })
}
