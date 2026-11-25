///|
/// One filesystem entry under a rooted directory.
pub(all) struct FsEntry {
  name : String
  path : String
  kind : String
  is_dir : Bool
  size : Int64
}

///|
/// Result of a rooted `stat`.
pub(all) struct FsStat {
  path : String
  kind : String
  size : Int64
}

///|
/// A directory that owns a filesystem boundary (ADR-0012 §6).
///
/// Every operation takes a *relative* path, resolves it with `realpath` (the
/// parent for writes to a new file) and rejects anything that leaves the root
/// after resolution. Absolute paths, `..` segments and symlinks pointing
/// outside the root are refused. There is no API that accepts a host path.
///
/// Known limit: the check-then-use window between `realpath` and the file
/// operation is not atomic (no `openat2` in this slice). Exploiting it needs
/// concurrent local write access to the root, which the 0700 state root and
/// workspace permissions already exclude for other users.
pub struct RootedDir {
  root : String
}

///|
pub async fn RootedDir::open(path : String) -> Result[RootedDir, String] {
  let requested = path.trim().to_owned()
  if requested == "" {
    return Err("root path is required")
  }
  let exists = @fs.exists(requested) catch { _ => false }
  if !exists {
    return Err("root path does not exist: " + requested)
  }
  let real = @fs.realpath(requested) catch {
    error => return Err("cannot resolve root path: " + error.to_string())
  }
  let kind = @fs.kind(real, follow_symlink=false) catch {
    error => return Err("cannot stat root path: " + error.to_string())
  }
  guard kind is Directory else { return Err("root path is not a directory") }
  Ok({ root: real, })
}

///|
pub fn RootedDir::root(self : RootedDir) -> String {
  self.root
}

///|
/// Validate a rooted-relative path without touching the filesystem.
/// Absolute paths and `..` are rejected instead of normalized away.
pub fn normalize_rooted_path(path : String) -> Result[String, String] {
  let trimmed = path.trim().to_owned()
  if trimmed == "" || trimmed == "." {
    return Ok("")
  }
  if trimmed.has_prefix("/") {
    return Err("absolute paths are not allowed")
  }
  let segments : Array[String] = []
  for raw in trimmed.split("/") {
    let segment = raw.to_owned()
    if segment == "" || segment == "." {
      continue
    }
    if segment == ".." {
      return Err("path may not escape the root")
    }
    segments.push(segment)
  }
  Ok(segments.join("/"))
}

///|
fn join_root(root : String, relative : String) -> String {
  if relative == "" {
    root
  } else {
    root + "/" + relative
  }
}

///|
fn is_within(root : String, candidate : String) -> Bool {
  candidate == root || candidate.has_prefix(root + "/")
}

///|
/// Resolve an existing relative path and require it to stay under the root.
async fn RootedDir::resolve_existing(
  self : RootedDir,
  relative : String,
) -> Result[String, String] {
  let candidate = join_root(self.root, relative)
  let real = @fs.realpath(candidate) catch {
    error => return Err("cannot resolve path: " + error.to_string())
  }
  if !is_within(self.root, real) {
    return Err("path escapes the root after resolution")
  }
  Ok(real)
}

///|
/// Resolve a write target. The parent must exist and stay under the root;
/// the final component is never interpreted as a path.
async fn RootedDir::resolve_for_write(
  self : RootedDir,
  relative : String,
) -> Result[String, String] {
  if relative == "" {
    return Err("path is the root directory")
  }
  let parts : Array[String] = []
  for part in relative.split("/") {
    parts.push(part.to_string())
  }
  let last = parts.length() - 1
  let name = parts[last]
  let parent_parts : Array[String] = []
  for index in 0..<last {
    parent_parts.push(parts[index])
  }
  let parent_rel = parent_parts.join("/")
  if name == "" || name == "." || name == ".." {
    return Err("invalid file name")
  }
  let parent = if parent_rel == "" {
    self.root
  } else {
    match RootedDir::resolve_existing(self, parent_rel) {
      Ok(value) => value
      Err(message) => return Err(message)
    }
  }
  let kind = @fs.kind(parent, follow_symlink=true) catch {
    error => return Err("cannot stat parent directory: " + error.to_string())
  }
  guard kind is Directory else { return Err("parent path is not a directory") }
  let target = join_root(parent, name)
  if !is_within(self.root, target) {
    return Err("path escapes the root after resolution")
  }
  // Refuse to write through a symlink: rename would replace the link itself,
  // which is surprising and could be used to shadow a host file.
  let exists = @fs.exists(target) catch { _ => false }
  if exists {
    let target_kind = @fs.kind(target, follow_symlink=false) catch {
      error => return Err("cannot stat path: " + error.to_string())
    }
    guard target_kind is Regular else {
      return Err("target path is not a regular file")
    }
    let real_target = @fs.realpath(target) catch {
      error => return Err("cannot resolve target path: " + error.to_string())
    }
    if !is_within(self.root, real_target) {
      return Err("path escapes the root after resolution")
    }
  }
  Ok(target)
}

///|
fn kind_label(kind : @fs.FileKind) -> String {
  match kind {
    Regular => "file"
    Directory => "dir"
    SymLink => "symlink"
    Socket => "socket"
    Pipe => "pipe"
    BlockDevice => "block_device"
    CharDevice => "char_device"
    _ => "unknown"
  }
}

///|
pub async fn RootedDir::read_text(
  self : RootedDir,
  path : String,
) -> Result[String, String] {
  let relative = match normalize_rooted_path(path) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if relative == "" {
    return Err("path is the root directory")
  }
  let real = match RootedDir::resolve_existing(self, relative) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let kind = @fs.kind(real, follow_symlink=true) catch {
    error => return Err("cannot stat path: " + error.to_string())
  }
  guard kind is Regular else { return Err("path is not a regular file") }
  let data = @fs.read_file(real) catch {
    error => return Err("cannot read file: " + error.to_string())
  }
  Ok(data.text() catch { _ => return Err("file is not valid UTF-8 text") })
}

///|
/// Atomic rooted write: write a 0600 temp file in the resolved parent
/// directory, fsync it, then rename it over the target. A failed write removes
/// the temp file; readers see either the old or the new content.
pub async fn RootedDir::write_text(
  self : RootedDir,
  path : String,
  content : String,
) -> Result[Unit, String] {
  let relative = match normalize_rooted_path(path) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let target = match RootedDir::resolve_for_write(self, relative) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let suffix = next_temp_suffix()
  let temp = target + ".monexus-tmp-" + suffix
  @fs.write_file(
    temp,
    content,
    create_mode=@fs.CreateMode::CreateNew,
    permission=0o600,
    sync=@fs.SyncMode::Data,
  ) catch {
    error => return Err("cannot write temporary file: " + error.to_string())
  }
  @fs.rename(temp, target, replace=true) catch {
    error => {
      @fs.remove(temp) catch {
        _ => ()
      }
      return Err("cannot publish written file: " + error.to_string())
    }
  }
  Ok(())
}

///|
pub async fn RootedDir::list(
  self : RootedDir,
  path : String,
) -> Result[Array[FsEntry], String] {
  let relative = match normalize_rooted_path(path) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let real = match RootedDir::resolve_existing(self, relative) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let kind = @fs.kind(real, follow_symlink=true) catch {
    error => return Err("cannot stat directory: " + error.to_string())
  }
  guard kind is Directory else { return Err("path is not a directory") }
  let names = @fs.readdir(
    real,
    include_hidden=true,
    include_special=false,
    sort=true,
  ) catch {
    error => return Err("cannot list directory: " + error.to_string())
  }
  let entries : Array[FsEntry] = []
  for name in names {
    let child_rel = if relative == "" { name } else { relative + "/" + name }
    let child_abs = join_root(real, name)
    let child_kind = @fs.kind(child_abs, follow_symlink=false) catch {
      _ => @fs.FileKind::Unknown
    }
    let size = if child_kind is Regular {
      @fs.file_size(child_abs) catch {
        _ => 0L
      }
    } else {
      0L
    }
    entries.push({
      name,
      path: child_rel,
      kind: kind_label(child_kind),
      is_dir: child_kind is Directory,
      size,
    })
  }
  Ok(entries)
}

///|
pub async fn RootedDir::stat(
  self : RootedDir,
  path : String,
) -> Result[FsStat, String] {
  let relative = match normalize_rooted_path(path) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let real = match RootedDir::resolve_existing(self, relative) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let kind = @fs.kind(real, follow_symlink=true) catch {
    error => return Err("cannot stat path: " + error.to_string())
  }
  let size = if kind is Regular {
    @fs.file_size(real) catch {
      _ => 0L
    }
  } else {
    0L
  }
  Ok({ path: relative, kind: kind_label(kind), size, })
}

///|
let temp_counter : Ref[Int32] = Ref(0)

///|
fn next_temp_suffix() -> String {
  temp_counter.val = temp_counter.val + 1
  @async.now().to_string() + "-" + temp_counter.val.to_string()
}
