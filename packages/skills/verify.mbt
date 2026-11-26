///|
/// Ed25519 skill signature verification (ADR-0015 §2.2).
///
/// This mirrors A2's external verifier boundary (`ssh-keygen -Y verify`) but
/// uses its own SSHSIG namespace and payload domain:
///
/// - namespace: `monexus-skill-v1`,
/// - payload: the ASCII `sig_input = "monexus.skill.sig.v1\n" + content_hash`,
/// - signer identity: `key_id` from the owner's `skill_keys` allowlist,
/// - `signature.sig`: the base64 SSHSIG body without armour or whitespace.
///
/// There is no TOFU and no hand-written cryptography. A missing/unusable
/// verifier fails closed.
pub async fn probe_skill_verifier(
  tool~ : String = "ssh-keygen",
  timeout_ms~ : Int = 5_000,
) -> @recipes.VerifierProbe {
  @recipes.probe_verifier(tool~, timeout_ms~)
}

///|
fn skill_armor_signature(sig_base64 : String) -> String {
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
fn valid_skill_signature_text(sig : String) -> Bool {
  if sig.length() == 0 || sig.length() > 8192 {
    return false
  }
  for index in 0..<sig.length() {
    let ch = match sig.get_char(index) {
      Some(value) => value
      None => return false
    }
    let code = ch.to_int()
    if code < 32 || code == 127 {
      return false
    }
  }
  let bytes = @base64.decode(sig) catch { _ => return false }
  if bytes.length() < 64 || bytes.length() > 4096 {
    return false
  }
  let view = bytes.exact_view()
  if view.length() < 6 {
    return false
  }
  let magic : FixedArray[Int] = [0x53, 0x53, 0x48, 0x53, 0x49, 0x47]
  for index in 0..<6 {
    if view[index].to_int() != magic[index] {
      return false
    }
  }
  true
}

///|
/// Validate an OpenSSH Ed25519 public key (`ssh-ed25519 <base64>`, no comment).
pub fn valid_skill_public_key(text : String) -> Bool {
  if text.length() < 30 || text.length() > 128 {
    return false
  }
  if !text.has_prefix("ssh-ed25519 ") {
    return false
  }
  let body = text[12:].to_owned()
  if body.length() == 0 {
    return false
  }
  for index in 0..<body.length() {
    let ch = match body.get_char(index) {
      Some(value) => value
      None => return false
    }
    let code = ch.to_int()
    if code < 32 || code == 127 || ch == ' ' {
      return false
    }
  }
  let bytes = @base64.decode(body) catch { _ => return false }
  if bytes.length() != 51 {
    return false
  }
  let view = bytes.exact_view()
  let expected : FixedArray[Int] = [0, 0, 0, 11, 115, 115, 104, 45, 101, 100,
    50, 53, 53, 49, 57, 0, 0, 0, 32]
  for index in 0..<19 {
    if view[index].to_int() != expected[index] {
      return false
    }
  }
  true
}

///|
/// Verify a skill signature over its computed content hash. `public_key` comes
/// from the owner key allowlist; callers must already have rejected unknown or
/// revoked keys.
pub async fn verify_skill_signature(
  content_hash : String,
  key_id : String,
  public_key : String,
  sig_base64 : String,
  verifier : @recipes.VerifierProbe,
  timeout_ms~ : Int = 10_000,
) -> Result[Unit, SkillFault] {
  if !verifier.usable {
    return Err(
      skill_fail(
        @contracts.SKILL_ERR_BAD_SIGNATURE,
        "signature verifier is not available: " + verifier.detail,
      ),
    )
  }
  if !@recipes.is_valid_key_id(key_id) {
    return Err(
      skill_fail(@contracts.SKILL_ERR_UNKNOWN_KEY, "invalid key id"),
    )
  }
  if !valid_skill_public_key(public_key) {
    return Err(
      skill_fail(@contracts.SKILL_ERR_UNKNOWN_KEY, "invalid allowlisted public key"),
    )
  }
  if !valid_skill_signature_text(sig_base64) {
    return Err(
      skill_fail(
        @contracts.SKILL_ERR_BAD_SIGNATURE,
        "signature is not a base64 SSHSIG body",
      ),
    )
  }
  let dir = @fs.tmpdir(prefix="monexus-skill-verify") catch {
    _ =>
      return Err(
        skill_fail(
          @contracts.SKILL_ERR_BAD_SIGNATURE,
          "cannot create verification directory",
        ),
      )
  }
  defer @async.protect_from_cancel(async fn() {
    @fs.rmdir(dir, recursive=true) catch { _ => () }
  })
  let allowed_path = dir + "/allowed_signers"
  let signature_path = dir + "/skill.sig"
  let payload_path = dir + "/sig_input"
  @fs.write_file(allowed_path, key_id + " " + public_key + "\n", permission=0o600) catch {
    _ =>
      return Err(
        skill_fail(@contracts.SKILL_ERR_BAD_SIGNATURE, "cannot write allowed-signers"),
      )
  }
  @fs.write_file(
    signature_path,
    skill_armor_signature(sig_base64),
    permission=0o600,
  ) catch {
    _ =>
      return Err(
        skill_fail(@contracts.SKILL_ERR_BAD_SIGNATURE, "cannot write signature"),
      )
  }
  @fs.write_file(
    payload_path,
    skill_sig_input(content_hash),
    permission=0o600,
  ) catch {
    _ =>
      return Err(
        skill_fail(@contracts.SKILL_ERR_BAD_SIGNATURE, "cannot write payload"),
      )
  }
  let argv = [
    "-Y",
    "verify",
    "-f",
    allowed_path,
    "-I",
    key_id,
    "-n",
    SKILL_SIGNATURE_NAMESPACE,
    "-s",
    signature_path,
  ]
  let budget = if timeout_ms < 100 { 100 } else { timeout_ms }
  let outcome = @async.with_timeout_opt(budget, async fn() {
    let input = @process.redirect_from_file(payload_path) catch { _ => return None }
    let result = @process.collect_output(verifier.tool, argv, stdin=input) catch {
      _ => return None
    }
    Some(result)
  })
  match outcome {
    None =>
      Err(
        skill_fail(
          @contracts.SKILL_ERR_BAD_SIGNATURE,
          "signature verification timed out",
        ),
      )
    Some(None) =>
      Err(
        skill_fail(
          @contracts.SKILL_ERR_BAD_SIGNATURE,
          "cannot spawn signature verifier",
        ),
      )
    Some(Some(value)) => {
      let (exit_code, _stdout, _stderr) = value
      if exit_code == 0 {
        Ok(())
      } else {
        Err(
          skill_fail(
            @contracts.SKILL_ERR_BAD_SIGNATURE,
            "verifier rejected the signature",
          ),
        )
      }
    }
  }
}
