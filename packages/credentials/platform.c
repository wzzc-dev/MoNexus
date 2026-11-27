/*
 * Compile-time platform identity for the credential store.
 *
 * The store selects the Keychain automatically on macOS. Shell variables
 * such as `OSTYPE` are not exported to GUI applications or their children,
 * so environment-based detection misclassified real Macs and made the
 * Keychain path fail closed. This stub reports the target the binary was
 * built for; it holds no secret and touches only a compile-time macro.
 */

#include <moonbit.h>

#include <stdint.h>

MOONBIT_FFI_EXPORT
int32_t monexus_credentials_is_macos(void) {
#if defined(__APPLE__)
  return 1;
#else
  return 0;
#endif
}
