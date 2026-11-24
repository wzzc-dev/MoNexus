///|
/// Task / Run / Evidence persistence tests: projection writes, idempotent
/// dispatch lookup, per-machine slot accounting, search and event replay.

///|
fn test_project() -> @contracts.ProjectRecord {
  @contracts.ProjectRecord::new(
    id="prj_1",
    name="demo",
    repo_url="",
    default_branch="main",
    verify=["moon test"],
    created_at="2026-01-01T00:00:00Z",
  )
}

///|
fn test_task() -> @contracts.TaskRecord {
  @contracts.TaskRecord::new(
    id="tsk_1",
    title="demo task",
    goal="verify the gate",
    parent_id="",
    project_id="prj_1",
    agent_id="",
    workspace_id="wsp_1",
    verify=["moon test"],
    created_at="2026-01-01T00:00:00Z",
    status=@contracts.TASK_STATUS_READY,
  )
}

///|
fn test_run(id : String, machine_id : String, status : String) -> @contracts.RunRecord {
  let base = @contracts.RunRecord::new(
    id~,
    task_id="tsk_1",
    agent_id="",
    machine_id~,
    workspace_id="wsp_1",
    worktree_id="",
    mode=@contracts.RUN_MODE_COMMAND,
    command="echo ok",
    prompt="",
    idempotency_key="key/" + id,
    created_at="2026-01-01T00:00:00Z",
  )
  { ..base, status }
}

///|
fn task_event(
  seq : Int64,
  event_type : String,
  subject : String,
  payload : @json.Json,
) -> @contracts.EventEnvelope {
  @contracts.EventEnvelope::new(
    id="evt-" + seq.to_string(),
    org_id=@contracts.ORG_LOCAL,
    event_type~,
    ts="2026-01-01T00:00:00Z",
    subject~,
    seq~,
    payload~,
    idempotency_key="evt/" + seq.to_string(),
  )
}

///|
fn open_test_store() -> MachineStore raise {
  match MachineStore::open(":memory:") {
    Ok(value) => value
    Err(message) => fail("cannot open in-memory store: " + message)
  }
}

///|
test "task projection persists and lists with filters" {
  let store = open_test_store()
  let project = test_project()
  match
    store.record_project_event(
      task_event(1L, @contracts.EVENT_PROJECT_CREATED, "project/prj_1", project.to_json()),
      project,
    ) {
    Ok(_) => ()
    Err(message) => fail("record_project_event failed: " + message)
  }
  let task = test_task()
  match
    store.record_task_event(
      task_event(2L, @contracts.EVENT_TASK_CREATED, "task/tsk_1", task.to_json()),
      task,
    ) {
    Ok(_) => ()
    Err(message) => fail("record_task_event failed: " + message)
  }
  match store.get_task("tsk_1") {
    Ok(Some(value)) => {
      assert_eq(value.title, "demo task")
      assert_eq(value.status, @contracts.TASK_STATUS_READY)
    }
    Ok(None) => fail("task projection missing")
    Err(message) => fail("get_task failed: " + message)
  }
  match store.list_tasks(@contracts.TASK_STATUS_READY, "") {
    Ok(value) => assert_eq(value.length(), 1)
    Err(message) => fail("list_tasks failed: " + message)
  }
  match store.list_tasks(@contracts.TASK_STATUS_DRAFT, "") {
    Ok(value) => assert_eq(value.length(), 0)
    Err(message) => fail("list_tasks failed: " + message)
  }
  store.close()
}

///|
test "idempotency key finds the already dispatched run" {
  let store = open_test_store()
  let run = test_run("run_1", "", @contracts.RUN_STATUS_QUEUED)
  match
    store.record_run_event(
      task_event(1L, @contracts.EVENT_RUN_QUEUED, "run/run_1", run.to_json()),
      run,
    ) {
    Ok(_) => ()
    Err(message) => fail("record_run_event failed: " + message)
  }
  match store.find_run_by_idempotency("key/run_1") {
    Ok(Some(value)) => assert_eq(value.id, "run_1")
    Ok(None) => fail("idempotent run lookup missed")
    Err(message) => fail("find_run_by_idempotency failed: " + message)
  }
  match store.find_run_by_idempotency("") {
    Ok(Some(_)) => fail("empty key must not match")
    Ok(None) => ()
    Err(message) => fail("find_run_by_idempotency failed: " + message)
  }
  store.close()
}

///|
test "slot counting ignores queued and terminal runs" {
  let store = open_test_store()
  let runs = [
    test_run("run_a", "", @contracts.RUN_STATUS_RUNNING),
    test_run("run_b", "", @contracts.RUN_STATUS_VERIFYING),
    test_run("run_c", "", @contracts.RUN_STATUS_QUEUED),
    test_run("run_d", "", @contracts.RUN_STATUS_SUCCEEDED),
    test_run("run_e", "mch_1", @contracts.RUN_STATUS_RUNNING),
  ]
  let mut seq = 0L
  for run in runs {
    seq = seq + 1L
    match
      store.record_run_event(
        task_event(seq, @contracts.EVENT_RUN_QUEUED, "run/" + run.id, run.to_json()),
        run,
      ) {
      Ok(_) => ()
      Err(message) => fail("record_run_event failed: " + message)
    }
  }
  match store.count_slot_runs("") {
    Ok(value) => assert_eq(value, 2)
    Err(message) => fail("count_slot_runs failed: " + message)
  }
  match store.count_slot_runs("mch_1") {
    Ok(value) => assert_eq(value, 1)
    Err(message) => fail("count_slot_runs failed: " + message)
  }
  store.close()
}

///|
test "search indexes sessions and decisions, FTS5 or LIKE" {
  let store = open_test_store()
  match
    store.search_index(
      "session/ses_1",
      "session",
      "ses_1",
      "session agt_1",
      "the agent fixed the flaky test and stopped",
      "2026-01-01T00:00:00Z",
    ) {
    Ok(_) => ()
    Err(message) => fail("search_index failed: " + message)
  }
  match
    store.search_index(
      "decision/dec_1",
      "decision",
      "dec_1",
      "verify failed",
      "owner waived the failing lint",
      "2026-01-01T00:00:01Z",
    ) {
    Ok(_) => ()
    Err(message) => fail("search_index failed: " + message)
  }
  match store.search_docs("flaky", 10) {
    Ok(hits) => {
      assert_eq(hits.length(), 1)
      assert_eq(hits[0].kind, "session")
      assert_true(hits[0].snippet.contains("flaky"))
    }
    Err(message) => fail("search_docs failed: " + message)
  }
  match store.search_docs("waived", 10) {
    Ok(hits) => {
      assert_eq(hits.length(), 1)
      assert_eq(hits[0].ref_id, "dec_1")
    }
    Err(message) => fail("search_docs failed: " + message)
  }
  match store.search_docs("", 10) {
    Ok(hits) => assert_eq(hits.length(), 0)
    Err(message) => fail("empty search failed: " + message)
  }
  store.close()
}

///|
test "task projection rebuilds from events" {
  let store = open_test_store()
  let project = test_project()
  let task = test_task()
  let run = test_run("run_1", "", @contracts.RUN_STATUS_QUEUED)
  let evidence = @contracts.EvidenceRecord::new(
    id="evd_1",
    run_id="run_1",
    name="verify[1]",
    kind="test",
    command="moon test",
    started_at="2026-01-01T00:00:02Z",
  )
  let events = [
    task_event(1L, @contracts.EVENT_PROJECT_CREATED, "project/prj_1", project.to_json()),
    task_event(2L, @contracts.EVENT_TASK_CREATED, "task/tsk_1", task.to_json()),
    task_event(3L, @contracts.EVENT_RUN_QUEUED, "run/run_1", run.to_json()),
    task_event(4L, @contracts.EVENT_RUN_EVIDENCE, "run/run_1", evidence.to_json()),
  ]
  for event in events {
    match store.append_event(event) {
      Ok(_) => ()
      Err(message) => fail("append_event failed: " + message)
    }
  }
  // The events were appended without projections, which is what a crash
  // between the event write and the projection write leaves behind.
  match store.reconcile_task_projection() {
    Ok((projects, tasks, runs)) => {
      assert_eq(projects, 1)
      assert_eq(tasks, 1)
      // One run event plus one evidence event (which also carries the run).
      assert_eq(runs, 2)
    }
    Err(message) => fail("reconcile_task_projection failed: " + message)
  }
  match store.get_run("run_1") {
    Ok(Some(value)) => assert_eq(value.status, @contracts.RUN_STATUS_QUEUED)
    Ok(None) => fail("run projection was not rebuilt")
    Err(message) => fail("get_run failed: " + message)
  }
  match store.list_evidence("run_1") {
    Ok(value) => assert_eq(value.length(), 1)
    Err(message) => fail("list_evidence failed: " + message)
  }
  store.close()
}
