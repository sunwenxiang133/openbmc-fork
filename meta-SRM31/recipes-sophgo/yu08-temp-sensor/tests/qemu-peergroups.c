/* Test-only workaround: QEMU 6/7 returns ERANGE forever for SO_PEERGROUPS.
 * Let libsystemd treat this optional credential query as unsupported.
 * This library is never installed in the firmware.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <sys/socket.h>

int getsockopt(int fd, int level, int option, void *value, socklen_t *length)
{
    if (level == SOL_SOCKET && option == 59 /* SO_PEERGROUPS */)
    {
        errno = ENOPROTOOPT;
        return -1;
    }
    int (*real_getsockopt)(int, int, int, void *, socklen_t *) =
        dlsym(RTLD_NEXT, "getsockopt");
    return real_getsockopt(fd, level, option, value, length);
}
