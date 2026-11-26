///|
/// Canonical JSON for skill manifests (ADR-0015 §2.2).
///
/// The rendering rules are identical to A2's recipe canonical form: sorted
/// object keys, no insignificant whitespace, decimal integers, control
/// characters escaped as lowercase `\u00xx`, raw UTF-8 otherwise. The
/// manifest's `content_hash` and `signature` fields are excluded from the
/// body because the hash and signature cover the body, not themselves.
pub(all) enum SkillCanonicalValue {
  ScString(String)
  ScInt(Int)
  ScBool(Bool)
  ScArray(Array[SkillCanonicalValue])
  ScObject(Array[(String, SkillCanonicalValue)])
}

///|
pub fn SkillCanonicalValue::render(self : SkillCanonicalValue) -> String {
  let out = StringBuilder()
  skill_render_into(self, out)
  out.to_string()
}

///|
fn skill_render_into(value : SkillCanonicalValue, out : StringBuilder) -> Unit {
  match value {
    ScString(text) => skill_render_string(text, out)
    ScInt(number) => out.write_string(number.to_string())
    ScBool(flag) =>
      if flag {
        out.write_string("true")
      } else {
        out.write_string("false")
      }
    ScArray(items) => {
      out.write_char('[')
      let mut first = true
      for item in items {
        if !first {
          out.write_char(',')
        }
        first = false
        skill_render_into(item, out)
      }
      out.write_char(']')
    }
    ScObject(fields) => {
      let sorted : Array[(String, SkillCanonicalValue)] = []
      for field in fields {
        sorted.push(field)
      }
      sorted.sort_by(fn(left : (String, SkillCanonicalValue),
        right : (String, SkillCanonicalValue)) -> Int32 {
        @recipes.compare_utf8(left.0, right.0)
      })
      out.write_char('{')
      let mut first = true
      for field in sorted {
        if !first {
          out.write_char(',')
        }
        first = false
        skill_render_string(field.0, out)
        out.write_char(':')
        skill_render_into(field.1, out)
      }
      out.write_char('}')
    }
  }
}

///|
fn skill_render_string(text : String, out : StringBuilder) -> Unit {
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
      out.write_char(skill_hex_digit(code >> 4))
      out.write_char(skill_hex_digit(code & 15))
    } else {
      out.write_char(ch)
    }
  }
  out.write_char('"')
}

///|
fn skill_hex_digit(value : Int) -> Char {
  if value < 10 {
    (value + 48).unsafe_to_char()
  } else {
    (value - 10 + 97).unsafe_to_char()
  }
}

///|
fn sc_string(value : String) -> SkillCanonicalValue {
  ScString(value)
}

///|
fn sc_strings(values : Array[String]) -> SkillCanonicalValue {
  let items : Array[SkillCanonicalValue] = []
  for value in values {
    items.push(ScString(value))
  }
  ScArray(items)
}

///|
/// The exact object hashed and signed for a skill manifest.
pub fn canonical_manifest_body(manifest : @contracts.SkillManifest) -> SkillCanonicalValue {
  let fields : Array[(String, SkillCanonicalValue)] = []
  fields.push(("schema_version", ScInt(manifest.schema_version)))
  fields.push(("name", sc_string(manifest.name)))
  fields.push(("version", sc_string(manifest.version)))
  fields.push(("description", sc_string(manifest.description)))
  fields.push(("permissions", sc_strings(manifest.permissions)))
  fields.push(
    (
      "entry",
      ScObject([
        ("path", sc_string(manifest.entry_path)),
        ("max_bytes", ScInt(manifest.entry_max_bytes)),
      ]),
    ),
  )
  if manifest.resources.length() > 0 {
    let items : Array[SkillCanonicalValue] = []
    for resource in manifest.resources {
      items.push(
        ScObject([
          ("path", sc_string(resource.path)),
          ("description", sc_string(resource.description)),
        ]),
      )
    }
    fields.push(("resources", ScArray(items)))
  }
  if manifest.commands.length() > 0 {
    let items : Array[SkillCanonicalValue] = []
    for command in manifest.commands {
      items.push(
        ScObject([
          ("id", sc_string(command.id)),
          ("argv", sc_strings(command.argv)),
          ("mode", sc_string(command.mode)),
          ("timeout_ms", ScInt(command.timeout_ms)),
          ("max_output_bytes", ScInt(command.max_output_bytes)),
        ]),
      )
    }
    fields.push(("commands", ScArray(items)))
  }
  if manifest.dependencies.length() > 0 {
    let items : Array[SkillCanonicalValue] = []
    for dependency in manifest.dependencies {
      let dependency_fields : Array[(String, SkillCanonicalValue)] = [
        ("kind", sc_string(dependency.kind)),
        ("name", sc_string(dependency.name)),
      ]
      if dependency.version != "" {
        dependency_fields.push(("version", sc_string(dependency.version)))
      }
      if dependency.content_hash != "" {
        dependency_fields.push(
          ("content_hash", sc_string(dependency.content_hash)),
        )
      }
      items.push(ScObject(dependency_fields))
    }
    fields.push(("dependencies", ScArray(items)))
  }
  fields.push(
    (
      "source",
      ScObject([
        ("kind", sc_string(manifest.source.kind)),
        ("path", sc_string(manifest.source.path)),
        ("author", sc_string(manifest.source.author)),
        ("created_at", sc_string(manifest.source.created_at)),
      ]),
    ),
  )
  if manifest.limits.max_runtime_ms > 0 || manifest.limits.max_output_bytes > 0 {
    let limit_fields : Array[(String, SkillCanonicalValue)] = []
    if manifest.limits.max_runtime_ms > 0 {
      limit_fields.push(("max_runtime_ms", ScInt(manifest.limits.max_runtime_ms)))
    }
    if manifest.limits.max_output_bytes > 0 {
      limit_fields.push(
        ("max_output_bytes", ScInt(manifest.limits.max_output_bytes)),
      )
    }
    fields.push(("limits", ScObject(limit_fields)))
  }
  ScObject(fields)
}

///|
pub fn canonical_manifest_string(manifest : @contracts.SkillManifest) -> String {
  canonical_manifest_body(manifest).render()
}

///|
pub const SKILL_HASH_DOMAIN : String = "monexus.skill.v1"

///|
pub const SKILL_SIG_DOMAIN : String = "monexus.skill.sig.v1"

///|
pub const SKILL_SIGNATURE_NAMESPACE : String = "monexus-skill-v1"

///|
/// `content_hash = "sha256:" + hex(sha256(domain + "\n" + body + "\n" + files))`
/// where `files` is the sorted concatenation of `"<path>\n<sha256(file)>\n"`.
pub fn compute_content_hash(
  body : String,
  files : Array[(String, String)],
) -> String {
  let sorted : Array[(String, String)] = []
  for entry in files {
    sorted.push(entry)
  }
  sorted.sort_by(fn(left : (String, String), right : (String, String)) -> Int32 {
    @recipes.compare_utf8(left.0, right.0)
  })
  let combined = StringBuilder()
  combined.write_string(SKILL_HASH_DOMAIN)
  combined.write_char('\n')
  combined.write_string(body)
  combined.write_char('\n')
  for entry in sorted {
    combined.write_string(entry.0)
    combined.write_char('\n')
    combined.write_string(@recipes.sha256_hex(entry.1))
    combined.write_char('\n')
  }
  "sha256:" + @recipes.sha256_hex(combined.to_string())
}

///|
pub fn skill_sig_input(content_hash : String) -> String {
  SKILL_SIG_DOMAIN + "\n" + content_hash
}

///|
pub fn sha256_file_hex(text : String) -> String {
  @recipes.sha256_hex(text)
}
