///|
/// `docker inspect` parsing tests. Secret environment values are planted in
/// the fixture and must never survive parsing, summaries or diagnostics.

///|
fn docker_inspect_json(name : String, home_value : String) -> String {
  let text =
    #|[
    #|  {
    #|    "Name": "/@NAME@",
    #|    "State": {"Status": "running", "Running": true},
    #|    "Config": {
    #|      "Image": "ghcr.io/acme/node-dev:1.0.0@sha256:3333333333333333333333333333333333333333333333333333333333333333",
    #|      "User": "1000:1000",
    #|      "Env": ["HOME=@HOME@", "PATH=/usr/bin:/s3cr3t-path", "WITH_EQUALS=a=b"],
    #|      "Labels": {
    #|        "monexus.managed": "true",
    #|        "monexus.primary_id": "owner01",
    #|        "monexus.environment_id": "env01",
    #|        "monexus.workspace_id": "ws01",
    #|        "monexus.recipe_hash": "sha256:4444444444444444444444444444444444444444444444444444444444444444"
    #|      }
    #|    },
    #|    "HostConfig": {
    #|      "NetworkMode": "bridge",
    #|      "Init": true,
    #|      "RestartPolicy": {"Name": "no"},
    #|      "Memory": 3221225472,
    #|      "NanoCpus": 1500000000,
    #|      "PidsLimit": 256
    #|    },
    #|    "Mounts": [
    #|      {"Type": "bind", "Source": "/home/dev/work", "Destination": "/workspace", "RW": true},
    #|      {"Type": "bind", "Source": "/home/dev/scratch", "Destination": "/scratch", "RW": false}
    #|    ]
    #|  }
    #|]
  text.replace(old="@NAME@", new=name).replace(old="@HOME@", new=home_value)
}

///|
test "inspect parses facts and keeps environment names only" {
  let secret = "s3cr3t-home-value"
  let json = docker_inspect_json("monexus-env-env01", secret)
  let parsed = match @docker.parse_inspect(json, "monexus-env-env01") {
    Ok(value) => value
    Err(error) => fail("valid inspect rejected: " + error.to_string())
  }
  inspect(parsed.name, content="monexus-env-env01")
  inspect(parsed.status, content="running")
  inspect(parsed.running, content="true")
  inspect(parsed.user, content="1000:1000")
  inspect(parsed.network_mode, content="bridge")
  inspect(parsed.init, content="true")
  inspect(parsed.restart_policy, content="no")
  match parsed.memory_bytes {
    Some(value) => inspect(value, content="3221225472")
    None => fail("memory limit missing")
  }
  match parsed.nano_cpus {
    Some(value) => inspect(value, content="1500000000")
    None => fail("nano cpus missing")
  }
  match parsed.pids_limit {
    Some(value) => inspect(value, content="256")
    None => fail("pids limit missing")
  }
  inspect(parsed.env_names.length(), content="3")
  inspect(parsed.env_names[0], content="HOME")
  inspect(parsed.env_names[1], content="PATH")
  inspect(parsed.env_names[2], content="WITH_EQUALS")
  inspect(parsed.mounts.length(), content="2")
  inspect(parsed.mounts[0].kind, content="bind")
  inspect(parsed.mounts[0].source, content="/home/dev/work")
  inspect(parsed.mounts[0].destination, content="/workspace")
  inspect(parsed.mounts[0].read_only, content="false")
  inspect(parsed.mounts[1].read_only, content="true")
  inspect(parsed.labels.length(), content="5")
  inspect(parsed.labels[0].0, content="monexus.environment_id")
  match @docker.label_value(parsed, "monexus.managed") {
    Some(value) => inspect(value, content="true")
    None => fail("managed label missing")
  }
  inspect(
    @docker.inspect_matches_identity(parsed, docker_identity()),
    content="true",
  )
  let summary = @docker.inspect_summary(parsed)
  inspect(
    summary,
    content="name=monexus-env-env01 status=running running=true network=bridge env_names=[HOME,PATH,WITH_EQUALS] mounts=2",
  )
  if summary.contains(secret) || summary.contains("s3cr3t-path") {
    fail("summary leaked an environment value")
  }
}

///|
test "inspect refuses another container and malformed documents" {
  let foreign = docker_inspect_json("some-other-container", "/root")
  match @docker.parse_inspect(foreign, "monexus-env-env01") {
    Ok(_) => fail("a foreign container must be refused")
    Err(error) =>
      if error.reason() != "inspect_mismatch" {
        fail("expected inspect_mismatch, got " + error.to_string())
      }
  }
  let cases : Array[String] = [
    "",
    "{}",
    "[]",
    "[{\"Name\":\"/monexus-env-env01\"},{\"Name\":\"/monexus-env-env01\"}]",
    "[{\"Name\":\"/monexus-env-env01\",\"State\":{\"Status\":\"running\"}}]",
    "[{\"Name\":\"/monexus-env-env01\",\"State\":{\"Status\":\"running\",\"Running\":true},\"Config\":{\"Env\":[\"BAD-NAME=x\"]}}]",
    "[{\"Name\":\"/monexus-env-env01\",\"State\":{\"Status\":\"running\",\"Running\":true},\"HostConfig\":{\"Memory\":-1}}]",
  ]
  for json in cases {
    match @docker.parse_inspect(json, "monexus-env-env01") {
      Ok(_) => fail("inspect should be rejected: " + json)
      Err(error) =>
        if error.reason() != "inspect_invalid" {
          fail("expected inspect_invalid but got " + error.to_string())
        }
    }
  }
}

///|
test "a mount without RW is treated as read-only" {
  let json =
    "[{\"Name\":\"/monexus-env-env01\",\"State\":{\"Status\":\"running\",\"Running\":true},\"Config\":{},\"Mounts\":[{\"Type\":\"bind\",\"Source\":\"/home/dev/work\",\"Destination\":\"/workspace\"}]}]"
  let parsed = match @docker.parse_inspect(json, "monexus-env-env01") {
    Ok(value) => value
    Err(error) => fail("minimal inspect rejected: " + error.to_string())
  }
  inspect(parsed.mounts.length(), content="1")
  inspect(parsed.mounts[0].read_only, content="true")
}

///|
test "managed labels must match the identity exactly" {
  let json = docker_inspect_json("monexus-env-env01", "/root")
  let parsed = match @docker.parse_inspect(json, "monexus-env-env01") {
    Ok(value) => value
    Err(error) => fail("valid inspect rejected: " + error.to_string())
  }
  let other = match @docker.EnvironmentIdentity::new(
    environment_id="env02",
    primary_id="owner01",
    workspace_id="ws01",
    recipe_hash=FULL_RECIPE_HASH,
  ) {
    Ok(value) => value
    Err(error) => fail("identity fixture rejected: " + error.to_string())
  }
  inspect(
    @docker.inspect_matches_identity(parsed, other),
    content="false",
  )
}
