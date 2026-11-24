///|
/// Task / Run contract tests: the two state machines, slot accounting, JSON
/// round-trips and the verify[] parameter parsing. Pure — no SQLite.

///|
fn sample_task() -> TaskRecord {
  TaskRecord::new(
    id="tsk_test",
    title="ship M5",
    goal="tasks + runs",
    parent_id="",
    project_id="prj_test",
    agent_id="",
    workspace_id="wsp_test",
    verify=["moon test", "moon build"],
    created_at="2026-01-01T00:00:00Z",
    status=TASK_STATUS_READY,
  )
}

///|
fn sample_run() -> RunRecord {
  RunRecord::new(
    id="run_test",
    task_id="tsk_test",
    agent_id="",
    machine_id="",
    workspace_id="wsp_test",
    worktree_id="wt_test",
    mode=RUN_MODE_COMMAND,
    command="echo ok",
    prompt="",
    idempotency_key="task/tsk_test/0",
    created_at="2026-01-01T00:00:00Z",
  )
}

///|
test "run state machine: happy path through verifying" {
  assert_true(run_transition_allowed(RUN_STATUS_QUEUED, RUN_STATUS_RUNNING))
  assert_true(run_transition_allowed(RUN_STATUS_RUNNING, RUN_STATUS_VERIFYING))
  assert_true(run_transition_allowed(RUN_STATUS_VERIFYING, RUN_STATUS_SUCCEEDED))
  assert_true(
    run_transition_allowed(RUN_STATUS_VERIFYING, RUN_STATUS_WAITING_APPROVAL),
  )
  assert_true(
    run_transition_allowed(RUN_STATUS_WAITING_APPROVAL, RUN_STATUS_SUCCEEDED),
  )
  assert_true(
    run_transition_allowed(RUN_STATUS_WAITING_APPROVAL, RUN_STATUS_VERIFYING),
  )
  assert_true(
    run_transition_allowed(RUN_STATUS_WAITING_APPROVAL, RUN_STATUS_FAILED),
  )
  assert_true(run_transition_allowed(RUN_STATUS_RUNNING, RUN_STATUS_FAILED))
  assert_true(run_transition_allowed(RUN_STATUS_RUNNING, RUN_STATUS_CANCELLED))
  assert_true(run_transition_allowed(RUN_STATUS_QUEUED, RUN_STATUS_CANCELLED))
}

///|
test "run state machine: terminal and skipped states are rejected" {
  assert_true(!run_transition_allowed(RUN_STATUS_SUCCEEDED, RUN_STATUS_RUNNING))
  assert_true(!run_transition_allowed(RUN_STATUS_FAILED, RUN_STATUS_RUNNING))
  assert_true(!run_transition_allowed(RUN_STATUS_CANCELLED, RUN_STATUS_QUEUED))
  // Verifying is only reachable after the main step ran.
  assert_true(!run_transition_allowed(RUN_STATUS_QUEUED, RUN_STATUS_VERIFYING))
  assert_true(!run_transition_allowed(RUN_STATUS_RUNNING, RUN_STATUS_QUEUED))
  assert_true(run_status_is_terminal(RUN_STATUS_SUCCEEDED))
  // `lost` is not terminal: M6 recovery decides between retry and failure.
  assert_true(!run_status_is_terminal(RUN_STATUS_LOST))
  assert_true(!run_status_is_terminal(RUN_STATUS_WAITING_APPROVAL))
}

///|
test "only executing states occupy a machine slot" {
  assert_true(run_status_occupies_slot(RUN_STATUS_RUNNING))
  assert_true(run_status_occupies_slot(RUN_STATUS_VERIFYING))
  assert_true(run_status_occupies_slot(RUN_STATUS_WAITING_APPROVAL))
  assert_true(run_status_occupies_slot(RUN_STATUS_WAITING_INPUT))
  assert_true(!run_status_occupies_slot(RUN_STATUS_QUEUED))
  assert_true(!run_status_occupies_slot(RUN_STATUS_SUCCEEDED))
  assert_true(!run_status_occupies_slot(RUN_STATUS_CANCELLED))
}

///|
test "task state machine rolls up run statuses" {
  assert_true(task_transition_allowed(TASK_STATUS_DRAFT, TASK_STATUS_PLANNED))
  assert_true(task_transition_allowed(TASK_STATUS_PLANNED, TASK_STATUS_READY))
  assert_true(task_transition_allowed(TASK_STATUS_READY, TASK_STATUS_RUNNING))
  assert_true(task_transition_allowed(TASK_STATUS_RUNNING, TASK_STATUS_SUCCEEDED))
  assert_true(
    task_transition_allowed(TASK_STATUS_RUNNING, TASK_STATUS_WAITING_APPROVAL),
  )
  assert_true(
    task_transition_allowed(TASK_STATUS_WAITING_APPROVAL, TASK_STATUS_RUNNING),
  )
  assert_true(
    task_transition_allowed(TASK_STATUS_WAITING_OWNER, TASK_STATUS_RUNNING),
  )
  assert_true(task_transition_allowed(TASK_STATUS_RUNNING, TASK_STATUS_FAILED))
  assert_true(task_transition_allowed(TASK_STATUS_RUNNING, TASK_STATUS_CANCELLED))
  assert_true(!task_transition_allowed(TASK_STATUS_SUCCEEDED, TASK_STATUS_RUNNING))
  assert_true(!task_transition_allowed(TASK_STATUS_CANCELLED, TASK_STATUS_READY))
  assert_true(task_status_is_terminal(TASK_STATUS_SUCCEEDED))
  assert_true(task_status_is_terminal(TASK_STATUS_CANCELLED))
  assert_true(task_status_is_active(TASK_STATUS_RUNNING))
}

///|
test "task and run records round-trip through JSON" {
  let task = sample_task()
  let parsed_task = task_from_json(task.to_json())
  match parsed_task {
    Some(value) => {
      assert_eq(value.id, task.id)
      assert_eq(value.status, TASK_STATUS_READY)
      assert_eq(value.verify.length(), 2)
      assert_eq(value.verify[0], "moon test")
      assert_eq(value.parent_id, "")
    }
    None => fail("task JSON did not round-trip")
  }
  let run = sample_run()
  assert_eq(run.status, RUN_STATUS_QUEUED)
  let parsed_run = run_from_json(run.to_json())
  match parsed_run {
    Some(value) => {
      assert_eq(value.id, run.id)
      assert_eq(value.mode, RUN_MODE_COMMAND)
      assert_eq(value.command, "echo ok")
      assert_eq(value.idempotency_key, "task/tsk_test/0")
      assert_eq(value.status, RUN_STATUS_QUEUED)
    }
    None => fail("run JSON did not round-trip")
  }
}

///|
test "verify[] accepts an array or one command per line" {
  let from_array = verify_list_param(
    Map([
      (
        "verify",
        json_array([
          json_string("moon test"),
          json_string("  "),
          json_string("moon build"),
        ]),
      ),
    ]),
    "verify",
  )
  assert_eq(from_array.length(), 2)
  let from_text = verify_list_param(
    Map([("verify", json_string("moon test\n\nmoon build\n"))]),
    "verify",
  )
  assert_eq(from_text.length(), 2)
  assert_eq(from_text[1], "moon build")
  let missing = verify_list_param(Map([]), "verify")
  assert_eq(missing.length(), 0)
}

///|
test "search hits round-trip" {
  let hits : Array[SearchHit] = [
    { kind: "session", ref_id: "ses_1", title: "session", ts: "t1", snippet: "run ok" },
    { kind: "decision", ref_id: "dec_1", title: "verify", ts: "t2", snippet: "waived" },
  ]
  let parsed = parse_search_hits(search_hits_result(hits))
  match parsed {
    Ok(value) => {
      assert_eq(value.length(), 2)
      assert_eq(value[0].ref_id, "ses_1")
      assert_eq(value[1].kind, "decision")
    }
    Err(message) => fail("search hits did not round-trip: " + message)
  }
}
