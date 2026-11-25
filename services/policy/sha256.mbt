///|
/// SHA-256 (FIPS 180-4) over the UTF-8 encoding of a string, returned as
/// lowercase hex. The policy core needs a collision-resistant, deterministic
/// fingerprint for snapshot content and command digests; implementing it here
/// keeps the package free of a crypto dependency and of any secret material.
/// It is not used for password hashing or credential derivation.
pub fn sha256_hex(text : String) -> String {
  sha256_bytes_hex(@utf8.encode(text))
}

///|
/// Rotate a 32-bit word right by `n` bits, 0 < n < 32.
fn rotr32(word : UInt32, n : Int) -> UInt32 {
  (word >> n) | (word << (32 - n))
}

///|
fn sha256_bytes_hex(input : Bytes) -> String {
  let src = input.to_fixedarray()
  let n = src.length()
  // Message + 0x80 + zero padding + 8-byte big-endian bit length.
  let total = ((n + 9 + 63) / 64) * 64
  let buf : FixedArray[Byte] = FixedArray::make(total, b'\x00')
  for i in 0..<n {
    buf[i] = src[i]
  }
  buf[n] = b'\x80'
  let bit_len : Int64 = n.to_int64() * 8L
  for i in 0..<8 {
    let shift : Int = (7 - i) * 8
    buf[total - 8 + i] = ((bit_len >> shift) & 255L).to_byte()
  }
  let state : FixedArray[UInt32] = FixedArray::make(8, 0U)
  state[0] = 0x6a09e667U
  state[1] = 0xbb67ae85U
  state[2] = 0x3c6ef372U
  state[3] = 0xa54ff53aU
  state[4] = 0x510e527fU
  state[5] = 0x9b05688cU
  state[6] = 0x1f83d9abU
  state[7] = 0x5be0cd19U
  let mut offset = 0
  while offset < total {
    sha256_compress(state, buf, offset)
    offset = offset + 64
  }
  let mut hex = ""
  for i in 0..<8 {
    let word = state[i]
    hex = hex +
      ((word >> 24) & 255U).to_byte().to_hex() +
      ((word >> 16) & 255U).to_byte().to_hex() +
      ((word >> 8) & 255U).to_byte().to_hex() +
      (word & 255U).to_byte().to_hex()
  }
  hex
}

///|
fn sha256_compress(
  state : FixedArray[UInt32],
  block : FixedArray[Byte],
  offset : Int,
) -> Unit {
  let k : Array[UInt32] = [
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU,
    0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U, 0xd807aa98U, 0x12835b01U,
    0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U,
    0xc19bf174U, 0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
    0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU, 0x983e5152U,
    0xa831c66dU, 0xb00327c8U, 0xbf597fc7U, 0xc6e00bf3U, 0xd5a79147U,
    0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU,
    0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
    0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U, 0xd192e819U,
    0xd6990624U, 0xf40e3585U, 0x106aa070U, 0x19a4c116U, 0x1e376c08U,
    0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU,
    0x682e6ff3U, 0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
    0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U,
  ]
  let w : FixedArray[UInt32] = FixedArray::make(64, 0U)
  for i in 0..<16 {
    let p = offset + i * 4
    w[i] = (block[p].to_uint() << 24) |
      (block[p + 1].to_uint() << 16) |
      (block[p + 2].to_uint() << 8) |
      block[p + 3].to_uint()
  }
  for i in 16..<64 {
    let x = w[i - 15]
    let y = w[i - 2]
    let s0 = rotr32(x, 7) ^ rotr32(x, 18) ^ (x >> 3)
    let s1 = rotr32(y, 17) ^ rotr32(y, 19) ^ (y >> 10)
    w[i] = w[i - 16] + s0 + w[i - 7] + s1
  }
  let mut a = state[0]
  let mut b = state[1]
  let mut c = state[2]
  let mut d = state[3]
  let mut e = state[4]
  let mut f = state[5]
  let mut g = state[6]
  let mut h = state[7]
  for i in 0..<64 {
    let s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
    let ch = (e & f) ^ ((e ^ 0xFFFFFFFFU) & g)
    let temp1 = h + s1 + ch + k[i] + w[i]
    let s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
    let maj = (a & b) ^ (a & c) ^ (b & c)
    let temp2 = s0 + maj
    h = g
    g = f
    f = e
    e = d + temp1
    d = c
    c = b
    b = a
    a = temp1 + temp2
  }
  state[0] = state[0] + a
  state[1] = state[1] + b
  state[2] = state[2] + c
  state[3] = state[3] + d
  state[4] = state[4] + e
  state[5] = state[5] + f
  state[6] = state[6] + g
  state[7] = state[7] + h
}
