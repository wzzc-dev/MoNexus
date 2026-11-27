/*
 * Test-only support for the A1.0 loopback TLS tests.
 *
 * moonbitlang/async (0.22.x) drains exactly one entry from OpenSSL's
 * thread-local error queue per raised TlsError. A deliberately failed
 * handshake (the plaintext-client rejection test) pushes more than one entry,
 * so entries survive the test. OpenSSL's SSL_get_error() consults that queue
 * before it looks at SSL_want_read/write, so the next healthy connection that
 * merely returns WANT_READ is misclassified as SSL_ERROR_SSL. async then
 * raises the stale error, which on OpenSSL 3.5 reads:
 *   error:0A000139:SSL routines::record layer failure
 *
 * The tests serialize TLS work with an async mutex and call this helper at the
 * start of every TLS test to reset the queue. This is test-only plumbing; it
 * does not change the transport or any security assertion.
 *
 * Linux native is the validation platform for this spike. On Windows the
 * helper is a no-op; on other Unixes it resolves ERR_clear_error through
 * dlsym against the OpenSSL already loaded by moonbitlang/async. macOS is
 * handled separately: the system ships libssl (which depends on libcrypto)
 * but no `libcrypto.dylib`; asking dyld for that Apple shim aborts the
 * process ("loading libcrypto in an unsafe way").
 */
#if defined(_WIN32)

void monexus_a1_clear_openssl_errors(void) {}

#else

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef void (*err_clear_error_fn)(void);

void monexus_a1_clear_openssl_errors(void) {
  static err_clear_error_fn clear = NULL;
  if (clear == NULL) {
    /*
     * dlopen() returns the handle of the already-loaded libcrypto when the
     * soname matches, so this shares the same error queue state as
     * moonbitlang/async. The handle is intentionally kept open.
     */
#if defined(__APPLE__)
    /*
     * moonbitlang/async loads the system OpenSSL through libssl. dyld returns
     * the same (already loaded) image, so ERR_clear_error resolves to the
     * shared libcrypto error queue. Do not name "libcrypto.dylib" here: that
     * is Apple's compatibility shim and aborts on dlopen.
     */
    void *handle = dlopen("/usr/lib/libssl.48.dylib", RTLD_LAZY);
    if (handle == NULL) {
      handle = dlopen("/usr/lib/libssl.46.dylib", RTLD_LAZY);
    }
#else
    void *handle = dlopen("libcrypto.so.3", RTLD_LAZY);
    if (handle == NULL) {
      handle = dlopen("libcrypto.so.1.1", RTLD_LAZY);
    }
    if (handle == NULL) {
      handle = dlopen("libcrypto.so", RTLD_LAZY);
    }
#endif
    if (handle != NULL) {
      clear = (err_clear_error_fn)dlsym(handle, "ERR_clear_error");
    }
    if (clear == NULL) {
      fprintf(
        stderr,
        "monexus a1 tests: unable to resolve OpenSSL ERR_clear_error\n"
      );
      abort();
    }
  }
  clear();
}

#endif
