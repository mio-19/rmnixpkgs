/* Fake EPFramebuffer implementation to test real Quill without panel hardware.
 * ABI names/layout are the public boundary used by Quill:
 * https://github.com/MaximeRivest/quill/blob/39262ee0bef69915e3ead3ac218d5973916f422a/src/vendor_probe.cpp
 * No vendor binary or implementation is copied here. */
#include <QImage>
#include <QRect>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
static uint32_t pixels[8 * 6];
static QImage *image;
extern "C" void *instance() asm("_ZN13EPFramebuffer8instanceEv");
extern "C" void *instance() {
  if (!image)
    image = new QImage(reinterpret_cast<uchar *>(pixels), 8, 6, 32,
                       QImage::Format_RGB32);
  return image;
}
extern "C" unsigned long swap(void *, QRect, int, int, int)
    asm("_ZN13EPFramebuffer11swapBuffersE5QRect13EPContentType12EPScreenMode6QFlagsINS_10UpdateFlagEE");
extern "C" unsigned long swap(void *, QRect, int, int, int) {
  FILE *f = std::fopen(std::getenv("MOCK_OUTPUT"), "wb");
  if (!f) std::abort();
  std::fwrite(pixels, 1, sizeof pixels, f);
  std::fclose(f);
  return 1;
}
