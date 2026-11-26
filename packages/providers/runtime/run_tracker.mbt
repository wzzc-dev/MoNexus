///|
/// Primary-side run tracker for a paired runtime (A1.2b).
///
/// The node is the only authority on what actually executed; the primary only
/// observes the durable event stream it accepts. This tracker therefore:
///
/// - dedupes by `(run_id, run_seq)`: a late, duplicate or replayed event never
///   rewinds state, and `cursor()` only moves forward over accepted seqs;
/// - settles a run **only** from an explicit terminal event or a later
///   `exec.status`/`pty.status` answer, never from the absence of events;
/// - on connection loss marks every non-terminal run `interrupted`, so a
///   dropped link can never be mistaken for success (ADR-0012 §4);
/// - after reconnect resumes at `cursor()` and lets `reconcile` re-query the
///   node, so the same stable `run_id` continues rather than being re-created.
///
/// The tracker is bounded: at most `MAX_TRACKED_RUNS` runs are kept, oldest
/// settled entries are evicted first.

///|
pub const MAX_TRACKED_RUNS : Int = 256

///|
/// Event kinds published by the runtime core (A1.1). They are part of the
/// wire contract, so the primary-side tracker names them without importing
/// the node's execution package.
const EVENT_EXEC_STARTED : String = "runtime.exec.started"

///|
const EVENT_EXEC_STDOUT : String = "runtime.exec.stdout"

///|
const EVENT_EXEC_STDERR : String = "runtime.exec.stderr"

///|
const EVENT_EXEC_TRUNCATED : String = "runtime.exec.truncated"

///|
const EVENT_EXEC_EXITED : String = "runtime.exec.exited"

///|
const EVENT_PTY_OPENED : String = "runtime.pty.opened"

///|
const EVENT_PTY_OUTPUT : String = "runtime.pty.output"

///|
const EVENT_PTY_GAP : String = "runtime.pty.gap"

///|
const EVENT_PTY_EXITED : String = "runtime.pty.exited"

///|
/// Streaming-process lifecycle events (A1.4). Streams are polled directly;
/// only started/exited are durable events, so a settled process can never be
/// resurrected by a late chunk or replay.
const EVENT_PROCESS_STARTED : String = "runtime.process.started"

///|
const EVENT_PROCESS_EXITED : String = "runtime.process.exited"

///|
const EVENT_GIT_RESULT : String = "runtime.git.result"

///|
const EVENT_GIT_ERRORED : String = "runtime.git.errored"

///|
const EVENT_GIT_WORKTREE_ADDED : String = "runtime.git.worktree_added"

///|
const EVENT_GIT_WORKTREE_REMOVED : String = "runtime.git.worktree_removed"

///|
pub(all) enum RunPhase {
  Pending
  Running
  Interrupted
  Succeeded
  Failed
  Cancelled
  Lost
}

///|
pub fn RunPhase::text(self : RunPhase) -> String {
  match self {
    Pending => "pending"
    Running => "running"
    Interrupted => "interrupted"
    Succeeded => "succeeded"
    Failed => "failed"
    Cancelled => "cancelled"
    Lost => "lost"
  }
}

///|
/// True once the run cannot change again. `Lost` is treated as settled here:
/// the node has no live process left to report on, and the primary must not
/// pretend the run is still making progress.
pub fn RunPhase::is_settled(self : RunPhase) -> Bool {
  match self {
    Succeeded | Failed | Cancelled | Lost => true
    Pending | Running | Interrupted => false
  }
}

///|
pub fn RunPhase::is_pending(self : RunPhase) -> Bool {
  match self {
    Pending => true
    _ => false
  }
}

///|
pub fn RunPhase::is_lost(self : RunPhase) -> Bool {
  match self {
    Lost => true
    _ => false
  }
}

///|
pub fn RunPhase::is_interrupted(self : RunPhase) -> Bool {
  match self {
    Interrupted => true
    _ => false
  }
}

///|
pub fn run_phase_of_status(status : String) -> RunPhase {
  if status == @contracts.RUN_STATUS_SUCCEEDED {
    Succeeded
  } else if status == @contracts.RUN_STATUS_FAILED {
    Failed
  } else if status == @contracts.RUN_STATUS_CANCELLED {
    Cancelled
  } else if status == @contracts.RUN_STATUS_LOST {
    Lost
  } else if status == @contracts.RUN_STATUS_RUNNING {
    Running
  } else {
    Pending
  }
}

///|
pub(all) struct TrackedRun {
  run_id : String
  kind : String
  client_request_id : String
  phase : RunPhase
  last_run_seq : Int64
  last_event_seq : Int64
  exit_code : Int?
  stop_reason : String
  ended_at : String
}

///|
pub fn TrackedRun::is_exec(self : TrackedRun) -> Bool {
  self.kind == "exec"
}

///|
pub fn TrackedRun::is_pty(self : TrackedRun) -> Bool {
  self.kind == "pty"
}

///|
/// A streaming process run (`process.start`), as opposed to an exec run or a
/// PTY session. Only process runs are launched by AgentRuntime.
pub fn TrackedRun::is_process(self : TrackedRun) -> Bool {
  self.kind == "process"
}

///|
pub struct RunTracker {
  runtime_id : String
  runs : Map[String, TrackedRun]
  order : Array[String]
  cursor : Ref[Int64]
  interrupted : Ref[Bool]
  max_runs : Int
}

///|
pub fn RunTracker::new(runtime_id : String) -> RunTracker {
  {
    runtime_id,
    runs: Map([]),
    order: [],
    cursor: Ref(0L),
    interrupted: Ref(false),
    max_runs: MAX_TRACKED_RUNS,
  }
}

///|
pub fn RunTracker::runtime_id(self : RunTracker) -> String {
  self.runtime_id
}

///|
/// Last event seq observed. `RuntimeMachine::pump_events` resumes from this
/// exact cursor, so a reconnect never re-reads an already-tracked event.
pub fn RunTracker::cursor(self : RunTracker) -> Int64 {
  self.cursor.val
}

///|
pub fn RunTracker::length(self : RunTracker) -> Int {
  self.runs.length()
}

///|
pub fn RunTracker::is_interrupted(self : RunTracker) -> Bool {
  self.interrupted.val
}

///|
pub fn RunTracker::get(self : RunTracker, run_id : String) -> TrackedRun? {
  self.runs.get(run_id)
}

///|
/// Snapshot of tracked runs in first-seen order.
pub fn RunTracker::runs(self : RunTracker) -> Array[TrackedRun] {
  let out : Array[TrackedRun] = []
  for run_id in self.order {
    match self.runs.get(run_id) {
      Some(value) => out.push(value)
      None => ()
    }
  }
  out
}

///|
/// Record a run the primary just started (or is about to start). Existing
/// state is kept, so a duplicate `exec.start` cannot reset progress.
pub fn RunTracker::begin(
  self : RunTracker,
  run_id : String,
  kind : String,
  client_request_id : String,
) -> Unit {
  match self.runs.get(run_id) {
    Some(_) => ()
    None => {
      self.insert({
        run_id,
        kind,
        client_request_id,
        phase: Pending,
        last_run_seq: 0L,
        last_event_seq: 0L,
        exit_code: None,
        stop_reason: "",
        ended_at: "",
      })
    }
  }
}

///|
fn kind_of_event(event_kind : String) -> String {
  if event_kind.has_prefix("runtime.exec.") {
    "exec"
  } else if event_kind.has_prefix("runtime.pty.") {
    "pty"
  } else if event_kind.has_prefix("runtime.process.") {
    "process"
  } else if event_kind.has_prefix("runtime.git.") {
    "git"
  } else {
    "other"
  }
}

///|
fn phase_after_terminal_payload(
  payload : @json.Json,
  fallback : RunPhase,
) -> RunPhase {
  let object = match @contracts.as_object(payload) {
    Some(value) => value
    None => return fallback
  }
  let status = @contracts.string_field_or(object, "status", "")
  if status == "" {
    fallback
  } else {
    run_phase_of_status(status)
  }
}

///|
fn terminal_exit_code(payload : @json.Json) -> Int? {
  match @contracts.as_object(payload) {
    Some(object) => @contracts.int_field(object, "exit_code")
    None => None
  }
}

///|
/// Feed one accepted event. Returns `false` when it was a duplicate or came
/// from an older per-run seq (dropped without touching state). The global
/// cursor still advances for a dropped duplicate so it is not re-read later.
pub fn RunTracker::observe(
  self : RunTracker,
  event : @transport.WireEvent,
) -> Bool {
  if event.seq <= self.cursor.val {
    return false
  }
  if event.seq > self.cursor.val {
    self.cursor.val = event.seq
  }
  let kind = kind_of_event(event.kind)
  let existing = match self.runs.get(event.run_id) {
    Some(value) => value
    None => {
      let created : TrackedRun = {
        run_id: event.run_id,
        kind,
        client_request_id: "",
        phase: Pending,
        last_run_seq: 0L,
        last_event_seq: 0L,
        exit_code: None,
        stop_reason: "",
        ended_at: "",
      }
      self.insert(created)
      created
    }
  }
  // A per-run duplicate (same run_seq) or a replayed older seq never rewinds
  // or re-settles the run.
  if event.run_seq <= existing.last_run_seq {
    return false
  }
  let mut phase = existing.phase
  let mut exit_code = existing.exit_code
  let mut stop_reason = existing.stop_reason
  let mut ended_at = existing.ended_at
  if event.kind == EVENT_EXEC_STARTED {
    if phase.is_pending() {
      phase = Running
    }
  } else if
    event.kind == EVENT_EXEC_STDOUT ||
    event.kind == EVENT_EXEC_STDERR ||
    event.kind == EVENT_EXEC_TRUNCATED {
    if phase.is_pending() || phase.is_interrupted() {
      phase = Running
    }
  } else if event.kind == EVENT_EXEC_EXITED {
    phase = phase_after_terminal_payload(event.payload, Failed)
    exit_code = terminal_exit_code(event.payload)
    stop_reason = payload_string(event.payload, "stop_reason")
    ended_at = payload_string(event.payload, "ended_at")
  } else if event.kind == EVENT_PTY_OPENED {
    if phase.is_pending() {
      phase = Running
    }
  } else if
    event.kind == EVENT_PTY_OUTPUT ||
    event.kind == EVENT_PTY_GAP {
    if phase.is_pending() || phase.is_interrupted() {
      phase = Running
    }
  } else if event.kind == EVENT_PTY_EXITED {
    phase = phase_after_terminal_payload(event.payload, Lost)
    exit_code = terminal_exit_code(event.payload)
    stop_reason = payload_string(event.payload, "stop_reason")
    ended_at = payload_string(event.payload, "ended_at")
  } else if event.kind == EVENT_PROCESS_STARTED {
    if phase.is_pending() || phase.is_interrupted() {
      phase = Running
    }
  } else if event.kind == EVENT_PROCESS_EXITED {
    // A lost terminal event means the node could not observe the exit (e.g.
    // host restart after a `started` event). That is never success.
    phase = phase_after_terminal_payload(event.payload, Lost)
    exit_code = terminal_exit_code(event.payload)
    stop_reason = payload_string(event.payload, "stop_reason")
    ended_at = payload_string(event.payload, "ended_at")
  } else if
    event.kind == EVENT_GIT_RESULT ||
    event.kind == EVENT_GIT_WORKTREE_ADDED ||
    event.kind == EVENT_GIT_WORKTREE_REMOVED {
    phase = Succeeded
  } else if event.kind == EVENT_GIT_ERRORED {
    phase = Failed
    stop_reason = payload_string(event.payload, "message")
  }
  self.runs.set(
    event.run_id,
    {
      ..existing,
      kind: if existing.kind == "other" { kind } else { existing.kind },
      phase,
      last_run_seq: event.run_seq,
      last_event_seq: event.seq,
      exit_code,
      stop_reason,
      ended_at,
    },
  )
  true
}

///|
fn payload_string(payload : @json.Json, key : String) -> String {
  match @contracts.as_object(payload) {
    Some(object) => @contracts.string_field_or(object, key, "")
    None => ""
  }
}

///|
/// Mark every non-terminal run `interrupted`. Called when the channel is
/// gone. No run is settled here: without a terminal event or a status answer
/// the primary does not know the outcome, and must not claim success.
pub fn RunTracker::mark_connection_lost(self : RunTracker) -> Int {
  self.interrupted.val = true
  let mut changed = 0
  for run_id in self.order {
    match self.runs.get(run_id) {
      Some(run) =>
        if !run.phase.is_settled() && !run.phase.is_interrupted() {
          self.runs.set(run_id, { ..run, phase: Interrupted })
          changed = changed + 1
        }
      None => ()
    }
  }
  changed
}

///|
pub fn RunTracker::mark_connection_restored(self : RunTracker) -> Unit {
  self.interrupted.val = false
}

///|
/// Reconcile one run with a fresh status answer from the node after a
/// reconnect. Returns `true` when the phase changed. A `running` answer brings
/// an interrupted run back to `running` under the same stable `run_id`.
pub fn RunTracker::reconcile_status(
  self : RunTracker,
  run_id : String,
  status : String,
  exit_code : Int?,
) -> Bool {
  let existing = match self.runs.get(run_id) {
    Some(value) => value
    None => return false
  }
  let phase = run_phase_of_status(status)
  if phase.text() == existing.phase.text() && exit_code == existing.exit_code {
    return false
  }
  self.runs.set(
    run_id,
    { ..existing, phase, exit_code, ended_at: existing.ended_at },
  )
  true
}

///|
/// Reconcile one streaming process with a fresh `process.exit` answer. An
/// absent record (`None`) settles the run `lost`: the node has no live
/// process left, so the primary must not keep it running or call it success.
pub fn RunTracker::reconcile_process_status(
  self : RunTracker,
  run_id : String,
  status : String?,
  exit_code : Int?,
) -> Bool {
  match status {
    Some(value) => self.reconcile_status(run_id, value, exit_code)
    None => {
      let existing = match self.runs.get(run_id) {
        Some(value) => value
        None => return false
      }
      if existing.phase.is_lost() {
        return false
      }
      self.runs.set(
        run_id,
        { ..existing, phase: Lost, exit_code: None, stop_reason: "lost" },
      )
      true
    }
  }
}

///|
/// Reconcile one PTY session with a fresh `pty.status` answer.
pub fn RunTracker::reconcile_pty_status(
  self : RunTracker,
  session_id : String,
  status : String,
  exit_code : Int?,
) -> Bool {
  self.reconcile_status(session_id, status, exit_code)
}

///|
fn RunTracker::insert(self : RunTracker, run : TrackedRun) -> Unit {
  self.runs.set(run.run_id, run)
  self.order.push(run.run_id)
  while self.order.length() > self.max_runs {
    let oldest = self.order.remove(0)
    self.runs.remove(oldest)
  }
}
