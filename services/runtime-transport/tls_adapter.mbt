///|
/// Pinned TLS listener/client adapter.
///
/// This is the *only* file that touches the upstream TLS server entry point,
/// and the only place that calls upstream APIs marked `#internal`. See
/// `docs/runtime-transport.md` §"Upstream gap" for the status:
///
/// - `moonbitlang/async@0.22.7` (pinned) exposes `Tls::server` /
///   `Tls::server_from_pair` publicly in the generated `.mbti`, but the source
///   is annotated `#internal(internal, "do not use, for internal testing
///   only")`. It is not an upstream production commitment.
/// - There is no public TLS server API in any published async version up to
///   0.22.10 (checked 2026-11-26), and no WSS server.
/// - A thin owned OpenSSL FFI would have to reimplement the record layer,
///   hostname verification and error mapping; that is a new cryptographic
///   transport surface, not a thin wrapper, and is out of scope for this
///   slice. We therefore isolate the internal call here, pin the dependency
///   major/minor exactly in moon.mod, and fail closed everywhere the API does
///   not exist (Windows native, wasm, non-native).
///
/// The upstream server context is a process-wide singleton: every
/// `Tls::server` call reconfigures `SSL_CTX_use_certificate_file` on the same
/// context. Concurrent server handshakes with different certificates race
/// inside OpenSSL, which is the flake recorded against the A1.0 spike. All
/// server handshakes in this process are serialized through one async mutex
/// and bounded by a handshake timeout. This adapter is not safe to use from
/// multiple threads; the MoonBit async runtime is single-threaded.

///|
let server_handshake_lock : Lazy[@async.Mutex] = Lazy(() => @async.Mutex::Mutex())

///|
pub(all) struct TlsServerConfig {
  bind_host : String
  bind_port : Int32
  certificate_file : String
  private_key_file : String
  handshake_timeout_ms : Int64
}

///|
pub fn TlsServerConfig::new(
  bind_host~ : String,
  bind_port~ : Int32,
  certificate_file~ : String,
  private_key_file~ : String,
  handshake_timeout_ms~ : Int64 = 10_000L,
) -> TlsServerConfig {
  {
    bind_host,
    bind_port,
    certificate_file,
    private_key_file,
    handshake_timeout_ms,
  }
}

///|
pub(all) struct TlsClientConfig {
  host : String
  port : Int32
  ca_certificate_file : String
  expected_leaf_sha256 : String
  server_name : String
}

///|
pub fn TlsClientConfig::new(
  host~ : String,
  port~ : Int32,
  ca_certificate_file~ : String,
  expected_leaf_sha256~ : String,
  server_name~ : String = "localhost",
) -> TlsClientConfig {
  { host, port, ca_certificate_file, expected_leaf_sha256, server_name }
}

///|
/// A TLS stream plus the underlying TCP socket. Both must be closed; the
/// upstream `Tls::close` does not close the socket.
pub struct TlsStream {
  tls : @tls.Tls
  tcp : @socket.Tcp
  peer : String
}

///|
pub fn TlsStream::close(self : TlsStream) -> Unit {
  self.tls.close()
  self.tcp.close()
}

///|
/// Peer address text for rate limiting. It is the loopback/remote socket
/// address, never a credential.
pub fn TlsStream::peer(self : TlsStream) -> String {
  self.peer
}

///|
pub async fn TlsStream::write(self : TlsStream, frame : @json.Json) -> Unit raise {
  write_frame(self.tls, frame)
}

///|
pub async fn TlsStream::read(self : TlsStream) -> @json.Json raise {
  read_frame(self.tls)
}

///|
/// A listening TLS endpoint. Only TLS is accepted; there is no plaintext
/// accept path in this package.
pub struct ServerListener {
  server : @socket.TcpServer
  config : TlsServerConfig
}

///|
/// Validate that a configured certificate/key file exists, is a regular file
/// and is not accessible by group or other. Fails closed instead of silently
/// chmod'ing operator-supplied files.
pub fn validate_secret_file(path : String, label : String) -> Result[Unit, String] {
  match stat_path(path) {
    None => Err(label + " is missing or cannot be stat'ed")
    Some(info) =>
      match info.kind {
        Regular =>
          if is_private_mode(info.mode) {
            Ok(())
          } else {
            Err(
              label +
              " must not be accessible by group or other (found mode " +
              mode_text(info.mode) + ")",
            )
          }
        _ => Err(label + " is not a regular file")
      }
  }
}

///|
/// Validate a state/configuration directory: must exist and not be group or
/// other accessible.
pub fn validate_private_dir(path : String, label : String) -> Result[Unit, String] {
  match stat_path(path) {
    None => Err(label + " is missing")
    Some(info) =>
      match info.kind {
        Directory =>
          if mode_is_directory_traversable_only(info.mode) {
            Ok(())
          } else {
            Err(
              label +
              " must be 0700 (found mode " + mode_text(info.mode) + ")",
            )
          }
        _ => Err(label + " is not a directory")
      }
  }
}

///|
/// Bind the configured endpoint after validating certificate/key isolation.
pub async fn TlsServerConfig::listen(
  self : TlsServerConfig,
) -> Result[ServerListener, String] {
  match validate_secret_file(self.certificate_file, "certificate file") {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  match validate_secret_file(self.private_key_file, "private key file") {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  let addr = @socket.Addr::parse(
    self.bind_host + ":" + self.bind_port.to_string(),
  ) catch {
    error => return Err("invalid bind address: " + error.to_string())
  }
  let server = @socket.TcpServer(addr) catch {
    error => return Err("cannot bind TLS endpoint: " + error.to_string())
  }
  Ok({ server, config: self })
}

///|
pub fn ServerListener::port(self : ServerListener) -> Int32 {
  self.server.addr().port()
}

///|
pub fn ServerListener::close(self : ServerListener) -> Unit {
  self.server.close()
}

///|
/// Accept one TCP connection and finish the TLS handshake. The handshake is
/// serialized (upstream shared `SSL_CTX`) and bounded by the configured
/// timeout. The returned peer string is the source key for rate limiting.
pub async fn ServerListener::accept(
  self : ServerListener,
) -> Result[TlsStream, String] {
  let (tcp, peer) = match self.accept_tcp() {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  self.finish_handshake(tcp, peer)
}

///|
/// Accept one TCP connection without a TLS handshake. Kept separate from
/// `finish_handshake` so a caller can poll the cheap accept on a timeout and
/// still run the handshake unbounded by that poll (the handshake has its own
/// timeout). `@socket.TcpServer::close()` does not wake a parked `accept()` in
/// async 0.22.7, so `PrimaryServer::run` relies on this split for shutdown.
async fn ServerListener::accept_tcp(
  self : ServerListener,
) -> Result[(@socket.Tcp, String), String] {
  let (tcp, peer) = self.server.accept() catch {
    error => return Err("accept failed: " + error.to_string())
  }
  Ok((tcp, peer.to_string()))
}

///|
/// Finish the TLS handshake for an accepted TCP connection. Serialized because
/// the upstream server context is a process-wide singleton, and bounded by the
/// configured handshake timeout. Always closes the TCP connection on failure.
async fn ServerListener::finish_handshake(
  self : ServerListener,
  tcp : @socket.Tcp,
  peer : String,
) -> Result[TlsStream, String] {
  let result = @async.with_timeout_opt(
    self.config.handshake_timeout_ms.to_int(),
    () => tls_server_handshake(tcp, self.config),
  )
  match result {
    None => {
      tcp.close()
      Err("TLS handshake timed out")
    }
    Some(Ok(tls)) => Ok({ tls, tcp, peer })
    Some(Err(message)) => {
      tcp.close()
      Err(message)
    }
  }
}

///|
/// The single upstream internal call site. `Tls::server` is annotated
/// testing-only upstream; see the file header. It is compiled only on
/// non-Windows native targets. On Windows the function exists but always
/// fails, so the package still builds and doctor reports unsupported.
#cfg(not(platform="windows"))
async fn tls_server_handshake(
  tcp : @socket.Tcp,
  config : TlsServerConfig,
) -> Result[@tls.Tls, String] {
  let lock = server_handshake_lock.force()
  lock.acquire()
  defer lock.release()
  let tls = @tls.Tls::server(
    tcp,
    private_key_file=config.private_key_file,
    private_key_type=@tls.X509FileType::PEM,
    certificate_file=config.certificate_file,
    certificate_type=@tls.X509FileType::PEM,
  ) catch {
    error => return Err("TLS server handshake failed: " + error.to_string())
  }
  Ok(tls)
}

///|
#cfg(platform="windows")
async fn tls_server_handshake(
  tcp : @socket.Tcp,
  config : TlsServerConfig,
) -> Result[@tls.Tls, String] {
  let _ = (tcp, config)
  Err("TLS server is not supported on this platform")
}

///|
/// Connect and enforce both pinning layers:
/// 1. `TrustedRoot::CustomPemFile` pins the CA so an unrelated CA cannot
///    complete the handshake at all;
/// 2. `get_peer_certificate` + SHA-256 comparison pins the leaf so a
///    swapped-but-trusted certificate fails before any payload.
///
/// Any failure closes the stream and returns an error. There is no fallback to
/// the system trust store and no plaintext path.
pub async fn TlsClientConfig::connect_pinned(
  self : TlsClientConfig,
) -> Result[TlsStream, String] {
  if !is_hex_of_length(self.expected_leaf_sha256, 64) {
    return Err("pinned certificate fingerprint must be 64 hex characters")
  }
  match stat_path(self.ca_certificate_file) {
    Some(info) =>
      match info.kind {
        Regular => ()
        _ => return Err("pinned CA file is not a regular file")
      }
    None => return Err("pinned CA file is missing")
  }
  let addr = @socket.Addr::parse(
    self.host + ":" + self.port.to_string(),
  ) catch {
    error => return Err("invalid server address: " + error.to_string())
  }
  let tcp = @socket.Tcp::connect(addr) catch {
    error => return Err("cannot connect: " + error.to_string())
  }
  let tls = @tls.Tls::client(
    tcp,
    host=self.server_name,
    trust=@tls.TrustedRoot::CustomPemFile(self.ca_certificate_file),
  ) catch {
    error => {
      tcp.close()
      return Err("pinned TLS handshake failed: " + error.to_string())
    }
  }
  match verify_peer_pin(tls, self.expected_leaf_sha256) {
    Ok(_) => Ok({ tls, tcp, peer: addr.to_string() })
    Err(message) => {
      tls.close()
      tcp.close()
      Err(message)
    }
  }
}

///|
/// Compare the peer leaf certificate's SHA-256 with the pinned value. Fails
/// closed when no certificate is presented or the value is malformed.
pub fn verify_peer_pin(
  tls : @tls.Tls,
  expected_sha256_hex : String,
) -> Result[Unit, String] {
  if !is_hex_of_length(expected_sha256_hex, 64) {
    return Err("pinned certificate fingerprint must be 64 hex characters")
  }
  // `get_peer_certificate` raises on OpenSSL failure; that is treated as a
  // closed connection, never as a successful pin.
  let certificate = tls.get_peer_certificate() catch {
    _ => return Err("cannot read peer certificate")
  }
  let der = match certificate {
    Some(value) => value
    None => return Err("peer presented no certificate")
  }
  let actual = certificate_fingerprint(der.exact_view())
  if constant_time_hex_eq(actual, expected_sha256_hex) {
    Ok(())
  } else {
    Err("certificate pin mismatch")
  }
}

///|
pub(all) struct DoctorReport {
  supported : Bool
  platform : String
  tls_server_api : String
  openssl_available : Bool
  notes : Array[String]
  problems : Array[String]
}

///|
pub fn DoctorReport::to_json(self : DoctorReport) -> @json.Json {
  @contracts.json_object([
    ("supported", @contracts.json_bool(self.supported)),
    ("platform", @contracts.json_string(self.platform)),
    ("tls_server_api", @contracts.json_string(self.tls_server_api)),
    ("openssl_available", @contracts.json_bool(self.openssl_available)),
    (
      "notes",
      @json.Json::array(
        self.notes.map(note => @contracts.json_string(note)),
      ),
    ),
    (
      "problems",
      @json.Json::array(
        self.problems.map(problem => @contracts.json_string(problem)),
      ),
    ),
  ])
}

///|
/// Runtime doctor. Fails closed: any platform without a usable TLS server
/// implementation reports `supported=false`, and a caller must not start the
/// listener in that case.
pub async fn doctor() -> DoctorReport {
  let notes : Array[String] = [
    "TLS server entry point is upstream #internal(testing-only) in moonbitlang/async " +
    "0.22.7; it is isolated behind tls_adapter.mbt and the dependency is pinned.",
    "Frame transport is pinned TLS + 4-byte big-endian length prefix; WSS and plaintext are not implemented.",
  ]
  let problems : Array[String] = []
  let openssl_available = openssl_probe()
  if !platform_supported() {
    problems.push(
      "this platform has no supported PEM TLS server entry point in this slice",
    )
  }
  if !openssl_available {
    problems.push("OpenSSL could not be loaded or its RAND source failed")
  }
  let supported = platform_supported() && openssl_available
  {
    supported,
    platform: platform_name(),
    tls_server_api: "moonbitlang/async@0.22.7 Tls::server (#internal, testing-only)",
    openssl_available,
    notes,
    problems,
  }
}

///|
pub fn doctor_supported() -> Bool {
  platform_supported() && openssl_probe()
}

///|
#cfg(not(platform="windows"))
pub fn platform_name() -> String {
  "native-unix-openssl"
}

///|
#cfg(platform="windows")
pub fn platform_name() -> String {
  "native-windows-schannel"
}

///|
#cfg(not(platform="windows"))
pub fn platform_supported() -> Bool {
  true
}

///|
#cfg(platform="windows")
pub fn platform_supported() -> Bool {
  false
}

///|
/// Probe OpenSSL availability via the same loader the TLS package uses.
/// `rand_bytes` is also marked internal upstream; keeping the probe next to
/// the server call site means the internal surface stays in one file.
#cfg(not(platform="windows"))
pub fn openssl_probe() -> Bool {
  let _ = @tls.rand_bytes(1) catch { _ => return false }
  true
}

///|
#cfg(platform="windows")
pub fn openssl_probe() -> Bool {
  false
}
