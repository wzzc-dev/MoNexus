///|
/// One path that has been proven to stay under the registered workspace root.
/// `relative` is the normalised, workspace-relative spelling; `absolute` is a
/// resolved real path (or, for a not-yet-created leaf, a real parent plus the
/// leaf name) suitable for handing to git.
struct RootedPath {
  absolute : String
  relative : String
}

///|
fn has_nul(text : String) -> Bool {
  for byte in @utf8.encode(text) {
    if byte == b'\x00' {
      return true
    }
  }
  false
}

///|
fn has_control_char(text : String) -> Bool {
  for ch in text {
    let code = ch.to_int()
    if code < 32 || code == 127 {
      return true
    }
  }
  false
}

///|
fn path_error(kind : GitErrorKind, message : String) -> GitError {
  git_error(kind, message)
}

///|
/// Normalise a workspace-relative path without resolving symlinks. Absolute
/// paths and any `..` segment are rejected rather than collapsed; the caller
/// may add the root prefix only after this check.
fn normalize_relative(path : String) -> Result[String, GitError] {
  if has_nul(path) {
    return Err(
      path_error(GitErrorKind::InvalidArgument, "path contains a NUL byte"),
    )
  }
  if has_control_char(path) {
    return Err(
      path_error(
        GitErrorKind::InvalidArgument,
        "path contains a control character",
      ),
    )
  }
  if path == "" || path == "." {
    return Ok("")
  }
  if path.has_prefix("/") {
    return Err(
      path_error(
        GitErrorKind::OutsideRoot,
        "absolute paths are not allowed here",
      ),
    )
  }
  let segments : Array[String] = []
  for raw in path.split("/") {
    if raw == "" || raw == "." {
      continue
    }
    if raw == ".." {
      return Err(
        path_error(
          GitErrorKind::OutsideRoot,
          "path may not escape the workspace root",
        ),
      )
    }
    segments.push(raw.to_owned())
  }
  Ok(segments.join("/"))
}

///|
fn root_join(root : String, relative : String) -> String {
  if relative == "" {
    root
  } else if root.has_suffix("/") {
    root + relative
  } else {
    root + "/" + relative
  }
}

///|
/// True when `path` is the root itself or lexically below it.
fn is_within(path : String, root : String) -> Bool {
  if path == root {
    return true
  }
  path.has_prefix(root + "/")
}

///|
/// Turn an absolute path under the root, or a relative path, into the
/// normalised workspace-relative spelling. An absolute path outside the root
/// is rejected before any filesystem lookup.
fn relative_input(root : String, input : String) -> Result[String, GitError] {
  if has_nul(input) {
    return Err(
      path_error(GitErrorKind::InvalidArgument, "path contains a NUL byte"),
    )
  }
  if input.has_prefix("/") {
    if input == root {
      return Ok("")
    }
    if !input.has_prefix(root + "/") {
      return Err(
        path_error(
          GitErrorKind::OutsideRoot,
          "absolute path is outside the workspace root",
        ),
      )
    }
    return normalize_relative(input.substring(start=root.length() + 1))
  }
  normalize_relative(input)
}

///|
fn split_relative(relative : String) -> (String, String) {
  match relative.rev_find("/") {
    Some(index) => (
      relative.substring(start=0, end=index),
      relative.substring(start=index + 1),
    )
    None => ("", relative)
  }
}

///|
/// Resolve a path that must exist today. The real path must stay under the
/// root, which rejects both `..` input and symlinks that point outside.
async fn resolve_existing(
  root : String,
  input : String,
  what : String,
) -> Result[RootedPath, GitError] {
  let relative = match relative_input(root, input) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let candidate = root_join(root, relative)
  let real = @fs.realpath(candidate) catch {
    _ =>
      return Err(
        git_error(
          GitErrorKind::NotFound,
          what + " does not exist under the workspace root",
        ),
      )
  }
  if !is_within(real, root) {
    return Err(
      git_error(
        GitErrorKind::OutsideRoot,
        what + " resolves outside the workspace root",
      ),
    )
  }
  Ok({ absolute: real, relative, })
}

///|
/// Resolve a path that may legitimately not exist yet (a deleted file in a
/// diff, for example). The existing parent is resolved and checked; the leaf
/// is appended to that real parent, so a symlinked parent cannot smuggle the
/// request out of the root.
async fn resolve_any(
  root : String,
  input : String,
  what : String,
) -> Result[RootedPath, GitError] {
  let relative = match relative_input(root, input) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let candidate = root_join(root, relative)
  let exists = @fs.exists(candidate) catch { _ => false }
  if exists {
    return resolve_existing(root, input, what)
  }
  if relative == "" {
    return Err(
      git_error(GitErrorKind::NotFound, what + " does not exist"),
    )
  }
  let (parent_rel, leaf) = split_relative(relative)
  let parent = root_join(root, parent_rel)
  let parent_real = @fs.realpath(parent) catch {
    _ =>
      return Err(
        git_error(
          GitErrorKind::NotFound,
          what + " has no existing parent directory under the workspace root",
        ),
      )
  }
  if !is_within(parent_real, root) {
    return Err(
      git_error(
        GitErrorKind::OutsideRoot,
        what + " resolves outside the workspace root",
      ),
    )
  }
  let kind = @fs.kind(parent_real) catch {
    _ =>
      return Err(
        git_error(GitErrorKind::NotFound, what + " has no readable parent"),
      )
  }
  if !(kind is @fs.FileKind::Directory) {
    return Err(
      git_error(GitErrorKind::InvalidArgument, what + " parent is not a directory"),
    )
  }
  Ok({ absolute: root_join(parent_real, leaf), relative, })
}

///|
/// Resolve the destination for a new worktree. The leaf must not exist yet
/// and its parent must be a real directory under the root.
async fn resolve_new(
  root : String,
  input : String,
  what : String,
) -> Result[RootedPath, GitError] {
  let relative = match relative_input(root, input) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if relative == "" {
    return Err(
      git_error(GitErrorKind::InvalidArgument, what + " may not be the root"),
    )
  }
  let candidate = root_join(root, relative)
  let exists = @fs.exists(candidate) catch { _ => false }
  if exists {
    return Err(
      git_error(GitErrorKind::Conflict, what + " already exists"),
    )
  }
  let (parent_rel, leaf) = split_relative(relative)
  let parent = root_join(root, parent_rel)
  let parent_real = @fs.realpath(parent) catch {
    _ =>
      return Err(
        git_error(
          GitErrorKind::NotFound,
          what + " has no existing parent directory under the workspace root",
        ),
      )
  }
  if !is_within(parent_real, root) {
    return Err(
      git_error(
        GitErrorKind::OutsideRoot,
        what + " resolves outside the workspace root",
      ),
    )
  }
  let kind = @fs.kind(parent_real) catch {
    _ =>
      return Err(
        git_error(GitErrorKind::NotFound, what + " has no readable parent"),
      )
  }
  if !(kind is @fs.FileKind::Directory) {
    return Err(
      git_error(GitErrorKind::InvalidArgument, what + " parent is not a directory"),
    )
  }
  Ok({ absolute: root_join(parent_real, leaf), relative, })
}
