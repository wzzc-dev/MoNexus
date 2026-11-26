///|
/// A5.0 storage tests: the file backend is 0700/0600, a widened file or
/// directory is a hard failure, secrets round-trip, and the unsupported
/// Keychain path fails closed on non-macOS hosts.

///|
async fn credential_store_test_root(prefix : String) -> String {
  @fs.tmpdir(prefix~) catch {
    _ => fail("cannot create a temporary credential store root")
  }
}

///|
async fn credential_store_test_cleanup(root : String) -> Unit {
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "file store is 0700/0600 and refuses a widened file" {
  let root = credential_store_test_root("monexus-cred-store")
  defer credential_store_test_cleanup(root)
  let store = CredentialStore::open(root + "/credentials", requested="file")
  assert_eq(store.backend, @contracts.CREDENTIAL_STORAGE_FILE)
  assert_true(!store.unsupported)
  let secret = "sk-test-secret-value-0123456789"
  match
    store.put(
      "crd_store_test",
      @contracts.CREDENTIAL_KIND_API_KEY,
      secret,
      1,
      "2026-01-01T00:00:00.000Z",
    ) {
    Ok(_) => ()
    Err(failure) => fail("put failed: " + failure.message())
  }
  let dir_mode = match credential_mode(root + "/credentials") {
    Ok(value) => value
    Err(failure) => fail("cannot stat credential dir: " + failure.message())
  }
  assert_eq(dir_mode & 0o077, 0)
  let file_path = root + "/credentials/crd_store_test.json"
  let file_mode = match credential_mode(file_path) {
    Ok(value) => value
    Err(failure) => fail("cannot stat credential file: " + failure.message())
  }
  assert_eq(file_mode & 0o077, 0)
  match store.get("crd_store_test") {
    Ok(value) => assert_eq(value, secret)
    Err(failure) => fail("get failed: " + failure.message())
  }
  // Widening the secret file is detected on the next read, not ignored.
  @fs.chmod(file_path, 0o644) catch {
    _ => fail("cannot widen the test file")
  }
  match store.get("crd_store_test") {
    Ok(_) => fail("a widened credential file must be refused")
    Err(failure) =>
      assert_eq(failure.reason, @contracts.CREDENTIAL_REASON_STORE_PERMISSIONS)
  }
  // Widening the directory is also a hard failure.
  @fs.chmod(file_path, 0o600) catch {
    _ => ()
  }
  @fs.chmod(root + "/credentials", 0o755) catch {
    _ => ()
  }
  match store.check() {
    Ok(_) => fail("a widened credential directory must be refused")
    Err(failure) =>
      assert_eq(failure.reason, @contracts.CREDENTIAL_REASON_STORE_PERMISSIONS)
  }
  // delete is idempotent; the secret is gone afterwards.
  @fs.chmod(root + "/credentials", 0o700) catch {
    _ => ()
  }
  match store.delete("crd_store_test") {
    Ok(_) => ()
    Err(failure) => fail("delete failed: " + failure.message())
  }
  match store.delete("crd_store_test") {
    Ok(_) => ()
    Err(failure) =>
      fail("repeated delete must be a no-op: " + failure.message())
  }
  match store.get("crd_store_test") {
    Ok(_) => fail("deleted secret is still readable")
    Err(_) => ()
  }
}

///|
async test "file store rejects invalid secret shapes without writing" {
  let root = credential_store_test_root("monexus-cred-store-invalid")
  defer credential_store_test_cleanup(root)
  let store = CredentialStore::open(root + "/credentials", requested="file")
  match
    store.put(
      "crd_empty",
      @contracts.CREDENTIAL_KIND_API_KEY,
      "",
      1,
      "2026-01-01T00:00:00.000Z",
    ) {
    Ok(_) => fail("an empty secret must be refused")
    Err(failure) =>
      assert_eq(failure.reason, @contracts.CREDENTIAL_REASON_SECRET_REQUIRED)
  }
  match
    store.put(
      "crd_multiline",
      @contracts.CREDENTIAL_KIND_API_KEY,
      "sk-one\nsk-two",
      1,
      "2026-01-01T00:00:00.000Z",
    ) {
    Ok(_) => fail("a multi-line secret must be refused")
    Err(failure) =>
      assert_eq(failure.reason, @contracts.CREDENTIAL_REASON_SECRET_INVALID)
  }
  match validate_credential_secret("ok-single-line") {
    Ok(_) => ()
    Err(failure) => fail("valid secret refused: " + failure.message())
  }
}

///|
async test "unsupported storage fails closed" {
  let root = credential_store_test_root("monexus-cred-store-unsupported")
  defer credential_store_test_cleanup(root)
  let unknown = CredentialStore::open(root + "/credentials", requested="vault")
  assert_true(unknown.unsupported)
  match
    unknown.put(
      "crd_unsupported",
      @contracts.CREDENTIAL_KIND_API_KEY,
      "sk-test",
      1,
      "2026-01-01T00:00:00.000Z",
    ) {
    Ok(_) => fail("an unsupported backend must not accept a secret")
    Err(failure) =>
      assert_eq(failure.reason, @contracts.CREDENTIAL_REASON_PROXY_UNSUPPORTED)
  }
  if !platform_is_macos() {
    let keychain = CredentialStore::open(
      root + "/keychain",
      requested=@contracts.CREDENTIAL_STORAGE_KEYCHAIN,
    )
    assert_true(keychain.unsupported)
    assert_eq(keychain.backend, @contracts.CREDENTIAL_STORAGE_UNSUPPORTED)
  }
}
