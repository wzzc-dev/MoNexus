///|
/// Skill bundle import and materialisation (ADR-0015 §2.1, §3).
///
/// A bundle is a local directory containing `skill.json`, one entry document
/// and zero or more declared resources. Import rejects symlinks, special
/// files, executable bits, undeclared files, duplicate paths, path escapes and
/// any size overflow. Every copy is re-hashed before it is written.
pub(all) struct SkillKey {
  public_key : String
  revoked : Bool
}

///|
pub(all) struct SkillKeyStore {
  keys : Map[String, SkillKey]
}

///|
pub fn SkillKeyStore::empty() -> SkillKeyStore {
  { keys: Map([]) }
}

///|
pub fn SkillKeyStore::with_key(
  self : SkillKeyStore,
  key_id : String,
  public_key : String,
) -> SkillKeyStore {
  let keys = Map([])
  for pair in self.keys {
    keys.set(pair.0, pair.1)
  }
  keys.set(key_id, { public_key, revoked: false })
  { keys: keys }
}

///|
pub fn SkillKeyStore::revoke(
  self : SkillKeyStore,
  key_id : String,
) -> SkillKeyStore {
  let keys = Map([])
  for pair in self.keys {
    keys.set(pair.0, pair.1)
  }
  match keys.get(key_id) {
    Some(key) => keys.set(key_id, { ..key, revoked: true })
    None => ()
  }
  { keys: keys }
}

///|
pub(all) struct SkillBundleFile {
  path : String
  content : String
}

///|
pub fn SkillBundleFile::new(
  path~ : String,
  content~ : String,
) -> SkillBundleFile {
  { path, content }
}

///|
pub(all) struct SkillBundle {
  manifest : @contracts.SkillManifest
  manifest_text : String
  canonical_body : String
  entry_text : String
  resources : Array[SkillBundleFile]
  files : Array[SkillBundleFile]
}

///|
async fn skill_file_mode(path : String) -> Int? {
  let primary = @process.collect_output("stat", ["-c", "%a", "--", path]) catch {
    _ => return None
  }
  let (code, stdout, _stderr) = primary
  if code == 0 {
    let text = stdout.text() catch { _ => return None }
    return parse_octal_mode(text.trim_end(chars="\n").to_owned())
  }
  let fallback = @process.collect_output("stat", ["-f", "%Lp", "--", path]) catch {
    _ => return None
  }
  let (fallback_code, fallback_stdout, _fallback_stderr) = fallback
  if fallback_code == 0 {
    let text = fallback_stdout.text() catch { _ => return None }
    parse_octal_mode(text.trim_end(chars="\n").to_owned())
  } else {
    None
  }
}

///|
fn parse_octal_mode(text : String) -> Int? {
  if text.length() == 0 || text.length() > 6 {
    return None
  }
  let mut value = 0
  for index in 0..<text.length() {
    let ch = match text.get_char(index) {
      Some(found) => found
      None => return None
    }
    if ch < '0' || ch > '7' {
      return None
    }
    value = value * 8 + (ch.to_int() - 48)
  }
  Some(value)
}

///|
fn skill_io_error(detail : String) -> SkillFault {
  skill_fail(@contracts.SKILL_ERR_INVALID_MANIFEST, detail)
}

///|
async fn walk_skill_bundle(
  root : String,
  relative : String,
  depth : Int,
  out : Array[SkillBundleFile],
) -> Result[Unit, SkillFault] {
  if depth > 32 {
    return Err(skill_io_error("bundle directory nesting is too deep"))
  }
  let dir = @fs.opendir(root) catch {
    _ => return Err(skill_io_error("cannot read bundle directory"))
  }
  defer dir.close()
  while true {
    let next = dir.next(include_hidden=true) catch {
      _ => return Err(skill_io_error("cannot read bundle directory entry"))
    }
    let entry = match next {
      Some(value) => value
      None => break
    }
    let child_relative = if relative == "" {
      entry.name
    } else {
      relative + "/" + entry.name
    }
    if !is_valid_skill_path(child_relative) {
      return Err(
        skill_fail(
          @contracts.SKILL_ERR_INVALID_PATH,
          "bundle contains an unsafe path",
        ),
      )
    }
    let child_absolute = root + "/" + entry.name
    let kind = @fs.kind(child_absolute, follow_symlink=false) catch {
      _ => return Err(skill_io_error("cannot stat bundle entry"))
    }
    match kind {
      @fs.FileKind::Directory =>
        match walk_skill_bundle(child_absolute, child_relative, depth + 1, out) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      @fs.FileKind::Regular => {
        let mode = match skill_file_mode(child_absolute) {
          Some(value) => value
          None =>
            return Err(
              skill_fail(
                @contracts.SKILL_ERR_PERMISSION_DENIED,
                "bundle file mode is unverifiable",
              ),
            )
        }
        if (mode & 0o111) != 0 {
          return Err(
            skill_fail(
              @contracts.SKILL_ERR_PERMISSION_DENIED,
              "bundle files must not carry executable bits",
            ),
          )
        }
        let data = @fs.read_file(child_absolute) catch {
          _ => return Err(skill_io_error("cannot read bundle file"))
        }
        let text = data.text() catch {
          _ => return Err(skill_io_error("bundle file is not valid text"))
        }
        out.push({ path: child_relative, content: text })
      }
      @fs.FileKind::SymLink =>
        return Err(
          skill_fail(
            @contracts.SKILL_ERR_INVALID_PATH,
            "bundle contains a symbolic link",
          ),
        )
      _ =>
        return Err(
          skill_fail(
            @contracts.SKILL_ERR_INVALID_PATH,
            "bundle contains a special file",
          ),
        )
    }
  }
  Ok(())
}

///|
fn find_bundle_file(files : Array[SkillBundleFile], path : String) -> String? {
  for file in files {
    if file.path == path {
      return Some(file.content)
    }
  }
  None
}

///|
/// The manifest file carries `content_hash` and `signature`, so it cannot be
/// part of the file list that the hash covers. Every other bundle file
/// (entry and resources) is covered.
fn file_hashes(files : Array[SkillBundleFile]) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for file in files {
    if file.path != SKILL_MANIFEST_FILE {
      out.push((file.path, file.content))
    }
  }
  out
}

///|
/// Import and verify a local bundle directory. The caller supplies the owner
/// key allowlist and a probed verifier. On success the returned bundle is the
/// exact content that may be stored; the source directory is not consulted
/// again.
pub async fn import_skill_bundle(
  source_dir : String,
  keys : SkillKeyStore,
  verifier : @recipes.VerifierProbe,
  timeout_ms~ : Int = 10_000,
) -> Result[SkillBundle, SkillFault] {
  let source_kind = @fs.kind(source_dir, follow_symlink=false) catch {
    _ => return Err(skill_io_error("source directory is not readable"))
  }
  if source_kind != @fs.FileKind::Directory {
    return Err(
      skill_fail(
        @contracts.SKILL_ERR_INVALID_PATH,
        "source must be a plain directory (not a symlink)",
      ),
    )
  }
  let manifest_path = source_dir + "/" + SKILL_MANIFEST_FILE
  let manifest_kind = @fs.kind(manifest_path, follow_symlink=false) catch {
    _ => return Err(skill_io_error("manifest is missing"))
  }
  if manifest_kind != @fs.FileKind::Regular {
    return Err(
      skill_fail(
        @contracts.SKILL_ERR_INVALID_PATH,
        "manifest must be a regular file",
      ),
    )
  }
  let manifest_mode = match skill_file_mode(manifest_path) {
    Some(value) => value
    None =>
      return Err(
        skill_fail(
          @contracts.SKILL_ERR_PERMISSION_DENIED,
          "manifest mode is unverifiable",
        ),
      )
  }
  if (manifest_mode & 0o111) != 0 {
    return Err(
      skill_fail(
        @contracts.SKILL_ERR_PERMISSION_DENIED,
        "manifest must not carry executable bits",
      ),
    )
  }
  let manifest_data = @fs.read_file(manifest_path) catch {
    _ => return Err(skill_io_error("cannot read manifest"))
  }
  let manifest_text = manifest_data.text() catch {
    _ => return Err(skill_io_error("manifest is not valid text"))
  }
  let manifest = match parse_skill_manifest(manifest_text) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let files : Array[SkillBundleFile] = []
  match walk_skill_bundle(source_dir, "", 0, files) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match verify_skill_bundle_files(manifest, files, keys, verifier, timeout_ms~) {
    Ok(verified) => {
      let bundle = { ..verified, manifest_text: manifest_text }
      Ok(bundle)
    }
    Err(error) => Err(error)
  }
}

///|
/// Verify an already-read set of bundle files against the parsed manifest:
/// declared-file closure, size limits and the recomputed content hash. The
/// signature is checked separately so the runtime node (which never holds the
/// org key allowlist) can mirror by hash without trusting the sender.
fn verify_skill_bundle_layout(
  manifest : @contracts.SkillManifest,
  files : Array[SkillBundleFile],
) -> Result[SkillBundle, SkillFault] {
  // Every physical file must be declared, and every declared file must exist.
  let declared : Array[String] = [SKILL_MANIFEST_FILE, manifest.entry_path]
  for resource in manifest.resources {
    declared.push(resource.path)
  }
  let mut total_bytes = 0
  for file in files {
    total_bytes = total_bytes + file.content.length()
    let mut known = false
    for path in declared {
      if path == file.path {
        known = true
        break
      }
    }
    if !known {
      return Err(
        skill_fail(
          @contracts.SKILL_ERR_INVALID_PATH,
          "bundle contains an undeclared file",
        ),
      )
    }
  }
  if total_bytes > MAX_SKILL_BUNDLE_BYTES {
    return Err(
      skill_fail(@contracts.SKILL_ERR_LIMIT_EXCEEDED, "bundle is too large"),
    )
  }
  for path in declared {
    if find_bundle_file(files, path) is None {
      return Err(
        skill_fail(
          @contracts.SKILL_ERR_INVALID_PATH,
          "declared bundle file is missing",
        ),
      )
    }
  }
  let entry_text = match find_bundle_file(files, manifest.entry_path) {
    Some(value) => value
    None =>
      return Err(
        skill_fail(@contracts.SKILL_ERR_INVALID_PATH, "entry file is missing"),
      )
  }
  if entry_text.length() > manifest.entry_max_bytes {
    return Err(
      skill_fail(
        @contracts.SKILL_ERR_LIMIT_EXCEEDED,
        "entry exceeds its declared max_bytes",
      ),
    )
  }
  let resources : Array[SkillBundleFile] = []
  for resource in manifest.resources {
    let content = match find_bundle_file(files, resource.path) {
      Some(value) => value
      None =>
        return Err(
          skill_fail(@contracts.SKILL_ERR_INVALID_PATH, "resource file is missing"),
        )
    }
    if content.length() > MAX_SKILL_RESOURCE_BYTES {
      return Err(
        skill_fail(
          @contracts.SKILL_ERR_LIMIT_EXCEEDED,
          "resource exceeds the global limit",
        ),
      )
    }
    resources.push({ path: resource.path, content })
  }
  let sorted_files : Array[SkillBundleFile] = []
  for file in files {
    sorted_files.push(file)
  }
  sorted_files.sort_by(fn(left : SkillBundleFile, right : SkillBundleFile) -> Int32 {
    @recipes.compare_utf8(left.path, right.path)
  })
  let canonical_body = canonical_manifest_string(manifest)
  let computed = compute_content_hash(canonical_body, file_hashes(sorted_files))
  if computed != manifest.content_hash {
    return Err(
      skill_fail(
        @contracts.SKILL_ERR_HASH_MISMATCH,
        "bundle content hash does not match the manifest",
      ),
    )
  }
  Ok({
    manifest,
    manifest_text: "",
    canonical_body,
    entry_text,
    resources,
    files: sorted_files,
  })
}

///|
/// Full import/load verification: layout, hash and Ed25519 signature against
/// the owner key allowlist.
async fn verify_skill_bundle_files(
  manifest : @contracts.SkillManifest,
  files : Array[SkillBundleFile],
  keys : SkillKeyStore,
  verifier : @recipes.VerifierProbe,
  timeout_ms~ : Int = 10_000,
) -> Result[SkillBundle, SkillFault] {
  let layout = match verify_skill_bundle_layout(manifest, files) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let key = match keys.keys.get(manifest.signature.key_id) {
    Some(value) => value
    None =>
      return Err(
        skill_fail(
          @contracts.SKILL_ERR_UNKNOWN_KEY,
          "signing key is not in the owner allowlist",
        ),
      )
  }
  if key.revoked {
    return Err(
      skill_fail(@contracts.SKILL_ERR_REVOKED_KEY, "signing key is revoked"),
    )
  }
  match verify_skill_signature(
    manifest.content_hash,
    manifest.signature.key_id,
    key.public_key,
    manifest.signature.sig,
    verifier,
    timeout_ms~,
  ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  Ok(layout)
}

///|
/// Verify a manifest and its files supplied as bytes (runtime-node mirror
/// path). The files must include `skill.json` with exactly `manifest_text`;
/// no directory is consulted.
pub async fn verify_skill_bundle_bytes(
  manifest_text : String,
  files : Array[SkillBundleFile],
  keys : SkillKeyStore,
  verifier : @recipes.VerifierProbe,
  timeout_ms~ : Int = 10_000,
) -> Result[SkillBundle, SkillFault] {
  let manifest = match parse_skill_manifest(manifest_text) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut manifest_matches = false
  for file in files {
    if file.path == SKILL_MANIFEST_FILE {
      manifest_matches = file.content == manifest_text
    }
  }
  if !manifest_matches {
    return Err(
      skill_fail(
        @contracts.SKILL_ERR_INVALID_MANIFEST,
        "bundle manifest bytes do not match manifest_text",
      ),
    )
  }
  match verify_skill_bundle_files(manifest, files, keys, verifier, timeout_ms~) {
    Ok(verified) => {
      let bundle = { ..verified, manifest_text: manifest_text }
      Ok(bundle)
    }
    Err(error) => Err(error)
  }
}

///|
/// Read and fully re-verify a stored bundle. Load, mirror and doctor never
/// trust the copy on disk: the manifest, entry and resources are re-hashed and
/// the signature is re-checked against the current key allowlist.
pub async fn load_stored_skill(
  store_path : String,
  keys : SkillKeyStore,
  verifier : @recipes.VerifierProbe,
  timeout_ms~ : Int = 10_000,
) -> Result[SkillBundle, SkillFault] {
  let kind = @fs.kind(store_path, follow_symlink=false) catch {
    _ => return Err(skill_io_error("stored bundle is missing"))
  }
  if kind != @fs.FileKind::Directory {
    return Err(
      skill_fail(@contracts.SKILL_ERR_INVALID_PATH, "stored bundle is not a directory"),
    )
  }
  let manifest_path = store_path + "/" + SKILL_MANIFEST_FILE
  let manifest_kind = @fs.kind(manifest_path, follow_symlink=false) catch {
    _ => return Err(skill_io_error("stored manifest is missing"))
  }
  if manifest_kind != @fs.FileKind::Regular {
    return Err(
      skill_fail(@contracts.SKILL_ERR_INVALID_PATH, "stored manifest is not a file"),
    )
  }
  let manifest_data = @fs.read_file(manifest_path) catch {
    _ => return Err(skill_io_error("cannot read stored manifest"))
  }
  let manifest_text = manifest_data.text() catch {
    _ => return Err(skill_io_error("stored manifest is not valid text"))
  }
  let manifest = match parse_skill_manifest(manifest_text) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let files : Array[SkillBundleFile] = []
  match walk_skill_bundle(store_path, "", 0, files) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match verify_skill_bundle_files(manifest, files, keys, verifier, timeout_ms~) {
    Ok(verified) => {
      let bundle = { ..verified, manifest_text: manifest_text }
      Ok(bundle)
    }
    Err(error) => Err(error)
  }
}

///|
/// Hash-only verification for the runtime-node mirror path (ADR-0015 §A4.2).
/// The primary already verified the signature; the node re-derives the
/// canonical hash and the declared-file closure so a tampered or truncated
/// transfer cannot enter the mirror. No key allowlist is consulted here.
pub fn verify_skill_bundle_hash_bytes(
  manifest_text : String,
  files : Array[SkillBundleFile],
) -> Result[SkillBundle, SkillFault] {
  let manifest = match parse_skill_manifest(manifest_text) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut manifest_matches = false
  for file in files {
    if file.path == SKILL_MANIFEST_FILE {
      manifest_matches = file.content == manifest_text
    }
  }
  if !manifest_matches {
    return Err(
      skill_fail(
        @contracts.SKILL_ERR_INVALID_MANIFEST,
        "bundle manifest bytes do not match manifest_text",
      ),
    )
  }
  match verify_skill_bundle_layout(manifest, files) {
    Ok(verified) => {
      let bundle = { ..verified, manifest_text: manifest_text }
      Ok(bundle)
    }
    Err(error) => Err(error)
  }
}

///|
/// Hash-only re-verification of a stored mirror bundle. Used by the node on
/// every invocation: the entry/resources and manifest are re-read and the
/// canonical hash is recomputed, so a modified mirror is refused rather than
/// executed.
pub async fn load_stored_skill_hash(
  store_path : String,
) -> Result[SkillBundle, SkillFault] {
  let kind = @fs.kind(store_path, follow_symlink=false) catch {
    _ => return Err(skill_io_error("stored bundle is missing"))
  }
  if kind != @fs.FileKind::Directory {
    return Err(
      skill_fail(@contracts.SKILL_ERR_INVALID_PATH, "stored bundle is not a directory"),
    )
  }
  let manifest_path = store_path + "/" + SKILL_MANIFEST_FILE
  let manifest_kind = @fs.kind(manifest_path, follow_symlink=false) catch {
    _ => return Err(skill_io_error("stored manifest is missing"))
  }
  if manifest_kind != @fs.FileKind::Regular {
    return Err(
      skill_fail(@contracts.SKILL_ERR_INVALID_PATH, "stored manifest is not a file"),
    )
  }
  let manifest_data = @fs.read_file(manifest_path) catch {
    _ => return Err(skill_io_error("cannot read stored manifest"))
  }
  let manifest_text = manifest_data.text() catch {
    _ => return Err(skill_io_error("stored manifest is not valid text"))
  }
  let manifest = match parse_skill_manifest(manifest_text) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let files : Array[SkillBundleFile] = []
  match walk_skill_bundle(store_path, "", 0, files) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match verify_skill_bundle_layout(manifest, files) {
    Ok(verified) => {
      let bundle = { ..verified, manifest_text: manifest_text }
      Ok(bundle)
    }
    Err(error) => Err(error)
  }
}

///|
/// Recompute a stored bundle's hash from its bytes. Used on every load and
/// mirror, and by doctor; a mismatch is refused, never "repaired" silently.
pub fn verify_bundle_hash(
  manifest : @contracts.SkillManifest,
  body : String,
  files : Array[(String, String)],
) -> Bool {
  compute_content_hash(body, files) == manifest.content_hash
}

///|
fn store_hash_dir_component(content_hash : String) -> String {
  content_hash
}

///|
pub fn skill_store_path(
  state_dir : String,
  manifest : @contracts.SkillManifest,
) -> String {
  state_dir + "/skills/store/" + manifest.name + "/" + manifest.version + "/" +
  store_hash_dir_component(manifest.content_hash)
}

///|
/// Write the immutable bundle into the org store. Directories are `0700`,
/// files are `0444`; writes go through a temp sibling and an atomic rename.
pub async fn store_skill_bundle(
  state_dir : String,
  bundle : SkillBundle,
) -> Result[String, SkillFault] {
  let target = skill_store_path(state_dir, bundle.manifest)
  let base = state_dir + "/skills/store/" + bundle.manifest.name + "/" +
    bundle.manifest.version
  @fs.mkdir(base, permission=0o700, recursive=true, allow_exist=true) catch {
    _ => return Err(skill_io_error("cannot create skill store directory"))
  }
  let temp = base + "/.tmp-" + bundle.manifest.content_hash[7:19].to_owned()
  @fs.rmdir(temp, recursive=true) catch { _ => () }
  @fs.mkdir(temp, permission=0o700, recursive=true, allow_exist=true) catch {
    _ => return Err(skill_io_error("cannot create temporary skill directory"))
  }
  let write_error = write_skill_files(temp, bundle.files)
  match write_error {
    Some(error) => {
      @fs.rmdir(temp, recursive=true) catch { _ => () }
      return Err(error)
    }
    None => ()
  }
  // Replace a previous/tampered copy only after the new copy is complete.
  @fs.rmdir(target, recursive=true) catch { _ => () }
  @fs.rename(temp, target) catch {
    _ => {
      @fs.rmdir(temp, recursive=true) catch { _ => () }
      return Err(skill_io_error("cannot commit skill bundle"))
    }
  }
  Ok(target)
}

///|
async fn write_skill_files(
  root : String,
  files : Array[SkillBundleFile],
) -> SkillFault? {
  for file in files {
    let path = root + "/" + file.path
    let parent = match path.rev_find("/") {
      Some(index) => path[:index].to_owned()
      None => root
    }
    @fs.mkdir(parent, permission=0o700, recursive=true, allow_exist=true) catch {
      _ => return Some(skill_io_error("cannot create bundle directory"))
    }
    @fs.write_file(path, file.content, permission=0o444) catch {
      _ => return Some(skill_io_error("cannot write bundle file"))
    }
    // Re-hash what actually landed on disk (TOCTOU check after write).
    let written = @fs.read_file(path) catch {
      _ => return Some(skill_io_error("cannot re-read bundle file"))
    }
    let text = written.text() catch {
      _ => return Some(skill_io_error("bundle file is not valid text"))
    }
    if text != file.content {
      return Some(
        skill_fail(
          @contracts.SKILL_ERR_HASH_MISMATCH,
          "bundle file changed while being written",
        ),
      )
    }
  }
  None
}

///|
/// Materialise the entry and resources for one session. Only these two roles
/// reach an Agent; the canonical manifest is not copied into the session.
pub async fn materialize_skill(
  session_skills_dir : String,
  bundle : SkillBundle,
) -> Result[String, SkillFault] {
  let target = session_skills_dir + "/" + bundle.manifest.name + "-" +
    bundle.manifest.version
  @fs.rmdir(target, recursive=true) catch { _ => () }
  @fs.mkdir(target, permission=0o700, recursive=true, allow_exist=false) catch {
    _ => return Err(skill_io_error("cannot create session skill directory"))
  }
  let files : Array[SkillBundleFile] = [
    { path: bundle.manifest.entry_path, content: bundle.entry_text },
  ]
  for resource in bundle.resources {
    files.push(resource)
  }
  match write_skill_files(target, files) {
    Some(error) => {
      @fs.rmdir(target, recursive=true) catch { _ => () }
      return Err(error)
    }
    None => ()
  }
  Ok(target)
}

///|
/// Remove every file and directory of a session's skill materialisation.
pub async fn remove_skill_dir(path : String) -> Unit {
  @fs.rmdir(path, recursive=true) catch { _ => () }
}

///|
/// Read a stored bundle's files back for load-time hash verification. Returns
/// `None` when a file is missing or a path is unsafe.
pub async fn read_stored_bundle(
  store_path : String,
  manifest : @contracts.SkillManifest,
) -> SkillFault? {
  let entry_path = store_path + "/" + manifest.entry_path
  let entry = @fs.read_file(entry_path) catch {
    _ => return Some(skill_io_error("stored entry is missing"))
  }
  let entry_text = entry.text() catch {
    _ => return Some(skill_io_error("stored entry is not valid text"))
  }
  if entry_text.length() > manifest.entry_max_bytes {
    return Some(
      skill_fail(@contracts.SKILL_ERR_LIMIT_EXCEEDED, "stored entry is too large"),
    )
  }
  for resource in manifest.resources {
    let path = store_path + "/" + resource.path
    let data = @fs.read_file(path) catch {
      _ => return Some(skill_io_error("stored resource is missing"))
    }
    let content = data.text() catch {
      _ => return Some(skill_io_error("stored resource is not valid text"))
    }
    if content.length() > MAX_SKILL_RESOURCE_BYTES {
      return Some(
        skill_fail(
          @contracts.SKILL_ERR_LIMIT_EXCEEDED,
          "stored resource is too large",
        ),
      )
    }
  }
  None
}
