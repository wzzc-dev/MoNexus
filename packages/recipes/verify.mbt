///|
/// Ed25519 recipe signature verification (ADR-0013 §2.3).
///
/// A1.0 established that MoonBit 0.22.x exposes no asymmetric signature API
/// (`spikes/a1-pairing/README.md` "Gaps found"). A2.0 therefore verifies
/// through one checked external adapter, `ssh-keygen -Y verify` (OpenSSH
/// SSHSIG), and refuses every recipe when the adapter is missing or unusable.
/// No hand-written cryptography and no "unsigned is acceptable" fallback
/// exists in this package.
///
/// Signed payload convention (pinned):
/// - namespace: `monexus-recipe-v1` (also the `-n` argument),
/// - payload bytes: the ASCII `content_hash` string, e.g.
///   `sha256:3f...` (71 bytes), with **no trailing newline**,
/// - `signature.sig`: the base64 body of the SSHSIG blob, no armour and no
///   whitespace; the adapter re-armours it at 70 columns before verification,
/// - the signer identity (`-I` and allowed-signers principal) is `key_id`.
///
/// The trust store is the only source of public keys. The SSHSIG blob carries
/// its own key, but `ssh-keygen -Y verify` only accepts it when that key is
/// listed for the principal in `allowed_signers`, which we build from the
/// trust store entry.

///|
pub const SIGNATURE_NAMESPACE : String = "monexus-recipe-v1"

///|
pub const MIN_SSH_KEYGEN_MAJOR : Int = 8

///|
pub const MIN_SSH_KEYGEN_MINOR : Int = 0

///|
pub(all) struct VerifierProbe {
  tool : String
  found : Bool
  version : String
  supports_signatures : Bool
  usable : Bool
  detail : String
}

///|
pub(all) struct VerifiedContent {
  canonical : String
  content_hash : String
  key_id : String
}

///|
pub(all) struct VerifiedRecipe {
  recipe : Recipe
  canonical : String
  content_hash : String
  key_id : String
}

///|
fn verifier_failure(code : RecipeErrorCode, detail : String) -> RecipeError {
  RecipeError::new(code).with_detail(detail)
}

///|
/// Parse `OpenSSH_9.6p1 ...` into `9.6`. Returns `None` when no numeric
/// version follows the marker; the numeric version is diagnostic only.
pub fn parse_openssh_version(text : String) -> String? {
  let marker = "OpenSSH_"
  let index = match text.find(marker) {
    Some(value) => value
    None => return None
  }
  let mut cursor = index + marker.length()
  let major = match read_digits(text, cursor) {
    Some(value) => value
    None => return None
  }
  cursor = major.1
  if text.get_char(cursor) != Some('.') {
    return None
  }
  cursor = cursor + 1
  let minor = match read_digits(text, cursor) {
    Some(value) => value
    None => return None
  }
  Some(major.0.to_string() + "." + minor.0.to_string())
}

///|
fn read_digits(text : String, start : Int) -> (Int, Int)? {
  let mut cursor = start
  let mut value = 0
  let mut digits = 0
  while cursor < text.length() {
    let ch = match text.get_char(cursor) {
      Some(found) => found
      None => break
    }
    if ch < '0' || ch > '9' {
      break
    }
    if digits >= 4 {
      return None
    }
    value = value * 10 + (ch.to_int() - 48)
    digits = digits + 1
    cursor = cursor + 1
  }
  if digits == 0 {
    None
  } else {
    Some((value, cursor))
  }
}

///|
fn version_supported(version : String) -> Bool {
  if version == "" {
    return true
  }
  let parts = version.split(".")
  let values : Array[Int] = []
  for raw in parts {
    let part = raw.to_owned()
    let mut value = 0
    let mut digits = 0
    for index in 0..<part.length() {
      let ch = match part.get_char(index) {
        Some(found) => found
        None => return false
      }
      if ch < '0' || ch > '9' {
        return false
      }
      value = value * 10 + (ch.to_int() - 48)
      digits = digits + 1
    }
    if digits == 0 {
      return false
    }
    values.push(value)
  }
  if values.length() < 2 {
    return false
  }
  if values[0] > MIN_SSH_KEYGEN_MAJOR {
    return true
  }
  if values[0] < MIN_SSH_KEYGEN_MAJOR {
    return false
  }
  values[1] >= MIN_SSH_KEYGEN_MINOR
}

///|
fn tool_basename(tool : String) -> String {
  match tool.rev_find("/") {
    Some(index) => tool[index + 1:].to_owned()
    None => tool
  }
}

///|
async fn ssh_version_near(tool : String) -> String {
  if tool_basename(tool) != "ssh-keygen" {
    return ""
  }
  let ssh = match tool.rev_find("/") {
    Some(index) => tool[:index + 1].to_owned() + "ssh"
    None => "ssh"
  }
  let collected = @async.with_timeout_opt(2_000, async fn() {
    let result = @process.collect_output(ssh, ["-V"]) catch { _ => return None }
    Some(result)
  })
  match collected {
    Some(Some(value)) => {
      let (_, stdout, stderr) = value
      let out = stdout.text() catch { _ => "" }
      let err = stderr.text() catch { _ => "" }
      match parse_openssh_version(out + err) {
        Some(version) => version
        None => ""
      }
    }
    _ => ""
  }
}

///|
/// Probe the verifier once. Presence is proven by spawning the tool; support is
/// proven by its own `-Y` usage text (OpenSSH ≥ 8.0 lists `-Y verify`), not by
/// trusting a version string. A numeric version, when the sibling `ssh -V`
/// yields one, must also satisfy the minimum.
pub async fn probe_verifier(
  tool~ : String = "ssh-keygen",
  timeout_ms~ : Int = 5_000,
) -> VerifierProbe {
  if tool == "" {
    return {
      tool,
      found: false,
      version: "",
      supports_signatures: false,
      usable: false,
      detail: "verifier path is empty",
    }
  }
  let budget = if timeout_ms < 100 { 100 } else { timeout_ms }
  let collected = @async.with_timeout_opt(budget, async fn() {
    let result = @process.collect_output(tool, ["-Y"]) catch { _ => return None }
    Some(result)
  })
  match collected {
    None =>
      return {
        tool,
        found: false,
        version: "",
        supports_signatures: false,
        usable: false,
        detail: "verifier probe timed out",
      }
    Some(None) =>
      return {
        tool,
        found: false,
        version: "",
        supports_signatures: false,
        usable: false,
        detail: "verifier was not found or could not be spawned",
      }
    Some(Some(value)) => {
      let (_, stdout, stderr) = value
      let out = stdout.text() catch { _ => "" }
      let err = stderr.text() catch { _ => "" }
      let usage = out + err
      let supports = usage.contains("-Y verify") && usage.contains("-Y sign")
      let version = ssh_version_near(tool)
      let usable = supports && version_supported(version)
      let detail = if usable {
        "ssh-keygen with SSHSIG support"
      } else if !supports {
        "ssh-keygen does not expose -Y sign/verify (OpenSSH 8.0 or newer is required)"
      } else {
        "ssh-keygen version is below the minimum"
      }
      {
        tool,
        found: true,
        version,
        supports_signatures: supports,
        usable,
        detail,
      }
    }
  }
}

///|
/// Re-armour a base64 SSHSIG body the way `ssh-keygen -Y sign` emits it.
fn armor_signature(sig_base64 : String) -> String {
  let out = StringBuilder()
  out.write_string("-----BEGIN SSH SIGNATURE-----\n")
  let mut index = 0
  while index < sig_base64.length() {
    let mut end = index + 70
    if end > sig_base64.length() {
      end = sig_base64.length()
    }
    out.write_string(sig_base64[index:end].to_owned())
    out.write_char('\n')
    index = end
  }
  out.write_string("-----END SSH SIGNATURE-----\n")
  out.to_string()
}

///|
fn verifier_unusable_error(verifier : VerifierProbe) -> RecipeError {
  if !verifier.found {
    verifier_failure(VerifierMissing, "signature verifier is not available")
  } else if !verifier.supports_signatures {
    verifier_failure(
      VerifierUnsupported,
      "signature verifier does not support SSHSIG",
    )
  } else {
    verifier_failure(
      VerifierUnsupported,
      "signature verifier version is not supported",
    )
  }
}

///|
async fn remove_dir_quietly(path : String) -> Unit {
  @fs.rmdir(path, recursive=true) catch { _ => () }
}

///|
/// Verify `sig_base64` over `canonical` with the trust store key `key_id`.
///
/// Fails closed for unknown/revoked keys, bad base64, a missing or unusable
/// verifier, timeout, spawn failure, non-zero exit and any malformed input.
pub async fn verify_signature_over(
  canonical : String,
  key_id : String,
  sig_base64 : String,
  trust : TrustStore,
  verifier : VerifierProbe,
  timeout_ms~ : Int = 10_000,
) -> Result[VerifiedContent, RecipeError] {
  if !verifier.usable {
    return Err(verifier_unusable_error(verifier))
  }
  if !is_valid_key_id(key_id) {
    return Err(RecipeError::new(KeyIdInvalid).at("signature.key_id"))
  }
  let key = match trust.get(key_id) {
    Some(value) => value
    None =>
      return Err(
        RecipeError::new(UnknownKey).at("signature.key_id").with_detail(
          "key is not present in the owner trust store",
        ),
      )
  }
  match key.revoked_at {
    Some(_) =>
      return Err(
        RecipeError::new(RevokedKey).at("signature.key_id").with_detail(
          "key has been revoked",
        ),
      )
    None => ()
  }
  match decode_ssh_signature(sig_base64) {
    Some(_) => ()
    None =>
      return Err(
        RecipeError::new(SignatureInvalid).at("signature.sig").with_detail(
          "expected the base64 SSHSIG body without whitespace",
        ),
      )
  }
  let content_hash = "sha256:" + sha256_hex(canonical)
  let dir = @fs.tmpdir(prefix="monexus-recipe-verify") catch {
    _ =>
      return Err(
        verifier_failure(VerifierFailed, "cannot create verification directory"),
      )
  }
  defer @async.protect_from_cancel(async fn() { remove_dir_quietly(dir) })
  let allowed_path = dir + "/allowed_signers"
  let signature_path = dir + "/recipe.sig"
  let payload_path = dir + "/content_hash"
  let allowed_text = key_id + " " + key.public_key + "\n"
  let armored = armor_signature(sig_base64)
  @fs.write_file(allowed_path, allowed_text, permission=0o600) catch {
    _ =>
      return Err(
        verifier_failure(VerifierFailed, "cannot write allowed-signers file"),
      )
  }
  @fs.write_file(signature_path, armored, permission=0o600) catch {
    _ =>
      return Err(
        verifier_failure(VerifierFailed, "cannot write signature file"),
      )
  }
  @fs.write_file(payload_path, content_hash, permission=0o600) catch {
    _ =>
      return Err(
        verifier_failure(VerifierFailed, "cannot write signed payload"),
      )
  }
  let argv = [
    "-Y", "verify", "-f", allowed_path, "-I", key_id, "-n", SIGNATURE_NAMESPACE,
    "-s", signature_path,
  ]
  let budget = if timeout_ms < 100 { 100 } else { timeout_ms }
  let outcome = @async.with_timeout_opt(budget, async fn() {
    let input = @process.redirect_from_file(payload_path) catch { _ => return None }
    let result = @process.collect_output(
      verifier.tool,
      argv,
      stdin=input,
    ) catch {
      _ => return None
    }
    Some(result)
  })
  match outcome {
    None =>
      Err(verifier_failure(VerifierFailed, "signature verification timed out"))
    Some(None) =>
      Err(verifier_failure(VerifierFailed, "cannot spawn signature verifier"))
    Some(Some(value)) => {
      let (exit_code, _stdout, _stderr) = value
      if exit_code == 0 {
        Ok({ canonical, content_hash, key_id })
      } else {
        Err(
          RecipeError::new(BadSignature).at("signature.sig").with_detail(
            "verifier rejected the signature",
          ),
        )
      }
    }
  }
}

///|
/// Parse, hash and verify a recipe document in one step.
pub async fn import_recipe(
  text : String,
  trust : TrustStore,
  verifier : VerifierProbe,
  timeout_ms~ : Int = 10_000,
) -> Result[VerifiedRecipe, RecipeError] {
  let recipe = match parse_recipe(text) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let canonical = canonical_string(recipe)
  let content_hash = "sha256:" + sha256_hex(canonical)
  let verified = match verify_signature_over(
    canonical,
    recipe.signature.key_id,
    recipe.signature.sig,
    trust,
    verifier,
    timeout_ms~,
  ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if verified.content_hash != content_hash {
    return Err(RecipeError::new(Internal).with_detail("hash mismatch"))
  }
  Ok({ recipe, canonical, content_hash, key_id: recipe.signature.key_id })
}

///|
/// Reattach the stored signature to canonical recipe bytes and parse the
/// result. The canonical bytes deliberately exclude `signature`, so they are
/// not a complete recipe document on their own; callers first verify the hash
/// and signature with `reverify_stored`, then use this for the structured
/// recipe. The key id and SSHSIG body are already validated and contain no
/// JSON metacharacters.
pub fn parse_stored_recipe(
  canonical : String,
  key_id : String,
  signature : String,
) -> Result[Recipe, RecipeError] {
  if canonical.length() < 2 ||
    canonical.get_char(canonical.length() - 1) != Some('}') {
    return Err(
      RecipeError::new(InvalidJson).at("recipe").with_detail(
        "canonical bytes are not a JSON object",
      ),
    )
  }
  let document = canonical[:canonical.length() - 1].to_owned() +
    ",\"signature\":{\"key_id\":\"" + key_id +
    "\",\"alg\":\"ed25519\",\"sig\":\"" + signature + "\"}}"
  parse_recipe(document)
}

///|
/// Re-verify a recipe loaded from storage. The canonical bytes and hash are the
/// authority: a mismatch is `hash_mismatch`, and the signature must still be
/// valid for the current trust store (ADR-0013 §2.3 "用前复验").
pub async fn reverify_stored(
  canonical : String,
  stored_hash : String,
  key_id : String,
  sig_base64 : String,
  trust : TrustStore,
  verifier : VerifierProbe,
  timeout_ms~ : Int = 10_000,
) -> Result[VerifiedContent, RecipeError] {
  if !check_content_hash(canonical, stored_hash) {
    return Err(
      RecipeError::new(HashMismatch).with_detail(
        "stored hash does not match the canonical bytes",
      ),
    )
  }
  let verified = match verify_signature_over(
    canonical,
    key_id,
    sig_base64,
    trust,
    verifier,
    timeout_ms~,
  ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if verified.content_hash != stored_hash {
    return Err(RecipeError::new(HashMismatch).with_detail("hash changed"))
  }
  Ok(verified)
}
