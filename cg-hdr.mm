// clang++ cg-hdr.mm -framework CoreGraphics -framework CoreFoundation -framework ImageIO && ./a.out
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/CGImageSource.h>
#include <Cocoa/Cocoa.h>
#include <stdio.h>
#include <stdlib.h>

const int kBlock = 64;
const int kSteps = 65;
const int kWidth = kSteps * kBlock;
const int kHeight = kBlock;
const int kColors = 4;
const int kBytesPerColor = 4;

#define CHECK(x) \
  do { \
    if (!(x)) { \
      fprintf(stderr, "Failed: '%s' at %s:%d\n", #x, __FILE__, __LINE__); \
      exit(1); \
    } \
  } while (0)

CGImageRef LoadImage(const char* filename) {
  printf("Loading: %s\n", filename);

  CGDataProviderRef provider = CGDataProviderCreateWithFilename(filename);
  CHECK(provider);
  CGImageSourceRef source = CGImageSourceCreateWithDataProvider(provider, nullptr);
  CHECK(source);

  // NSDictionary* options = @{(id)kCGImageSourceDecodeToHDR: @(YES)};
  NSDictionary* options = nullptr;

  CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, (CFDictionaryRef)options);
  CHECK(image);
  // CFShow(CGImageGetColorSpace(image));
  printf(" is HDR: %d\n", CGColorSpaceUsesITUR_2100TF(CGImageGetColorSpace(image)));
  return image;
}

void DrawStuff(CFStringRef dst_space, const char* dst_space_name, CGImageRef image) {
  float* pixels = new float[kColors*kWidth*kHeight];
  memset(pixels, 0, kBytesPerColor*kColors*kWidth*kHeight);

  CGContextRef ctx = CGBitmapContextCreate(
      pixels, kWidth, kHeight, 8*kBytesPerColor, kBytesPerColor*kColors*kWidth,
      CGColorSpaceCreateWithName(dst_space), kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Host|kCGBitmapFloatComponents);
  CHECK(ctx);

  if (image) {
    CGContextDrawImage(ctx, CGRectMake(0, 0, kWidth, kHeight), image);
  } else {
    printf("src_sRGB = np.array([");
    for (int i = 0; i < kSteps; ++i) {
      float value = i/(kSteps - 1.f);
      CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
      CGFloat components[4] = {value, value, value, 1};
      CGColorRef color = CGColorCreate(space, components);
      CGContextSetFillColorWithColor(ctx, color);
      CFRelease(color);
      printf("%f, ", value);
      CGContextFillRect(ctx, CGRectMake(i*kBlock, 0, kBlock, kBlock));
    }
    printf("])\n");
  }
  CFRelease(ctx);

  printf("dst_%s = np.array([", dst_space_name);

  for (int i = 0; i < kSteps; ++i) {
    int x = kBlock * i + kBlock/2;
    int y = kBlock/2;
    float* pixel = pixels + kColors*(kWidth*y + x);
    printf("%f, ", pixel[2]);
  }
  printf("])\n");
}

int main(int argc, char* argv[]) {
  CGImageRef srgb_staircase = LoadImage("staircase-srgb.avif");
  // CGImageRef hlg_staircase = LoadImage("staircase-hlg.avif");
  // CGImageRef pq_staircase = LoadImage("staircase-pq.avif");

  DrawStuff(kCGColorSpaceSRGB, "sRGB", nullptr);
  printf("\n");
  DrawStuff(kCGColorSpaceITUR_2100_PQ, "pq", nullptr);
  printf("\n");
  DrawStuff(kCGColorSpaceITUR_2100_HLG, "hlg", nullptr);

  return 0;
}

