///|
/// Canonical JSON over a recipe's declared fields (ADR-0013 §2.3).
///
/// Rules pinned by this module and by test vectors:
/// - object keys sorted by UTF-8 byte order,
/// - no insignificant whitespace,
/// - integers rendered in decimal (no exponent, no trailing `.0`),
/// - strings escaped with `\" \\ \b \f \n \r \t` and lowercase `\u00xx` for
///   the remaining C0 controls; everything else is emitted as raw UTF-8,
/// - arrays keep declaration order,
/// - the `signature` object is excluded so it can cover the result.
///
/// Only the declared fields are emitted: an absent optional field stays
/// absent, so the hash covers the exact document the author signed rather than
/// a normalised projection with defaults filled in.
pub(all) enum CanonicalValue {
  CvString(String)
  CvInt(Int64)
  CvBool(Bool)
  CvNull
  CvArray(Array[CanonicalValue])
  CvObject(Array[(String, CanonicalValue)])
}

///|
pub fn CanonicalValue::render(self : CanonicalValue) -> String {
  let out = StringBuilder()
  render_into(self, out)
  out.to_string()
}

///|
fn render_into(value : CanonicalValue, out : StringBuilder) -> Unit {
  match value {
    CvString(text) => render_string(text, out)
    CvInt(number) => out.write_string(number.to_string())
    CvBool(flag) =>
      if flag {
        out.write_string("true")
      } else {
        out.write_string("false")
      }
    CvNull => out.write_string("null")
    CvArray(items) => {
      out.write_char('[')
      let mut first = true
      for item in items {
        if !first {
          out.write_char(',')
        }
        first = false
        render_into(item, out)
      }
      out.write_char(']')
    }
    CvObject(fields) => {
      let sorted : Array[(String, CanonicalValue)] = []
      for field in fields {
        sorted.push(field)
      }
      sorted.sort_by(fn(left : (String, CanonicalValue),
        right : (String, CanonicalValue)) -> Int32 {
        compare_utf8(left.0, right.0)
      })
      out.write_char('{')
      let mut first = true
      for field in sorted {
        if !first {
          out.write_char(',')
        }
        first = false
        render_string(field.0, out)
        out.write_char(':')
        render_into(field.1, out)
      }
      out.write_char('}')
    }
  }
}

///|
fn render_string(text : String, out : StringBuilder) -> Unit {
  out.write_char('"')
  for index in 0..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => continue
    }
    let code = ch.to_int()
    if ch == '"' {
      out.write_string("\\\"")
    } else if ch == '\\' {
      out.write_string("\\\\")
    } else if code == 8 {
      out.write_string("\\b")
    } else if code == 9 {
      out.write_string("\\t")
    } else if code == 10 {
      out.write_string("\\n")
    } else if code == 12 {
      out.write_string("\\f")
    } else if code == 13 {
      out.write_string("\\r")
    } else if code < 32 {
      out.write_string("\\u00")
      out.write_char(hex_digit(code >> 4))
      out.write_char(hex_digit(code & 15))
    } else {
      out.write_char(ch)
    }
  }
  out.write_char('"')
}

///|
fn hex_digit(value : Int) -> Char {
  if value < 10 {
    (value + 48).unsafe_to_char()
  } else {
    (value - 10 + 97).unsafe_to_char()
  }
}

///|
fn cv_string(value : String) -> CanonicalValue {
  CvString(value)
}

///|
fn cv_int(value : Int) -> CanonicalValue {
  CvInt(value.to_int64())
}

///|
fn hook_value(hook : LifecycleHook) -> CanonicalValue {
  let fields : Array[(String, CanonicalValue)] = []
  match hook.command {
    HookArgv(argv) => {
      let items : Array[CanonicalValue] = []
      for argument in argv {
        items.push(cv_string(argument))
      }
      fields.push(("argv", CvArray(items)))
    }
    HookScript(script) => fields.push(("script", cv_string(script)))
  }
  fields.push(("timeout_s", cv_int(hook.timeout_s)))
  CvObject(fields)
}

///|
/// The exact object that is hashed and signed: every declared field of the
/// recipe except `signature`.
pub fn canonical_content(recipe : Recipe) -> CanonicalValue {
  let fields : Array[(String, CanonicalValue)] = []
  fields.push(("schema_version", cv_int(recipe.schema_version)))
  fields.push(("name", cv_string(recipe.name)))
  fields.push(("version", cv_string(recipe.version)))
  fields.push(
    (
      "image",
      CvObject([
        ("ref", cv_string(recipe.image.reference)),
        ("digest", cv_string(recipe.image.digest)),
      ]),
    ),
  )
  match recipe.workdir {
    Some(value) => fields.push(("workdir", cv_string(value)))
    None => ()
  }
  match recipe.user {
    Some(value) => fields.push(("user", cv_string(value)))
    None => ()
  }
  let mounts : Array[CanonicalValue] = []
  for mount in recipe.mounts {
    mounts.push(
      CvObject([
        ("source", cv_string(mount.source.label())),
        ("target", cv_string(mount.target)),
        ("mode", cv_string(mount.mode.label())),
      ]),
    )
  }
  fields.push(("mounts", CvArray(mounts)))
  match recipe.env_allowlist {
    Some(names) => {
      let items : Array[CanonicalValue] = []
      for name in names {
        items.push(cv_string(name))
      }
      fields.push(("env_allowlist", CvArray(items)))
    }
    None => ()
  }
  let limit_fields : Array[(String, CanonicalValue)] = []
  match recipe.limits.cpu_millis {
    Some(value) => limit_fields.push(("cpu_millis", cv_int(value)))
    None => ()
  }
  match recipe.limits.memory_mb {
    Some(value) => limit_fields.push(("memory_mb", cv_int(value)))
    None => ()
  }
  match recipe.limits.pids {
    Some(value) => limit_fields.push(("pids", cv_int(value)))
    None => ()
  }
  if limit_fields.length() > 0 {
    fields.push(("limits", CvObject(limit_fields)))
  }
  match recipe.network {
    Some(value) => fields.push(("network", cv_string(value.label())))
    None => ()
  }
  fields.push(
    (
      "lifecycle",
      CvObject([
        ("prepare", hook_value(recipe.lifecycle.prepare)),
        ("start", hook_value(recipe.lifecycle.start)),
        ("stop", hook_value(recipe.lifecycle.stop)),
      ]),
    ),
  )
  match recipe.doctor {
    Some(doctor) => {
      let items : Array[CanonicalValue] = []
      for argument in doctor.argv {
        items.push(cv_string(argument))
      }
      fields.push(
        ("doctor", CvObject([("argv", CvArray(items)),
          ("timeout_s", cv_int(doctor.timeout_s))])),
      )
    }
    None => ()
  }
  fields.push(
    (
      "source",
      CvObject([
        ("kind", cv_string(recipe.source.kind)),
        ("path", cv_string(recipe.source.path)),
        ("author", cv_string(recipe.source.author)),
        ("created_at", cv_string(recipe.source.created_at)),
      ]),
    ),
  )
  CvObject(fields)
}

///|
/// Canonical JSON text (UTF-8, no whitespace). This is the byte string the
/// author hashes and signs.
pub fn canonical_string(recipe : Recipe) -> String {
  canonical_content(recipe).render()
}

///|
/// SHA-256 over a string's UTF-8 bytes, lowercase hex.
pub fn sha256_hex(text : String) -> String {
  let digest = @crypto.sha256(@utf8.encode(text).exact_view())
  let bytes = Bytes::from_array(digest)
  @hex.encode(bytes.exact_view())
}

///|
/// `content_hash = "sha256:" + hex(SHA-256(canonical JSON))`.
/// The prefixed form is also the exact ASCII payload signed by Ed25519.
pub fn content_hash(recipe : Recipe) -> String {
  "sha256:" + sha256_hex(canonical_string(recipe))
}

///|
/// Recompute the hash of stored canonical bytes and compare it with the value
/// that was persisted at import time (ADR-0013 §2.3 "用前复验").
pub fn check_content_hash(canonical : String, stored_hash : String) -> Bool {
  "sha256:" + sha256_hex(canonical) == stored_hash
}
