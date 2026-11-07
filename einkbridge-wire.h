/* Private local IPC: native uint32_t headers followed by grayscale dirty rows.
 * Both processes run on the same CPU. Never exposed as a network protocol. */
#ifndef EINKBRIDGE_WIRE_H
#define EINKBRIDGE_WIRE_H
#include <errno.h>
#include <stdint.h>
#include <unistd.h>
#define EINK_MAGIC UINT32_C(0x524d5050)
static int wire_read(int fd, void *data, size_t n) {
  unsigned char *p = data;
  while (n) {
    ssize_t r = read(fd, p, n);
    if (r < 0 && errno == EINTR)
      continue;
    if (r <= 0)
      return -1;
    p += r;
    n -= (size_t)r;
  }
  return 0;
}
static int wire_write(int fd, const void *data, size_t n) {
  const unsigned char *p = data;
  while (n) {
    ssize_t r = write(fd, p, n);
    if (r < 0 && errno == EINTR)
      continue;
    if (r <= 0)
      return -1;
    p += r;
    n -= (size_t)r;
  }
  return 0;
}
#endif
