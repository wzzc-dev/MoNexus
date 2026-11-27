///|
/// A5.2 node-local credential custody end-to-end (ADR-0016 as amended).
///
/// The node enrolls the secret locally, the primary sends only a metadata
/// marker, and every start/lease/revoke goes through the real pinned-TLS
/// transport. The test asserts that the secret stays inside the node's 0600
/// store: it is absent from the child environment, `/proc/<pid>/environ`, the
/// workspace, the metadata file, the audit rings and every primary response.

///|
async fn credential_e2e_scan_dir(
  root : String,
  skip : Array[String],
  secret : String,
) -> Unit {
  let names = @fs.readdir(root, include_hidden=true, sort=false) catch {
    _ => []
  }
  for name in names {
    let path = root + "/" + name
    let mut skipped = false
    for allowed in skip {
      if path == allowed {
        skipped = true
      }
    }
    if skipped {
      continue
    }
    let kind = @fs.kind(path, follow_symlink=false) catch {
      _ => @fs.FileKind::Unknown
    }
    match kind {
      @fs.FileKind::Directory => credential_e2e_scan_dir(path, skip, secret)
      @fs.FileKind::Regular => {
        let data = @fs.read_file(path) catch { _ => continue }
        let text = data.text() catch { _ => continue }
        if text.contains(secret) {
          fail("the node credential secret leaked into " + path)
        }
      }
      _ => ()
    }
  }
}

///|
/// Read a small text file without propagating a missing-file error; the
/// credential env poll retries until the shell has flushed its output.
async fn credential_e2e_read_text(path : String) -> String {
  let data = @fs.read_file(path) catch { _ => return "" }
  data.text() catch { _ => "" }
}

///|
async test "node credentials stay node-local across lease and revoke" {
  host_run_scenario(
    "mn-node-cred",
    "rt-node-cred",
    5_000L,
    3,
    5_000L,
    100L,
    8,
    None,
    async fn(h) {
      let state_dir = h.host.state_dir()
      let vault = h.host.credentials()
      let secret = "sk-node-local-e2e-secret-0123456789abcdef"
      let profile = "anthropic"
      let agent_id = "agent-node-cred-e2e"
      let binding_id = "bind-node-cred-e2e"
      let entry = match vault.enroll(profile, secret) {
        Ok(value) => value
        Err(message) => fail("node enrollment failed: " + message)
      }
      // Node-local possession: 0700 directory, 0600 metadata and secret file.
      assert_eq(host_mode(state_dir + "/credentials"), 0o700)
      assert_eq(host_mode(state_dir + "/credentials/profiles.json"), 0o600)
      let secret_file = state_dir +
        "/credentials/" +
        entry.credential_id +
        ".json"
      assert_eq(host_mode(secret_file), 0o600)
      let secret_data = @fs.read_file(secret_file) catch {
        _ => fail("the node-local secret file is missing")
      }
      let secret_text = secret_data.text() catch { _ => "" }
      assert_true(secret_text.contains(secret))
      // Status is metadata only.
      let status_text = vault.status_json().stringify()
      assert_true(status_text.contains(entry.fingerprint))
      assert_true(!status_text.contains(secret))
      assert_true(!status_text.contains("mxs_"))
      let marker = @provider_runtime.ProcessCredential::new(
        binding_id~,
        credential_id=entry.credential_id,
        machine_id="rt-node-cred",
        agent_id~,
        profile~,
        version=entry.version,
        fingerprint=entry.fingerprint,
      )
      // A start before the primary leases the binding fails closed. The
      // script avoids `sh -c`, which the policy classifies as high risk.
      let _ = match
        h.machine.fs_write(
          path="cred_env.sh",
          content="env > env1.txt\nsleep 30\n",
          client_request_id="cred-fs-1",
        ) {
        Ok(value) => value
        Err(error) =>
          fail("cannot write the credential script: " + error.message)
      }
      match
        h.machine.process_start(
          run_id="run-cred-0",
          client_request_id="cred-0",
          argv=["/bin/sh", "cred_env.sh"],
          credential=Some(marker),
        ) {
        Ok(_) => fail("a start without a primary lease must fail closed")
        Err(error) =>
          assert_true(
            error.message.contains(@contracts.CREDENTIAL_REASON_LEASE_EXPIRED),
          )
      }
      // Lease renewal crosses the real transport with metadata only.
      let lease = match
        h.machine.credential_lease(
          binding_id~,
          credential_id=entry.credential_id,
          machine_id="rt-node-cred",
          agent_id~,
          profile~,
          version=entry.version,
          fingerprint=entry.fingerprint,
          lease_ttl_ms=1_000L,
          client_request_id="cred-lease",
        ) {
        Ok(value) => value
        Err(error) => fail("credential lease failed: " + error.message)
      }
      let lease_text = lease.stringify()
      assert_true(lease_text.contains(entry.fingerprint))
      assert_true(lease_text.contains("\"version\":1"))
      assert_true(!lease_text.contains(secret))
      assert_true(!lease_text.contains("mxs_"))
      // A leased binding starts a node-local proxy and injects only the
      // capability token into the child environment.
      let started = match
        h.machine.process_start(
          run_id="run-cred-1",
          client_request_id="cred-1",
          argv=["/bin/sh", "cred_env.sh"],
          credential=Some(marker),
        ) {
        Ok(value) => value
        Err(error) => fail("credential process start failed: " + error.message)
      }
      let (process, existing) = started
      assert_true(!existing)
      assert_true(process.pid > 0)
      let env_path = h.workspace + "/env1.txt"
      // The shell creates the file before it flushes every line, so poll its
      // content instead of racing on an empty file in CI.
      let mut env_text = ""
      let env_deadline = @async.now() + 5_000L
      while @async.now() < env_deadline {
        let text = credential_e2e_read_text(env_path)
        if text.contains(@contracts.CREDENTIAL_ENV_PROXY_URL + "=") &&
          text.contains(
            @contracts.CREDENTIAL_ENV_PROXY_TOKEN +
            "=" +
            @contracts.CREDENTIAL_NODE_TOKEN_PREFIX,
          ) {
          env_text = text
          break
        }
        @async.sleep(20)
      }
      assert_true(
        env_text.contains(@contracts.CREDENTIAL_ENV_PROXY_URL + "="),
      )
      assert_true(
        env_text.contains(
          @contracts.CREDENTIAL_ENV_PROXY_TOKEN +
          "=" +
          @contracts.CREDENTIAL_NODE_TOKEN_PREFIX,
        ),
      )
      assert_true(!env_text.contains(secret))
      // Linux also exposes the child environment through `/proc`; macOS has
      // no `/proc`, and the child-written env file is the same observation.
      let proc_available = @fs.exists("/proc") catch { _ => false }
      if proc_available {
        let proc_env = @fs.read_file(
          "/proc/" + process.pid.to_string() + "/environ",
        ) catch {
          _ => fail("cannot read the credential process environment")
        }
        let proc_text = proc_env.text() catch { _ => "" }
        assert_true(proc_text.contains(@contracts.CREDENTIAL_NODE_TOKEN_PREFIX))
        assert_true(!proc_text.contains(secret))
      }
      // The secret is absent from every node surface except its own 0600
      // store file, and from the workspace.
      credential_e2e_scan_dir(state_dir, [secret_file], secret)
      credential_e2e_scan_dir(h.workspace, [], secret)
      // An expired lease fails closed for the next start.
      @async.sleep(1_500)
      match
        h.machine.process_start(
          run_id="run-cred-2",
          client_request_id="cred-2",
          argv=["/bin/sh", "cred_env.sh"],
          credential=Some(marker),
        ) {
        Ok(_) => fail("an expired node lease must fail closed")
        Err(error) =>
          assert_true(
            error.message.contains(@contracts.CREDENTIAL_REASON_LEASE_EXPIRED),
          )
      }
      // Revoke destroys the node-local copy and stops the live proxy. The
      // signal carries the profile only; the reply is metadata.
      let revoked = match
        h.machine.credential_revoke(
          binding_id~,
          credential_id=entry.credential_id,
          machine_id="rt-node-cred",
          agent_id~,
          profile~,
          version=entry.version,
          fingerprint=entry.fingerprint,
          client_request_id="cred-revoke",
        ) {
        Ok(value) => value
        Err(error) => fail("credential revoke failed: " + error.message)
      }
      let revoked_text = revoked.stringify()
      assert_true(revoked_text.contains(@contracts.CREDENTIAL_STATE_REVOKED))
      assert_true(!revoked_text.contains(secret))
      assert_true(!(@fs.exists(secret_file) catch { _ => false }))
      assert_true(h.host.credential_proxies.get("run-cred-1") is None)
      let profiles_data = @fs.read_file(
        state_dir + "/credentials/profiles.json",
      ) catch {
        _ => fail("the node credential metadata is missing")
      }
      let profiles_text = profiles_data.text() catch { _ => "" }
      assert_true(profiles_text.contains(@contracts.CREDENTIAL_STATE_REVOKED))
      assert_true(!profiles_text.contains(secret))
      // A node that reconnects after the revocation cannot renew a lease:
      // withdrawal is synced before any local copy could be used again.
      match
        h.machine.credential_lease(
          binding_id~,
          credential_id=entry.credential_id,
          machine_id="rt-node-cred",
          agent_id~,
          profile~,
          version=entry.version,
          fingerprint=entry.fingerprint,
          lease_ttl_ms=60_000L,
          client_request_id="cred-lease-reconnect",
        ) {
        Ok(_) => fail("a revoked node credential must not renew a lease")
        Err(error) =>
          assert_true(
            error.message.contains(@contracts.CREDENTIAL_REASON_REVOKED),
          )
      }
      // A replay is idempotent and reports the same revoked state.
      let revoked_again = match
        h.machine.credential_revoke(
          binding_id~,
          credential_id=entry.credential_id,
          machine_id="rt-node-cred",
          agent_id~,
          profile~,
          version=entry.version,
          fingerprint=entry.fingerprint,
          client_request_id="cred-revoke-again",
        ) {
        Ok(value) => value
        Err(error) =>
          fail("repeated credential revoke failed: " + error.message)
      }
      assert_true(
        revoked_again.stringify().contains(@contracts.CREDENTIAL_STATE_REVOKED),
      )
      // A revoked binding cannot start again.
      match
        h.machine.process_start(
          run_id="run-cred-3",
          client_request_id="cred-3",
          argv=["/bin/sh", "cred_env.sh"],
          credential=Some(marker),
        ) {
        Ok(_) => fail("a revoked node credential must fail closed")
        Err(error) =>
          assert_true(
            error.message.contains(@contracts.CREDENTIAL_REASON_REVOKED),
          )
      }
      ignore(
        h.machine.process_cancel("run-cred-1", client_request_id="cred-cancel"),
      )
      // Neither audit ring, nor any primary-side audit entry, carries the
      // secret.
      assert_true(!h.host.audit_text().contains(secret))
      for event in h.state.audit_events() {
        assert_true(!event.stringify().contains(secret))
      }
    },
  )
}
