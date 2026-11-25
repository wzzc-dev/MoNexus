///|
/// End-to-end harness: a primary serving JSON-RPC over pinned loopback TLS,
/// and a node client that speaks the same frames. Time comes from
/// `@async.now()`; entropy comes from `@tls.rand_bytes`, the same CSPRNG the
/// production transport would use. Nothing here reads user secrets or opens a
/// non-loopback socket.

///|
/// Accept one TLS connection and answer exactly `count` requests through the
/// protocol dispatcher. The connection is closed when the frames are done.
pub async fn serve_frames(
  server : @socket.TcpServer,
  pki : @transport.TestPki,
  state : @protocol.PrimaryState,
  count : Int,
) -> Unit raise {
  let (tls, tcp, _) = @transport.accept_tls(server, pki)
  defer @transport.close_stream(tls, tcp)
  for _ in 0..<count {
    let frame = @transport.read_frame(tls)
    let request = match @contracts.parse_request(frame) {
      Ok(value) => value
      Err(message) => raise Failure::Failure("bad request: " + message)
    }
    let response = state.dispatch(request, @async.now(), @tls.rand_bytes(48))
    @transport.write_frame(tls, response.to_json())
  }
}

///|
pub async fn rpc(
  tls : @tls.Tls,
  id : String,
  method : String,
  params : Map[String, @json.Json],
) -> @contracts.RpcResponse raise {
  let request = @contracts.RpcRequest::new(id, method, params)
  @transport.write_frame(tls, request.to_json())
  let reply = @transport.read_frame(tls)
  match @contracts.parse_response(reply) {
    Ok(value) => value
    Err(message) => raise Failure::Failure("bad response: " + message)
  }
}

///|
pub async fn hmac_auth(
  tls : @tls.Tls,
  id_prefix : String,
  runtime_id : String,
  credential_id : String,
  credential : String,
  nonce : String,
) -> @protocol.SessionGrant raise {
  let challenge_json = expect_result(
    rpc(
      tls,
      id_prefix + "-challenge",
      @protocol.METHOD_RUNTIME_CHALLENGE,
      @protocol.challenge_params(
        id_prefix + "-challenge",
        runtime_id,
        credential_id,
      ),
    ),
  )
  let challenge = match @protocol.parse_challenge(challenge_json) {
    Some(value) => value
    None => raise Failure::Failure("challenge did not parse")
  }
  let mac = match
    @protocol.auth_mac(
      credential,
      runtime_id,
      challenge.challenge_id,
      challenge.challenge,
      nonce,
    ) {
    Ok(value) => value
    Err(message) => raise Failure::Failure(message)
  }
  let session_json = expect_result(
    rpc(
      tls,
      id_prefix + "-authenticate",
      @protocol.METHOD_RUNTIME_AUTHENTICATE,
      @protocol.authenticate_params(
        id_prefix + "-authenticate",
        challenge.challenge_id,
        mac,
        nonce,
      ),
    ),
  )
  match @protocol.parse_session_grant(session_json) {
    Some(value) => value
    None => raise Failure::Failure("session grant did not parse")
  }
}

///|
pub async fn bearer_auth(
  tls : @tls.Tls,
  id_prefix : String,
  runtime_id : String,
  credential_id : String,
  credential : String,
  nonce : String,
) -> @protocol.SessionGrant raise {
  let session_json = expect_result(
    rpc(
      tls,
      id_prefix + "-auth",
      @protocol.METHOD_RUNTIME_AUTHENTICATE_BEARER,
      @protocol.bearer_auth_params(
        id_prefix + "-auth",
        runtime_id,
        credential_id,
        credential,
        nonce,
      ),
    ),
  )
  match @protocol.parse_session_grant(session_json) {
    Some(value) => value
    None => raise Failure::Failure("session grant did not parse")
  }
}

///|
pub fn expect_result(response : @contracts.RpcResponse) -> @json.Json {
  match response.result {
    Some(value) => value
    None => {
      let detail = match response.error {
        Some(error) => error.message
        None => "no error"
      }
      abort("expected result, got error: " + detail)
    }
  }
}

///|
pub fn expect_error(
  response : @contracts.RpcResponse,
  expected_code : Int,
  expected_message : String,
) -> Unit raise {
  match response.error {
    Some(error) => {
      assert_eq(error.code, expected_code)
      assert_eq(error.message, expected_message)
    }
    None => abort("expected error " + expected_message)
  }
}
