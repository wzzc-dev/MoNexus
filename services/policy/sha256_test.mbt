///|
/// SHA-256 known vectors (FIPS 180-4 / NIST examples). These pin the
/// implementation used for policy snapshot hashes and command digests.

///|
test "sha256: empty input" {
  assert_eq(
    @policy.sha256_hex(""),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
}

///|
test "sha256: abc vector" {
  assert_eq(
    @policy.sha256_hex("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
}

///|
test "sha256: two-block vector" {
  assert_eq(
    @policy.sha256_hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  )
}

///|
test "sha256: repeated input is stable" {
  let text = "monexus policy snapshot"
  assert_eq(@policy.sha256_hex(text), @policy.sha256_hex(text))
  assert_eq(@policy.sha256_hex(text).length(), 64)
  assert_false(@policy.sha256_hex(text + "!") == @policy.sha256_hex(text))
}
