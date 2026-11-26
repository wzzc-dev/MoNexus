///|
/// Invocation gate helpers for the host-owned `skill.invoke` entry point
/// (ADR-0015 §5.1, §6.2).
///
/// The gateway never accepts a command, argv, path or environment from the
/// Agent. It re-resolves the frozen snapshot and manifest, then applies these
/// checks before any policy/Decision path runs.
pub fn skill_interpreters() -> Array[String] {
  [
  "sh", "bash", "zsh", "dash", "fish", "ksh", "csh", "tcsh", "pwsh", "powershell",
  "cmd", "env", "xargs", "eval", "exec", "source", "python", "python3", "python2",
  "node", "deno", "bun", "perl", "ruby", "php", "lua", "tclsh", "awk", "sed",
  ]
}

///|
pub fn skill_first_token_is_interpreter(argv : Array[String]) -> Bool {
  if argv.length() == 0 {
    return false
  }
  let first = argv[0]
  let base = match first.rev_find("/") {
    Some(index) => first[index + 1:].to_owned()
    None => first
  }
  for name in skill_interpreters() {
    if base == name {
      return true
    }
  }
  false
}

///|
fn argument_escapes(argument : String) -> Bool {
  if argument.has_prefix("/") || argument.has_prefix("~") {
    return true
  }
  let parts = argument.split("/")
  for part in parts {
    if part == ".." {
      return true
    }
  }
  false
}

///|
/// Exact-argv validation: no interpreter, no absolute or `..` path arguments,
/// no empty argv.
pub fn skill_argv_safe(argv : Array[String]) -> Bool {
  if argv.length() == 0 {
    return false
  }
  if skill_first_token_is_interpreter(argv) {
    return false
  }
  for argument in argv {
    if argument_escapes(argument) {
      return false
    }
  }
  true
}

///|
pub fn skill_permissions_subset(
  declared : Array[String],
  allowed : Array[String],
) -> Bool {
  for permission in declared {
    let mut present = false
    for candidate in allowed {
      if candidate == permission {
        present = true
        break
      }
    }
    if !present {
      return false
    }
  }
  true
}

///|
pub fn skill_permissions_intersect(
  left : Array[String],
  right : Array[String],
) -> Array[String] {
  let out : Array[String] = []
  for permission in left {
    for candidate in right {
      if permission == candidate {
        let mut duplicate = false
        for existing in out {
          if existing == permission {
            duplicate = true
            break
          }
        }
        if !duplicate {
          out.push(permission)
        }
      }
    }
  }
  out
}

///|
/// Classify one owner-declared command. The command text passed to the
/// classifier is the exact argv joined with spaces; it is never executed
/// through a shell.
pub fn classify_skill_command(argv : Array[String]) -> @contracts.PolicyVerdict {
  @contracts.evaluate_command_policy(argv.join(" "))
}

///|
pub fn skill_mode_requires_decision(mode : String) -> Bool {
  mode == @contracts.SKILL_ENTRY_MODE_WRITE
}

///|
/// A write entry always needs a Decision, even when policy says `allow`.
/// `deny` and `critical` never reach a Decision.
pub fn skill_verdict_needs_decision(
  mode : String,
  verdict : @contracts.PolicyVerdict,
) -> Bool {
  if verdict.action == @contracts.POLICY_DENY ||
    verdict.risk == @contracts.RISK_CRITICAL {
    return false
  }
  skill_mode_requires_decision(mode) || verdict.action == @contracts.POLICY_ASK
}

///|
/// Find a command by id in a manifest.
pub fn find_skill_command(
  manifest : @contracts.SkillManifest,
  entry_id : String,
) -> @contracts.SkillCommand? {
  for command in manifest.commands {
    if command.id == entry_id {
      return Some(command)
    }
  }
  None
}

///|
/// The only tool schema exposed to the Agent.
pub fn skill_invoke_tool_description(
  entries : Array[@contracts.SkillSnapshotEntry],
) -> String {
  let out = StringBuilder()
  out.write_string(
    "Invoke a host-declared skill command. The host chooses the exact argv; you supply only entry_id.",
  )
  for entry in entries {
    if entry.mode == @contracts.SKILL_MODE_LOADED {
      out.write_string("\n- " + entry.name + "@" + entry.version + ": ")
      let mut first = true
      for id in entry.entry_ids {
        if !first {
          out.write_string(", ")
        }
        first = false
        out.write_string(id)
      }
    }
  }
  out.to_string()
}
