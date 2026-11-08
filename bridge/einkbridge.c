/* Independently implemented Wayland screencopy -> e-paper bridge (MIT).
 * Protocol contract:
 * https://gitlab.freedesktop.org/wlroots/wlr-protocols/-/blob/master/unstable/wlr-screencopy-unstable-v1.xml
 * Quill API:
 * https://github.com/MaximeRivest/quill/blob/39262ee0bef69915e3ead3ac218d5973916f422a/src/quill.h
 * There was no published upstream einkbridge source to adapt. Input remains
 * on labwc's libinput/Wayland seat, preserving multi-touch/tablet semantics.
 */
#define _GNU_SOURCE
#include "einkbridge-wire.h"
#include "wlr-screencopy-client.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

static volatile sig_atomic_t stopping;
static void stop(int sig) {
  (void)sig;
  stopping = 1;
}
static void die(const char *msg) {
  fprintf(stderr, "einkbridge: %s\n", msg);
  exit(1);
}
static unsigned number(const char *s) {
  char *end;
  errno = 0;
  unsigned long v = strtoul(s, &end, 10);
  if (errno || !*s || *end || v == 0 || v > 16384)
    die("invalid numeric argument");
  return (unsigned)v;
}
struct output {
  struct wl_output *wl;
  uint32_t id;
  char name[128];
};
struct state {
  struct wl_display *display;
  struct wl_registry *registry;
  struct wl_shm *shm;
  struct zwlr_screencopy_manager_v1 *manager;
  struct output outputs[16];
  unsigned outputs_len;
  struct wl_output *selected;
  struct wl_buffer *buffer;
  void *pixels;
  size_t bytes;
  uint32_t width, height, stride, format, flags;
  bool done, failed, copying;
};
static void geometry(void *d, struct wl_output *o, int32_t x, int32_t y,
                     int32_t pw, int32_t ph, int32_t sub, const char *m,
                     const char *model, int32_t t) {
  (void)d;
  (void)o;
  (void)x;
  (void)y;
  (void)pw;
  (void)ph;
  (void)sub;
  (void)m;
  (void)model;
  (void)t;
}
static void mode(void *d, struct wl_output *o, uint32_t f, int32_t w, int32_t h,
                 int32_t r) {
  (void)d;
  (void)o;
  (void)f;
  (void)w;
  (void)h;
  (void)r;
}
static void output_done(void *d, struct wl_output *o) {
  (void)d;
  (void)o;
}
static void scale(void *d, struct wl_output *o, int32_t s) {
  (void)d;
  (void)o;
  (void)s;
}
static void output_name(void *d, struct wl_output *o, const char *n) {
  (void)o;
  snprintf(((struct output *)d)->name, 128, "%s", n);
}
static void description(void *d, struct wl_output *o, const char *n) {
  (void)d;
  (void)o;
  (void)n;
}
static const struct wl_output_listener output_listener = {
    geometry, mode, output_done, scale, output_name, description};
static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
  struct state *s = data;
  if (!strcmp(interface, "wl_shm"))
    s->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
  else if (!strcmp(interface, "zwlr_screencopy_manager_v1") && version >= 3)
    s->manager = wl_registry_bind(registry, name,
                                  &zwlr_screencopy_manager_v1_interface, 3);
  else if (!strcmp(interface, "wl_output") && s->outputs_len < 16) {
    struct output *o = &s->outputs[s->outputs_len++];
    o->id = name;
    o->wl = wl_registry_bind(registry, name, &wl_output_interface,
                             version < 4 ? version : 4);
    wl_output_add_listener(o->wl, &output_listener, o);
  }
}
static void removed(void *data, struct wl_registry *r, uint32_t id) {
  (void)r;
  struct state *s = data;
  for (unsigned i = 0; i < s->outputs_len; i++)
    if (s->outputs[i].id == id && s->selected == s->outputs[i].wl)
      stopping = 1;
}
static const struct wl_registry_listener registry_listener = {global, removed};
static void frame_buffer(void *data, struct zwlr_screencopy_frame_v1 *frame,
                         uint32_t format, uint32_t w, uint32_t h,
                         uint32_t stride) {
  (void)frame;
  struct state *s = data;
  s->format = format;
  s->width = w;
  s->height = h;
  s->stride = stride;
}
static void frame_flags(void *d, struct zwlr_screencopy_frame_v1 *f,
                        uint32_t flags) {
  (void)f;
  ((struct state *)d)->flags = flags;
}
static void ready(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t hi,
                  uint32_t lo, uint32_t ns) {
  (void)f;
  (void)hi;
  (void)lo;
  (void)ns;
  ((struct state *)d)->done = true;
}
static void failed(void *d, struct zwlr_screencopy_frame_v1 *f) {
  (void)f;
  ((struct state *)d)->failed = true;
  ((struct state *)d)->done = true;
}
static void damage(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t x,
                   uint32_t y, uint32_t w, uint32_t h) {
  (void)d;
  (void)f;
  (void)x;
  (void)y;
  (void)w;
  (void)h;
}
static void dmabuf(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t fmt,
                   uint32_t w, uint32_t h) {
  (void)d;
  (void)f;
  (void)fmt;
  (void)w;
  (void)h;
}
static void buffer_done(void *data, struct zwlr_screencopy_frame_v1 *frame) {
  struct state *s = data;
  if (!s->width || !s->height || s->width > 16384 || s->height > 16384 ||
      s->stride < s->width * 4 || s->stride > INT_MAX / s->height || s->copying)
    die("invalid or missing screencopy SHM buffer");
  if (s->format != WL_SHM_FORMAT_XRGB8888 &&
      s->format != WL_SHM_FORMAT_ARGB8888 &&
      s->format != WL_SHM_FORMAT_XBGR8888 &&
      s->format != WL_SHM_FORMAT_ABGR8888)
    die("unsupported screencopy format (need 32-bit RGB)");
  s->bytes = (size_t)s->stride * s->height;
  int fd = memfd_create("rmpp-screencopy", MFD_CLOEXEC);
  if (fd < 0 || ftruncate(fd, (off_t)s->bytes))
    die("cannot allocate screencopy storage");
  s->pixels = mmap(NULL, s->bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (s->pixels == MAP_FAILED)
    die("cannot map screencopy storage");
  struct wl_shm_pool *pool = wl_shm_create_pool(s->shm, fd, (int)s->bytes);
  s->buffer = wl_shm_pool_create_buffer(pool, 0, (int)s->width, (int)s->height,
                                        (int)s->stride, s->format);
  wl_shm_pool_destroy(pool);
  close(fd);
  s->copying = true;
  zwlr_screencopy_frame_v1_copy(frame, s->buffer);
}
static const struct zwlr_screencopy_frame_v1_listener frame_listener = {
    frame_buffer, frame_flags, ready, failed, damage, dmabuf, buffer_done};
static bool capture(struct state *s) {
  s->done = s->failed = s->copying = false;
  s->width = 0;
  s->flags = 0;
  struct zwlr_screencopy_frame_v1 *f =
      zwlr_screencopy_manager_v1_capture_output(s->manager, 1, s->selected);
  zwlr_screencopy_frame_v1_add_listener(f, &frame_listener, s);
  while (!s->done && !stopping) {
    while (wl_display_prepare_read(s->display) != 0) {
      if (wl_display_dispatch_pending(s->display) < 0)
        die("Wayland dispatch failed");
      if (s->done || stopping)
        break;
    }
    if (s->done || stopping)
      break;
    if (wl_display_flush(s->display) < 0 && errno != EAGAIN) {
      wl_display_cancel_read(s->display);
      die("Wayland flush failed");
    }
    struct pollfd p = {wl_display_get_fd(s->display), POLLIN, 0};
    int r = poll(&p, 1, 5000);
    if (r < 0 && errno == EINTR) {
      wl_display_cancel_read(s->display);
      continue;
    }
    if (r <= 0 || !(p.revents & POLLIN)) {
      wl_display_cancel_read(s->display);
      die("screencopy timeout or compositor disconnected");
    }
    if (wl_display_read_events(s->display) < 0 ||
        wl_display_dispatch_pending(s->display) < 0)
      die("compositor disconnected");
  }
  zwlr_screencopy_frame_v1_destroy(f);
  if (s->failed)
    die("compositor refused screencopy");
  return !stopping;
}
static void release_frame(struct state *s) {
  if (s->buffer)
    wl_buffer_destroy(s->buffer);
  if (s->pixels && s->pixels != MAP_FAILED)
    munmap(s->pixels, s->bytes);
  s->buffer = NULL;
  s->pixels = NULL;
}
static void convert(struct state *s, uint8_t *dst, unsigned w, unsigned h,
                    bool dither) {
  /* Ordered Bayer dithering: https://en.wikipedia.org/wiki/Ordered_dithering
   * BT.601 luma integer approximation:
   * https://en.wikipedia.org/wiki/Luma_(video) */
  static const uint8_t bayer[4][4] = {
      {0, 8, 2, 10}, {12, 4, 14, 6}, {3, 11, 1, 9}, {15, 7, 13, 5}};
  bool bgr = s->format == WL_SHM_FORMAT_ABGR8888 ||
             s->format == WL_SHM_FORMAT_XBGR8888;
  for (unsigned y = 0; y < h; y++)
    for (unsigned x = 0; x < w; x++) {
      unsigned sy = (uint64_t)y * s->height / h,
               sx = (uint64_t)x * s->width / w;
      if (s->flags & ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT)
        sy = s->height - 1 - sy;
      uint32_t p;
      memcpy(&p, (uint8_t *)s->pixels + (size_t)sy * s->stride + sx * 4, 4);
      unsigned r = bgr ? (p & 255) : ((p >> 16) & 255), g = (p >> 8) & 255,
               b = bgr ? ((p >> 16) & 255) : (p & 255);
      unsigned gray = (77 * r + 150 * g + 29 * b + 128) >> 8;
      dst[(size_t)y * w + x] =
          dither ? (gray > (unsigned)bayer[y % 4][x % 4] * 16 + 7 ? 255 : 0)
                 : (uint8_t)gray;
    }
}
static bool rect(const uint8_t *a, const uint8_t *b, unsigned w, unsigned h,
                 uint32_t *r, bool first) {
  unsigned x0 = w, y0 = h, x1 = 0, y1 = 0;
  for (unsigned y = 0; y < h; y++)
    for (unsigned x = 0; x < w; x++)
      if (first || a[(size_t)y * w + x] != b[(size_t)y * w + x]) {
        if (x < x0)
          x0 = x;
        if (y < y0)
          y0 = y;
        if (x > x1)
          x1 = x;
        if (y > y1)
          y1 = y;
      }
  if (x0 == w)
    return false;
  r[0] = x0;
  r[1] = y0;
  r[2] = x1 - x0 + 1;
  r[3] = y1 - y0 + 1;
  return true;
}
int main(int argc, char **argv) {
  const char *pgm = NULL, *host = NULL, *quill = NULL, *output = NULL,
             *vendor = NULL;
  unsigned width = 0, height = 0, frames = 0, interval = 100;
  bool dither = true;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--help")) {
      puts("rmpp-einkbridge (--pgm FILE | --quill-host FILE --quill-lib FILE) "
           "[--vendor-lib FILE] [--width N --height N] [--output NAME] "
           "[--frames N] [--interval-ms N] [--grayscale]");
      return 0;
    }
    if (!strcmp(argv[i], "--grayscale")) {
      dither = false;
      continue;
    }
    if (i + 1 == argc)
      die("missing option argument");
    const char *k = argv[i], *v = argv[++i];
    if (!strcmp(k, "--pgm"))
      pgm = v;
    else if (!strcmp(k, "--quill-host"))
      host = v;
    else if (!strcmp(k, "--quill-lib"))
      quill = v;
    else if (!strcmp(k, "--vendor-lib"))
      vendor = v;
    else if (!strcmp(k, "--output"))
      output = v;
    else if (!strcmp(k, "--width"))
      width = number(v);
    else if (!strcmp(k, "--height"))
      height = number(v);
    else if (!strcmp(k, "--frames"))
      frames = number(v);
    else if (!strcmp(k, "--interval-ms"))
      interval = number(v);
    else
      die("unknown option");
  }
  if ((pgm != NULL) == (host != NULL) || (host && !quill) ||
      ((width == 0) != (height == 0)))
    die("choose one output backend; dimensions must be paired");
  signal(SIGTERM, stop);
  signal(SIGINT, stop);
  signal(SIGPIPE, SIG_IGN);
  int panel = -1;
  pid_t worker = -1;
  if (host) {
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair))
      die("socketpair failed");
    worker = fork();
    if (worker < 0)
      die("fork failed");
    if (worker == 0) {
      close(pair[0]);
      if (dup2(pair[1], 3) < 0)
        _exit(127);
      if (pair[1] != 3)
        close(pair[1]);
      if (vendor)
        execl(host, host, "--fd", "3", "--quill-lib", quill, "--vendor-lib",
              vendor, (char *)NULL);
      else
        execl(host, host, "--fd", "3", "--quill-lib", quill, (char *)NULL);
      _exit(127);
    }
    close(pair[1]);
    panel = pair[0];
    uint32_t hello[4];
    if (wire_read(panel, hello, sizeof hello) || hello[0] != EINK_MAGIC ||
        hello[1] != 1 || !hello[2] || !hello[3] || hello[2] > 16384 ||
        hello[3] > 16384)
      die("panel worker did not initialize");
    width = hello[2];
    height = hello[3];
  }
  struct state s = {0};
  s.display = wl_display_connect(NULL);
  if (!s.display)
    die("cannot connect to Wayland display");
  s.registry = wl_display_get_registry(s.display);
  wl_registry_add_listener(s.registry, &registry_listener, &s);
  if (wl_display_roundtrip(s.display) < 0 ||
      wl_display_roundtrip(s.display) < 0)
    die("Wayland discovery failed");
  if (!s.shm || !s.manager || !s.outputs_len)
    die("compositor needs wl_shm and screencopy v3 and an output");
  for (unsigned i = 0; i < s.outputs_len; i++)
    if (!output || !strcmp(output, s.outputs[i].name)) {
      s.selected = s.outputs[i].wl;
      break;
    }
  if (!s.selected)
    die("requested output not found");
  uint8_t *current = NULL, *previous = NULL;
  unsigned count = 0, updates = 0;
  while (!stopping && (!frames || count < frames)) {
    if (!capture(&s))
      break;
    if (!width) {
      width = s.width;
      height = s.height;
    }
    if (!current) {
      current = malloc((size_t)width * height);
      previous = malloc((size_t)width * height);
      if (!current || !previous)
        die("out of memory");
    }
    convert(&s, current, width, height, dither);
    uint32_t dirty[4];
    if (rect(current, previous, width, height, dirty, count == 0)) {
      if (pgm) {
        FILE *f = fopen(pgm, "wb");
        if (!f)
          die("cannot open PGM output");
        fprintf(f, "P5\n%u %u\n255\n", width, height);
        if (fwrite(current, width, height, f) != height || fclose(f))
          die("PGM write failed");
      } else {
        uint32_t message[5] = {EINK_MAGIC, dirty[0], dirty[1], dirty[2],
                               dirty[3]};
        if (wire_write(panel, message, sizeof message))
          die("panel worker disconnected");
        for (unsigned y = dirty[1]; y < dirty[1] + dirty[3]; y++)
          if (wire_write(panel, current + (size_t)y * width + dirty[0],
                         dirty[2]))
            die("panel write failed");
        uint32_t ack;
        if (wire_read(panel, &ack, sizeof ack) || ack != EINK_MAGIC)
          die("panel refresh failed");
      }
      updates++;
    }
    uint8_t *tmp = previous;
    previous = current;
    current = tmp;
    release_frame(&s);
    count++;
    struct timespec delay = {interval / 1000, (interval % 1000) * 1000000L};
    nanosleep(&delay, NULL);
  }
  release_frame(&s);
  free(current);
  free(previous);
  wl_display_disconnect(s.display);
  if (panel >= 0) {
    close(panel);
    int status;
    while (waitpid(worker, &status, 0) < 0 && errno == EINTR) {
    }
  }
  fprintf(stderr, "einkbridge: %u captures, %u changed frames\n", count,
          updates);
  return 0;
}
