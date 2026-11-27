///|
/// Platform credential store (A5.0, ADR-0016 §2).
///
/// Two backends exist behind one interface:
///
/// - `file` (Linux/default): a 0700 state directory with one 0600 JSON file per
///   credential. The file is written atomically through a 0600 temp file and a
///   rename, and it is re-checked on read: group/other permission bits are a
///   hard error (`credential_store_bad_permissions`), never a warning.
/// - `keychain` (macOS): a generic-password item whose secret is fed through
///   the `security` tool's stdin. The secret never appears in argv, so it is
///   not visible through `ps`. This path is recorded as unverified on
///   non-macOS CI; an explicit `credential.storage=file` is the documented
///   fallback.
///
/// The store never writes a secret to SQLite, events, logs or the workspace.
/// SQLite holds metadata only (see `packages/machines/credential_store.mbt`).

///|
/// A secret-free failure. `reason` is one of the ADR-0016 fixed reasons; the
/// detail is a fixed explanation that never contains the secret.
pub(all) struct CredentialFailure {
  reason : String
  detail : String
}

///|
pub fn credential_failure(
  reason : String,
  detail~ : String = "",
) -> CredentialFailure {
  { reason, detail, }
}

///|
pub fn CredentialFailure::message(self : CredentialFailure) -> String {
  if self.detail == "" {
    self.reason
  } else {
    self.reason + ": " + self.detail
  }
}

///|
/// One file-envelope. `format` is checked on read so a foreign JSON file is
/// rejected instead of being interpreted as a credential.
pub(all) struct CredentialEnvelope {
  format : String
  credential_id : String
  kind : String
  secret : String
  version : Int32
  created_at : String
}

///|
pub fn CredentialEnvelope::to_json(self : CredentialEnvelope) -> @json.Json {
  @contracts.json_object([
    ("format", @contracts.json_string(self.format)),
    ("credential_id", @contracts.json_string(self.credential_id)),
    ("kind", @contracts.json_string(self.kind)),
    ("secret", @contracts.json_string(self.secret)),
    ("version", @contracts.json_int(self.version)),
    ("created_at", @contracts.json_string(self.created_at)),
  ])
}

///|
pub fn CredentialEnvelope::from_json(json : @json.Json) -> CredentialEnvelope? {
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return None
  }
  let format = @contracts.string_field_or(object, "format", "")
  if format != "monexus.credential.v1" {
    return None
  }
  let credential_id = @contracts.string_field_or(object, "credential_id", "")
  let secret = @contracts.string_field_or(object, "secret", "")
  if credential_id == "" || secret == "" {
    return None
  }
  Some({
    format,
    credential_id,
    kind: @contracts.string_field_or(
      object,
      "kind",
      @contracts.CREDENTIAL_KIND_API_KEY,
    ),
    secret,
    version: @contracts.int_field_or(object, "version", 1),
    created_at: @contracts.string_field_or(object, "created_at", ""),
  })
}

///|
/// Domain-separated, non-reversible fingerprint of a secret. It is safe to
/// persist and to show in status output.
pub fn credential_fingerprint(secret : String) -> String {
  let input = @utf8.encode(@contracts.CREDENTIAL_FINGERPRINT_DOMAIN + secret)
  @crypto.bytes_to_hex_string(@crypto.sha256(input))
}

///|
extern "c" fn credential_is_macos_raw() -> Int32 = "monexus_credentials_is_macos"

///|
/// Whether the requested backend is usable on this host. `auto` prefers the
/// Keychain on macOS and the file backend elsewhere. This is the binary's
/// target, not `OSTYPE`: GUI applications do not inherit shell variables.
pub fn platform_is_macos() -> Bool {
  credential_is_macos_raw() == 1
}

///|
pub(all) struct CredentialStore {
  root : String
  backend : String
  detail : String
  /// When true the host must refuse enrollment: the operator asked for a
  /// backend this build cannot provide (for example Keychain on Linux) and did
  /// not opt into the file fallback.
  unsupported : Bool
}

///|
/// Open the store. `requested` is `credential.storage`:
///
/// - `file` → 0700 directory + 0600 files
/// - `keychain` → macOS Keychain; on non-macOS this fails closed
/// - empty/`auto` → Keychain on macOS, file elsewhere
pub fn CredentialStore::open(
  root : String,
  requested~ : String = "",
) -> CredentialStore {
  let want_keychain = requested == @contracts.CREDENTIAL_STORAGE_KEYCHAIN
  let want_file = requested == @contracts.CREDENTIAL_STORAGE_FILE
  let auto = requested == "" || requested == "auto"
  if want_keychain {
    if platform_is_macos() {
      return {
        root,
        backend: @contracts.CREDENTIAL_STORAGE_KEYCHAIN,
        detail: "keychain; secret passed through stdin, never argv",
        unsupported: false,
      }
    }
    return {
      root,
      backend: @contracts.CREDENTIAL_STORAGE_UNSUPPORTED,
      detail: "keychain requires macOS; set credential.storage=file explicitly",
      unsupported: true,
    }
  }
  if want_file || auto {
    return {
      root,
      backend: @contracts.CREDENTIAL_STORAGE_FILE,
      detail: "0700 directory, 0600 files, atomic rename",
      unsupported: false,
    }
  }
  {
    root,
    backend: @contracts.CREDENTIAL_STORAGE_UNSUPPORTED,
    detail: "unknown credential storage: " + requested,
    unsupported: true,
  }
}

///|
fn CredentialStore::credential_path(
  self : CredentialStore,
  credential_id : String,
) -> String {
  self.root + "/" + credential_id + ".json"
}

///|
/// Validate a secret without logging it. Rejects empty, oversized and
/// multi-line values; API keys and bearer tokens are single-line tokens.
pub fn validate_credential_secret(
  secret : String,
) -> Result[Unit, CredentialFailure] {
  let length = @utf8.encode(secret).length()
  if length == 0 {
    return Err(
      credential_failure(
        @contracts.CREDENTIAL_REASON_SECRET_REQUIRED,
        detail="secret is empty",
      ),
    )
  }
  if length > 4096 {
    return Err(
      credential_failure(
        @contracts.CREDENTIAL_REASON_SECRET_INVALID,
        detail="secret is too long",
      ),
    )
  }
  let mut index = 0
  while index < secret.length() {
    let ch = match secret.get_char(index) {
      Some(value) => value
      None => break
    }
    let code = ch.to_int()
    if code == 10 || code == 13 || code == 0 {
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_SECRET_INVALID,
          detail="secret must be a single line",
        ),
      )
    }
    index = index + 1
  }
  Ok(())
}

///|
/// Read a POSIX permission mode. The async filesystem API exposes chmod but
/// not stat mode, so a small `stat` call is used; the values are compared as
/// integers and a failure is a hard error rather than a best-effort pass.
async fn credential_mode(path : String) -> Result[Int32, CredentialFailure] {
  let args : Array[String] = if platform_is_macos() {
    ["-f", "%Lp", path]
  } else {
    ["-c", "%a", path]
  }
  let (exit_code, stdout, _stderr) = @process.collect_output("stat", args) catch {
    _ =>
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_STORE_PERMISSIONS,
          detail="cannot stat credential file",
        ),
      )
  }
  if exit_code != 0 {
    return Err(
      credential_failure(
        @contracts.CREDENTIAL_REASON_STORE_PERMISSIONS,
        detail="stat failed",
      ),
    )
  }
  let text = stdout.text() catch {
    _ =>
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_STORE_PERMISSIONS,
          detail="stat output was not UTF-8",
        ),
      )
  }
  let trimmed = text.trim()
  let mode = @string.parse_int(trimmed, radix=8) catch {
    _ =>
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_STORE_PERMISSIONS,
          detail="unreadable stat output",
        ),
      )
  }
  Ok(mode.to_int())
}

///|
async fn credential_null_output() -> &@process.ProcessOutput {
  @process.redirect_to_file("/dev/null")
}

///|
async fn CredentialStore::credential_check_dir(
  self : CredentialStore,
) -> Result[Unit, CredentialFailure] {
  @fs.mkdir(self.root, permission=0o700, recursive=true, allow_exist=true) catch {
    _ =>
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_STORE_PERMISSIONS,
          detail="cannot create credential directory",
        ),
      )
  }
  // Refuse a directory another process has widened instead of silently
  // repairing it; a widened credential directory is a failed security check.
  let mode = match credential_mode(self.root) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if (mode & 0o077) != 0 {
    return Err(
      credential_failure(
        @contracts.CREDENTIAL_REASON_STORE_PERMISSIONS,
        detail="credential directory must be 0700",
      ),
    )
  }
  @fs.chmod(self.root, 0o700) catch {
    _ =>
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_STORE_PERMISSIONS,
          detail="cannot set credential directory permissions",
        ),
      )
  }
  Ok(())
}

///|
async fn CredentialStore::credential_check_file(
  self : CredentialStore,
  path : String,
) -> Result[Unit, CredentialFailure] {
  let mode = match credential_mode(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if (mode & 0o077) != 0 {
    return Err(
      credential_failure(
        @contracts.CREDENTIAL_REASON_STORE_PERMISSIONS,
        detail="credential file must be 0600",
      ),
    )
  }
  let kind = @fs.kind(path, follow_symlink=false) catch {
    _ =>
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_LOCKED,
          detail="credential file is missing",
        ),
      )
  }
  if !(kind is @fs.FileKind::Regular) {
    return Err(
      credential_failure(
        @contracts.CREDENTIAL_REASON_LOCKED,
        detail="credential path is not a regular file",
      ),
    )
  }
  Ok(())
}

///|
fn credential_keychain_service(credential_id : String) -> String {
  "monexus.credential." + credential_id
}

///|
async fn credential_keychain_put(
  credential_id : String,
  secret : String,
) -> Result[Unit, CredentialFailure] {
  // `security` prompts on stdin when `-w` is omitted. A 0600 temp file feeds
  // the prompt; the secret never enters argv. The temp file is removed in all
  // paths.
  let temp_dir = match @env.get_env_var("HOME") {
    Some(value) => value
    None => "/tmp"
  }
  let temp_path = temp_dir +
    "/.monexus-credential-" +
    @contracts.new_id("tmp", @async.now()) +
    ".secret"
  @fs.write_file(temp_path, secret, permission=0o600) catch {
    _ =>
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_PROXY_UNSUPPORTED,
          detail="cannot stage keychain secret",
        ),
      )
  }
  let input = @process.redirect_from_file(temp_path)
  let sink = credential_null_output()
  let exit_code = @process.run(
    "security",
    [
      "add-generic-password",
      "-U",
      "-a",
      "monexus",
      "-s",
      credential_keychain_service(credential_id),
      "-l",
      "MoNexus managed credential",
    ],
    stdin=input,
    stdout=sink,
    stderr=sink,
  ) catch {
    _ => {
      @fs.remove(temp_path) catch {
        _ => ()
      }
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_PROXY_UNSUPPORTED,
          detail="security add-generic-password failed",
        ),
      )
    }
  }
  @fs.remove(temp_path) catch {
    _ => ()
  }
  if exit_code != 0 {
    return Err(
      credential_failure(
        @contracts.CREDENTIAL_REASON_PROXY_UNSUPPORTED,
        detail="security add-generic-password returned non-zero",
      ),
    )
  }
  Ok(())
}

///|
async fn credential_keychain_get(
  credential_id : String,
) -> Result[String, CredentialFailure] {
  let (exit_code, stdout, _stderr) = @process.collect_output("security", [
    "find-generic-password",
    "-a",
    "monexus",
    "-s",
    credential_keychain_service(credential_id),
    "-w",
  ]) catch {
    _ =>
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_LOCKED,
          detail="cannot read Keychain item",
        ),
      )
  }
  if exit_code != 0 {
    return Err(
      credential_failure(
        @contracts.CREDENTIAL_REASON_MISSING,
        detail="Keychain item is missing or locked",
      ),
    )
  }
  let secret = stdout.text() catch {
    _ =>
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_LOCKED,
          detail="Keychain output was not UTF-8",
        ),
      )
  }
  Ok(secret.trim().to_owned())
}

///|
async fn credential_keychain_delete(
  credential_id : String,
) -> Result[Unit, CredentialFailure] {
  let sink = credential_null_output()
  let exit_code = @process.run(
    "security",
    [
      "delete-generic-password",
      "-a",
      "monexus",
      "-s",
      credential_keychain_service(credential_id),
    ],
    stdout=sink,
    stderr=sink,
  ) catch {
    _ =>
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_LOCKED,
          detail="cannot delete Keychain item",
        ),
      )
  }
  if exit_code != 0 {
    return Err(
      credential_failure(
        @contracts.CREDENTIAL_REASON_MISSING,
        detail="Keychain item is already gone",
      ),
    )
  }
  Ok(())
}

///|
/// Persist a secret. The caller has already generated the `crd_` id and
/// version. Fails closed when the configured backend is unsupported.
pub async fn CredentialStore::put(
  self : CredentialStore,
  credential_id : String,
  kind : String,
  secret : String,
  version : Int32,
  created_at : String,
) -> Result[Unit, CredentialFailure] {
  match validate_credential_secret(secret) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if self.unsupported {
    return Err(
      credential_failure(
        @contracts.CREDENTIAL_REASON_PROXY_UNSUPPORTED,
        detail=self.detail,
      ),
    )
  }
  if self.backend == @contracts.CREDENTIAL_STORAGE_KEYCHAIN {
    return credential_keychain_put(credential_id, secret)
  }
  match self.credential_check_dir() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let path = self.credential_path(credential_id)
  let temp = path + ".new"
  let envelope = CredentialEnvelope::{
    format: "monexus.credential.v1",
    credential_id,
    kind,
    secret,
    version,
    created_at,
  }
  @fs.write_file(temp, envelope.to_json().stringify(), permission=0o600) catch {
    _ =>
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_LOCKED,
          detail="cannot write credential file",
        ),
      )
  }
  @fs.chmod(temp, 0o600) catch {
    _ => ()
  }
  @fs.rename(temp, path) catch {
    _ => {
      @fs.remove(temp) catch {
        _ => ()
      }
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_LOCKED,
          detail="cannot finalize credential file",
        ),
      )
    }
  }
  @fs.chmod(path, 0o600) catch {
    _ => ()
  }
  match self.credential_check_file(path) {
    Ok(_) => Ok(())
    Err(error) => Err(error)
  }
}

///|
/// Read a secret for the proxy. The store re-verifies permissions on every
/// read; a widened file is a hard failure and the proxy returns 503.
pub async fn CredentialStore::get(
  self : CredentialStore,
  credential_id : String,
) -> Result[String, CredentialFailure] {
  if self.unsupported {
    return Err(
      credential_failure(
        @contracts.CREDENTIAL_REASON_PROXY_UNSUPPORTED,
        detail=self.detail,
      ),
    )
  }
  if self.backend == @contracts.CREDENTIAL_STORAGE_KEYCHAIN {
    return credential_keychain_get(credential_id)
  }
  let path = self.credential_path(credential_id)
  match self.credential_check_file(path) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let data = @fs.read_file(path) catch {
    _ =>
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_MISSING,
          detail="cannot read credential file",
        ),
      )
  }
  let text = data.text() catch {
    _ =>
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_LOCKED,
          detail="credential file was not UTF-8",
        ),
      )
  }
  let json = @json.parse(text) catch {
    _ =>
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_LOCKED,
          detail="credential file is not valid JSON",
        ),
      )
  }
  let envelope = match CredentialEnvelope::from_json(json) {
    Some(value) => value
    None =>
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_LOCKED,
          detail="credential file has an unsupported format",
        ),
      )
  }
  if envelope.credential_id != credential_id {
    return Err(
      credential_failure(
        @contracts.CREDENTIAL_REASON_LOCKED,
        detail="credential file id does not match its name",
      ),
    )
  }
  Ok(envelope.secret)
}

///|
/// Destroy the stored secret. Deleting an already-absent item succeeds so a
/// retried revoke is idempotent; the caller records the metadata state.
pub async fn CredentialStore::delete(
  self : CredentialStore,
  credential_id : String,
) -> Result[Unit, CredentialFailure] {
  if self.unsupported {
    return Ok(())
  }
  if self.backend == @contracts.CREDENTIAL_STORAGE_KEYCHAIN {
    match credential_keychain_delete(credential_id) {
      Ok(_) => return Ok(())
      Err(error) =>
        if error.reason == @contracts.CREDENTIAL_REASON_MISSING {
          return Ok(())
        } else {
          return Err(error)
        }
    }
  }
  let path = self.credential_path(credential_id)
  let present = @fs.exists(path) catch { _ => false }
  if present {
    @fs.remove(path) catch {
      _ =>
        return Err(
          credential_failure(
            @contracts.CREDENTIAL_REASON_LOCKED,
            detail="cannot delete credential file",
          ),
        )
    }
  }
  Ok(())
}

///|
/// Check that the file/directory permission invariants hold. The doctor uses
/// this instead of a "best effort" claim.
pub async fn CredentialStore::check(
  self : CredentialStore,
) -> Result[Unit, CredentialFailure] {
  if self.unsupported {
    return Err(
      credential_failure(
        @contracts.CREDENTIAL_REASON_PROXY_UNSUPPORTED,
        detail=self.detail,
      ),
    )
  }
  if self.backend == @contracts.CREDENTIAL_STORAGE_KEYCHAIN {
    if !platform_is_macos() {
      return Err(
        credential_failure(
          @contracts.CREDENTIAL_REASON_PROXY_UNSUPPORTED,
          detail="Keychain is unavailable on this platform",
        ),
      )
    }
    return Ok(())
  }
  self.credential_check_dir()
}
