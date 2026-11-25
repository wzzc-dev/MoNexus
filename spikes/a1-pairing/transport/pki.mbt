///|
/// Test-only PKI generation for the loopback TLS tests.
///
/// Certificates are generated with the local `openssl` CLI into a fresh
/// `@fs.tmpdir` directory created for the test run. Nothing touches the user's
/// home directory, `~/.ssh`, the repository, or the system trust store. The
/// directory is removed by `TestPki::cleanup`, which tests call from `defer`.
///
/// Keys are ephemeral and test-only; they are never printed or persisted
/// outside the temporary directory.

///|
pub(all) struct TestPki {
  dir : String
  ca_cert : String
  server_cert : String
  server_key : String
  other_ca_cert : String
  leaf_fingerprint_sha256 : String
}

///|
async fn openssl(args : Array[String]) -> Unit raise {
  let (code, stdout, stderr) = @process.collect_output("openssl", args)
  let _ = stdout
  if code != 0 {
    let detail = @utf8.decode_lossy(stderr.binary().exact_view())
    raise Failure::Failure("openssl failed (\{code}): " + detail)
  }
}

///|
async fn write_text(path : String, text : String) -> Unit raise {
  @fs.write_file(path, text)
}

///|
async fn generate_ca(dir : String, stem : String, subject : String) -> Unit raise {
  let key = dir + "/" + stem + ".key"
  let cert = dir + "/" + stem + ".pem"
  openssl([
    "ecparam",
    "-name",
    "prime256v1",
    "-genkey",
    "-noout",
    "-out",
    key,
  ])
  openssl([
    "req",
    "-x509",
    "-new",
    "-key",
    key,
    "-sha256",
    "-days",
    "1",
    "-subj",
    subject,
    "-out",
    cert,
  ])
}

///|
async fn leaf_fingerprint(dir : String) -> String raise {
  let der_path = dir + "/server.der"
  openssl(["x509", "-in", dir + "/server.pem", "-outform", "der", "-out", der_path])
  let der = @fs.read_file(der_path).binary()
  @protocol.sha256_hex(der.exact_view())
}

///|
/// Generate a throwaway CA + `DNS:localhost` leaf plus an unrelated CA that is
/// used to prove untrusted-CA rejection. The leaf is valid for `localhost`
/// only, matching `host="localhost"` in the pinned client.
pub async fn generate_test_pki() -> TestPki raise {
  let dir = @fs.tmpdir(prefix="@monexus-a1-pki")
  generate_ca(dir, "ca", "/CN=MoNexus A1 Test CA")
  generate_ca(dir, "other-ca", "/CN=MoNexus A1 Other Test CA")
  let server_key = dir + "/server.key"
  let server_csr = dir + "/server.csr"
  let ext = dir + "/server.ext"
  openssl([
    "ecparam",
    "-name",
    "prime256v1",
    "-genkey",
    "-noout",
    "-out",
    server_key,
  ])
  openssl([
    "req",
    "-new",
    "-key",
    server_key,
    "-subj",
    "/CN=localhost",
    "-out",
    server_csr,
  ])
  write_text(
    ext,
    "subjectAltName=DNS:localhost\n" +
    "basicConstraints=CA:FALSE\n" +
    "keyUsage=digitalSignature,keyEncipherment\n" +
    "extendedKeyUsage=serverAuth\n",
  )
  openssl([
    "x509",
    "-req",
    "-in",
    server_csr,
    "-CA",
    dir + "/ca.pem",
    "-CAkey",
    dir + "/ca.key",
    "-CAcreateserial",
    "-days",
    "1",
    "-sha256",
    "-extfile",
    ext,
    "-out",
    dir + "/server.pem",
  ])
  let fingerprint = leaf_fingerprint(dir)
  {
    dir,
    ca_cert: dir + "/ca.pem",
    server_cert: dir + "/server.pem",
    server_key,
    other_ca_cert: dir + "/other-ca.pem",
    leaf_fingerprint_sha256: fingerprint,
  }
}

///|
/// Remove the whole temporary directory, including private keys.
pub async fn TestPki::cleanup(self : TestPki) -> Unit {
  @fs.rmdir(self.dir, recursive=true)
}
