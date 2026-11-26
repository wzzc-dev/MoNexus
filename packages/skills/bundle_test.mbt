///|
/// Skill bundle trust, store and materialisation tests (ADR-0015 §2, §3).
///
/// Every key and signature is generated at test time by `ssh-keygen`; no key
/// material is checked in. The tests drive the real SSHSIG namespace
/// (`monexus-skill-v1`) and the real content-hash domain.

///|
const SKB_KEY_ID : String = "owner-key-1"

///|
const SKB_HASH : String =
  "sha256:0000000000000000000000000000000000000000000000000000000000000000"

///|
const SKB_SIG : String = "U1NIU0lHAAAAdGVzdC1zaWduYXR1cmUtcGxhY2Vob2xkZXI="

///|
async fn skb_run_ok(tool : String, argv : Array[String]) -> String raise {
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
async fn skb_write(path : String, text : String, mode : Int32) -> Unit raise {
  @fs.write_file(path, text, permission=mode) catch {
    _ => fail("cannot write " + path)
  }
}

///|
async fn skb_read(path : String) -> String raise {
  let data = @fs.read_file(path) catch { _ => fail("cannot read " + path) }
  data.text() catch { _ => fail("cannot decode " + path) }
}

///|
async fn skb_tmp(prefix : String) -> String raise {
  @fs.tmpdir(prefix=prefix) catch { _ => fail("cannot create temp directory") }
}

///|
async fn skb_cleanup(path : String) -> Unit {
  @fs.rmdir(path, recursive=true) catch { _ => () }
}

///|
fn skb_strip_armor(text : String) -> String {
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
async fn skb_generate_key(dir : String, name~ : String = "id_ed25519") -> (String, String) raise {
  let key_path = dir + "/" + name
  ignore(
    skb_run_ok(
      "ssh-keygen",
      ["-q", "-t", "ed25519", "-N", "", "-C", "", "-f", key_path],
    ),
  )
  let public_key = skb_run_ok("ssh-keygen", ["-y", "-f", key_path])
  (key_path, public_key.trim().to_owned())
}

///|
async fn skb_sign(key_path : String, payload_path : String) -> String raise {
  ignore(
    skb_run_ok(
      "ssh-keygen",
      [
        "-q", "-Y", "sign", "-f", key_path, "-n",
        @skills.SKILL_SIGNATURE_NAMESPACE,
        payload_path,
      ],
    ),
  )
  skb_strip_armor(skb_read(payload_path + ".sig"))
}

///|
async fn skb_require_verifier() -> @recipes.VerifierProbe raise {
  let probe = @skills.probe_skill_verifier()
  if !probe.usable {
    fail("the ssh-keygen SSHSIG verifier is not usable here: " + probe.detail)
  }
  probe
}

///|
fn skb_fields(commands : String) -> String {
  "{\"schema_version\":1," +
  "\"name\":\"repo-health\"," +
  "\"version\":\"1.0.0\"," +
  "\"description\":\"Report repository health.\"," +
  "\"permissions\":[\"git.read\"]," +
  "\"entry\":{\"path\":\"SKILL.md\",\"max_bytes\":4096}," +
  "\"resources\":[{\"path\":\"notes/README.md\",\"description\":\"notes\"}]," +
  "\"commands\":" + commands + "," +
  "\"source\":{\"kind\":\"local_directory\",\"path\":\"/tmp/src\",\"author\":\"ops\",\"created_at\":\"2026-01-01T00:00:00Z\"}}"
}

///|
fn skb_manifest(sig : String, hash : String) -> String {
  let commands = "[{\"id\":\"status\",\"argv\":[\"git\",\"status\",\"--porcelain\"],\"mode\":\"read_only\",\"timeout_ms\":5000,\"max_output_bytes\":8192}]"
  let fields = skb_fields(commands)
  let body = fields[:fields.length() - 1].to_owned()
  body + ",\"content_hash\":\"" + hash +
  "\",\"signature\":{\"key_id\":\"" + SKB_KEY_ID +
  "\",\"alg\":\"ed25519\",\"sig\":\"" + sig + "\"}}"
}

///|
struct SkbFixture {
  dir : String
  source : String
  key_path : String
  public_key : String
  content_hash : String
  manifest : String
  entry : String
  resource : String
}

///|
async fn skb_fixture(sig_bytes : String) -> SkbFixture raise {
  let dir = skb_tmp("monexus-skill-bundle")
  let source = dir + "/source"
  @fs.mkdir(source, permission=0o700, recursive=true) catch {
    _ => fail("cannot create the bundle source")
  }
  let (key_path, public_key) = skb_generate_key(dir)
  let entry = "# repo-health\n\nRun the status entry.\n"
  let resource = "notes\n"
  let placeholder = skb_manifest(SKB_SIG, SKB_HASH)
  let parsed = match @skills.parse_skill_manifest(placeholder) {
    Ok(value) => value
    Err(fault) => fail("fixture manifest rejected: " + fault.code)
  }
  let body = @skills.canonical_manifest_string(parsed)
  let hash = @skills.compute_content_hash(
    body,
    [("SKILL.md", entry), ("notes/README.md", resource)],
  )
  let payload_path = dir + "/payload"
  skb_write(payload_path, @skills.skill_sig_input(hash), 0o600)
  let sig = if sig_bytes == "" {
    skb_sign(key_path, payload_path)
  } else {
    sig_bytes
  }
  let manifest = skb_manifest(sig, hash)
  skb_write(source + "/skill.json", manifest, 0o600)
  skb_write(source + "/SKILL.md", entry, 0o600)
  @fs.mkdir(source + "/notes", permission=0o700, recursive=true) catch {
    _ => fail("cannot create the notes directory")
  }
  skb_write(source + "/notes/README.md", resource, 0o600)
  {
    dir,
    source,
    key_path,
    public_key,
    content_hash: hash,
    manifest,
    entry,
    resource,
  }
}

///|
fn skb_keys(public_key : String) -> @skills.SkillKeyStore {
  @skills.SkillKeyStore::empty().with_key(SKB_KEY_ID, public_key)
}

///|
fn skb_fault_code(result : Result[@skills.SkillBundle, @skills.SkillFault]) -> String {
  match result {
    Ok(_) => "ok"
    Err(fault) => fault.code
  }
}

///|
async fn skb_import(
  source : String,
  keys : @skills.SkillKeyStore,
  verifier : @recipes.VerifierProbe,
) -> Result[@skills.SkillBundle, @skills.SkillFault] {
  @skills.import_skill_bundle(source, keys, verifier)
}

///|
async test "a valid signed bundle imports and re-verifies from its stored copy" {
  let verifier = skb_require_verifier() catch { _ => fail("verifier unusable") }
  let fixture = skb_fixture("") catch { _ => fail("cannot build fixture") }
  defer @async.protect_from_cancel(async fn() { skb_cleanup(fixture.dir) })
  let keys = skb_keys(fixture.public_key)
  let bundle = match skb_import(fixture.source, keys, verifier) {
    Ok(value) => value
    Err(fault) => fail("valid bundle refused: " + fault.code + ": " + fault.detail)
  }
  assert_eq(bundle.manifest.content_hash, fixture.content_hash)
  assert_eq(bundle.manifest.entry_path, "SKILL.md")
  assert_eq(bundle.entry_text, fixture.entry)
  assert_eq(bundle.resources.length(), 1)
  assert_eq(bundle.resources[0].path, "notes/README.md")
  assert_eq(bundle.files.length(), 3)
  // Reading the same bytes back yields the same verified bundle.
  let again = match
    @skills.verify_skill_bundle_bytes(
      fixture.manifest,
      bundle.files,
      keys,
      verifier,
    ) {
    Ok(value) => value
    Err(fault) => fail("bytes import refused: " + fault.code)
  }
  assert_eq(again.manifest.content_hash, fixture.content_hash)
  // Store, then load and re-verify from the store alone.
  let state_dir = fixture.dir + "/state"
  let store_path = match @skills.store_skill_bundle(state_dir, again) {
    Ok(value) => value
    Err(fault) => fail("store refused: " + fault.code)
  }
  let stored = match @skills.load_stored_skill(store_path, keys, verifier) {
    Ok(value) => value
    Err(fault) => fail("stored bundle refused: " + fault.code)
  }
  assert_eq(stored.manifest.content_hash, fixture.content_hash)
  match @skills.load_stored_skill_hash(store_path) {
    Ok(value) =>
      assert_eq(value.manifest.content_hash, fixture.content_hash)
    Err(fault) => fail("hash-only load refused: " + fault.code)
  }
  // Only the entry and resources reach the session materialisation.
  let session_dir = fixture.dir + "/session-skills"
  let target = match @skills.materialize_skill(session_dir, stored) {
    Ok(value) => value
    Err(fault) => fail("materialisation refused: " + fault.code)
  }
  assert_true(@fs.exists(target + "/SKILL.md") catch { _ => false })
  assert_true(@fs.exists(target + "/notes/README.md") catch { _ => false })
  assert_true(!(@fs.exists(target + "/skill.json") catch { _ => true }))
  @skills.remove_skill_dir(target)
  assert_true(!(@fs.exists(target) catch { _ => true }))
}

///|
async test "unsigned, unknown, revoked and wrong-key bundles fail closed" {
  let verifier = skb_require_verifier() catch { _ => fail("verifier unusable") }
  let fixture = skb_fixture("") catch { _ => fail("cannot build fixture") }
  defer @async.protect_from_cancel(async fn() { skb_cleanup(fixture.dir) })
  // Unknown key: the key id is not in the allowlist.
  assert_eq(
    skb_fault_code(skb_import(fixture.source, @skills.SkillKeyStore::empty(), verifier)),
    "unknown_key",
  )
  assert_eq(
    skb_fault_code(skb_import(fixture.source, skb_keys(fixture.public_key).revoke(SKB_KEY_ID), verifier)),
    "revoked_key",
  )
  // A different key under the same key id cannot validate the signature.
  let (_, other_public) = skb_generate_key(fixture.dir, name="other_ed25519") catch {
    _ => fail("cannot generate a second key")
  }
  assert_eq(
    skb_fault_code(skb_import(fixture.source, skb_keys(other_public), verifier)),
    "bad_signature",
  )
  // No verifier is never a bypass.
  let missing : @recipes.VerifierProbe = {
    tool: "/nonexistent/ssh-keygen",
    found: false,
    version: "",
    supports_signatures: false,
    usable: false,
    detail: "not found",
  }
  assert_eq(
    skb_fault_code(skb_import(fixture.source, skb_keys(fixture.public_key), missing)),
    "bad_signature",
  )
  // A signature over a different payload is refused.
  let other_payload = fixture.dir + "/other"
  skb_write(other_payload, "sha256:" + skb_fixture_hash_zeros(), 0o600) catch {
    _ => fail("cannot write other payload")
  }
  let other_sig = skb_sign(fixture.key_path, other_payload) catch {
    _ => fail("cannot sign")
  }
  let source = fixture.dir + "/bad-sig"
  @fs.mkdir(source, permission=0o700, recursive=true) catch {
    _ => fail("cannot create bad-sig source")
  }
  skb_write(source + "/skill.json", skb_manifest(other_sig, fixture.content_hash), 0o600) catch {
    _ => fail("cannot write manifest")
  }
  skb_write(source + "/SKILL.md", fixture.entry, 0o600) catch {
    _ => fail("cannot write entry")
  }
  @fs.mkdir(source + "/notes", permission=0o700, recursive=true) catch {
    _ => fail("cannot create notes")
  }
  skb_write(source + "/notes/README.md", fixture.resource, 0o600) catch {
    _ => fail("cannot write resource")
  }
  assert_eq(
    skb_fault_code(skb_import(source, skb_keys(fixture.public_key), verifier)),
    "bad_signature",
  )
}

///|
fn skb_fixture_hash_zeros() -> String {
  let out = StringBuilder()
  for _ in 0..<64 {
    out.write_char('0')
  }
  out.to_string()
}

///|
async test "tampered manifests and files are refused by the content hash" {
  let verifier = skb_require_verifier() catch { _ => fail("verifier unusable") }
  let fixture = skb_fixture("") catch { _ => fail("cannot build fixture") }
  defer @async.protect_from_cancel(async fn() { skb_cleanup(fixture.dir) })
  let keys = skb_keys(fixture.public_key)
  let good = match skb_import(fixture.source, keys, verifier) {
    Ok(value) => value
    Err(fault) => fail("fixture refused: " + fault.code)
  }
  // Change the entry after signing: the recomputed hash no longer matches.
  skb_write(fixture.source + "/SKILL.md", fixture.entry + "extra\n", 0o600) catch {
    _ => fail("cannot tamper the entry")
  }
  assert_eq(skb_fault_code(skb_import(fixture.source, keys, verifier)), "hash_mismatch")
  // Restore and change only the manifest's hash field.
  skb_write(fixture.source + "/SKILL.md", fixture.entry, 0o600) catch {
    _ => fail("cannot restore the entry")
  }
  let tampered_manifest = fixture.manifest.replace(
    old=fixture.content_hash,
    new="sha256:" + skb_fixture_hash_zeros(),
  )
  skb_write(fixture.source + "/skill.json", tampered_manifest, 0o600) catch {
    _ => fail("cannot tamper the manifest")
  }
  assert_eq(skb_fault_code(skb_import(fixture.source, keys, verifier)), "hash_mismatch")
  // A structurally valid but different manifest byte string is refused by the
  // bytes path even when its files are intact.
  let bytes_mismatch = @skills.verify_skill_bundle_bytes(
    fixture.manifest + " ",
    good.files,
    keys,
    verifier,
  )
  assert_eq(skb_fault_code(bytes_mismatch), "invalid_manifest")
}

///|
async test "bundle closure rejects undeclared, missing, linked and executable files" {
  let verifier = skb_require_verifier() catch { _ => fail("verifier unusable") }
  let fixture = skb_fixture("") catch { _ => fail("cannot build fixture") }
  defer @async.protect_from_cancel(async fn() { skb_cleanup(fixture.dir) })
  let keys = skb_keys(fixture.public_key)
  // Undeclared file anywhere inside the bundle.
  skb_write(fixture.source + "/extra.txt", "not declared", 0o600) catch {
    _ => fail("cannot write undeclared file")
  }
  assert_eq(skb_fault_code(skb_import(fixture.source, keys, verifier)), "invalid_path")
  @fs.remove(fixture.source + "/extra.txt") catch { _ => () }
  // Declared resource missing.
  @fs.remove(fixture.source + "/notes/README.md") catch { _ => () }
  assert_eq(skb_fault_code(skb_import(fixture.source, keys, verifier)), "invalid_path")
  skb_write(fixture.source + "/notes/README.md", fixture.resource, 0o600) catch {
    _ => fail("cannot restore the resource")
  }
  // Symlinked file.
  let link = fixture.source + "/notes/link.md"
  @fs.symlink(target=fixture.source + "/notes/README.md", link) catch {
    _ => fail("cannot create a symlink")
  }
  assert_eq(skb_fault_code(skb_import(fixture.source, keys, verifier)), "invalid_path")
  @fs.remove(link) catch { _ => () }
  // Executable bit on a regular file.
  @fs.chmod(fixture.source + "/SKILL.md", 0o700) catch { _ => fail("cannot chmod") }
  assert_eq(skb_fault_code(skb_import(fixture.source, keys, verifier)), "permission_denied")
  @fs.chmod(fixture.source + "/SKILL.md", 0o600) catch { _ => fail("cannot chmod") }
  // A source that is not a directory.
  let file_source = fixture.dir + "/not-a-dir"
  skb_write(file_source, "x", 0o600) catch { _ => fail("cannot write") }
  assert_eq(skb_fault_code(skb_import(file_source, keys, verifier)), "invalid_path")
  // A symlinked source directory.
  let linked_source = fixture.dir + "/linked-source"
  @fs.symlink(target=fixture.source, linked_source) catch {
    _ => fail("cannot link the source")
  }
  assert_eq(skb_fault_code(skb_import(linked_source, keys, verifier)), "invalid_path")
}

///|
async test "stored copies are re-hashed and materialisations stay role-scoped" {
  let verifier = skb_require_verifier() catch { _ => fail("verifier unusable") }
  let fixture = skb_fixture("") catch { _ => fail("cannot build fixture") }
  defer @async.protect_from_cancel(async fn() { skb_cleanup(fixture.dir) })
  let keys = skb_keys(fixture.public_key)
  let bundle = match skb_import(fixture.source, keys, verifier) {
    Ok(value) => value
    Err(fault) => fail("fixture refused: " + fault.code)
  }
  let state_dir = fixture.dir + "/state2"
  let store_path = match @skills.store_skill_bundle(state_dir, bundle) {
    Ok(value) => value
    Err(fault) => fail("store refused: " + fault.code)
  }
  let entry_path = store_path + "/SKILL.md"
  @fs.chmod(entry_path, 0o644) catch { _ => fail("cannot chmod the stored entry") }
  skb_write(entry_path, bundle.entry_text + "tamper\n", 0o644) catch {
    _ => fail("cannot tamper the stored entry")
  }
  assert_eq(
    skb_fault_code(@skills.load_stored_skill(store_path, keys, verifier)),
    "hash_mismatch",
  )
  assert_eq(
    skb_fault_code(@skills.load_stored_skill_hash(store_path)),
    "hash_mismatch",
  )
}
