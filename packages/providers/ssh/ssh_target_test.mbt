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
    "ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/kh -p 2222 -i /tmp/key example.com true",
  )
}

///|
test "remote_exec_command passes argv as positional parameters" {
  assert_eq(
    remote_exec_command("/tmp/x y", ["printf", "%s\\n", "a b"]),
    "sh -c 'cd -- \"$1\" && shift && exec \"$@\"' monexus-run '/tmp/x y' 'printf' '%s\\n' 'a b'",
  )
}

///|
test "disabling ssh config pins the client to -F /dev/null" {
  let target = SshTarget::new(
    host="example.com",
    port=2222,
    user="tester",
    identity="/tmp/key",
    use_ssh_config=false,
    host_key_policy="yes",
    known_hosts_file="/tmp/kh",
    timeout_seconds=3,
  )
  assert_eq(
    ssh_argv(target, "true").join(" "),
    "ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/tmp/kh -p 2222 -i /tmp/key tester@example.com true",
  )
}

///|
test "host key policy variants map to StrictHostKeyChecking" {
  let insecure = SshTarget::new(
    host="h",
    use_ssh_config=false,
    host_key_policy="no",
    timeout_seconds=1,
  )
  assert_eq(
    ssh_argv(insecure, "true").join(" "),
    "ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=1 -o StrictHostKeyChecking=no -p 22 h true",
  )
  // "config" means ~/.ssh/config decides: no StrictHostKeyChecking is added.
  let from_config = SshTarget::new(
    host="h",
    use_ssh_config=false,
    host_key_policy="config",
    timeout_seconds=1,
  )
  let argv = ssh_argv(from_config, "true").join(" ")
  assert_eq(
    argv,
    "ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=1 -p 22 h true",
  )
  assert_false(argv.contains("StrictHostKeyChecking"))
}

///|
test "ssh -G argv resolves without a remote command" {
  let target = SshTarget::new(
    host="example.com",
    user="tester",
    use_ssh_config=true,
    host_key_policy="accept-new",
    timeout_seconds=3,
  )
  let argv = ssh_g_argv(target)
  assert_eq(argv[argv.length() - 2], "-G")
  assert_eq(argv[argv.length() - 1], "tester@example.com")
  // No remote command is appended: -G is pure local resolution.
  assert_eq(argv.length(), 11)
}

///|
test "destination only adds user@ when a user is explicit" {
  assert_eq(SshTarget::new(host="h").destination(), "h")
  assert_eq(SshTarget::new(host="h", user="u").destination(), "u@h")
}

///|
test "parse_ssh_g keeps selected keys, first occurrence wins" {
  let effective = parse_ssh_g(
    "hostname example.com\r\nuser bob\nport 2200\nidentityfile /k1\nidentityfile /k2\nproxyjump jump\nunknownthing value\n",
  )
  assert_eq(effective.get("hostname"), Some("example.com"))
  assert_eq(effective.get("user"), Some("bob"))
  assert_eq(effective.get("port"), Some("2200"))
  assert_eq(effective.get("identityfile"), Some("/k1"))
  assert_eq(effective.get("proxyjump"), Some("jump"))
  assert_eq(effective.get("unknownthing"), None)
}

///|
test "parse_ssh_g lowercases keys and drops empty lines" {
  let effective = parse_ssh_g("\nHostName box\nPort 22\n")
  assert_eq(effective.get("hostname"), Some("box"))
  assert_eq(effective.get("port"), Some("22"))
}

///|
test "parse_probe fills the M2 profile fields" {
  let profile = parse_probe(
    "OS=Linux\nARCH=x86_64\nKERNEL=6.8\nHOSTNAME=box\nSHELL=/bin/bash\nCPUS=100\nDOCKER=/usr/bin/docker\nGUI=yes\nTOOL=git=/usr/bin/git\nTOOL=moon=\n",
  )
  assert_eq(profile.os, "Linux")
  assert_eq(profile.arch, "x86_64")
  assert_eq(profile.kernel, "6.8")
  assert_eq(profile.hostname, "box")
  assert_eq(profile.shell, "/bin/bash")
  // CPUS is clamped so a big machine cannot inflate the scheduler budget.
  assert_eq(profile.max_parallel, 64)
  assert_true(profile.has_docker)
  assert_true(profile.has_gui)
  assert_eq(profile.tools.get("docker"), Some("/usr/bin/docker"))
  assert_eq(profile.tools.get("git"), Some("/usr/bin/git"))
  assert_eq(profile.tools.get("moon"), Some(""))
  assert_true(profile.notes.contains("has_docker"))
}

///|
test "parse_probe falls back when CPUS is missing or invalid" {
  let low = parse_probe("OS=Linux\nCPUS=0\n")
  assert_eq(low.max_parallel, 4)
  assert_false(low.has_docker)
  assert_false(low.has_gui)
  let junk = parse_probe("OS=Linux\nCPUS=many\n")
  assert_eq(junk.max_parallel, 4)
}

///|
test "classify_ssh_failure maps stderr to readable categories" {
  let host_key = classify_ssh_failure(255, "Host key verification failed.")
  assert_eq(host_key.kind.label(), "host_key")
  assert_eq(host_key.message, "SSH host key was rejected")
  assert_eq(host_key.exit_code, Some(255))

  let auth = classify_ssh_failure(255, "u@h: Permission denied (publickey).")
  assert_eq(auth.kind.label(), "auth_failed")
  assert_eq(auth.message, "SSH authentication failed")

  let not_found = classify_ssh_failure(
    255,
    "ssh: Could not resolve hostname nope: Name or service not known",
  )
  assert_eq(not_found.kind.label(), "not_found")
  assert_eq(not_found.message, "SSH host could not be resolved")

  let timeout = classify_ssh_failure(
    255,
    "ssh: connect to host h port 22: Connection timed out",
  )
  assert_eq(timeout.kind.label(), "connect_timeout")
  assert_eq(timeout.message, "SSH connection timed out")

  let transport = classify_ssh_failure(
    255,
    "ssh: connect to host h port 22: Connection refused",
  )
  assert_eq(transport.kind.label(), "transport")
  assert_eq(transport.message, "SSH connection failed")

  let unknown = classify_ssh_failure(255, "something unexpected")
  assert_eq(unknown.kind.label(), "auth_failed")
  assert_eq(unknown.message, "SSH connection or authentication failed")
  match unknown.detail {
    Some(text) => assert_true(text.contains("unexpected"))
    None => fail("expected stderr detail")
  }
}
