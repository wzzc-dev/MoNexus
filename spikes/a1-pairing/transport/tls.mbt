///|
/// Loopback TLS listener/client helpers.
///
/// The listener binds `127.0.0.1:0` (ephemeral port) and only accepts TLS.
/// The client requires `host="localhost"`, a pinned CA PEM and a pinned leaf
/// SHA-256 fingerprint. The CA pin makes an unrelated CA fail the handshake;
/// the leaf pin makes a swapped-but-trusted certificate fail before any
/// JSON-RPC payload is written.

///|
pub async fn tls_listen_localhost() -> @socket.TcpServer raise {
  @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
}

///|
/// Note: `@tls.Tls::close` frees the TLS context but does not close the
/// underlying `Tcp`; callers must close both (or use `close_stream`).
pub async fn accept_tls(
  server : @socket.TcpServer,
  pki : TestPki,
) -> (@tls.Tls, @socket.Tcp, @socket.Addr) raise {
  let (tcp, peer) = server.accept()
  errdefer tcp.close()
  let tls = @tls.Tls::server(
    tcp,
    private_key_file=pki.server_key,
    private_key_type=@tls.X509FileType::PEM,
    certificate_file=pki.server_cert,
    certificate_type=@tls.X509FileType::PEM,
  )
  (tls, tcp, peer)
}

///|
pub fn close_stream(tls : @tls.Tls, tcp : @socket.Tcp) -> Unit {
  tls.close()
  tcp.close()
}

///|
/// Connect to a loopback TLS endpoint and enforce both pinning layers. On any
/// failure the TLS stream is closed and the error is raised; there is no
/// fallback transport.
pub async fn connect_pinned(
  port : Int32,
  ca_cert : String,
  expected_fingerprint_sha256 : String,
) -> (@tls.Tls, @socket.Tcp) raise {
  let addr = @socket.Addr::parse("127.0.0.1:\{port}")
  let tcp = @socket.Tcp::connect(addr)
  errdefer tcp.close()
  let tls = @tls.Tls::client(
    tcp,
    host="localhost",
    trust=@tls.TrustedRoot::CustomPemFile(ca_cert),
  )
  match verify_pin(tls, expected_fingerprint_sha256) {
    Ok(_) => (tls, tcp)
    Err(message) => {
      tls.close()
      raise Failure::Failure(message)
    }
  }
}
