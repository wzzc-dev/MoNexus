///|
/// The SSH env-file hand-off verifies the remote mode and ownership the same
/// way the local runner does. The check script is exercised locally with `sh`
/// so the exact bytes the remote side runs are covered without an SSH server.

///|
async fn env_verify_script_exit(dir : String) -> Int {
  let result = @process.collect_output(
    "sh",
    ["-c", ssh_env_file_verify_script(), "monexus-env-verify", dir],
  ) catch {
    _ => return -1
  }
  let (code, _, _) = result
  code
}

///|
async test "ssh env-file verification enforces owner-only dir and file" {
  let root = @fs.tmpdir(prefix="env-ssh-verify")
  defer cleanup_root(root)
  let dir = root + "/envdir"
  @fs.mkdir(dir, permission=0o700) catch {
    _ => fail("cannot create the test directory")
  }
  @fs.chmod(dir, 0o700) catch { _ => () }
  let file = dir + "/env"
  @fs.write_file(file, "API_KEY=supersecret", permission=0o600) catch {
    _ => fail("cannot write the test env file")
  }
  assert_eq(env_verify_script_exit(dir), 0)
  assert_true(@fs.exists(file) catch { _ => false })
  // A world-readable secret is rejected and removed, never accepted.
  @fs.chmod(file, 0o644) catch { _ => () }
  assert_true(env_verify_script_exit(dir) != 0)
  assert_true(!(@fs.exists(file) catch { _ => true }))
  // A directory that is not owner-only is rejected even when the file is 0600.
  @fs.write_file(file, "API_KEY=supersecret", permission=0o600) catch {
    _ => fail("cannot rewrite the test env file")
  }
  @fs.chmod(dir, 0o755) catch { _ => () }
  assert_true(env_verify_script_exit(dir) != 0)
  assert_true(!(@fs.exists(file) catch { _ => true }))
}
