/* Isolated vendor-runtime worker for einkbridge (MIT).
 * Quill contract and RGB32 layout:
 * https://github.com/MaximeRivest/quill/blob/39262ee0bef69915e3ead3ac218d5973916f422a/src/quill.h
 * https://github.com/MaximeRivest/quill/blob/39262ee0bef69915e3ead3ac218d5973916f422a/src/vendor_probe.cpp
 * Runs with the stock loader/libc; Quill pulls in stock Qt before the vendor.
 * No Nix Wayland/Mesa libraries enter this process.
 */
#define _GNU_SOURCE
#include "einkbridge-wire.h"
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifndef TABLET_QT
#error TABLET_QT must come from os.nix
#endif
static void die(const char *m) {
  const char *e = dlerror();
  fprintf(stderr, "quill-host: %s%s%s\n", m, e ? ": " : "", e ? e : "");
  exit(1);
}
static void *symbol(void *h, const char *n) {
  void *p = dlsym(h, n);
  if (!p)
    die(n);
  return p;
}
int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
  const char *vendor = "/usr/lib/plugins/scenegraph/libqsgepaper.so",
             *library = NULL;
  int fd = -1, probe = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--probe")) {
      probe = 1;
      continue;
    }
    if (i + 1 == argc)
      die("missing option argument");
    const char *k = argv[i], *v = argv[++i];
    if (!strcmp(k, "--fd")) {
      char *end;
      long n = strtol(v, &end, 10);
      if (*end || n < 0 || n > 1024)
        die("invalid fd");
      fd = (int)n;
    } else if (!strcmp(k, "--quill-lib"))
      library = v;
    else if (!strcmp(k, "--vendor-lib"))
      vendor = v;
    else
      die("unknown option");
  }
  if (!library || (!probe && fd < 0))
    die("need --quill-lib and --fd (or --probe)");
  /* Quill must precede Qt and the vendor in the link map: its QImage
   * constructor aliases observe vendor allocations via RTLD_NEXT. Its RPATH
   * is /usr/lib, so these dependencies are the device's own matching Qt. */
  void *q = dlopen(library, RTLD_NOW | RTLD_GLOBAL);
  if (!q)
    die("cannot load Quill");
  const char *(*qtversion)(void) = dlsym(q, "qVersion");
  if (!qtversion)
    qtversion = dlsym(q, "_Z8qVersionv");
  if (!qtversion || strcmp(qtversion(), TABLET_QT))
    die("vendor Qt does not match os.nix");
  void *v = dlopen(vendor, RTLD_NOW | RTLD_GLOBAL);
  if (!v)
    die("cannot load vendor display library");
  const char *ctor = "_ZN6QImageC1EPhiixNS_6FormatEPFvPvES2_";
  if (!dlsym(q, ctor) || dlsym(RTLD_DEFAULT, ctor) != dlsym(q, ctor))
    die("Quill QImage interposition is unavailable");
  int (*init)(void) = symbol(q, "quill_init");
  int (*width)(void) = symbol(q, "quill_width"),
      (*height)(void) = symbol(q, "quill_height"),
      (*stride)(void) = symbol(q, "quill_stride"),
      (*format)(void) = symbol(q, "quill_format");
  unsigned char *(*buffer)(void) = symbol(q, "quill_buffer");
  unsigned long (*swap)(int, int, int, int) = symbol(q, "quill_swap_mono_fast");
  void (*events)(void) = symbol(q, "quill_process_events");
  if (probe) {
    printf("Quill ABI loaded with vendor Qt %s; quill_init not called\n",
           qtversion());
    return 0;
  }
  if (init())
    die("Quill initialization failed");
  int w = width(), h = height(), s = stride();
  unsigned char *p = buffer();
  /* QImage::Format_RGB32 = 4, the only framebuffer layout Quill accepts.
   * https://code.qt.io/cgit/qt/qtbase.git/tree/src/gui/image/qimage.h?h=v6.10.3 */
  if (w <= 0 || h <= 0 || w > 16384 || h > 16384 || s < w * 4 || !p ||
      format() != 4)
    die("invalid Quill RGB32 framebuffer");
  uint32_t hello[4] = {EINK_MAGIC, 1, (uint32_t)w, (uint32_t)h};
  if (wire_write(fd, hello, sizeof hello))
    return 1;
  uint8_t *row = malloc((size_t)w);
  if (!row)
    die("out of memory");
  for (;;) {
    uint32_t r[5];
    if (wire_read(fd, r, sizeof r))
      break;
    unsigned x = r[1], y = r[2], rw = r[3], rh = r[4];
    if (r[0] != EINK_MAGIC || !rw || !rh || x >= (unsigned)w ||
        y >= (unsigned)h || rw > (unsigned)w - x || rh > (unsigned)h - y)
      die("invalid dirty rectangle");
    for (unsigned yy = y; yy < y + rh; yy++) {
      if (wire_read(fd, row, rw))
        return 1;
      for (unsigned xx = 0; xx < rw; xx++) {
        uint32_t rgb =
            UINT32_C(0xff000000) | ((uint32_t)row[xx] * UINT32_C(0x010101));
        memcpy(p + (size_t)yy * s + (x + xx) * 4, &rgb, 4);
      }
    }
    swap((int)x, (int)y, (int)rw, (int)rh);
    events();
    uint32_t ack = EINK_MAGIC;
    if (wire_write(fd, &ack, sizeof ack))
      break;
  }
  free(row);
  /* Exit normally: the vendor engine's process teardown releases the panel.
   * Do not dlclose Qt/Quill while its threads may still reference objects. */
  return 0;
}
