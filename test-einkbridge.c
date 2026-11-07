/* Regression tests for independent frame conversion/damage handling. */
#define main einkbridge_main
#include "einkbridge.c"
#undef main
#include <assert.h>
int main(void) {
  uint32_t pixels[6] = {0x00ff0000, 0x000000ff, 0xdeadbeef,
                        0x00ffffff, 0,          0xdeadbeef};
  struct state s = {.pixels = pixels,
                    .width = 2,
                    .height = 2,
                    .stride = 12,
                    .format = WL_SHM_FORMAT_XRGB8888};
  uint8_t out[16], old[16] = {0};
  uint32_t r[4];
  convert(&s, out, 2, 2, false);
  assert(out[0] == 77 && out[1] == 29 && out[2] == 255 && out[3] == 0);
  s.flags = ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT;
  convert(&s, out, 2, 2, false);
  assert(out[0] == 255 && out[1] == 0 && out[2] == 77);
  s.flags = 0;
  s.format = WL_SHM_FORMAT_XBGR8888;
  convert(&s, out, 2, 2, false);
  assert(out[0] == 29 && out[1] == 77);
  s.format = WL_SHM_FORMAT_ARGB8888;
  convert(&s, out, 4, 4, false);
  assert(out[0] == 77 && out[1] == 77 && out[2] == 29 && out[8] == 255 &&
         out[15] == 0);
  for (unsigned i = 0; i < 6; i++)
    pixels[i] = 0x00808080;
  convert(&s, out, 4, 4, true);
  unsigned white = 0;
  for (unsigned i = 0; i < 16; i++) {
    assert(out[i] == 0 || out[i] == 255);
    white += out[i] == 255;
  }
  assert(white == 8);
  assert(rect(out, old, 4, 4, r, true) && r[0] == 0 && r[1] == 0 && r[2] == 4 &&
         r[3] == 4);
  memcpy(old, out, 16);
  assert(!rect(out, old, 4, 4, r, false));
  out[15] ^= 255;
  assert(rect(out, old, 4, 4, r, false) && r[0] == 3 && r[1] == 3 &&
         r[2] == 1 && r[3] == 1);
  puts("conversion, stride, channel order, inversion, scaling, dithering and "
       "damage tests passed");
  return 0;
}
