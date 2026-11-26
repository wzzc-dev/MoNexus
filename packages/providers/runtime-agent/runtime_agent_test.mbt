///|
/// A1.5: primary -> node workspace path mapping for the runtime launcher.

///|
fn mapped_cwd(cwd : String, roots : Array[String]) -> String {
  match runtime_agent_cwd(cwd, roots) {
    Ok(value) => "ok:" + value
    Err(_) => "rejected"
  }
}

///|
test "runtime agent cwd: relative cwd passes through unchanged" {
  let roots = ["/home/owner/project"]
  assert_eq(mapped_cwd("", roots), "ok:")
  assert_eq(mapped_cwd("src/app", roots), "ok:src/app")
  assert_eq(mapped_cwd("./pkg", roots), "ok:./pkg")
  // Containment (including `..`) is enforced by the node against its own
  // workspace root; the adapter must not rewrite it into something else.
  assert_eq(mapped_cwd("../elsewhere", roots), "ok:../elsewhere")
}

///|
test "runtime agent cwd: absolute cwd maps under a workspace root" {
  let roots = ["/home/owner/project", "/srv/work/"]
  assert_eq(mapped_cwd("/home/owner/project", roots), "ok:")
  assert_eq(mapped_cwd("/home/owner/project/", roots), "ok:")
  assert_eq(mapped_cwd("/home/owner/project/pkg/a", roots), "ok:pkg/a")
  assert_eq(mapped_cwd("/home/owner/project/pkg/a/", roots), "ok:pkg/a")
  assert_eq(mapped_cwd("/srv/work/repo", roots), "ok:repo")
  assert_eq(mapped_cwd("  /home/owner/project/pkg  ", roots), "ok:pkg")
}

///|
test "runtime agent cwd: unmapped absolute cwd is rejected" {
  let roots = ["/home/owner/project"]
  assert_eq(mapped_cwd("/etc", roots), "rejected")
  // A path that only shares a textual prefix is not inside the root.
  assert_eq(mapped_cwd("/home/owner/project2", roots), "rejected")
  assert_eq(mapped_cwd("/home/owner/project-other/x", roots), "rejected")
  // Roots must themselves be absolute; junk roots never match.
  assert_eq(mapped_cwd("/ws/x", ["ws", "", "/ws/"]), "ok:x")
}

///|
test "runtime agent cwd: no mapped roots rejects absolute cwd" {
  assert_eq(mapped_cwd("/home/owner/project", []), "rejected")
}
