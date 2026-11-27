///|
/// Signature and trust-store tests.
///
/// Every key and signature is generated at test time by `ssh-keygen` inside a
/// throwaway temp directory; no fixture key material is checked in. The tests
/// exercise the real adapter, so they also prove the pinned OpenSSH invocation
/// (allowed-signers principal, namespace, stdin payload) works end to end.

///|
const TEST_KEY_ID : String = "dev-key-1"

///|
const PLACEHOLDER_SIG : String =
  "U1NIU0lHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

///|
fn signed_recipe_document(sig_base64 : String) -> String {
  let text =
    #|{
    #|  "schema_version": 1,
    #|  "name": "signed-app",
    #|  "version": "2.0.0",
    #|  "image": {
    #|    "ref": "ghcr.io/acme/signed-app:2.0.0",
    #|    "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"
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
    #|    "path": "/srv/recipes/signed-app.json",
    #|    "author": "ops",
    #|    "created_at": "2026-02-01T00:00:00Z"
    #|  },
    #|  "signature": {"key_id": "dev-key-1", "alg": "ed25519", "sig": "@SIG@"}
    #|}
  text.replace(old="@SIG@", new=sig_base64)
}

///|
fn trust_with(
  key_id : String,
  public_key : String,
  revoked : Bool,
) -> @recipes.TrustStore raise {
  let revoked_field = if revoked {
    ",\"revoked_at\":\"2026-06-01T00:00:00Z\""
  } else {
    ""
  }
  let text = "{\"keys\":[{\"key_id\":\"" + key_id + "\",\"public_key\":\"" +
    public_key + "\",\"added_at\":\"2026-01-01T00:00:00Z\"" + revoked_field + "}]}"
  match @recipes.parse_trust_store(text) {
    Ok(value) => value
    Err(error) => fail("trust store fixture was rejected: " + error.to_string())
  }
}

///|
async fn run_ok(tool : String, argv : Array[String]) -> String raise {
  let result = @process.collect_output(tool, argv) catch {
    _ => fail("cannot spawn " + tool)
  }
  let (code, stdout, stderr) = result
  if code != 0 {
    let message = stderr.text() catch { _ => "" }
    fail(tool + " exited " + code.to_string() + ": " + message)
  }
  stdout.text() catch { _ => "" }
}

///|
async fn read_text(path : String) -> String raise {
  let data = @fs.read_file(path) catch { _ => fail("cannot read " + path) }
  data.text() catch { _ => fail("cannot decode " + path) }
}

///|
async fn write_text(path : String, text : String, mode : Int32) -> Unit raise {
  @fs.write_file(path, text, permission=mode) catch {
    _ => fail("cannot write " + path)
  }
}

///|
async fn make_temp_dir(prefix : String) -> String raise {
  @fs.tmpdir(prefix=prefix) catch { _ => fail("cannot create temp directory") }
}

///|
async fn cleanup_dir(path : String) -> Unit {
  @fs.rmdir(path, recursive=true) catch { _ => () }
}

///|
fn strip_armor(text : String) -> String {
  let out = StringBuilder()
  for line in text.split("\n") {
    let trimmed = line.trim()
    if trimmed.has_prefix("-----") || trimmed.length() == 0 {
      continue
    }
    out.write_string(trimmed.to_owned())
  }
  out.to_string()
}

///|
async fn generate_key(dir : String, name~ : String = "id_ed25519") -> (String, String) raise {
  let key_path = dir + "/" + name
  ignore(
    run_ok(
      "ssh-keygen",
      ["-q", "-t", "ed25519", "-N", "", "-C", "", "-f", key_path],
    ),
  )
  let public_key = run_ok("ssh-keygen", ["-y", "-f", key_path])
  (key_path, public_key.trim().to_owned())
}

///|
async fn sign_payload(key_path : String, payload_path : String) -> String raise {
  ignore(
    run_ok(
      "ssh-keygen",
      [
        "-q", "-Y", "sign", "-f", key_path, "-n",
        @recipes.SIGNATURE_NAMESPACE, payload_path,
      ],
    ),
  )
  strip_armor(read_text(payload_path + ".sig"))
}

///|
async fn require_usable_verifier() -> @recipes.VerifierProbe raise {
  let probe = @recipes.probe_verifier()
  if !probe.usable {
    fail("the ssh-keygen SSHSIG verifier is not usable here: " + probe.detail)
  }
  probe
}

///|
async fn expect_import_reject(
  document : String,
  trust : @recipes.TrustStore,
  verifier : @recipes.VerifierProbe,
  reason : String,
) -> Unit raise {
  match @recipes.import_recipe(document, trust, verifier) {
    Ok(_) => fail("expected " + reason + " but the recipe verified")
    Err(error) =>
      if error.reason() != reason {
        fail("expected " + reason + " but got " + error.to_string())
      }
  }
}

///|
async test "a real ed25519 signature over the canonical hash verifies" {
  let probe = require_usable_verifier()
  let dir = make_temp_dir("monexus-verify-good")
  defer @async.protect_from_cancel(async fn() { cleanup_dir(dir) })
  let (key_path, public_key) = generate_key(dir)
  let placeholder = signed_recipe_document(PLACEHOLDER_SIG)
  let recipe = match @recipes.parse_recipe(placeholder) {
    Ok(value) => value
    Err(error) => fail("signed fixture rejected: " + error.to_string())
  }
  let canonical = @recipes.canonical_string(recipe)
  let hash = @recipes.content_hash(recipe)
  let payload_path = dir + "/payload"
  write_text(payload_path, hash, 0o600)
  let sig = sign_payload(key_path, payload_path)
  let document = signed_recipe_document(sig)
  let trust = trust_with(TEST_KEY_ID, public_key, false)
  match @recipes.import_recipe(document, trust, probe) {
    Ok(verified) => {
      inspect(verified.key_id, content=TEST_KEY_ID)
      inspect(verified.content_hash, content=hash)
      inspect(verified.canonical, content=canonical)
    }
    Err(error) => fail("valid signature was rejected: " + error.to_string())
  }
  // A stored recipe re-verifies from its canonical bytes and hash alone.
  match @recipes.reverify_stored(canonical, hash, TEST_KEY_ID, sig, trust, probe) {
    Ok(verified) =>
      if verified.content_hash != hash {
        fail("reverify changed the content hash")
      }
    Err(error) =>
      fail("stored recipe did not re-verify: " + error.to_string())
  }
  // Canonical bytes omit the signature field, so reattaching the verified
  // signature must produce the same structured recipe without changing the
  // signed bytes.
  match @recipes.parse_stored_recipe(canonical, TEST_KEY_ID, sig) {
    Ok(stored) =>
      if stored.identity() != "signed-app@2.0.0" {
        fail("stored recipe identity changed")
      }
    Err(error) =>
      fail("stored canonical recipe did not parse: " + error.to_string())
  }
}

///|
async test "a signature over another payload is refused as bad_signature" {
  let probe = require_usable_verifier()
  let dir = make_temp_dir("monexus-verify-bad")
  defer @async.protect_from_cancel(async fn() { cleanup_dir(dir) })
  let (key_path, public_key) = generate_key(dir)
  let other_payload = dir + "/other"
  let zeros = StringBuilder()
  for _ in 0..<64 {
    zeros.write_char('0')
  }
  write_text(other_payload, "sha256:" + zeros.to_string(), 0o600)
  let sig = sign_payload(key_path, other_payload)
  let trust = trust_with(TEST_KEY_ID, public_key, false)
  expect_import_reject(
    signed_recipe_document(sig),
    trust,
    probe,
    "bad_signature",
  )
}

///|
async test "unknown and revoked keys fail closed" {
  let probe = require_usable_verifier()
  let dir = make_temp_dir("monexus-verify-trust")
  defer @async.protect_from_cancel(async fn() { cleanup_dir(dir) })
  let (key_path, public_key) = generate_key(dir)
  let placeholder = signed_recipe_document(PLACEHOLDER_SIG)
  let recipe = match @recipes.parse_recipe(placeholder) {
    Ok(value) => value
    Err(error) => fail("signed fixture rejected: " + error.to_string())
  }
  let hash = @recipes.content_hash(recipe)
  let payload_path = dir + "/payload"
  write_text(payload_path, hash, 0o600)
  let sig = sign_payload(key_path, payload_path)
  let document = signed_recipe_document(sig)
  expect_import_reject(document, @recipes.TrustStore::empty(), probe, "unknown_key")
  expect_import_reject(
    document,
    trust_with(TEST_KEY_ID, public_key, true),
    probe,
    "revoked_key",
  )
}

///|
async test "a different trust key is refused even with a valid signature" {
  let probe = require_usable_verifier()
  let dir = make_temp_dir("monexus-verify-wrong-key")
  defer @async.protect_from_cancel(async fn() { cleanup_dir(dir) })
  let (key_path, public_key) = generate_key(dir)
  let placeholder = signed_recipe_document(PLACEHOLDER_SIG)
  let recipe = match @recipes.parse_recipe(placeholder) {
    Ok(value) => value
    Err(error) => fail("signed fixture rejected: " + error.to_string())
  }
  let hash = @recipes.content_hash(recipe)
  let payload_path = dir + "/payload"
  write_text(payload_path, hash, 0o600)
  let sig = sign_payload(key_path, payload_path)
  ignore(public_key)
  // A second, unrelated key under the same key id cannot validate the blob.
  let (_, other_public_key) = generate_key(dir, name="other_ed25519")
  let trust = trust_with(TEST_KEY_ID, other_public_key, false)
  expect_import_reject(
    signed_recipe_document(sig),
    trust,
    probe,
    "bad_signature",
  )
}

///|
async test "missing and unusable verifiers fail closed without fallback" {
  let missing : @recipes.VerifierProbe = {
    tool: "/nonexistent/ssh-keygen",
    found: false,
    version: "",
    supports_signatures: false,
    usable: false,
    detail: "not found",
  }
  let unsupported : @recipes.VerifierProbe = {
    tool: "/usr/bin/false",
    found: true,
    version: "",
    supports_signatures: false,
    usable: false,
    detail: "no SSHSIG",
  }
  let trust = @recipes.TrustStore::empty()
  let result = @recipes.verify_signature_over(
    "{}",
    TEST_KEY_ID,
    PLACEHOLDER_SIG,
    trust,
    missing,
  )
  match result {
    Ok(_) => fail("a missing verifier must never accept a recipe")
    Err(error) =>
      if error.reason() != "verifier_missing" {
        fail("expected verifier_missing, got " + error.to_string())
      }
  }
  let result = @recipes.verify_signature_over(
    "{}",
    TEST_KEY_ID,
    PLACEHOLDER_SIG,
    trust,
    unsupported,
  )
  match result {
    Ok(_) => fail("an unusable verifier must never accept a recipe")
    Err(error) =>
      if error.reason() != "verifier_unsupported" {
        fail("expected verifier_unsupported, got " + error.to_string())
      }
  }
}

///|
async test "a probed but absent tool is verifier_missing" {
  let probe = @recipes.probe_verifier(tool="/nonexistent/ssh-keygen", timeout_ms=500)
  inspect(probe.found, content="false")
  inspect(probe.usable, content="false")
  inspect(probe.detail, content="verifier was not found or could not be spawned")
  match @recipes.verify_signature_over(
    "{}",
    TEST_KEY_ID,
    PLACEHOLDER_SIG,
    @recipes.TrustStore::empty(),
    probe,
  ) {
    Ok(_) => fail("absent tool must fail closed")
    Err(error) =>
      if error.reason() != "verifier_missing" {
        fail("expected verifier_missing, got " + error.to_string())
      }
  }
}

///|
async test "stored hashes are pinned to their canonical bytes" {
  let probe = require_usable_verifier()
  let placeholder = signed_recipe_document(PLACEHOLDER_SIG)
  let recipe = match @recipes.parse_recipe(placeholder) {
    Ok(value) => value
    Err(error) => fail("signed fixture rejected: " + error.to_string())
  }
  let canonical = @recipes.canonical_string(recipe)
  let hash = @recipes.content_hash(recipe)
  let tampered = canonical[:canonical.length() - 1].to_owned() + " }"
  match @recipes.reverify_stored(
    tampered,
    hash,
    TEST_KEY_ID,
    PLACEHOLDER_SIG,
    @recipes.TrustStore::empty(),
    probe,
  ) {
    Ok(_) => fail("tampered canonical bytes must be refused")
    Err(error) =>
      if error.reason() != "hash_mismatch" {
        fail("expected hash_mismatch, got " + error.to_string())
      }
  }
  match @recipes.reverify_stored(
    canonical,
    "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    TEST_KEY_ID,
    PLACEHOLDER_SIG,
    @recipes.TrustStore::empty(),
    probe,
  ) {
    Ok(_) => fail("a wrong stored hash must be refused")
    Err(error) =>
      if error.reason() != "hash_mismatch" {
        fail("expected hash_mismatch, got " + error.to_string())
      }
  }
}

///|
async test "OpenSSH version parsing is bounded and exact" {
  inspect(
    match @recipes.parse_openssh_version("OpenSSH_9.6p1 Ubuntu-3ubuntu13, OpenSSL 3.0") {
      Some(value) => value
      None => "none"
    },
    content="9.6",
  )
  inspect(
    match @recipes.parse_openssh_version("OpenSSH_8.0") {
      Some(value) => value
      None => "none"
    },
    content="8.0",
  )
  inspect(
    match @recipes.parse_openssh_version("no marker here") {
      None => "none"
      Some(value) => value
    },
    content="none",
  )
  inspect(
    match @recipes.parse_openssh_version("OpenSSH_x.y") {
      None => "none"
      Some(value) => value
    },
    content="none",
  )
}

///|
async test "trust store loading enforces owner-only modes and regular files" {
  let dir = make_temp_dir("monexus-trust-load")
  defer @async.protect_from_cancel(async fn() { cleanup_dir(dir) })
  let (_, public_key) = generate_key(dir)
  let document = {
    "{\"keys\":[{\"key_id\":\"dev-key-1\",\"public_key\":\"" +
    public_key + "\",\"added_at\":\"2026-01-01T00:00:00Z\"}]}"
  }
  let path = dir + "/trust.json"
  write_text(path, document, 0o600)
  match @recipes.load_trust_store(path) {
    Ok(store) =>
      match store.get("dev-key-1") {
        Some(_) => ()
        None => fail("loaded store lost its key")
      }
    Err(error) => fail("0600 trust store was rejected: " + error.to_string())
  }
  @fs.chmod(path, 0o400) catch { _ => fail("cannot chmod trust store") }
  match @recipes.load_trust_store(path) {
    Ok(_) => ()
    Err(error) => fail("0400 trust store was rejected: " + error.to_string())
  }
  @fs.chmod(path, 0o644) catch { _ => fail("cannot chmod trust store") }
  match @recipes.load_trust_store(path) {
    Ok(_) => fail("group-readable trust store must be refused")
    Err(error) =>
      if error.reason() != "trust_store_insecure" {
        fail("expected trust_store_insecure, got " + error.to_string())
      }
  }
  match @recipes.load_trust_store(dir + "/missing.json") {
    Ok(_) => fail("a missing trust store must be refused")
    Err(error) =>
      if error.reason() != "trust_store_missing" {
        fail("expected trust_store_missing, got " + error.to_string())
      }
  }
  let link = dir + "/link.json"
  @fs.symlink(target=path, link) catch { _ => fail("cannot create symlink") }
  match @recipes.load_trust_store(link) {
    Ok(_) => fail("a symlinked trust store must be refused")
    Err(error) =>
      if error.reason() != "trust_store_insecure" {
        fail("expected trust_store_insecure, got " + error.to_string())
      }
  }
  let invalid = dir + "/invalid.json"
  write_text(invalid, "{\"keys\":[{\"key_id\":\"dev-key-1\"}]}", 0o600)
  match @recipes.load_trust_store(invalid) {
    Ok(_) => fail("an incomplete trust key must be refused")
    Err(error) =>
      if error.reason() != "trust_store_invalid" {
        fail("expected trust_store_invalid, got " + error.to_string())
      }
  }
  let duplicate = dir + "/duplicate.json"
  write_text(
    duplicate,
    "{\"keys\":[{\"key_id\":\"dev-key-1\",\"public_key\":\"" + public_key +
    "\",\"added_at\":\"2026-01-01T00:00:00Z\"},{\"key_id\":\"dev-key-1\",\"public_key\":\"" +
    public_key + "\",\"added_at\":\"2026-01-02T00:00:00Z\"}]}",
    0o600,
  )
  match @recipes.load_trust_store(duplicate) {
    Ok(_) => fail("a duplicated trust key must be refused")
    Err(error) =>
      if error.reason() != "duplicate_trust_key" {
        fail("expected duplicate_trust_key, got " + error.to_string())
      }
  }
  let bad_key = dir + "/bad-key.json"
  write_text(
    bad_key,
    "{\"keys\":[{\"key_id\":\"dev-key-1\",\"public_key\":\"ssh-ed25519 AAAA\",\"added_at\":\"2026-01-01T00:00:00Z\"}]}",
    0o600,
  )
  match @recipes.load_trust_store(bad_key) {
    Ok(_) => fail("a malformed public key must be refused")
    Err(error) =>
      if error.reason() != "trust_key_invalid" {
        fail("expected trust_key_invalid, got " + error.to_string())
      }
  }
}

///|
async test "trust store parsing rejects unknown fields and bad timestamps" {
  let dir = make_temp_dir("monexus-trust-parse")
  defer @async.protect_from_cancel(async fn() { cleanup_dir(dir) })
  let (_, public_key) = generate_key(dir)
  let cases : Array[(String, String)] = [
    (
      "{\"keys\":[],\"extra\":true}",
      "trust_store_invalid",
    ),
    (
      "{\"keys\":[{\"key_id\":\"dev-key-1\",\"public_key\":\"" + public_key +
      "\",\"added_at\":\"2026-01-01T00:00:00Z\",\"extra\":1}]}",
      "trust_store_invalid",
    ),
    (
      "{\"keys\":[{\"key_id\":\"dev key\",\"public_key\":\"" + public_key +
      "\",\"added_at\":\"2026-01-01T00:00:00Z\"}]}",
      "key_id_invalid",
    ),
    (
      "{\"keys\":[{\"key_id\":\"dev-key-1\",\"public_key\":\"" + public_key +
      "\",\"added_at\":\"yesterday\"}]}",
      "timestamp_invalid",
    ),
    (
      "{\"keys\":[{\"key_id\":\"dev-key-1\",\"public_key\":\"" + public_key +
      "\",\"added_at\":\"2026-01-01T00:00:00Z\",\"revoked_at\":\"2026-13-01T00:00:00Z\"}]}",
      "timestamp_invalid",
    ),
    ("not json", "trust_store_invalid"),
  ]
  for entry in cases {
    match @recipes.parse_trust_store(entry.0) {
      Ok(_) => fail("trust store should be rejected: " + entry.0)
      Err(error) =>
        if error.reason() != entry.1 {
          fail("expected " + entry.1 + " but got " + error.to_string())
        }
    }
  }
}
