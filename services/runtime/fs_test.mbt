///|
/// Rooted filesystem tests: every read/write/list/stat goes through a
/// `RootedDir`, and anything that resolves outside the root is rejected.
async fn fs_cleanup(path : String) -> Unit {
  @fs.rmdir(path, recursive=true) catch {
    _ => ()
  }
}

///|
async fn open_work_root(root : String) -> RootedDir {
  let state = match RuntimeState::open(root) {
    Ok(value) => value
    Err(message) => fail("cannot open state: " + message)
  }
  match RootedDir::open(state.work_dir()) {
    Ok(value) => value
    Err(message) => fail("cannot open rooted work dir: " + message)
  }
}

///|
async test "rooted write, read, list and stat stay inside the root" {
  let root = @fs.tmpdir(prefix="rt-fs")
  defer fs_cleanup(root)
  let dir = open_work_root(root)
  assert_eq(
    match dir.write_text("notes.txt", "hello") {
      Ok(_) => "ok"
      Err(message) => message
    },
    "ok",
  )
  assert_eq(
    match dir.read_text("notes.txt") {
      Ok(value) => value
      Err(message) => message
    },
    "hello",
  )
  let stat = match dir.stat("notes.txt") {
    Ok(value) => value
    Err(message) => fail("stat failed: " + message)
  }
  assert_eq(stat.kind, "file")
  assert_eq(stat.size, 5L)
  assert_eq(stat.path, "notes.txt")
  let entries = match dir.list("") {
    Ok(value) => value
    Err(message) => fail("list failed: " + message)
  }
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].name, "notes.txt")
  assert_true(!entries[0].is_dir)
  let root_stat = match dir.stat("") {
    Ok(value) => value
    Err(message) => fail("root stat failed: " + message)
  }
  assert_eq(root_stat.kind, "dir")
}

///|
async test "rooted write is atomic and leaves no temp files" {
  let root = @fs.tmpdir(prefix="rt-fs-atomic")
  defer fs_cleanup(root)
  let dir = open_work_root(root)
  let _ = dir.write_text("note.txt", "first version") catch {
    _ => fail("initial write failed")
  }
  let _ = dir.write_text("note.txt", "second") catch {
    _ => fail("overwrite failed")
  }
  assert_eq(
    match dir.read_text("note.txt") {
      Ok(value) => value
      Err(message) => message
    },
    "second",
  )
  let entries = match dir.list("") {
    Ok(value) => value
    Err(message) => fail("list failed: " + message)
  }
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].name, "note.txt")
  // A nested path needs its parent to already exist.
  assert_true(
    match dir.write_text("missing/child.txt", "x") {
      Ok(_) => false
      Err(_) => true
    },
  )
  assert_true(
    match dir.write_text("child.txt", "x") {
      Ok(_) => true
      Err(message) => fail("root-level write failed: " + message)
    },
  )
}

///|
async test "rooted paths reject traversal and absolute escapes" {
  let root = @fs.tmpdir(prefix="rt-fs-escape")
  defer fs_cleanup(root)
  let dir = open_work_root(root)
  assert_true(
    match dir.read_text("../etc/passwd") {
      Ok(_) => false
      Err(_) => true
    },
  )
  assert_true(
    match dir.write_text("../escape.txt", "x") {
      Ok(_) => false
      Err(_) => true
    },
  )
  assert_true(
    match dir.write_text("/tmp/monexus-escape.txt", "x") {
      Ok(_) => false
      Err(_) => true
    },
  )
  assert_true(
    match dir.read_text("/etc/passwd") {
      Ok(_) => false
      Err(_) => true
    },
  )
  assert_true(
    match dir.list("../") {
      Ok(_) => false
      Err(_) => true
    },
  )
  assert_true(
    match dir.stat("a/../../b") {
      Ok(_) => false
      Err(_) => true
    },
  )
  // Nothing outside the root was created.
  assert_true(!(@fs.exists("/tmp/monexus-escape.txt") catch { _ => true }))
}

///|
async test "symlinks pointing outside the root are rejected" {
  let root = @fs.tmpdir(prefix="rt-fs-symlink")
  defer fs_cleanup(root)
  let outside = @fs.tmpdir(prefix="rt-fs-outside")
  defer fs_cleanup(outside)
  let outside_file = outside + "/secret.txt"
  @fs.write_file(outside_file, "outside content", permission=0o600) catch {
    _ => fail("cannot write outside fixture")
  }
  let dir = open_work_root(root)
  let work = dir.root()
  @fs.symlink(target=outside_file, work + "/file-link") catch {
    _ => fail("cannot create file symlink")
  }
  @fs.symlink(target=outside, work + "/dir-link") catch {
    _ => fail("cannot create dir symlink")
  }
  assert_true(
    match dir.read_text("file-link") {
      Ok(_) => false
      Err(_) => true
    },
  )
  assert_true(
    match dir.write_text("dir-link/escape.txt", "x") {
      Ok(_) => false
      Err(_) => true
    },
  )
  assert_true(
    match dir.list("dir-link") {
      Ok(_) => false
      Err(_) => true
    },
  )
  assert_true(!(@fs.exists(outside + "/escape.txt") catch { _ => true }))
  // A symlink resolving inside the root is still refused for writes (the
  // rename would replace the link), so writes cannot shadow host files.
  let _ = dir.write_text("inside.txt", "inside") catch {
    _ => fail("cannot write inside file")
  }
  @fs.symlink(target=work + "/inside.txt", work + "/inside-link") catch {
    _ => fail("cannot create inside symlink")
  }
  assert_true(
    match dir.write_text("inside-link", "shadow") {
      Ok(_) => false
      Err(_) => true
    },
  )
  assert_eq(
    match dir.read_text("inside.txt") {
      Ok(value) => value
      Err(message) => message
    },
    "inside",
  )
}

///|
async test "rooted operations reject missing paths and directories" {
  let root = @fs.tmpdir(prefix="rt-fs-missing")
  defer fs_cleanup(root)
  let dir = open_work_root(root)
  assert_true(
    match dir.read_text("missing.txt") {
      Ok(_) => false
      Err(_) => true
    },
  )
  assert_true(
    match dir.stat("missing.txt") {
      Ok(_) => false
      Err(_) => true
    },
  )
  assert_true(
    match dir.read_text("") {
      Ok(_) => false
      Err(_) => true
    },
  )
  let _ = dir.write_text("file.txt", "x") catch { _ => fail("write failed") }
  assert_true(
    match dir.list("file.txt") {
      Ok(_) => false
      Err(_) => true
    },
  )
  assert_true(
    match dir.read_text("file.txt/child") {
      Ok(_) => false
      Err(_) => true
    },
  )
}
