///|
/// A transport-independent PTY runtime. A runtime owns a caller-provided
/// 0700 state directory with one append-only transcript per session, and
/// publishes bounded, monotonic events. Sessions live in a caller-provided
/// `@async.TaskGroup`; the runtime never spawns a detached process.
///
/// Because MoonBit async is structured-concurrency-only, `open` takes the
/// long-lived group that should own the session. The host's runtime group is
/// the intended owner; closing the session (or cancelling that group) closes
/// the terminal and terminates the child's process group.
pub struct PtyRuntime {
  priv root : String
  priv instance_id : String
  priv sessions_root : String
  priv limits : PtyLimits
  priv mutex : @async.Mutex
  priv sessions : Map[String, PtySession]
  priv request_index : Map[String, String]
}

///|
priv struct PtyLogPaths {
  log_path : String
  log_file : @fs.File
}

///|
fn pty_random_instance_id() -> String {
  let random = @random.Rand::chacha8()
  @async.now().to_string() + "-" + random.int(limit=1_000_000_000).to_string()
}

///|
pub async fn PtyRuntime::new(
  state_dir : String,
) -> Result[PtyRuntime, PtyError] {
  PtyRuntime::new_with_limits(state_dir, PtyLimits::new())
}

///|
pub async fn PtyRuntime::new_with_limits(
  state_dir : String,
  limits : PtyLimits,
) -> Result[PtyRuntime, PtyError] {
  if state_dir == "" || !state_dir.has_prefix("/") || pty_has_control(state_dir) ||
    pty_has_nul(state_dir) {
    return Err(
      pty_error(
        PtyErrorKind::StateDir,
        "state_dir must be a non-empty absolute path without control characters",
      ),
    )
  }
  @fs.mkdir(state_dir, permission=0o700, recursive=true, allow_exist=true) catch {
    _ =>
      return Err(
        pty_error(PtyErrorKind::StateDir, "cannot create the state directory"),
      )
  }
  let root = @fs.realpath(state_dir) catch {
    _ =>
      return Err(
        pty_error(PtyErrorKind::StateDir, "cannot resolve the state directory"),
      )
  }
  let kind = @fs.kind(root) catch {
    _ => return Err(pty_error(PtyErrorKind::StateDir, "state directory is not readable"))
  }
  if !(kind is @fs.FileKind::Directory) {
    return Err(
      pty_error(PtyErrorKind::StateDir, "state directory is not a directory"),
    )
  }
  if root == "/" {
    return Err(
      pty_error(
        PtyErrorKind::StateDir,
        "refusing a state directory of / (arbitrary host paths)",
      ),
    )
  }
  if pty_has_ssh_component(root) {
    return Err(
      pty_error(
        PtyErrorKind::StateDir,
        "the state directory must not be inside a .ssh directory",
      ),
    )
  }
  @fs.chmod(root, 0o700) catch { _ => () }
  let instance_id = pty_random_instance_id()
  let sessions_root = pty_join(pty_join(root, "pty"), instance_id)
  @fs.mkdir(
    sessions_root,
    permission=0o700,
    recursive=true,
    allow_exist=true,
  ) catch {
    _ =>
      return Err(
        pty_error(PtyErrorKind::StateDir, "cannot create the PTY state directory"),
      )
  }
  let real_sessions_root = @fs.realpath(sessions_root) catch {
    _ =>
      return Err(
        pty_error(PtyErrorKind::StateDir, "cannot resolve the PTY state directory"),
      )
  }
  if !pty_is_within(real_sessions_root, root) {
    return Err(
      pty_error(PtyErrorKind::StateDir, "PTY state directory escaped its root"),
    )
  }
  let sessions_kind = @fs.kind(real_sessions_root) catch {
    _ =>
      return Err(
        pty_error(PtyErrorKind::StateDir, "PTY state directory is not readable"),
      )
  }
  if !(sessions_kind is @fs.FileKind::Directory) {
    return Err(
      pty_error(PtyErrorKind::StateDir, "PTY state path is not a directory"),
    )
  }
  @fs.chmod(real_sessions_root, 0o700) catch { _ => () }
  Ok({
    root,
    instance_id,
    sessions_root: real_sessions_root,
    limits,
    mutex: @async.Mutex::Mutex(),
    sessions: Map([]),
    request_index: Map([]),
  })
}

///|
pub fn PtyRuntime::state_root(self : PtyRuntime) -> String {
  self.root
}

///|
pub fn PtyRuntime::instance_id(self : PtyRuntime) -> String {
  self.instance_id
}

///|
pub fn PtyRuntime::sessions_root(self : PtyRuntime) -> String {
  self.sessions_root
}

///|
async fn pty_prepare_session_dir(
  rt : PtyRuntime,
  session_id : String,
) -> Result[PtyLogPaths, PtyError] {
  let dir = pty_join(rt.sessions_root, session_id)
  let before = @fs.kind(dir, follow_symlink=false) catch {
    _ => @fs.FileKind::Unknown
  }
  match before {
    @fs.FileKind::SymLink =>
      return Err(
        pty_error(PtyErrorKind::StateDir, "session state path is a symlink"),
      )
    @fs.FileKind::Directory => ()
    @fs.FileKind::Unknown =>
      @fs.mkdir(dir, permission=0o700, recursive=true, allow_exist=true) catch {
        _ =>
          return Err(
            pty_error(PtyErrorKind::StateDir, "cannot create the session state directory"),
          )
      }
    _ =>
      return Err(
        pty_error(PtyErrorKind::StateDir, "session state path is not a directory"),
      )
  }
  let real_dir = @fs.realpath(dir) catch {
    _ =>
      return Err(
        pty_error(PtyErrorKind::StateDir, "cannot resolve the session state directory"),
      )
  }
  if !pty_is_within(real_dir, rt.sessions_root) {
    return Err(
      pty_error(PtyErrorKind::StateDir, "session state directory escaped its root"),
    )
  }
  @fs.chmod(real_dir, 0o700) catch { _ => () }
  let log_path = pty_join(real_dir, "transcript.log")
  let log_kind = @fs.kind(log_path, follow_symlink=false) catch {
    _ => @fs.FileKind::Unknown
  }
  match log_kind {
    @fs.FileKind::SymLink =>
      return Err(
        pty_error(PtyErrorKind::StateDir, "session transcript path is a symlink"),
      )
    @fs.FileKind::Regular | @fs.FileKind::Unknown => ()
    _ =>
      return Err(
        pty_error(PtyErrorKind::StateDir, "session transcript path is not a regular file"),
      )
  }
  let log_file = @fs.open(
    log_path,
    mode=@fs.Mode::WriteOnly,
    append=true,
    create_mode=@fs.CreateMode::OpenOrCreate,
    permission=0o600,
  ) catch {
    _ =>
      return Err(
        pty_error(PtyErrorKind::Io, "cannot open the session transcript"),
      )
  }
  @fs.chmod(log_path, 0o600) catch { _ => () }
  Ok({ log_path, log_file })
}

///|
async fn pty_find_session(
  rt : PtyRuntime,
  session_id : String,
) -> PtySession? {
  rt.mutex.acquire()
  let session = rt.sessions.get(session_id)
  rt.mutex.release()
  session
}

///|
async fn pty_status_now(rt : PtyRuntime, session : PtySession) -> PtyStatus {
  rt.mutex.acquire()
  let status = pty_status_of(session)
  rt.mutex.release()
  status
}

///|
async fn pty_open_existing(
  rt : PtyRuntime,
  session : PtySession,
  normalized : NormalizedOpen,
) -> Result[PtySessionHandle, PtyError] {
  if !pty_same_request(session.request, normalized.request) {
    return Err(
      pty_error(
        PtyErrorKind::Conflict,
        "session_id is already in use by a different open request",
      ).with_session(normalized.request.session_id),
    )
  }
  match pty_wait_started(rt, session) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  rt.mutex.acquire()
  let handle = pty_handle_of(session, false)
  rt.mutex.release()
  Ok(handle)
}

///|
/// Open an idempotent PTY session. `session_id` is the stable identity; a
/// repeated request with the same body and `client_request_id` returns the
/// existing session (created=false) and never spawns a second process. A
/// different body or request id for an existing session is a Conflict.
///
/// The caller must pass the long-lived group that should own the session.
/// The session task is spawned into that group; all cleanup is scoped to it.
pub async fn[X] PtyRuntime::open(
  self : PtyRuntime,
  group : @async.TaskGroup[X],
  request : PtyOpenRequest,
) -> Result[PtySessionHandle, PtyError] {
  let normalized = match pty_validate_open(request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let session_id = normalized.request.session_id
  self.mutex.acquire()
  match self.sessions.get(session_id) {
    Some(session) => {
      self.mutex.release()
      return pty_open_existing(self, session, normalized)
    }
    None => {
      let request_id = normalized.request.client_request_id
      if request_id != "" {
        match self.request_index.get(request_id) {
          Some(other) => {
            if other != session_id {
              self.mutex.release()
              return Err(
                pty_error(
                  PtyErrorKind::Conflict,
                  "client_request_id is already bound to another session",
                ).with_session(session_id),
              )
            }
          }
          None => ()
        }
      }
      self.mutex.release()
    }
  }
  let paths = match pty_prepare_session_dir(self, session_id) {
    Ok(value) => value
    Err(error) => return Err(error.with_session(session_id))
  }
  self.mutex.acquire()
  match self.sessions.get(session_id) {
    Some(existing) => {
      self.mutex.release()
      paths.log_file.close()
      return pty_open_existing(self, existing, normalized)
    }
    None => {
      let request_id = normalized.request.client_request_id
      if request_id != "" {
        match self.request_index.get(request_id) {
          Some(other) => {
            self.mutex.release()
            paths.log_file.close()
            if other != session_id {
              return Err(
                pty_error(
                  PtyErrorKind::Conflict,
                  "client_request_id is already bound to another session",
                ).with_session(session_id),
              )
            }
            return Err(
              pty_error(
                PtyErrorKind::Conflict,
                "session_id was concurrently registered by another open",
              ).with_session(session_id),
            )
          }
          None => ()
        }
      }
      let session = pty_session_new(normalized, paths.log_path, paths.log_file)
      self.sessions[session_id] = session
      if request_id != "" {
        self.request_index[request_id] = session_id
      }
      let task = group.spawn(
        no_wait=false,
        allow_failure=true,
        () => pty_session_main(self, session),
      )
      session.task.val = Some(task)
      self.mutex.release()
      match pty_wait_started(self, session) {
        Ok(_) => {
          self.mutex.acquire()
          let handle = pty_handle_of(session, true)
          self.mutex.release()
          Ok(handle)
        }
        Err(error) => {
          if error.kind is PtyErrorKind::Timeout {
            pty_terminate(self, session, false, true)
            let status = pty_status_now(self, session)
            return Err(error.with_residual(status.residual_pids))
          }
          Err(error)
        }
      }
    }
  }
}

///|
/// Send UTF-8 text to the session. Input is not logged; the caller must not
/// put secrets in terminal input. Bounds are enforced before the write.
pub async fn PtyRuntime::input(
  self : PtyRuntime,
  session_id : String,
  data : String,
) -> Result[Unit, PtyError] {
  let bytes = @utf8.encode(data)
  self.input_bytes(session_id, bytes)
}

///|
pub async fn PtyRuntime::input_bytes(
  self : PtyRuntime,
  session_id : String,
  data : Bytes,
) -> Result[Unit, PtyError] {
  if data.length() > self.limits.max_input_bytes {
    return Err(
      pty_error(
        PtyErrorKind::InvalidArgument,
        "input is larger than max_input_bytes",
      ).with_session(session_id),
    )
  }
  self.mutex.acquire()
  let session = self.sessions.get(session_id)
  let pty = match session {
    Some(value) => {
      if value.finalized.val {
        self.mutex.release()
        return Err(
          pty_error(PtyErrorKind::AlreadyClosed, "session is closed")
          .with_session(session_id),
        )
      }
      value.pty.val
    }
    None => None
  }
  self.mutex.release()
  match session {
    None =>
      return Err(
        pty_error(PtyErrorKind::NotFound, "session does not exist")
        .with_session(session_id),
      )
    Some(_) => ()
  }
  let handle = match pty {
    Some(value) => value
    None =>
      return Err(
        pty_error(PtyErrorKind::Internal, "session has no PTY handle")
        .with_session(session_id),
      )
  }
  handle.write(data) catch {
    _ =>
      return Err(
        pty_error(
          PtyErrorKind::Io,
          "input failed; the session may have closed",
        ).with_session(session_id),
      )
  }
  Ok(())
}

///|
pub async fn PtyRuntime::resize(
  self : PtyRuntime,
  session_id : String,
  rows : Int32,
  cols : Int32,
) -> Result[Unit, PtyError] {
  if rows <= 0 || rows > 10_000 || cols <= 0 || cols > 10_000 {
    return Err(
      pty_error(
        PtyErrorKind::InvalidArgument,
        "rows and cols must be between 1 and 10000",
      ).with_session(session_id),
    )
  }
  self.mutex.acquire()
  let session = self.sessions.get(session_id)
  let pty = match session {
    Some(value) => {
      if value.finalized.val {
        self.mutex.release()
        return Err(
          pty_error(PtyErrorKind::AlreadyClosed, "session is closed")
          .with_session(session_id),
        )
      }
      value.pty.val
    }
    None => None
  }
  self.mutex.release()
  match session {
    None =>
      return Err(
        pty_error(PtyErrorKind::NotFound, "session does not exist")
        .with_session(session_id),
      )
    Some(_) => ()
  }
  let handle = match pty {
    Some(value) => value
    None =>
      return Err(
        pty_error(PtyErrorKind::Internal, "session has no PTY handle")
        .with_session(session_id),
      )
  }
  handle.resize(rows=rows, cols=cols) catch {
    _ => {
      self.mutex.acquire()
      let closed = match self.sessions.get(session_id) {
        Some(value) => value.finalized.val
        None => true
      }
      self.mutex.release()
      if closed {
        return Err(
          pty_error(PtyErrorKind::AlreadyClosed, "session is closed")
          .with_session(session_id),
        )
      }
      return Err(
        pty_error(PtyErrorKind::Io, "terminal resize failed")
        .with_session(session_id),
      )
    }
  }
  self.mutex.acquire()
  match self.sessions.get(session_id) {
    Some(value) => {
      if !value.finalized.val {
        value.rows.val = rows
        value.cols.val = cols
      }
    }
    None => ()
  }
  self.mutex.release()
  Ok(())
}

///|
pub async fn PtyRuntime::close(
  self : PtyRuntime,
  session_id : String,
) -> Result[PtyStatus, PtyError] {
  let session = match pty_find_session(self, session_id) {
    Some(value) => value
    None =>
      return Err(
        pty_error(PtyErrorKind::NotFound, "session does not exist")
        .with_session(session_id),
      )
  }
  pty_terminate(self, session, true, false)
  Ok(pty_status_now(self, session))
}

///|
/// Wait for the session to finish. `timeout_ms <= 0` waits without a local
/// timeout; a positive timeout terminates the process tree and returns a
/// status with `timed_out=true` and `success=false`.
pub async fn PtyRuntime::wait(
  self : PtyRuntime,
  session_id : String,
  timeout_ms~ : Int = 0,
) -> Result[PtyStatus, PtyError] {
  let session = match pty_find_session(self, session_id) {
    Some(value) => value
    None =>
      return Err(
        pty_error(PtyErrorKind::NotFound, "session does not exist")
        .with_session(session_id),
      )
  }
  if timeout_ms > 0 && !pty_wait_final(self, session, timeout_ms) {
    pty_terminate(self, session, false, true)
  } else {
    let _ = pty_wait_final(self, session, 0)
  }
  Ok(pty_status_now(self, session))
}

///|
pub async fn PtyRuntime::status(
  self : PtyRuntime,
  session_id : String,
) -> Result[PtyStatus, PtyError] {
  let session = match pty_find_session(self, session_id) {
    Some(value) => value
    None =>
      return Err(
        pty_error(PtyErrorKind::NotFound, "session does not exist")
        .with_session(session_id),
      )
  }
  Ok(pty_status_now(self, session))
}

///|
/// Read output events after `after_seq`. Events are in sequence order and
/// bounded in both count and bytes. `next_seq` is the sequence to pass to
/// the next call; `dropped` means the ring evicted older events and the
/// transcript should be used (event `log_offset` points into it).
pub async fn PtyRuntime::events(
  self : PtyRuntime,
  session_id : String,
  after_seq~ : Int64 = 0L,
  max_events~ : Int = 256,
  max_bytes~ : Int = 65_536,
) -> Result[PtyEventPage, PtyError] {
  if after_seq < 0L {
    return Err(
      pty_error(
        PtyErrorKind::InvalidArgument,
        "after_seq must be non-negative",
      ).with_session(session_id),
    )
  }
  let event_limit = max_events.max(1).min(4_096)
  let byte_limit = max_bytes.max(1).min(1_048_576)
  self.mutex.acquire()
  let session = self.sessions.get(session_id)
  match session {
    None => {
      self.mutex.release()
      return Err(
        pty_error(PtyErrorKind::NotFound, "session does not exist")
        .with_session(session_id),
      )
    }
    Some(value) => {
      let events : Array[PtyOutputEvent] = []
      let mut bytes = 0
      let mut last_seq = after_seq
      for event in value.ring {
        if event.seq <= after_seq {
          continue
        }
        if events.length() >= event_limit {
          break
        }
        let event_bytes = @utf8.encode(event.data).length()
        if events.length() > 0 && bytes + event_bytes > byte_limit {
          break
        }
        events.push(event)
        bytes = bytes + event_bytes
        last_seq = event.seq
      }
      let earliest = if value.ring.length() > 0 {
        value.ring[0].seq
      } else {
        0L
      }
      let page = {
        session_id,
        events,
        next_seq: last_seq,
        earliest_seq: earliest,
        dropped: value.dropped.val,
        log_path: value.log_path,
        log_bytes: value.log_bytes.val,
        log_truncated: value.log_truncated.val,
      }
      self.mutex.release()
      Ok(page)
    }
  }
}

///|
/// Read a bounded slice of the redacted append-only transcript. `offset` is
/// a byte offset; `log_truncated` reports that the transcript reached its
/// size cap.
pub async fn PtyRuntime::read_log(
  self : PtyRuntime,
  session_id : String,
  offset~ : Int64 = 0L,
  max_bytes~ : Int = 65_536,
) -> Result[PtyLogSlice, PtyError] {
  if offset < 0L {
    return Err(
      pty_error(PtyErrorKind::InvalidArgument, "offset must be non-negative")
      .with_session(session_id),
    )
  }
  let limit = max_bytes.max(1).min(1_048_576)
  let session = match pty_find_session(self, session_id) {
    Some(value) => value
    None =>
      return Err(
        pty_error(PtyErrorKind::NotFound, "session does not exist")
        .with_session(session_id),
      )
  }
  let log_path = session.log_path
  let truncated = session.log_truncated.val
  let file = @fs.open(
    log_path,
    mode=@fs.Mode::ReadOnly,
    create_mode=@fs.CreateMode::OpenExisting,
  ) catch {
    _ =>
      return Err(
        pty_error(PtyErrorKind::Io, "cannot open the session transcript")
        .with_session(session_id),
      )
  }
  defer file.close()
  let size = @fs.file_size(log_path) catch {
    _ =>
      return Err(
        pty_error(PtyErrorKind::Io, "cannot stat the session transcript")
        .with_session(session_id),
      )
  }
  if offset >= size {
    return Ok({
      session_id,
      offset,
      data: "",
      bytes: 0L,
      eof: true,
      log_bytes: size,
      truncated,
    })
  }
  let available = size - offset
  let requested = if available > limit.to_int64() {
    limit
  } else {
    available.to_int()
  }
  let buffer : FixedArray[Byte] = FixedArray::make(requested, b'\x00')
  let mut got = 0
  while got < requested {
    let count = file.read_at(
      buffer,
      position=offset + got.to_int64(),
      offset=got,
      len=requested - got,
    ) catch {
      _ =>
        return Err(
          pty_error(PtyErrorKind::Io, "cannot read the session transcript")
          .with_session(session_id),
        )
    }
    if count <= 0 {
      break
    }
    got = got + count
  }
  let bytes = Bytes::from_fixedarray(buffer, len=got)
  let data = @utf8.decode_lossy(bytes[:])
  Ok({
    session_id,
    offset,
    data,
    bytes: got.to_int64(),
    eof: offset + got.to_int64() >= size,
    log_bytes: size,
    truncated,
  })
}

///|
pub async fn PtyRuntime::list_sessions(
  self : PtyRuntime,
) -> Array[PtyStatus] {
  self.mutex.acquire()
  let result : Array[PtyStatus] = []
  for _session_id, session in self.sessions {
    result.push(pty_status_of(session))
  }
  self.mutex.release()
  result
}

///|
/// Close every session owned by this runtime. Sessions already finished are
/// returned unchanged. Idempotent and safe to call at host shutdown before
/// the owning task group exits.
pub async fn PtyRuntime::close_all(
  self : PtyRuntime,
) -> Array[PtyStatus] {
  let ids : Array[String] = []
  self.mutex.acquire()
  for session_id, _session in self.sessions {
    ids.push(session_id)
  }
  self.mutex.release()
  let result : Array[PtyStatus] = []
  for session_id in ids {
    match self.close(session_id) {
      Ok(status) => result.push(status)
      Err(_) => ()
    }
  }
  result
}
