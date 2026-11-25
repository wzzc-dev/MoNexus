///|
/// Read POSIX permission bits for a path.
///
/// `moonbitlang/async/fs` can set a mode and chmod, but cannot read one back.
/// The transport needs this to refuse certificate/key files that are readable
/// by group or other and to assert 0600/0700 in the tests. The native stub is
/// a single `stat(2)` call; it touches no key material.

///|
#borrow(path, out_mode, out_kind, out_uid, out_gid)
extern "C" fn stat_ffi(
  path : Bytes,
  path_len : Int32,
  out_mode : Ref[Int32],
  out_kind : Ref[Int32],
  out_uid : Ref[Int32],
  out_gid : Ref[Int32],
) -> Int32 = "monexus_transport_stat"

///|
pub(all) enum PathKind {
  Other
  Regular
  Directory
  SymLink
}

///|
pub(all) struct PathStat {
  mode : Int
  kind : PathKind
  uid : Int
  gid : Int
}

///|
/// `None` when the path does not exist or cannot be stat'ed.
pub fn stat_path(path : String) -> PathStat? {
  let bytes = @utf8.encode(path)
  if bytes.length() > 4095 {
    return None
  }
  let mode = Ref(0)
  let kind = Ref(0)
  let uid = Ref(0)
  let gid = Ref(0)
  if stat_ffi(bytes, bytes.length(), mode, kind, uid, gid) != 0 {
    return None
  }
  Some({
    mode: mode.val.to_int(),
    kind: match kind.val {
      1 => Regular
      2 => Directory
      3 => SymLink
      _ => Other
    },
    uid: uid.val.to_int(),
    gid: gid.val.to_int(),
  })
}

///|
/// True when no group or other permission bit is set (0600/0400/0700/0500
/// style). The owner bits are reported by the caller as needed.
pub fn is_private_mode(mode : Int) -> Bool {
  (mode & 0o077) == 0
}

///|
pub fn mode_is_directory_traversable_only(mode : Int) -> Bool {
  (mode & 0o077) == 0
}

///|
/// Format a mode as three octal digits, for bounded diagnostics (never for
/// anything secret).
pub fn mode_text(mode : Int) -> String {
  let digits = mode & 0o777
  let out = digits.to_string()
  let padded = if out.length() >= 3 {
    out
  } else if out.length() == 2 {
    "0" + out
  } else {
    "00" + out
  }
  padded
}
