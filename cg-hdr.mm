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

/*
Sonoma output:
src_sRGB = np.array([0.000000, 0.015625, 0.031250, 0.046875, 0.062500, 0.078125, 0.093750, 0.109375, 0.125000, 0.140625, 0.156250, 0.171875, 0.187500, 0.203125, 0.218750, 0.234375, 0.250000, 0.265625, 0.281250, 0.296875, 0.312500, 0.328125, 0.343750, 0.359375, 0.375000, 0.390625, 0.406250, 0.421875, 0.437500, 0.453125, 0.468750, 0.484375, 0.500000, 0.515625, 0.531250, 0.546875, 0.562500, 0.578125, 0.593750, 0.609375, 0.625000, 0.640625, 0.656250, 0.671875, 0.687500, 0.703125, 0.718750, 0.734375, 0.750000, 0.765625, 0.781250, 0.796875, 0.812500, 0.828125, 0.843750, 0.859375, 0.875000, 0.890625, 0.906250, 0.921875, 0.937500, 0.953125, 0.968750, 0.984375, 1.000000, ])

dst_PQ = np.array([0.000001, 0.089803, 0.116683, 0.135337, 0.152281, 0.168265, 0.183395, 0.197760, 0.211436, 0.224484, 0.236966, 0.248925, 0.260408, 0.271449, 0.282082, 0.292342, 0.302247, 0.311827, 0.321101, 0.330086, 0.338806, 0.347268, 0.355491, 0.363491, 0.371269, 0.378852, 0.386241, 0.393449, 0.400478, 0.407343, 0.414051, 0.420607, 0.427018, 0.433291, 0.439432, 0.445444, 0.451342, 0.457112, 0.462774, 0.468326, 0.473777, 0.479117, 0.484370, 0.489523, 0.494589, 0.499566, 0.504460, 0.509272, 0.514004, 0.518663, 0.523242, 0.527753, 0.532189, 0.536567, 0.540871, 0.545113, 0.549293, 0.553413, 0.557471, 0.561477, 0.565423, 0.569320, 0.573160, 0.576948, 0.580692, ])

dst_HLG = np.array([0.000000, 0.031007, 0.043851, 0.053946, 0.064022, 0.074369, 0.084963, 0.095782, 0.106809, 0.118029, 0.129431, 0.141002, 0.152734, 0.164618, 0.176647, 0.188814, 0.201113, 0.213539, 0.226087, 0.238752, 0.251530, 0.264417, 0.277410, 0.290504, 0.303699, 0.316989, 0.330373, 0.343848, 0.357411, 0.371061, 0.384795, 0.398611, 0.412508, 0.426483, 0.440535, 0.454661, 0.468862, 0.483134, 0.497478, 0.511644, 0.525203, 0.538204, 0.550697, 0.562727, 0.574332, 0.585545, 0.596397, 0.606912, 0.617114, 0.627024, 0.636661, 0.646041, 0.655179, 0.664090, 0.672785, 0.681277, 0.689575, 0.697690, 0.705631, 0.713405, 0.721020, 0.728483, 0.735802, 0.742981, 0.750028, ])

Ventura output:
X
*/

int main(int argc, char* argv[]) {
  CGImageRef srgb_staircase = LoadImage("staircase-srgb.avif");
  // CGImageRef hlg_staircase = LoadImage("staircase-hlg.avif");
  // CGImageRef pq_staircase = LoadImage("staircase-pq.avif");

  DrawStuff(kCGColorSpaceSRGB, "sRGB", nullptr);
  printf("\n");
  DrawStuff(kCGColorSpaceITUR_2100_PQ, "PQ", nullptr);
  printf("\n");
  DrawStuff(kCGColorSpaceITUR_2100_HLG, "HLG", nullptr);

  return 0;
}

