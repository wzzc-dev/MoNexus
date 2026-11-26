///|
/// A5.1 child-environment test: a local Agent gets the fixed base allowlist
/// plus explicit proxy coordinates, never the host's model keys, and the real
/// process environment (`/proc/<pid>/environ`) is equally clean.

///|
fn agent_env_test_unset() -> Unit {
  @env.unset_env_var("ANTHROPIC_API_KEY")
  @env.unset_env_var("MONEXUS_TEST_API_KEY")
}

///|
async fn agent_env_test_cleanup(root : String) -> Unit {
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "agent child receives scoped proxy env and no host secret" {
  let root = @fs.tmpdir(prefix="monexus-agent-env") catch {
    _ => fail("cannot create the agent env test root")
  }
  defer agent_env_test_cleanup(root)
  @env.set_env_var("ANTHROPIC_API_KEY", "sk-host-secret-value")
  @env.set_env_var("MONEXUS_TEST_API_KEY", "sk-host-other-secret")
  defer agent_env_test_unset()
  let env_path = root + "/env.txt"
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let spec_env : Map[String, String] = Map([])
    spec_env.set(@contracts.CREDENTIAL_ENV_PROXY_URL, "http://127.0.0.1:45678")
    spec_env.set(@contracts.CREDENTIAL_ENV_PROXY_TOKEN, "mxp_agent_env_token")
    let spec = AgentSpec::new(
      agent_id="env-agent",
      mode=@contracts.AGENT_MODE_STDOUT,
      command="/bin/sh",
      args=["-c", "env > " + env_path + "; sleep 30"],
      env=spec_env,
    )
    let process = match spawn_agent(group, spec, async fn(_line) { () }) {
      Ok(value) => value
      Err(message) => fail("cannot spawn the env agent: " + message)
    }
    let pid = process.pid()
    assert_true(pid > 0)
    let mut waited = 0
    while waited < 5_000 && !(@fs.exists(env_path) catch { _ => false }) {
      @async.sleep(50)
      waited = waited + 50
    }
    let env_data = @fs.read_file(env_path) catch {
      _ => fail("the agent did not write its environment")
    }
    let env_text = env_data.text() catch { _ => "" }
    assert_true(
      env_text.contains(
        @contracts.CREDENTIAL_ENV_PROXY_TOKEN + "=mxp_agent_env_token",
      ),
    )
    assert_true(env_text.contains("MONEXUS_CREDENTIAL_PROXY_URL="))
    assert_true(!env_text.contains("sk-host-secret-value"))
    assert_true(!env_text.contains("sk-host-other-secret"))
    // The OS-visible environment is the same map: no model key survives in
    // `/proc/<pid>/environ`.
    let proc_path = "/proc/" + pid.to_string() + "/environ"
    let proc_env = @fs.read_file(proc_path) catch {
      _ => fail("cannot read " + proc_path)
    }
    let proc_text = proc_env.text() catch { _ => "" }
    assert_true(!proc_text.contains("sk-host-secret-value"))
    assert_true(!proc_text.contains("sk-host-other-secret"))
    assert_true(proc_text.contains("mxp_agent_env_token"))
  })
}
