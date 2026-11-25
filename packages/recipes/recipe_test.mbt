///|
/// A complete, valid recipe used by the accept and canonical-vector tests.
/// Every declared field is present at least once here; the mutation helpers
/// below change one thing at a time so a rejection can only come from that
/// change.
fn fixture_json() -> String {
  let text =
    #|{
  #|  "schema_version": 1,
  #|  "name": "node-dev",
  #|  "version": "1.2.3",
  #|  "image": {
  #|    "ref": "ghcr.io/acme/node-dev:1.2.3",
  #|    "digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  #|  },
  #|  "workdir": "/workspace/project",
  #|  "user": "1000:1000",
  #|  "mounts": [
  #|    {"source": "workspace", "target": "/workspace", "mode": "rw"},
  #|    {"source": "scratch", "target": "/scratch", "mode": "ro"}
  #|  ],
  #|  "env_allowlist": ["HOME", "PATH"],
  #|  "limits": {"cpu_millis": 2000, "memory_mb": 4096, "pids": 1024},
  #|  "network": "bridge",
  #|  "lifecycle": {
  #|    "prepare": {"argv": ["/bin/sh", "-c", "echo prepare"], "timeout_s": 60},
  #|    "start": {"script": "echo start\n", "timeout_s": 30},
  #|    "stop": {"argv": ["/bin/true"], "timeout_s": 10}
  #|  },
  #|  "doctor": {"argv": ["/bin/sh", "-c", "uname -a"], "timeout_s": 30},
  #|  "source": {
  #|    "kind": "local_file",
  #|    "path": "/home/dev/recipes/node-dev.json",
  #|    "author": "dev@example.com",
  #|    "created_at": "2026-01-15T10:30:00Z"
  #|  },
  #|  "signature": {"key_id": "dev-key-1", "alg": "ed25519", "sig": "U1NIU0lHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}
    #|}
  text
}

///|
fn minimal_json() -> String {
  let text =
    #|{
  #|  "schema_version": 1,
  #|  "name": "tiny",
  #|  "version": "0.1.0",
  #|  "image": {
  #|    "ref": "docker.io/library/alpine",
  #|    "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"
  #|  },
  #|  "mounts": [
  #|    {"source": "workspace", "target": "/workspace", "mode": "rw"}
  #|  ],
  #|  "lifecycle": {
  #|    "prepare": {"argv": ["/bin/true"], "timeout_s": 5},
  #|    "start": {"argv": ["/bin/sleep", "infinity"], "timeout_s": 5},
  #|    "stop": {"argv": ["/bin/true"], "timeout_s": 5}
  #|  },
  #|  "source": {
  #|    "kind": "local_file",
  #|    "path": "/srv/recipes/tiny.json",
  #|    "author": "ops",
  #|    "created_at": "2026-02-01T00:00:00Z"
  #|  },
  #|  "signature": {"key_id": "ops-key", "alg": "ed25519", "sig": "U1NIU0lHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}
    #|}
  text
}

///|
fn mutate(json : String, old : String, new : String) -> String {
  json.replace(old~, new~)
}

///|
fn expect_reject(json : String, reason : String) -> Unit raise {
  match @recipes.parse_recipe(json) {
    Ok(_) => fail("expected " + reason + " but recipe was accepted")
    Err(error) =>
      if error.reason() != reason {
        fail("expected " + reason + " but got " + error.to_string())
      }
  }
}

///|
fn expect_accept(json : String) -> @recipes.Recipe raise {
  match @recipes.parse_recipe(json) {
    Ok(value) => value
    Err(error) => fail("expected acceptance but got " + error.to_string())
  }
}

///|
test "full recipe parses with every field" {
  let recipe = expect_accept(fixture_json())
  inspect(recipe.identity(), content="node-dev@1.2.3")
  inspect(recipe.image.reference, content="ghcr.io/acme/node-dev:1.2.3")
  inspect(
    recipe.image.digest,
    content="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  )
  inspect(recipe.effective_workdir(), content="/workspace/project")
  match recipe.user {
    Some(value) => inspect(value, content="1000:1000")
    None => fail("user should be declared")
  }
  inspect(recipe.mounts.length(), content="2")
  inspect(recipe.effective_network().label(), content="bridge")
  inspect(recipe.effective_limits().cpu_millis, content="2000")
  inspect(recipe.effective_limits().memory_mb, content="4096")
  inspect(recipe.effective_limits().pids, content="1024")
  match recipe.env_allowlist {
    Some(names) => {
      inspect(names.length(), content="2")
      inspect(names[0], content="HOME")
      inspect(names[1], content="PATH")
    }
    None => fail("env_allowlist should be declared")
  }
  let flags = recipe.risk_flags()
  inspect(flags.root_user, content="false")
  inspect(flags.bridge_network, content="true")
  inspect(flags.script_lifecycle, content="true")
  inspect(flags.workspace_read_only, content="false")
  let workspace = match recipe.workspace_mount() {
    Some(mount) => mount
    None => fail("workspace mount missing")
  }
  inspect(workspace.target, content="/workspace")
  inspect(workspace.mode.label(), content="rw")
  let scratch = match recipe.scratch_mount() {
    Some(mount) => mount
    None => fail("scratch mount missing")
  }
  inspect(scratch.mode.label(), content="ro")
}

///|
test "absent optional fields take documented defaults" {
  let recipe = expect_accept(minimal_json())
  inspect(recipe.effective_workdir(), content="/workspace")
  inspect(recipe.effective_network().label(), content="none")
  let limits = recipe.effective_limits()
  inspect(limits.cpu_millis, content="1000")
  inspect(limits.memory_mb, content="2048")
  inspect(limits.pids, content="512")
  match recipe.user {
    None => ()
    Some(_) => fail("user should be absent")
  }
  match recipe.env_allowlist {
    None => ()
    Some(_) => fail("env_allowlist should be absent")
  }
  match recipe.doctor {
    None => ()
    Some(_) => fail("doctor should be absent")
  }
  match recipe.limits.cpu_millis {
    None => ()
    Some(_) => fail("limits should be absent")
  }
}

///|
test "canonical hash matches the pinned cross-checked vector" {
  let expected =
    #|{"doctor":{"argv":["/bin/sh","-c","uname -a"],"timeout_s":30},"env_allowlist":["HOME","PATH"],"image":{"digest":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","ref":"ghcr.io/acme/node-dev:1.2.3"},"lifecycle":{"prepare":{"argv":["/bin/sh","-c","echo prepare"],"timeout_s":60},"start":{"script":"echo start\n","timeout_s":30},"stop":{"argv":["/bin/true"],"timeout_s":10}},"limits":{"cpu_millis":2000,"memory_mb":4096,"pids":1024},"mounts":[{"mode":"rw","source":"workspace","target":"/workspace"},{"mode":"ro","source":"scratch","target":"/scratch"}],"name":"node-dev","network":"bridge","schema_version":1,"source":{"author":"dev@example.com","created_at":"2026-01-15T10:30:00Z","kind":"local_file","path":"/home/dev/recipes/node-dev.json"},"user":"1000:1000","version":"1.2.3","workdir":"/workspace/project"}
  match @recipes.parse_recipe(fixture_json()) {
    Ok(value) => {
      inspect(@recipes.canonical_string(value), content=expected)
      inspect(
        @recipes.content_hash(value),
        content="sha256:ae7f71a3315bb514297232a72dee884a9ac94995d97c43ec60ee9c106f99214d",
      )
      inspect(
        @recipes.check_content_hash(
          expected,
          "sha256:ae7f71a3315bb514297232a72dee884a9ac94995d97c43ec60ee9c106f99214d",
        ),
        content="true",
      )
    }
    Err(error) => fail("fixture rejected: " + error.to_string())
  }
}

///|
test "signature is excluded from the canonical content" {
  let first = expect_accept(fixture_json())
  let second = expect_accept(
    mutate(fixture_json(), "\"key_id\": \"dev-key-1\"", "\"key_id\": \"dev-key-2\""),
  )
  if @recipes.canonical_string(first) != @recipes.canonical_string(second) {
    fail("signature leaked into the canonical bytes")
  }
}

///|
test "identity parsing is strict" {
  match @recipes.parse_identity("node-dev@1.2.3") {
    Ok(value) => {
      inspect(value.0, content="node-dev")
      inspect(value.1, content="1.2.3")
    }
    Err(error) => fail("valid identity rejected: " + error.to_string())
  }
  for candidate in [
    "node-dev", "node-dev@", "@1.2.3", "node-dev@1.2.3@x", "Node@1.0.0",
    "-bad@1.0.0", "node-dev@01.0.0",
  ] {
    match @recipes.parse_identity(candidate) {
      Ok(_) => fail("identity should be rejected: " + candidate)
      Err(error) =>
        if error.reason() != "identity_invalid" {
          fail("unexpected reason for " + candidate + ": " + error.to_string())
        }
    }
  }
}

///|
test "unknown and unsupported fields are rejected, never ignored" {
  expect_reject(
    mutate(fixture_json(), "\"schema_version\": 1,", "\"schema_version\": 1, \"extra\": true,"),
    "unknown_field",
  )
  expect_reject(
    mutate(fixture_json(), "\"schema_version\": 1,", "\"schema_version\": 1, \"privileged\": true,"),
    "unsupported_field",
  )
  expect_reject(
    mutate(fixture_json(), "\"schema_version\": 1,", "\"schema_version\": 1, \"ports\": [8080],"),
    "unsupported_field",
  )
  expect_reject(
    mutate(
      fixture_json(),
      "\"limits\": {\"cpu_millis\": 2000, \"memory_mb\": 4096, \"pids\": 1024}",
      "\"limits\": {\"cpu_millis\": 2000, \"memory_mb\": 4096, \"pids\": 1024, \"disk\": 10}",
    ),
    "unsupported_field",
  )
  expect_reject(
    mutate(
      fixture_json(),
      "\"limits\": {\"cpu_millis\": 2000, \"memory_mb\": 4096, \"pids\": 1024}",
      "\"limits\": {\"cpu_millis\": 2000, \"memory_mb\": 4096, \"pids\": 1024, \"cap_add\": [\"SYS_ADMIN\"]}",
    ),
    "unsupported_field",
  )
}

///|
test "required fields and types are enforced" {
  expect_reject(
    mutate(fixture_json(), "\"name\": \"node-dev\",\n", ""),
    "missing_field",
  )
  expect_reject(
    mutate(fixture_json(), "\"schema_version\": 1,", "\"schema_version\": \"1\","),
    "invalid_type",
  )
  expect_reject(
    mutate(fixture_json(), "\"schema_version\": 1,", ""),
    "missing_field",
  )
  expect_reject(
    mutate(fixture_json(), "\"schema_version\": 1,", "\"schema_version\": 2,"),
    "schema_version_unsupported",
  )
  expect_reject(
    mutate(fixture_json(), "\"env_allowlist\": [\"HOME\", \"PATH\"],", "\"env_allowlist\": \"HOME\","),
    "invalid_type",
  )
  let duplicate = mutate(
    fixture_json(),
    "\"name\": \"node-dev\",",
    "\"name\": \"node-dev\", \"name\": \"node-dev\",",
  )
  expect_reject(duplicate, "invalid_json")
}

///|
test "name and version grammar is strict" {
  for bad_name in ["Node-Dev", "node_dev", "-node", "node dev"] {
    expect_reject(
      mutate(fixture_json(), "node-dev\"", bad_name + "\""),
      "name_invalid",
    )
  }
  for bad_version in ["1.2", "v1.2.3", "01.2.3", "1.2.3-", "1.2.3+"] {
    expect_reject(
      mutate(fixture_json(), "\"version\": \"1.2.3\"", "\"version\": \"" + bad_version + "\""),
      "version_invalid",
    )
  }
  // Prerelease and build metadata are valid SemVer.
  ignore(
    expect_accept(
      mutate(
        fixture_json(),
        "\"version\": \"1.2.3\"",
        "\"version\": \"1.2.3-rc.1+build.5\"",
      ),
    ),
  )
}

///|
test "image reference and digest are pinned" {
  for bad_ref in [
    "ghcr.io/Acme/node-dev:1.2.3",
    "ghcr.io/acme/node-dev@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "node dev",
    "ghcr.io/acme/node-dev:",
  ] {
    expect_reject(
      mutate(
        fixture_json(),
        "ghcr.io/acme/node-dev:1.2.3",
        bad_ref,
      ),
      "image_ref_invalid",
    )
  }
  for bad_digest in [
    "sha256:0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef",
    "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde",
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "sha512:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  ] {
    expect_reject(
      mutate(
        fixture_json(),
        "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        bad_digest,
      ),
      "image_digest_invalid",
    )
  }
}

///|
test "mounts are restricted to workspace and scratch with safe targets" {
  expect_reject(
    mutate(fixture_json(), "\"source\": \"workspace\"", "\"source\": \"/home/dev\""),
    "mount_source_invalid",
  )
  expect_reject(
    mutate(fixture_json(), "\"target\": \"/scratch\"", "\"target\": \"scratch\""),
    "mount_target_invalid",
  )
  expect_reject(
    mutate(fixture_json(), "\"target\": \"/scratch\"", "\"target\": \"/scratch/../etc\""),
    "mount_target_invalid",
  )
  expect_reject(
    mutate(fixture_json(), "\"target\": \"/scratch\"", "\"target\": \"/scratch/\""),
    "mount_target_invalid",
  )
  expect_reject(
    mutate(fixture_json(), "\"target\": \"/scratch\"", "\"target\": \"/workspace\""),
    "mount_duplicate",
  )
  expect_reject(
    mutate(fixture_json(), "\"source\": \"workspace\"", "\"source\": \"scratch\""),
    "mount_missing_workspace",
  )
  expect_reject(
    mutate(fixture_json(), "\"mode\": \"ro\"", "\"mode\": \"x\""),
    "invalid_value",
  )
  expect_reject(
    mutate(
      fixture_json(),
      "{\"source\": \"scratch\", \"target\": \"/scratch\", \"mode\": \"ro\"}",
      "{\"source\": \"scratch\", \"target\": \"/scratch\", \"mode\": \"ro\", \"host\": \"/tmp\"}",
    ),
    "unknown_field",
  )
}

///|
test "workdir and user are validated against mounts" {
  expect_reject(
    mutate(fixture_json(), "\"/workspace/project\"", "\"/opt/project\""),
    "workdir_outside_mount",
  )
  expect_reject(
    mutate(fixture_json(), "\"/workspace/project\"", "\"workspace/project\""),
    "workdir_invalid",
  )
  expect_reject(
    mutate(fixture_json(), "\"/workspace/project\"", "\"/workspace/../etc\""),
    "workdir_invalid",
  )
  for bad_user in ["1000;1000", "-1000", "1000:", ":1000", "a b"] {
    expect_reject(
      mutate(fixture_json(), "\"user\": \"1000:1000\"", "\"user\": \"" + bad_user + "\""),
      "user_invalid",
    )
  }
  ignore(
    expect_accept(
      mutate(fixture_json(), "\"user\": \"1000:1000\"", "\"user\": \"node\""),
    ),
  )
}

///|
test "environment allowlist names are grammar-checked and unique" {
  expect_reject(
    mutate(fixture_json(), "\"HOME\"", "\"HOME=x\""),
    "env_name_invalid",
  )
  expect_reject(
    mutate(fixture_json(), "\"HOME\"", "\"1HOME\""),
    "env_name_invalid",
  )
  expect_reject(
    mutate(fixture_json(), "[\"HOME\", \"PATH\"]", "[\"HOME\", \"HOME\"]"),
    "env_name_duplicate",
  )
  expect_reject(
    mutate(fixture_json(), "\"PATH\"", "\"PA-TH\""),
    "env_name_invalid",
  )
}

///|
test "limits default and hard caps are enforced" {
  expect_reject(
    mutate(fixture_json(), "\"cpu_millis\": 2000", "\"cpu_millis\": 99"),
    "limit_out_of_range",
  )
  expect_reject(
    mutate(fixture_json(), "\"cpu_millis\": 2000", "\"cpu_millis\": 16001"),
    "limit_out_of_range",
  )
  expect_reject(
    mutate(fixture_json(), "\"memory_mb\": 4096", "\"memory_mb\": 127"),
    "limit_out_of_range",
  )
  expect_reject(
    mutate(fixture_json(), "\"memory_mb\": 4096", "\"memory_mb\": 32769"),
    "limit_out_of_range",
  )
  expect_reject(
    mutate(fixture_json(), "\"pids\": 1024", "\"pids\": 15"),
    "limit_out_of_range",
  )
  expect_reject(
    mutate(fixture_json(), "\"pids\": 1024", "\"pids\": 8193"),
    "limit_out_of_range",
  )
  expect_reject(
    mutate(fixture_json(), "\"cpu_millis\": 2000", "\"cpu_millis\": 2000.5"),
    "invalid_type",
  )
}

///|
test "network is none or bridge only" {
  for bad_network in ["host", "container", "overlay", "none,host"] {
    expect_reject(
      mutate(fixture_json(), "\"network\": \"bridge\"", "\"network\": \"" + bad_network + "\""),
      "network_unsupported",
    )
  }
  // An absent network is valid and means `none`; only bad values are refused.
  ignore(expect_accept(mutate(fixture_json(), "\"network\": \"bridge\",", "")))
}

///|
test "lifecycle hooks are argv xor script with bounded timeouts" {
  expect_reject(
    mutate(
      fixture_json(),
      "\"prepare\": {\"argv\": [\"/bin/sh\", \"-c\", \"echo prepare\"], \"timeout_s\": 60}",
      "\"prepare\": {\"argv\": [\"/bin/sh\"], \"script\": \"echo prepare\", \"timeout_s\": 60}",
    ),
    "hook_conflict",
  )
  expect_reject(
    mutate(
      fixture_json(),
      "\"prepare\": {\"argv\": [\"/bin/sh\", \"-c\", \"echo prepare\"], \"timeout_s\": 60}",
      "\"prepare\": {\"timeout_s\": 60}",
    ),
    "missing_field",
  )
  expect_reject(
    mutate(fixture_json(), "\"timeout_s\": 60", "\"timeout_s\": 0"),
    "hook_timeout_range",
  )
  expect_reject(
    mutate(fixture_json(), "\"timeout_s\": 60", "\"timeout_s\": 3601"),
    "hook_timeout_range",
  )
  expect_reject(
    mutate(
      fixture_json(),
      "\"argv\": [\"/bin/true\"]",
      "\"argv\": [\"/bin/true\\u0001\"]",
    ),
    "argv_invalid",
  )
  expect_reject(
    mutate(
      fixture_json(),
      "\"argv\": [\"/bin/sh\", \"-c\", \"echo prepare\"]",
      "\"argv\": []",
    ),
    "argv_invalid",
  )
  let too_many = StringBuilder()
  too_many.write_string("\"argv\": [")
  for index in 0..<65 {
    if index > 0 {
      too_many.write_string(",")
    }
    too_many.write_string("\"a\"")
  }
  too_many.write_string("]")
  expect_reject(
    mutate(
      fixture_json(),
      "\"argv\": [\"/bin/sh\", \"-c\", \"echo prepare\"]",
      too_many.to_string(),
    ),
    "argv_invalid",
  )
  expect_reject(
    mutate(fixture_json(), "\"script\": \"echo start\\n\"", "\"script\": \"\""),
    "script_invalid",
  )
  expect_reject(
    mutate(fixture_json(), "\"script\": \"echo start\\n\"", "\"script\": \"echo\\u0000start\""),
    "script_invalid",
  )
  expect_reject(
    mutate(
      fixture_json(),
      "\"start\": {\"script\": \"echo start\\n\", \"timeout_s\": 30}",
      "\"start\": {\"argv\": [\"true\"], \"script\": \"echo\", \"timeout_s\": 30}",
    ),
    "hook_conflict",
  )
}

///|
test "doctor and source are strict" {
  expect_reject(
    mutate(
      fixture_json(),
      "\"doctor\": {\"argv\": [\"/bin/sh\", \"-c\", \"uname -a\"], \"timeout_s\": 30}",
      "\"doctor\": {\"argv\": [\"/bin/sh\"], \"timeout_s\": 301}",
    ),
    "doctor_invalid",
  )
  expect_reject(
    mutate(
      fixture_json(),
      "\"doctor\": {\"argv\": [\"/bin/sh\", \"-c\", \"uname -a\"], \"timeout_s\": 30}",
      "\"doctor\": {\"argv\": [], \"timeout_s\": 30}",
    ),
    "argv_invalid",
  )
  expect_reject(
    mutate(fixture_json(), "\"kind\": \"local_file\"", "\"kind\": \"remote\""),
    "source_invalid",
  )
  expect_reject(
    mutate(fixture_json(), "\"path\": \"/home/dev/recipes/node-dev.json\"", "\"path\": \"relative/path\""),
    "source_invalid",
  )
  expect_reject(
    mutate(fixture_json(), "\"created_at\": \"2026-01-15T10:30:00Z\"", "\"created_at\": \"2026-01-15\""),
    "timestamp_invalid",
  )
  expect_reject(
    mutate(fixture_json(), "\"created_at\": \"2026-01-15T10:30:00Z\"", "\"created_at\": \"2026-13-15T10:30:00Z\""),
    "timestamp_invalid",
  )
}

///|
test "signature fields are strict" {
  expect_reject(
    mutate(fixture_json(), "\"alg\": \"ed25519\"", "\"alg\": \"rsa\""),
    "signature_alg_unsupported",
  )
  expect_reject(
    mutate(fixture_json(), "\"key_id\": \"dev-key-1\"", "\"key_id\": \"dev key!\""),
    "key_id_invalid",
  )
  expect_reject(
    mutate(
      fixture_json(),
      "U1NIU0lHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      "not-base64!",
    ),
    "signature_invalid",
  )
  expect_reject(
    mutate(
      fixture_json(),
      "U1NIU0lHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    ),
    "signature_invalid",
  )
  expect_reject(
    mutate(
      fixture_json(),
      "U1NIU0lHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      "U1NIU0lH AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    ),
    "signature_invalid",
  )
  expect_reject(
    mutate(
      fixture_json(),
      "\"signature\": {\"key_id\": \"dev-key-1\", \"alg\": \"ed25519\", \"sig\": \"U1NIU0lHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"}",
      "\"signature\": {\"key_id\": \"dev-key-1\", \"alg\": \"ed25519\", \"sig\": \"U1NIU0lHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\", \"x\": 1}",
    ),
    "unknown_field",
  )
}

///|
test "documents are bounded and must be one JSON object" {
  let empty = ""
  expect_reject(empty, "invalid_json")
  expect_reject("[]", "invalid_type")
  expect_reject("null", "invalid_type")
  let huge = StringBuilder()
  for _ in 0..<262_145 {
    huge.write_char('a')
  }
  expect_reject(huge.to_string(), "invalid_json")
}
