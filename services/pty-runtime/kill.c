#include "moonbit.h"

#include <errno.h>
#include <signal.h>
#include <sys/types.h>

/*
 * Kill an entire process group. The PTY child is a session leader, so its
 * pid is also its process-group id. Returns 0 on success or -errno. A pgid
 * of 0 or 1 is never signalled (kill(0, ...) would hit the host's group).
 */
MOONBIT_FFI_EXPORT
int32_t monexus_pty_kill_group(int32_t pgid, int32_t signal_number) {
  if (pgid <= 1) {
    return -EINVAL;
  }
  if (kill(-((pid_t)pgid), (int)signal_number) != 0) {
    return -errno;
  }
  return 0;
}
