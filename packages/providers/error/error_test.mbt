///|
test "provider errors keep category and exit code separate" {
  let error = ProviderError::new(
    AuthFailed,
    "SSH authentication or connection failed",
  )
  .with_exit(255)
  .with_detail("permission denied")
  assert_eq(
    error.to_string(),
    "auth_failed: SSH authentication or connection failed (exit 255): permission denied",
  )
  assert_eq(ProviderErrorKind::RemoteExit.label(), "remote_exit")
}
