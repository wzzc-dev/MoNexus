///|
/// Stable reason codes for recipe parsing, trust and signature failures.
///
/// These labels are part of the observable contract: A2.1/A2.2 write them to
/// `recipe.refused` events and doctor reports, so they must not be renamed
/// without a migration. `label()` is the only serialized form.
pub(all) enum RecipeErrorCode {
  InvalidJson
  UnknownField
  UnsupportedField
  MissingField
  InvalidType
  InvalidValue
  SchemaVersionUnsupported
  NameInvalid
  VersionInvalid
  IdentityInvalid
  ImageRefInvalid
  ImageDigestInvalid
  MountInvalid
  MountSourceInvalid
  MountTargetInvalid
  MountDuplicate
  MountMissingWorkspace
  WorkdirInvalid
  WorkdirOutsideMount
  UserInvalid
  EnvNameInvalid
  EnvNameDuplicate
  LimitOutOfRange
  NetworkUnsupported
  LifecycleInvalid
  HookConflict
  HookTimeoutRange
  ArgvInvalid
  ScriptInvalid
  DoctorInvalid
  SourceInvalid
  TimestampInvalid
  SignatureInvalid
  SignatureAlgUnsupported
  KeyIdInvalid
  TrustKeyInvalid
  DuplicateTrustKey
  TrustStoreMissing
  TrustStoreInvalid
  TrustStoreInsecure
  TrustStoreUnverifiable
  UnknownKey
  RevokedKey
  HashMismatch
  VerifierMissing
  VerifierUnsupported
  VerifierFailed
  BadSignature
  IoFailed
  Internal
}

///|
pub fn RecipeErrorCode::label(self : RecipeErrorCode) -> String {
  match self {
    InvalidJson => "invalid_json"
    UnknownField => "unknown_field"
    UnsupportedField => "unsupported_field"
    MissingField => "missing_field"
    InvalidType => "invalid_type"
    InvalidValue => "invalid_value"
    SchemaVersionUnsupported => "schema_version_unsupported"
    NameInvalid => "name_invalid"
    VersionInvalid => "version_invalid"
    IdentityInvalid => "identity_invalid"
    ImageRefInvalid => "image_ref_invalid"
    ImageDigestInvalid => "image_digest_invalid"
    MountInvalid => "mount_invalid"
    MountSourceInvalid => "mount_source_invalid"
    MountTargetInvalid => "mount_target_invalid"
    MountDuplicate => "mount_duplicate"
    MountMissingWorkspace => "mount_missing_workspace"
    WorkdirInvalid => "workdir_invalid"
    WorkdirOutsideMount => "workdir_outside_mount"
    UserInvalid => "user_invalid"
    EnvNameInvalid => "env_name_invalid"
    EnvNameDuplicate => "env_name_duplicate"
    LimitOutOfRange => "limit_out_of_range"
    NetworkUnsupported => "network_unsupported"
    LifecycleInvalid => "lifecycle_invalid"
    HookConflict => "hook_conflict"
    HookTimeoutRange => "hook_timeout_range"
    ArgvInvalid => "argv_invalid"
    ScriptInvalid => "script_invalid"
    DoctorInvalid => "doctor_invalid"
    SourceInvalid => "source_invalid"
    TimestampInvalid => "timestamp_invalid"
    SignatureInvalid => "signature_invalid"
    SignatureAlgUnsupported => "signature_alg_unsupported"
    KeyIdInvalid => "key_id_invalid"
    TrustKeyInvalid => "trust_key_invalid"
    DuplicateTrustKey => "duplicate_trust_key"
    TrustStoreMissing => "trust_store_missing"
    TrustStoreInvalid => "trust_store_invalid"
    TrustStoreInsecure => "trust_store_insecure"
    TrustStoreUnverifiable => "trust_store_unverifiable"
    UnknownKey => "unknown_key"
    RevokedKey => "revoked_key"
    HashMismatch => "hash_mismatch"
    VerifierMissing => "verifier_missing"
    VerifierUnsupported => "verifier_unsupported"
    VerifierFailed => "verifier_failed"
    BadSignature => "bad_signature"
    IoFailed => "io_failed"
    Internal => "internal"
  }
}

///|
/// A structured recipe failure. `detail` is built only from constants and
/// field names: recipe text, environment values and key material never reach
/// it, so an error is safe to log verbatim.
pub(all) struct RecipeError {
  code : RecipeErrorCode
  field : String?
  detail : String?
}

///|
pub fn RecipeError::new(code : RecipeErrorCode) -> RecipeError {
  { code, field: None, detail: None, }
}

///|
pub fn RecipeError::at(self : RecipeError, field : String) -> RecipeError {
  { ..self, field: Some(field) }
}

///|
pub fn RecipeError::with_detail(
  self : RecipeError,
  detail : String,
) -> RecipeError {
  { ..self, detail: Some(bounded_detail(detail)), }
}

///|
pub fn RecipeError::reason(self : RecipeError) -> String {
  self.code.label()
}

///|
pub fn RecipeError::to_string(self : RecipeError) -> String {
  let mut text = self.code.label()
  match self.field {
    Some(field) if field != "" => text = text + " (" + field + ")"
    _ => ()
  }
  match self.detail {
    Some(detail) if detail != "" => text = text + ": " + detail
    _ => ()
  }
  text
}

///|
fn bounded_detail(detail : String) -> String {
  let cap = 240
  if detail.length() <= cap {
    return detail
  }
  detail[:cap].to_owned() + "…"
}
