/*
 * Small POSIX helpers for the runtime transport.
 *
 * The MoonBit async fs API can create files with a mode and chmod them, but
 * cannot read permission bits back. The transport needs to check that
 * configured certificate/key files are not accessible by group or other, and
 * the tests need to assert 0600/0700 state. This stub only calls stat(2); it
 * holds no key material and performs no cryptographic work.
 */

#include <moonbit.h>

#include <stdint.h>
#include <string.h>
#include <sys/stat.h>

#define MONEXUS_PATH_MAX 4096

/* Return 0 on success, -1 on stat failure or an over-long path. */
int32_t monexus_transport_stat(
  moonbit_bytes_t path,
  int32_t path_len,
  int32_t *out_mode,
  int32_t *out_kind,
  int32_t *out_uid,
  int32_t *out_gid
) {
  char buf[MONEXUS_PATH_MAX];
  if (path == NULL || path_len < 0 || path_len >= MONEXUS_PATH_MAX) {
    return -1;
  }
  memcpy(buf, path, (size_t)path_len);
  buf[path_len] = '\0';
  struct stat st;
  if (stat(buf, &st) != 0) {
    return -1;
  }
  *out_mode = (int32_t)(st.st_mode & 07777);
  if (S_ISREG(st.st_mode)) {
    *out_kind = 1;
  } else if (S_ISDIR(st.st_mode)) {
    *out_kind = 2;
  } else if (S_ISLNK(st.st_mode)) {
    *out_kind = 3;
  } else {
    *out_kind = 0;
  }
  *out_uid = (int32_t)st.st_uid;
  *out_gid = (int32_t)st.st_gid;
  return 0;
}
