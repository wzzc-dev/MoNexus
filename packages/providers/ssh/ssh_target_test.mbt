///|
/// Unit tests for the SSH argv/quoting layer. These run without a network:
/// they pin the properties that keep a remote argv from becoming shell text.
test "shell_quote keeps metacharacters literal" {
  assert_eq(shell_quote("plain"), "'plain'")
  assert_eq(
    shell_quote("a b; echo INJECTED"),
    "'a b; echo INJECTED'",
  )
  assert_eq(shell_quote("$(echo SUBST)"), "'$(echo SUBST)'")
  assert_eq(shell_quote("it's"), "'it'\\''s'")
  assert_eq(shell_quote(""), "''")
}

///|
test "ssh_argv is non-interactive and ordered" {
  let target = SshTarget::new(
    host="example.com",
    port=2222,
    identity="/tmp/key",
    timeout_seconds=3,
    extra_options=["UserKnownHostsFile=/tmp/kh"],
  )
  assert_eq(
    ssh_argv(target, "true").join(" "),
    "ssh -o BatchMode=yes -o ConnectTimeout=3 -o UserKnownHostsFile=/tmp/kh -p 2222 -i /tmp/key example.com true",
  )
}

///|
test "remote_exec_command passes argv as positional parameters" {
  assert_eq(
    remote_exec_command("/tmp/x y", ["printf", "%s\\n", "a b"]),
    "sh -c 'cd -- \"$1\" && shift && exec \"$@\"' monexus-run '/tmp/x y' 'printf' '%s\\n' 'a b'",
  )
}
