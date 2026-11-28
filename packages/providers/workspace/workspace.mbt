///|
/// WorkspaceProvider: one interface over a local directory and a directory on
/// an SSH machine (architecture §6.2).
///
/// The local implementation uses `moonbitlang/async/fs`; the SSH one reuses
/// M0/M2 argv construction (`ssh_argv`, `shell_quote`, `remote_exec_command`)
/// and executes only fixed POSIX scripts, never interpolated user text. Writes
/// go through a temporary file in the target directory followed by an atomic
/// rename, on both sides.

///|
pub(all) struct EntryInfo {
  name : String
  path : String
  kind : String
  is_dir : Bool
  size : Int64
}

///|
pub(all) struct StatInfo {
  path : String
  kind : String
  size : Int64
}

///|
pub(all) struct GitChangeInfo {
  path : String
  status : String
  index_status : String
  worktree_status : String
}

///|
pub(all) struct GitStatusInfo {
  is_git : Bool
  branch : String
  upstream : String
  ahead : Int
  behind : Int
  changes : Array[GitChangeInfo]
}

///|
pub(all) struct GitDiffInfo {
  path : String
  cached : Bool
  range : String
  text : String
  truncated : Bool
}

///|
pub(all) struct LocalWorkspace {
  root : String
  git_root : String
  is_git : Bool
}

///|
pub(all) struct SshWorkspace {
  target : @ssh.SshTarget
  root : String
  git_root : String
  is_git : Bool
}

///|
pub(all) enum WorkspaceProvider {
  Local(LocalWorkspace)
  Ssh(SshWorkspace)
}

///|
pub(all) enum TerminalInput {
  Data(String)
  Resize(Int32, Int32)
  Close
}

///|
pub(all) enum TerminalEvent {
  Data(String)
  Eof
}

///|
fn ws_error(kind : @error.ProviderErrorKind, message : String) -> @error.ProviderError {
  @error.ProviderError::new(kind, message)
}

///|
/// Validate a workspace-relative path. Absolute paths and `..` segments are
/// rejected instead of normalized, so a request can never walk out of the
/// workspace root. The empty path means the root itself.
pub fn normalize_relative(path : String) -> Result[String, String] {
  let trimmed = path.trim()
  if trimmed == "" || trimmed == "." {
    return Ok("")
  }
  if trimmed.has_prefix("/") {
    return Err("absolute paths are not allowed")
  }
  let segments : Array[String] = []
  for raw in trimmed.split("/") {
    let segment = raw.trim()
    if segment == "" || segment == "." {
      continue
    }
    if segment == ".." {
      return Err("path may not escape the workspace")
    }
    segments.push(segment.to_owned())
  }
  Ok(segments.join("/"))
}

///|
fn absolute_path(root : String, relative : String) -> String {
  if relative == "" {
    root
  } else if root.ends_with("/") {
    root + relative
  } else {
    root + "/" + relative
  }
}

///|
pub fn WorkspaceProvider::root(self : WorkspaceProvider) -> String {
  match self {
    Local(local) => local.root
    Ssh(remote) => remote.root
  }
}

///|
pub fn WorkspaceProvider::git_root(self : WorkspaceProvider) -> String {
  match self {
    Local(local) => local.git_root
    Ssh(remote) => remote.git_root
  }
}

///|
pub fn WorkspaceProvider::is_git(self : WorkspaceProvider) -> Bool {
  match self {
    Local(local) => local.is_git
    Ssh(remote) => remote.is_git
  }
}

// ---------------------------------------------------------------------------
// Local provider
// ---------------------------------------------------------------------------

///|
async fn fs_error(action : String, error : Error) -> @error.ProviderError {
  let text = error.to_string()
  let lower = text.to_lower()
  if lower.contains("no such file") || lower.contains("not found") {
    ws_error(@error.ProviderErrorKind::NotFound, action).with_detail(text)
  } else {
    ws_error(@error.ProviderErrorKind::Internal, action).with_detail(text)
  }
}

///|
fn kind_label(kind : @fs.FileKind) -> String {
  match kind {
    Regular => "file"
    Directory => "dir"
    SymLink => "symlink"
    Socket => "socket"
    Pipe => "pipe"
    BlockDevice => "block"
    CharDevice => "char"
    _ => "other"
  }
}

///|
struct CmdResult {
  exit_code : Int
  stdout : String
  stderr : String
}

///|
async fn run_local(
  argv : Array[String],
  cwd : String,
  timeout_seconds : Int,
) -> Result[CmdResult, @error.ProviderError] {
  if argv.is_empty() {
    return Err(ws_error(@error.ProviderErrorKind::Internal, "empty argv"))
  }
  let collected = @async.with_timeout_opt(
    timeout_seconds.max(1) * 1_000,
    async fn() {
      let (exit_code, stdout, stderr) = @process.collect_output(
        argv[0],
        argv[1:].to_owned(),
        cwd=cwd,
      ) catch {
        error =>
          return Err(
            ws_error(
              @error.ProviderErrorKind::SpawnFailed,
              "cannot run " + argv[0],
            ).with_detail(error.to_string()),
          )
      }
      let out = stdout.text() catch { _ => "" }
      let err = stderr.text() catch { _ => "" }
      Ok({ exit_code, stdout: out, stderr: err })
    },
  )
  match collected {
    Some(Ok(value)) => Ok(value)
    Some(Err(error)) => Err(error)
    None =>
      Err(
        ws_error(
          @error.ProviderErrorKind::ConnectTimeout,
          "command timed out after " + timeout_seconds.to_string() + "s",
        ),
      )
  }
}

///|
async fn detect_git_local(root : String) -> (Bool, String) {
  match run_local(
    ["git", "-C", root, "rev-parse", "--show-toplevel"],
    root,
    10,
  ) {
    Ok(result) if result.exit_code == 0 =>
      (true, result.stdout.trim().to_owned())
    _ => (false, "")
  }
}

///|
pub async fn open_local(
  root : String,
) -> Result[WorkspaceProvider, @error.ProviderError] {
  let real = @fs.realpath(root) catch {
    error => return Err(fs_error("cannot resolve workspace root", error))
  }
  let kind = @fs.kind(real) catch {
    error => return Err(fs_error("cannot stat workspace root", error))
  }
  if !(kind is Directory) {
    return Err(
      ws_error(
        @error.ProviderErrorKind::NotFound,
        "workspace root is not a directory",
      ),
    )
  }
  let (is_git, git_root) = detect_git_local(real)
  Ok(Local({ root: real, git_root, is_git }))
}

///|
async fn local_list(
  ws : LocalWorkspace,
  relative : String,
) -> Result[Array[EntryInfo], @error.ProviderError] {
  let base = absolute_path(ws.root, relative)
  let names = @fs.readdir(base, include_hidden=true, sort=false) catch {
    error => return Err(fs_error("cannot list directory", error))
  }
  let entries : Array[EntryInfo] = []
  for name in names {
    let child_rel = if relative == "" {
      name
    } else {
      relative + "/" + name
    }
    let child_abs = absolute_path(ws.root, child_rel)
    let kind = @fs.kind(child_abs, follow_symlink=false) catch {
      _ => @fs.FileKind::Unknown
    }
    let size = if kind is Regular {
      @fs.file_size(child_abs) catch { _ => 0L }
    } else {
      0L
    }
    entries.push({
      name,
      path: child_rel,
      kind: kind_label(kind),
      is_dir: kind is Directory,
      size,
    })
  }
  sort_entries(entries)
  Ok(entries)
}

///|
fn sort_entries(entries : Array[EntryInfo]) -> Unit {
  let mut index = 1
  while index < entries.length() {
    let current = entries[index]
    let mut position = index
    while position > 0 {
      let previous = entries[position - 1]
      let before = if current.is_dir != previous.is_dir {
        current.is_dir
      } else {
        current.name < previous.name
      }
      if !before {
        break
      }
      entries[position] = previous
      position = position - 1
    }
    entries[position] = current
    index = index + 1
  }
}

///|
async fn local_stat(
  ws : LocalWorkspace,
  relative : String,
) -> Result[StatInfo, @error.ProviderError] {
  let abs = absolute_path(ws.root, relative)
  let kind = @fs.kind(abs, follow_symlink=false) catch {
    error => return Err(fs_error("cannot stat path", error))
  }
  let size = if kind is Regular {
    @fs.file_size(abs) catch { _ => 0L }
  } else {
    0L
  }
  Ok({ path: relative, kind: kind_label(kind), size })
}

// ---------------------------------------------------------------------------
// SSH provider
// ---------------------------------------------------------------------------

///|
fn remote_exit(
  exit_code : Int,
  stderr : String,
  action : String,
) -> @error.ProviderError {
  let lower = stderr.to_lower()
  let kind = if lower.contains("no such file") ||
    lower.contains("not found") ||
    lower.contains("does not exist") {
    @error.ProviderErrorKind::NotFound
  } else {
    @error.ProviderErrorKind::RemoteExit
  }
  ws_error(kind, action).with_exit(exit_code).with_detail(stderr)
}

///|
async fn run_remote_checked(
  target : @ssh.SshTarget,
  argv : Array[String],
  cwd : String,
  action : String,
) -> Result[CmdResult, @error.ProviderError] {
  let result = match
    @ssh.run(target, argv, cwd=cwd, timeout_seconds=60) {
    Ok(value) =>
      Ok({
        exit_code: value.exit_code,
        stdout: value.stdout,
        stderr: value.stderr,
      })
    Err(error) => Err(error)
  }
  let result = match result {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if result.exit_code != 0 {
    return Err(remote_exit(result.exit_code, result.stderr, action))
  }
  Ok(result)
}

///|
async fn detect_git_ssh(
  target : @ssh.SshTarget,
  root : String,
) -> (Bool, String) {
  match
    @ssh.run(
      target,
      ["git", "rev-parse", "--show-toplevel"],
      cwd=root,
      timeout_seconds=10,
    ) {
    Ok(result) if result.exit_code == 0 =>
      (true, result.stdout.trim().to_owned())
    _ => (false, "")
  }
}

///|
pub async fn open_ssh(
  target : @ssh.SshTarget,
  root : String,
) -> Result[WorkspaceProvider, @error.ProviderError] {
  let check = match
    @ssh.run(
      target,
      ["sh", "-c", "test -d \"$1\"", "monexus-check", root],
      cwd=".",
      timeout_seconds=15,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if check.exit_code != 0 {
    return Err(
      ws_error(
        @error.ProviderErrorKind::NotFound,
        "remote workspace root is not a directory",
      ).with_detail(check.stderr),
    )
  }
  let real = match
    @ssh.run(
      target,
      ["sh", "-c", "cd -- \"$1\" && pwd -P", "monexus-realpath", root],
      cwd=".",
      timeout_seconds=15,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if real.exit_code != 0 {
    return Err(
      remote_exit(real.exit_code, real.stderr, "cannot resolve remote workspace root"),
    )
  }
  let real_root = real.stdout.trim().to_owned()
  let (is_git, git_root) = detect_git_ssh(target, real_root)
  Ok(Ssh({
    target,
    root: real_root,
    git_root,
    is_git,
  }))
}

// ---------------------------------------------------------------------------
// WorkspaceProvider file operations
// ---------------------------------------------------------------------------

///|
pub async fn WorkspaceProvider::list(
  self : WorkspaceProvider,
  path : String,
) -> Result[Array[EntryInfo], @error.ProviderError] {
  let relative = match normalize_relative(path) {
    Ok(value) => value
    Err(message) =>
      return Err(ws_error(@error.ProviderErrorKind::Internal, message))
  }
  match self {
    Local(local) => local_list(local, relative)
    Ssh(remote) => {
      let base = absolute_path(remote.root, relative)
      let script = [
        "cd -- \"$1\" || exit 1",
        "for name in * .[!.]* ..?*; do",
        "  [ -e \"$name\" ] || [ -L \"$name\" ] || continue",
        "  if [ -d \"$name\" ]; then k=d; elif [ -L \"$name\" ]; then k=l; else k=f; fi",
        "  if [ \"$k\" = f ]; then s=$(wc -c < \"$name\" 2>/dev/null || printf 0); else s=0; fi",
        "  printf '%s\\t%s\\t%s\\n' \"$k\" \"$s\" \"$name\"",
        "done",
      ].join("\n")
      let result = match
        run_remote_checked(
          remote.target,
          ["sh", "-c", script, "monexus-ls", base],
          ".",
          "cannot list remote directory",
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let entries : Array[EntryInfo] = []
      for line in result.stdout.split("\n") {
        let clean = line.trim_end(chars="\r").to_owned()
        if clean == "" {
          continue
        }
        guard clean.split_once("\t") is Some((flag, rest)) else { continue }
        guard rest.split_once("\t") is Some((size_text, name)) else {
          continue
        }
        let size = @string.parse_int64(size_text) catch { _ => 0L }
        let name = name.to_owned()
        let child_rel = if relative == "" {
          name
        } else {
          relative + "/" + name
        }
        let kind = if flag == "d" {
          "dir"
        } else if flag == "l" {
          "symlink"
        } else {
          "file"
        }
        entries.push({
          name,
          path: child_rel,
          kind,
          is_dir: flag == "d",
          size,
        })
      }
      sort_entries(entries)
      Ok(entries)
    }
  }
}

///|
pub async fn WorkspaceProvider::stat(
  self : WorkspaceProvider,
  path : String,
) -> Result[StatInfo, @error.ProviderError] {
  let relative = match normalize_relative(path) {
    Ok(value) => value
    Err(message) =>
      return Err(ws_error(@error.ProviderErrorKind::Internal, message))
  }
  match self {
    Local(local) => local_stat(local, relative)
    Ssh(remote) => {
      let abs = absolute_path(remote.root, relative)
      let script = [
        "if [ ! -e \"$1\" ] && [ ! -L \"$1\" ]; then printf 'missing\\n'; exit 3; fi",
        "if [ -d \"$1\" ]; then k=dir; elif [ -L \"$1\" ]; then k=symlink; else k=file; fi",
        "s=$(wc -c < \"$1\" 2>/dev/null || printf 0)",
        "printf '%s\\t%s\\n' \"$k\" \"$s\"",
      ].join("\n")
      let result = match
        @ssh.run(
          remote.target,
          ["sh", "-c", script, "monexus-stat", abs],
          cwd=".",
          timeout_seconds=20,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if result.exit_code != 0 {
        return Err(
          remote_exit(result.exit_code, result.stderr, "cannot stat remote path"),
        )
      }
      let kind = match result.stdout.trim().split_once("\t") {
        Some((kind, size_text)) => {
          let size = @string.parse_int64(size_text) catch { _ => 0L }
          (kind.to_owned(), size)
        }
        None =>
          return Err(
            ws_error(
              @error.ProviderErrorKind::RemoteExit,
              "remote stat returned malformed output",
            ),
          )
      }
      Ok({ path: relative, kind: kind.0, size: kind.1 })
    }
  }
}

///|
pub async fn WorkspaceProvider::read_text(
  self : WorkspaceProvider,
  path : String,
) -> Result[String, @error.ProviderError] {
  let relative = match normalize_relative(path) {
    Ok(value) => value
    Err(message) =>
      return Err(ws_error(@error.ProviderErrorKind::Internal, message))
  }
  if relative == "" {
    return Err(
      ws_error(@error.ProviderErrorKind::Internal, "path is a directory"),
    )
  }
  match self {
    Local(local) => {
      let abs = absolute_path(local.root, relative)
      let data = @fs.read_file(abs) catch {
        error => return Err(fs_error("cannot read file", error))
      }
      let text = data.text() catch {
        error =>
          return Err(
            ws_error(
              @error.ProviderErrorKind::Internal,
              "file is not valid UTF-8 text",
            ).with_detail(error.to_string()),
          )
      }
      Ok(text)
    }
    Ssh(remote) => {
      let abs = absolute_path(remote.root, relative)
      let result = match
        run_remote_checked(
          remote.target,
          ["sh", "-c", "cat \"$1\"", "monexus-read", abs],
          ".",
          "cannot read remote file",
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok(result.stdout)
    }
  }
}

///|
pub async fn WorkspaceProvider::write_text(
  self : WorkspaceProvider,
  path : String,
  content : String,
) -> Result[Unit, @error.ProviderError] {
  let relative = match normalize_relative(path) {
    Ok(value) => value
    Err(message) =>
      return Err(ws_error(@error.ProviderErrorKind::Internal, message))
  }
  if relative == "" {
    return Err(
      ws_error(@error.ProviderErrorKind::Internal, "path is a directory"),
    )
  }
  match self {
    Local(local) => {
      let abs = absolute_path(local.root, relative)
      let suffix = @random.Rand::chacha8().int(limit=1_000_000_000)
      let temp = abs + ".monexus-tmp-" + suffix.to_string()
      @fs.write_file(
        temp,
        content,
        create_mode=@fs.CreateMode::CreateOrTruncate,
        permission=0o600,
      ) catch {
        error => return Err(fs_error("cannot write temporary file", error))
      }
      @fs.rename(temp, abs, replace=true) catch {
        error => {
          @fs.remove(temp) catch { _ => () }
          return Err(fs_error("cannot publish written file", error))
        }
      }
      Ok(())
    }
    Ssh(remote) => {
      let abs = absolute_path(remote.root, relative)
      let script = [
        "umask 077",
        "tmp=\"$1.monexus-tmp-$$\"",
        "trap 'rm -f \"$tmp\"' EXIT HUP INT TERM",
        "cat > \"$tmp\" || exit 1",
        "mv -f \"$tmp\" \"$1\" || exit 1",
      ].join("\n")
      let result = match
        @ssh.run_with_input(
          remote.target,
          ["sh", "-c", script, "monexus-write", abs],
          cwd=".",
          input=content,
          timeout_seconds=60,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if result.exit_code != 0 {
        return Err(
          remote_exit(result.exit_code, result.stderr, "cannot write remote file"),
        )
      }
      Ok(())
    }
  }
}

///|
pub async fn WorkspaceProvider::move(
  self : WorkspaceProvider,
  from_path : String,
  to_path : String,
) -> Result[Unit, @error.ProviderError] {
  let from_rel = match normalize_relative(from_path) {
    Ok(value) => value
    Err(message) =>
      return Err(ws_error(@error.ProviderErrorKind::Internal, message))
  }
  let to_rel = match normalize_relative(to_path) {
    Ok(value) => value
    Err(message) =>
      return Err(ws_error(@error.ProviderErrorKind::Internal, message))
  }
  if from_rel == "" || to_rel == "" {
    return Err(
      ws_error(@error.ProviderErrorKind::Internal, "path is a directory"),
    )
  }
  match self {
    Local(local) => {
      let from = absolute_path(local.root, from_rel)
      let to = absolute_path(local.root, to_rel)
      @fs.rename(from, to, replace=false) catch {
        error => return Err(fs_error("cannot move path", error))
      }
      Ok(())
    }
    Ssh(remote) => {
      let from = absolute_path(remote.root, from_rel)
      let to = absolute_path(remote.root, to_rel)
      let result = match
        @ssh.run(
          remote.target,
          ["sh", "-c", "mv -f \"$1\" \"$2\"", "monexus-move", from, to],
          cwd=".",
          timeout_seconds=30,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if result.exit_code != 0 {
        return Err(
          remote_exit(result.exit_code, result.stderr, "cannot move remote path"),
        )
      }
      Ok(())
    }
  }
}

///|
pub async fn WorkspaceProvider::remove(
  self : WorkspaceProvider,
  path : String,
) -> Result[Unit, @error.ProviderError] {
  let relative = match normalize_relative(path) {
    Ok(value) => value
    Err(message) =>
      return Err(ws_error(@error.ProviderErrorKind::Internal, message))
  }
  if relative == "" {
    return Err(
      ws_error(@error.ProviderErrorKind::Internal, "cannot remove workspace root"),
    )
  }
  match self {
    Local(local) => {
      let abs = absolute_path(local.root, relative)
      let kind = @fs.kind(abs, follow_symlink=false) catch {
        error => return Err(fs_error("cannot stat path", error))
      }
      if kind is Directory {
        @fs.rmdir(abs, recursive=false) catch {
          error => return Err(fs_error("cannot remove directory", error))
        }
      } else {
        @fs.remove(abs) catch {
          error => return Err(fs_error("cannot remove file", error))
        }
      }
      Ok(())
    }
    Ssh(remote) => {
      let abs = absolute_path(remote.root, relative)
      let script = [
        "if [ -d \"$1\" ] && [ ! -L \"$1\" ]; then rmdir \"$1\"; else rm -f \"$1\"; fi",
      ].join("\n")
      let result = match
        @ssh.run(
          remote.target,
          ["sh", "-c", script, "monexus-remove", abs],
          cwd=".",
          timeout_seconds=30,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if result.exit_code != 0 {
        return Err(
          remote_exit(result.exit_code, result.stderr, "cannot remove remote path"),
        )
      }
      Ok(())
    }
  }
}

// ---------------------------------------------------------------------------
// Git
// ---------------------------------------------------------------------------

///|
async fn run_git(
  provider : WorkspaceProvider,
  args : Array[String],
  timeout_seconds : Int,
) -> Result[CmdResult, @error.ProviderError] {
  let git_args : Array[String] = ["git"]
  for arg in args {
    git_args.push(arg)
  }
  match provider {
    Local(local) => run_local(git_args, local.root, timeout_seconds)
    Ssh(remote) =>
      match
        @ssh.run(
          remote.target,
          git_args,
          cwd=remote.root,
          timeout_seconds=timeout_seconds,
        ) {
        Ok(value) =>
          Ok({
            exit_code: value.exit_code,
            stdout: value.stdout,
            stderr: value.stderr,
          })
        Err(error) => Err(error)
      }
  }
}

///|
pub fn parse_git_status(raw : String, is_git : Bool) -> GitStatusInfo {
  let mut branch = ""
  let mut upstream = ""
  let mut ahead = 0
  let mut behind = 0
  let changes : Array[GitChangeInfo] = []
  for raw_line in raw.split("\n") {
    let line = raw_line.trim_end(chars="\r").to_owned()
    if line == "" {
      continue
    }
    if line.has_prefix("## ") {
      let header = line.substring(start=3)
      let tracked = match header.split_once("...") {
        Some((local_branch, rest)) => {
          upstream = match rest.split_once(" ") {
            Some((name, _)) => name.to_owned()
            None => rest.to_owned()
          }
          local_branch.to_owned()
        }
        None => header
      }
      branch = tracked
      let open = line.find("[")
      match open {
        Some(index) => {
          let close = line.find("]")
          match close {
            Some(end) =>
              if end > index {
                let details = line.substring(start=index + 1, end=end)
                for part in details.split(",") {
                  let piece = part.trim().to_owned()
                  if piece.has_prefix("ahead ") {
                    ahead = @string.parse_int(piece.substring(start=6)) catch {
                      _ => 0
                    }
                  }
                  if piece.has_prefix("behind ") {
                    behind = @string.parse_int(piece.substring(start=7)) catch {
                      _ => 0
                    }
                  }
                }
              }
            None => ()
          }
        }
        None => ()
      }
      continue
    }
    if line.length() < 3 {
      continue
    }
    let index_status = line.substring(start=0, end=1)
    let worktree_status = line.substring(start=1, end=2)
    let path_text = line.substring(start=3)
    let path = match path_text.split_once(" -> ") {
      Some((_, new_path)) => new_path.to_owned()
      None => path_text
    }
    let status = (index_status + worktree_status).trim().to_owned()
    changes.push({
      path,
      status: if status == "" { "??" } else { status },
      index_status,
      worktree_status,
    })
  }
  {
    is_git,
    branch,
    upstream,
    ahead,
    behind,
    changes,
  }
}

///|
pub async fn WorkspaceProvider::git_status(
  self : WorkspaceProvider,
) -> Result[GitStatusInfo, @error.ProviderError] {
  if !self.is_git() {
    return Ok(parse_git_status("", false))
  }
  let result = match
    run_git(self, ["--no-pager", "status", "--porcelain=v1", "--branch"], 30) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if result.exit_code != 0 {
    return Err(
      remote_exit(result.exit_code, result.stderr, "git status failed"),
    )
  }
  Ok(parse_git_status(result.stdout, true))
}

///|
fn truncate_text(text : String, limit : Int32) -> (String, Bool) {
  if text.length() <= limit {
    return (text, false)
  }
  let mut out = ""
  let mut index = 0
  while index < limit {
    match text.get_char(index) {
      Some(ch) => out = out + ch.to_string()
      None => break
    }
    index = index + 1
  }
  (out + "\n... (diff truncated)", true)
}

///|
pub async fn WorkspaceProvider::git_diff(
  self : WorkspaceProvider,
  path : String,
  cached : Bool,
  range : String,
) -> Result[GitDiffInfo, @error.ProviderError] {
  let relative = match normalize_relative(path) {
    Ok(value) => value
    Err(message) =>
      return Err(ws_error(@error.ProviderErrorKind::Internal, message))
  }
  let args : Array[String] = ["--no-pager", "diff", "--no-color"]
  if cached {
    args.push("--cached")
  }
  let safe_range = if range.trim() != "" && !range.has_prefix("-") {
    range.trim().to_owned()
  } else {
    ""
  }
  if safe_range != "" {
    args.push(safe_range)
  }
  if relative != "" {
    args.push("--")
    args.push(relative)
  }
  let result = match run_git(self, args, 60) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if result.exit_code != 0 {
    return Err(remote_exit(result.exit_code, result.stderr, "git diff failed"))
  }
  let (text, truncated) = truncate_text(result.stdout, 131_072)
  Ok({ path: relative, cached, range: safe_range, text, truncated })
}

// ---------------------------------------------------------------------------
// Worktrees
// ---------------------------------------------------------------------------

///|
pub async fn WorkspaceProvider::create_worktree(
  self : WorkspaceProvider,
  path : String,
  branch : String,
  base : String,
) -> Result[Unit, @error.ProviderError] {
  if !self.is_git() {
    return Err(
      ws_error(
        @error.ProviderErrorKind::Internal,
        "workspace is not a git repository",
      ),
    )
  }
  if !path.has_prefix("/") {
    return Err(
      ws_error(
        @error.ProviderErrorKind::Internal,
        "worktree path must be absolute",
      ),
    )
  }
  let args : Array[String] = ["worktree", "add"]
  let branch_text = branch.trim().to_owned()
  if branch_text == "" {
    args.push("--detach")
  } else {
    args.push("-b")
    args.push(branch_text)
  }
  args.push(path)
  let base_text = base.trim().to_owned()
  if base_text != "" && !base_text.has_prefix("-") {
    args.push(base_text)
  }
  let result = match run_git(self, args, 120) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if result.exit_code != 0 {
    return Err(
      remote_exit(result.exit_code, result.stderr, "git worktree add failed"),
    )
  }
  Ok(())
}

///|
pub async fn WorkspaceProvider::remove_worktree(
  self : WorkspaceProvider,
  path : String,
  force : Bool,
) -> Result[Unit, @error.ProviderError] {
  let args : Array[String] = ["worktree", "remove"]
  if force {
    args.push("--force")
  }
  args.push(path)
  let result = match run_git(self, args, 60) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if result.exit_code != 0 {
    return Err(
      remote_exit(result.exit_code, result.stderr, "git worktree remove failed"),
    )
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// Terminal
// ---------------------------------------------------------------------------

///|
/// Strip ANSI/VT control sequences and turn carriage returns into line
/// breaks, so the desktop can show the line-oriented V0.1 transcript without
/// a full terminal grid.
pub fn sanitize_terminal(text : String) -> String {
  let mut out = ""
  let mut index = 0
  let length = text.length()
  while index < length {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => break
    }
    let code = ch.to_int()
    if code == 27 {
      index = index + 1
      if index < length {
        match text.get_char(index) {
          Some(next) =>
            if next.to_int() == 91 {
              index = index + 1
              while index < length {
                match text.get_char(index) {
                  Some(inner) => {
                    index = index + 1
                    let c = inner.to_int()
                    if c >= 64 && c <= 126 {
                      break
                    }
                  }
                  None => break
                }
              }
            } else if next.to_int() == 93 {
              index = index + 1
              let mut done = false
              while index < length && !done {
                match text.get_char(index) {
                  Some(inner) => {
                    let c = inner.to_int()
                    index = index + 1
                    if c == 7 {
                      done = true
                    } else if c == 27 {
                      index = index + 1
                      done = true
                    }
                  }
                  None => break
                }
              }
            } else {
              index = index + 1
            }
          None => ()
        }
      }
      continue
    }
    if code == 13 {
      out = out + "\n"
      index = index + 1
      continue
    }
    if code == 7 {
      index = index + 1
      continue
    }
    if code == 8 {
      index = index + 1
      continue
    }
    if code == 10 || code == 9 || code >= 32 {
      out = out + ch.to_string()
    }
    index = index + 1
  }
  out
}

///|
async fn run_local_terminal(
  ws : LocalWorkspace,
  command : String,
  rows : Int32,
  cols : Int32,
  input : @aqueue.Queue[TerminalInput],
  output : @aqueue.Queue[TerminalEvent],
) -> Unit {
  let shell = match @env.get_env_var("SHELL") {
    Some(value) if value != "" => value
    _ => "/bin/sh"
  }
  let has_command = command.trim() != ""
  let program : String = if has_command { "sh" } else { shell }
  let args : Array[StringView] = if has_command {
    ["-c", command.to_string_view()]
  } else {
    ["-i"]
  }
  @async.with_task_group(async fn(group) {
    let pty = @pty.spawn(
      group,
      program,
      args,
      rows=rows,
      cols=cols,
      cwd=ws.root,
      no_wait=true,
    )
    group.spawn_bg(() => {
      for ;; {
        let chunk = pty.read_some() catch { _ => break }
        match chunk {
          Some(bytes) => {
            let text = @utf8.decode_lossy(bytes[:], ignore_bom=false)
            let clean = sanitize_terminal(text)
            if clean != "" {
              output.put(Data(clean)) catch { _ => break }
            }
          }
          None => break
        }
      }
      output.put(Eof) catch { _ => () }
      group.return_immediately(())
    })
    for ;; {
      let item = input.get() catch { _ => break }
      match item {
        Data(text) => pty.write(text) catch { _ => break }
        Resize(rows, cols) =>
          pty.resize(rows~, cols~) catch {
            _ => ()
          }
        Close => break
      }
    }
  })
  output.put(Eof) catch { _ => () }
  output.close()
}

///|
fn ssh_tty_argv(
  target : @ssh.SshTarget,
  remote_command : String,
) -> Array[String] {
  let argv = @ssh.ssh_argv(target, remote_command)
  let out : Array[String] = []
  if argv.length() < 2 {
    return argv
  }
  let mut index = 0
  while index < argv.length() - 2 {
    out.push(argv[index])
    index = index + 1
  }
  out.push("-tt")
  out.push(argv[argv.length() - 2])
  out.push(argv[argv.length() - 1])
  out
}

///|
/// Wrap an `ssh -tt` argv so it runs behind a local PTY. The shell puts the
/// slave PTY into raw mode before exec: without it the local terminal starts
/// canonical with echo, which line-buffers input and duplicates local echo in
/// front of the remote terminal's echo.
fn ssh_pty_argv(argv : Array[String]) -> Array[String] {
  let wrapped : Array[String] = [
    "sh",
    "-c",
    "stty raw -echo 2>/dev/null || true; exec \"$0\" \"$@\"",
  ]
  for arg in argv {
    wrapped.push(arg)
  }
  wrapped
}

///|
fn remote_terminal_command(
  root : String,
  session_name : String,
  command : String,
) -> String {
  // A one-shot command runs directly under ssh -tt: tmux would repaint its
  // status bar and can swallow short-lived command output. Interactive
  // sessions are attached to (or created in) a tmux session so they survive
  // reconnects, per the M3 terminal contract.
  if command.trim() != "" {
    let script = "cd -- \"$1\" && exec sh -c \"$2\""
    return [
      "sh",
      "-c",
      @ssh.shell_quote(script),
      "monexus-term",
      @ssh.shell_quote(root),
      @ssh.shell_quote(command),
    ].join(" ")
  }
  let script = [
    "if command -v tmux >/dev/null 2>&1; then",
    "  exec env TERM=xterm-256color tmux -u new-session -A -s \"$1\" -c \"$2\" sh -c \"$3\"",
    "fi",
    "cd -- \"$2\" && exec sh -c \"$3\"",
  ].join("\n")
  [
    "sh",
    "-c",
    @ssh.shell_quote(script),
    "monexus-term",
    @ssh.shell_quote(session_name),
    @ssh.shell_quote(root),
    @ssh.shell_quote("exec ${SHELL:-/bin/sh} -i"),
  ].join(" ")
}

///|
/// Run an SSH terminal through a local PTY. Resizing that PTY sends SIGWINCH
/// to `ssh`, which forwards the window-change event to the remote PTY.
pub async fn run_ssh_pty_terminal(
  target : @ssh.SshTarget,
  remote_command : String,
  rows : Int32,
  cols : Int32,
  input : @aqueue.Queue[TerminalInput],
  output : @aqueue.Queue[TerminalEvent],
) -> Unit {
  let argv = ssh_pty_argv(ssh_tty_argv(target, remote_command))
  let args : Array[StringView] = []
  for index in 1..<argv.length() {
    args.push(argv[index].to_string_view())
  }
  @async.with_task_group(async fn(group) {
    let pty = @pty.spawn(
      group,
      argv[0],
      args,
      rows=rows,
      cols=cols,
      no_wait=true,
    ) catch {
      error => {
        output.put(
          Data("terminal: cannot spawn ssh: " + error.to_string() + "\n"),
        ) catch { _ => () }
        output.put(Eof) catch { _ => () }
        group.return_immediately(())
        return
      }
    }
    group.spawn_bg(() => {
      for ;; {
        let chunk = pty.read_some() catch {
          error => {
            output.put(
              Data("terminal: ssh read failed: " + error.to_string() + "\n"),
            ) catch { _ => () }
            break
          }
        }
        match chunk {
          Some(bytes) => {
            let text = @utf8.decode_lossy(bytes[:], ignore_bom=false)
            let clean = sanitize_terminal(text)
            if clean != "" {
              output.put(Data(clean)) catch { _ => break }
            }
          }
          None => break
        }
      }
      output.put(Eof) catch { _ => () }
      group.return_immediately(())
    })
    for ;; {
      let item = input.get() catch { _ => break }
      match item {
        Data(text) =>
          pty.write(text) catch {
            error => {
              output.put(
                Data("terminal: ssh write failed: " + error.to_string() + "\n"),
              ) catch { _ => () }
              group.return_immediately(())
              break
            }
          }
        Resize(rows, cols) =>
          pty.resize(rows~, cols~) catch {
            _ => ()
          }
        Close => break
      }
    }
  })
  output.put(Eof) catch { _ => () }
  output.close()
}

///|
async fn run_ssh_terminal(
  ws : SshWorkspace,
  session_name : String,
  command : String,
  rows : Int32,
  cols : Int32,
  input : @aqueue.Queue[TerminalInput],
  output : @aqueue.Queue[TerminalEvent],
) -> Unit {
  let remote = remote_terminal_command(ws.root, session_name, command)
  run_ssh_pty_terminal(ws.target, remote, rows, cols, input, output)
}

///|
/// Run one terminal session until the child exits or `Close` is queued.
/// Output events are sanitized and line-oriented; the host keeps the
/// transcript and cursor.
pub async fn WorkspaceProvider::run_terminal(
  self : WorkspaceProvider,
  session_name : String,
  command : String,
  rows : Int32,
  cols : Int32,
  input : @aqueue.Queue[TerminalInput],
  output : @aqueue.Queue[TerminalEvent],
) -> Unit {
  match self {
    Local(local) =>
      run_local_terminal(local, command, rows, cols, input, output)
    Ssh(remote) =>
      run_ssh_terminal(remote, session_name, command, rows, cols, input, output)
  }
}

///|
/// One-shot command result for Run execution and the evidence gate.
pub(all) struct ExecResult {
  exit_code : Int
  stdout : String
  stderr : String
  timed_out : Bool
}

///|
/// Execute one `sh -c` command with `cwd` as the working directory on the
/// workspace's transport. Used by M5 Runs and the evidence gate; the command
/// is owner-declared (project verify[] or an authenticated `run.create`), not
/// agent-submitted, so it may use shell syntax. Output collection is bounded
/// at 1 MiB by the caller; the provider returns what the transport produced.
pub async fn WorkspaceProvider::exec(
  self : WorkspaceProvider,
  command : String,
  cwd~ : String,
  timeout_seconds~ : Int = 120,
) -> Result[ExecResult, @error.ProviderError] {
  if command.trim() == "" {
    return Err(
      @error.ProviderError::new(
        @error.ProviderErrorKind::Internal,
        "empty command",
      ),
    )
  }
  match self {
    Local(_) => {
      let budget_ms = timeout_seconds.max(1) * 1_000
      let collected = @async.with_timeout_opt(
        budget_ms,
        async fn() -> Result[ExecResult, @error.ProviderError] {
          let (exit_code, stdout, stderr) = @process.collect_output(
            "/bin/sh",
            ["-c", command],
            cwd=cwd,
          ) catch {
            error =>
              return Err(
                @error.ProviderError::new(
                  @error.ProviderErrorKind::SpawnFailed,
                  "failed to spawn command",
                ).with_detail(error.to_string()),
              )
          }
          let stdout_text = stdout.text() catch { _ => "" }
          let stderr_text = stderr.text() catch { _ => "" }
          Ok({
            exit_code: exit_code.to_int(),
            stdout: stdout_text,
            stderr: stderr_text,
            timed_out: false,
          })
        },
      )
      match collected {
        Some(Ok(value)) => Ok(value)
        Some(Err(error)) => Err(error)
        None =>
          Err(
            @error.ProviderError::new(
              @error.ProviderErrorKind::ConnectTimeout,
              "command timed out after " + timeout_seconds.to_string() + "s",
            ),
          )
      }
    }
    Ssh(remote) =>
      match
        @ssh.run(
          remote.target,
          ["sh", "-c", command],
          cwd=cwd,
          timeout_seconds=timeout_seconds,
        ) {
        Ok(result) =>
          Ok({
            exit_code: result.exit_code,
            stdout: result.stdout,
            stderr: result.stderr,
            timed_out: false,
          })
        Err(error) => Err(error)
      }
  }
}

// ---------------------------------------------------------------------------
// Durable (tmux-backed) execution — M6 recovery
// ---------------------------------------------------------------------------

///|
/// Where a durable run lives. `durable=false` means tmux was unavailable and
/// the caller must fall back to a plain `exec` (that run is then not
/// recoverable after a host restart, which recovery records as unverifiable).
pub(all) struct DurableHandle {
  durable : Bool
  session : String
  log_path : String
  exit_path : String
}

///|
/// One poll of a durable run. `alive` means the tmux session still exists;
/// `exited` means the exit marker exists and `exit_code` is authoritative.
/// `dead` means the session exists but its pane is dead (`remain-on-exit`):
/// if no exit marker was written, the command's exit code is unknowable and
/// the caller must treat the run as lost instead of polling forever.
pub(all) struct DurablePoll {
  alive : Bool
  exited : Bool
  exit_code : Int
  dead : Bool
  dead_status : Int
  output : String
  error : String
}

///|
const DURABLE_TAIL_BYTES : Int = 65_536

///|
fn durable_poll_script(
  session : String,
  log_path : String,
  exit_path : String,
) -> String {
  let q = @ssh.shell_quote
  [
    "if command -v tmux >/dev/null 2>&1; then",
    "  if tmux has-session -t " + q(session) + " 2>/dev/null; then",
    "    printf '__ALIVE__\\n'",
    "    pane_dead=$(tmux list-panes -t " + q(session) + " -F '#{pane_dead}' 2>/dev/null | head -n 1)",
    "    if [ \"$pane_dead\" = \"1\" ]; then",
    "      pane_status=$(tmux display-message -p -t " + q(session) + " '#{pane_dead_status}' 2>/dev/null)",
    "      if [ -z \"$pane_status\" ]; then pane_status=-1; fi",
    "      printf '__DEAD__%s\\n' \"$pane_status\"",
    "    elif [ -z \"$pane_dead\" ] && tmux capture-pane -p -t " + q(session) + " 2>/dev/null | grep -q 'Pane is dead'; then",
    "      printf '__DEAD__-1\\n'",
    "    fi",
    "  fi",
    "fi",
    "if [ -f " + q(exit_path) + " ]; then",
    "  printf '__EXIT__%s\\n' \"$(cat " + q(exit_path) + ")\"",
    "fi",
    "if [ -f " + q(log_path) + " ]; then",
    "  printf '__LOG__\\n'",
    "  tail -c " + DURABLE_TAIL_BYTES.to_string() + " " + q(log_path) + " 2>/dev/null",
    "fi",
  ].join("\n")
}

///|
fn parse_durable_poll(text : String) -> DurablePoll {
  let mut alive = false
  let mut exited = false
  let mut exit_code = -1
  let mut dead = false
  let mut dead_status = -1
  let mut in_log = false
  // Lines after `__LOG__` are the raw log tail. Collecting and joining them
  // (instead of appending "\n" per line) keeps an empty log empty and
  // preserves a trailing newline only when the log really has one.
  let log_lines : Array[String] = []
  for raw in text.split("\n") {
    let line = raw.to_owned()
    if in_log {
      log_lines.push(line)
    } else if line == "__ALIVE__" {
      alive = true
    } else if line.has_prefix("__EXIT__") {
      exited = true
      let code = @string.parse_int(line.substring(start=8).trim()) catch {
        _ => -1
      }
      exit_code = code
    } else if line.has_prefix("__DEAD__") {
      dead = true
      let code = @string.parse_int(line.substring(start=8).trim()) catch {
        _ => -1
      }
      dead_status = code
    } else if line == "__LOG__" {
      in_log = true
    }
  }
  let output = log_lines.join("\n")
  { alive, exited, exit_code, dead, dead_status, output, error: "" }
}

///|
fn replace_home_prefix(path : String, home : String) -> String {
  if path.has_prefix("$HOME") {
    home + path.substring(start=5)
  } else {
    path
  }
}

///|
/// Start `command` in a new tmux session so it survives a host exit. The
/// command writes stdout/stderr to `log_path` and its exit code to
/// `exit_path`; both are polled by `durable_poll`. Local runs keep their log
/// under the host state dir; SSH runs use `$HOME/.monexus/logs/<session>` on
/// the target machine (architecture §12).
pub async fn WorkspaceProvider::durable_start(
  self : WorkspaceProvider,
  session~ : String,
  command~ : String,
  cwd~ : String,
  local_dir~ : String,
) -> Result[DurableHandle, @error.ProviderError] {
  let q = @ssh.shell_quote
  let (log_path, exit_path, start_script) = match self {
    Local(_) => {
      let log_path = local_dir + "/run.log"
      let exit_path = local_dir + "/run.exit"
      let script = [
        "mkdir -p " + q(local_dir),
        "rm -f " + q(exit_path) + " " + q(exit_path + ".tmp"),
        "if ! command -v tmux >/dev/null 2>&1; then printf '__MONEXUS_NO_TMUX__\\n'; exit 0; fi",
        // A crashed or cancelled previous run can leave a dead pane with the
        // same deterministic name (remain-on-exit keeps it listed). Remove it
        // before creating the session, otherwise new-session fails silently
        // and this run never gets a fresh exit marker.
        "tmux kill-session -t " + q(session) + " 2>/dev/null || true",
        "if ! tmux new-session -d -s " + q(session) + " -c " + q(cwd) +
        " sh -c 'sh -c \"$1\" > \"$2\" 2>&1; printf \"%s\" \"$?\" > \"$3.tmp\"; mv \"$3.tmp\" \"$3\"' monexus-run " +
        q(command) + " " + q(log_path) + " " + q(exit_path) + "; then",
        "  printf '__MONEXUS_TMUX_FAILED__\\n'; exit 3",
        "fi",
        "printf '__MONEXUS_STARTED__\\n'",
      ].join("\n")
      (log_path, exit_path, script)
    }
    Ssh(_) => {
      let log_path = "$HOME/.monexus/logs/" + session + ".log"
      let exit_path = "$HOME/.monexus/logs/" + session + ".exit"
      let script = [
        "dir=\"$HOME/.monexus/logs\"; mkdir -p \"$dir\"",
        "printf '__HOME__%s\\n' \"$HOME\"",
        "log=\"$dir/" + session + ".log\"; exitf=\"$dir/" + session + ".exit\"",
        "rm -f \"$exitf\" \"$exitf.tmp\"",
        "if ! command -v tmux >/dev/null 2>&1; then printf '__MONEXUS_NO_TMUX__\\n'; exit 0; fi",
        "tmux kill-session -t " + q(session) + " 2>/dev/null || true",
        "if ! tmux new-session -d -s " + q(session) + " -c " + q(cwd) +
        " sh -c 'sh -c \"$1\" > \"$2\" 2>&1; printf \"%s\" \"$?\" > \"$3.tmp\"; mv \"$3.tmp\" \"$3\"' monexus-run " +
        q(command) + " \"$log\" \"$exitf\"; then",
        "  printf '__MONEXUS_TMUX_FAILED__\\n'; exit 3",
        "fi",
        "printf '__MONEXUS_STARTED__\\n'",
      ].join("\n")
      (log_path, exit_path, script)
    }
  }
  let result = match self.exec(start_script, cwd~, timeout_seconds=30) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if result.timed_out || result.exit_code != 0 {
    return Err(
      @error.ProviderError::new(
        @error.ProviderErrorKind::RemoteExit,
        "durable start failed",
      ).with_detail(result.stderr),
    )
  }
  let durable = result.stdout.contains("__MONEXUS_STARTED__")
  // SSH paths were built with a literal `$HOME`; resolve it from the start
  // script so later polls can `test -f` the real absolute path.
  let mut resolved_log = log_path
  let mut resolved_exit = exit_path
  for line in result.stdout.split("\n") {
    let line = line.to_string()
    if line.has_prefix("__HOME__") {
      let home = line.substring(start=8).trim_end(chars="\r").to_owned()
      if home != "" && home != "~" {
        resolved_log = replace_home_prefix(log_path, home)
        resolved_exit = replace_home_prefix(exit_path, home)
      }
    }
  }
  Ok({
    durable,
    session,
    log_path: resolved_log,
    exit_path: resolved_exit,
  })
}

///|
/// Poll one durable run. A transport failure is returned as `error` with
/// `alive=false, exited=false`; callers treat that as "cannot observe", never
/// as "the command exited".
pub async fn WorkspaceProvider::durable_poll(
  self : WorkspaceProvider,
  handle : DurableHandle,
) -> DurablePoll {
  if !handle.durable {
    return {
      alive: false,
      exited: false,
      exit_code: -1,
      dead: false,
      dead_status: -1,
      output: "",
      error: "run is not durable (tmux unavailable)",
    }
  }
  let script = durable_poll_script(
    handle.session,
    handle.log_path,
    handle.exit_path,
  )
  let result = match self.exec(script, cwd="/", timeout_seconds=15) {
    Ok(value) => value
    Err(error) =>
      return {
        alive: false,
        exited: false,
        exit_code: -1,
        dead: false,
        dead_status: -1,
        output: "",
        error: error.to_string(),
      }
  }
  if result.exit_code == 255 {
    return {
      alive: false,
      exited: false,
      exit_code: -1,
      dead: false,
      dead_status: -1,
      output: "",
      error: "transport unavailable: " + result.stderr,
    }
  }
  parse_durable_poll(result.stdout)
}

///|
/// Best-effort teardown of a durable session (cancel or retry).
pub async fn WorkspaceProvider::durable_stop(
  self : WorkspaceProvider,
  handle : DurableHandle,
) -> Unit {
  if !handle.durable {
    return
  }
  let q = @ssh.shell_quote
  let script = "if command -v tmux >/dev/null 2>&1; then tmux kill-session -t " +
    q(handle.session) + " 2>/dev/null || true; fi"
  let _ = self.exec(script, cwd="/", timeout_seconds=10)
}
