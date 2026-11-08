/* Test double for the Quill C ABI; never installed on the tablet. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#ifndef TABLET_QT
#error TABLET_QT must come from os.nix
#endif
static uint32_t image[8 * 6];
const char *qVersion(void) {
  const char *v = getenv("MOCK_QT");
  return v ? v : TABLET_QT;
}
int quill_init(void) {
  const char *p = getenv("MOCK_INIT");
  if (p) {
    FILE *f = fopen(p, "w");
    if (f)
      fclose(f);
  }
  return 0;
}
int quill_width(void) { return 8; }
int quill_height(void) { return 6; }
int quill_stride(void) { return 32; }
int quill_format(void) { return 4; }
unsigned char *quill_buffer(void) { return (unsigned char *)image; }
unsigned long quill_swap_mono_fast(int x, int y, int w, int h) {
  (void)x;
  (void)y;
  (void)w;
  (void)h;
  FILE *f = fopen(getenv("MOCK_OUTPUT"), "wb");
  if (!f)
    abort();
  fwrite(image, 1, sizeof image, f);
  fclose(f);
  return 1;
}
void quill_process_events(void) {}

void mock_image(void) __asm__("_ZN6QImageC1EPhiixNS_6FormatEPFvPvES2_");
void mock_image(void) {}
