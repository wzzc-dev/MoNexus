///|
/// Shared fixtures for the Docker provider tests. Recipes are parsed through
/// the real recipe parser so the argv builders are always exercised with
/// validated input, exactly as A2.2 will use them.

///|
const PLACEHOLDER_RECIPE_SIG : String =
  "U1NIU0lHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

///|
const FULL_RECIPE_HASH : String =
  "sha256:4444444444444444444444444444444444444444444444444444444444444444"

///|
fn docker_full_recipe_json() -> String {
  let text =
    #|{
    #|  "schema_version": 1,
    #|  "name": "node-dev",
    #|  "version": "1.0.0",
    #|  "image": {
    #|    "ref": "ghcr.io/acme/node-dev:1.0.0",
    #|    "digest": "sha256:3333333333333333333333333333333333333333333333333333333333333333"
    #|  },
    #|  "workdir": "/workspace/app",
    #|  "user": "1000:1000",
    #|  "mounts": [
    #|    {"source": "workspace", "target": "/workspace", "mode": "rw"},
    #|    {"source": "scratch", "target": "/scratch", "mode": "ro"}
    #|  ],
    #|  "env_allowlist": ["HOME", "PATH"],
    #|  "limits": {"cpu_millis": 1500, "memory_mb": 3072, "pids": 256},
    #|  "network": "bridge",
    #|  "lifecycle": {
    #|    "prepare": {"argv": ["/bin/true"], "timeout_s": 5},
    #|    "start": {"argv": ["/bin/sleep", "infinity"], "timeout_s": 5},
    #|    "stop": {"argv": ["/bin/true"], "timeout_s": 5}
    #|  },
    #|  "source": {
    #|    "kind": "local_file",
    #|    "path": "/srv/recipes/node-dev.json",
    #|    "author": "ops",
    #|    "created_at": "2026-02-01T00:00:00Z"
    #|  },
    #|  "signature": {"key_id": "dev-key-1", "alg": "ed25519", "sig": "@SIG@"}
    #|}
  text.replace(old="@SIG@", new=PLACEHOLDER_RECIPE_SIG)
}

///|
fn docker_minimal_recipe_json() -> String {
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
    #|  "signature": {"key_id": "dev-key-1", "alg": "ed25519", "sig": "@SIG@"}
    #|}
  text.replace(old="@SIG@", new=PLACEHOLDER_RECIPE_SIG)
}

///|
fn docker_full_recipe() -> @recipes.Recipe raise {
  match @recipes.parse_recipe(docker_full_recipe_json()) {
    Ok(value) => value
    Err(error) => fail("full recipe fixture rejected: " + error.to_string())
  }
}

///|
fn docker_minimal_recipe() -> @recipes.Recipe raise {
  match @recipes.parse_recipe(docker_minimal_recipe_json()) {
    Ok(value) => value
    Err(error) => fail("minimal recipe fixture rejected: " + error.to_string())
  }
}

///|
fn docker_identity() -> @docker.EnvironmentIdentity raise {
  match @docker.EnvironmentIdentity::new(
    environment_id="env01",
    primary_id="owner01",
    workspace_id="ws01",
    recipe_hash=FULL_RECIPE_HASH,
  ) {
    Ok(value) => value
    Err(error) => fail("identity fixture rejected: " + error.to_string())
  }
}

///|
fn docker_roots() -> @docker.ResolvedRoots raise {
  match @docker.ResolvedRoots::new(
    workspace_root="/home/dev/work",
    scratch_root="/home/dev/scratch",
  ) {
    Ok(value) => value
    Err(error) => fail("roots fixture rejected: " + error.to_string())
  }
}
