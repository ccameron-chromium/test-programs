// Dump the first frame of a mov file.
// clang++ heic2avif.mm -framework AVFoundation -framework QuartzCore -framework CoreMedia -framework VideoToolbox -framework Cocoa ../libavif/libavif_internal.a ../libavif/ext/aom_build/libaom.a -g -o heic2avif

#include <Cocoa/Cocoa.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>
#include <ImageIO/CGImageSource.h>
#include <map>
#include <deque>
#include <algorithm>
#include <stdio.h>

#include "avif/avif.h"

#define CHECK(x) \
  do { \
    if (!(x)) { \
      fprintf(stderr, "Failed: '%s' at %s:%d\n", #x, __FILE__, __LINE__); \
      exit(1); \
    } \
  } while (0)

const float BT2020_10bit_limited_rgb_to_yuv[] = {
      0.224951f,  0.580575f,  0.050779f,  0.000000f,  0.062561f,
     -0.122296f, -0.315632f,  0.437928f,  0.000000f,  0.500489f,
      0.437928f, -0.402706f, -0.035222f,  0.000000f,  0.500489f,
      0.000000f,  0.000000f,  0.000000f,  1.000000f,  0.000000f,
};
void RGBtoYUV(const float rgb[3], float yuv[3]) {
  for (int i = 0; i < 3; ++i) {
    yuv[i] = BT2020_10bit_limited_rgb_to_yuv[5*i + 4];
    for (int j = 0; j < 3; ++j) {
      yuv[i] += BT2020_10bit_limited_rgb_to_yuv[5*i + j] * rgb[j];
    }
  }
}
void RGBtoYUV16(const float rgb[3], uint16_t yuv16[3]) {
  float yuv[3];
  RGBtoYUV(rgb, yuv);

  for (int i = 0; i < 3; ++i) {
    yuv[i] = 65535.f * yuv[i] + 0.5f;
    yuv16[i] = static_cast<uint16_t>(yuv[i]);
  }
}

int orientation_int = 0;

CGImageRef LoadImage(const char* filename) {
  printf("Loading: %s\n", filename);

  CGDataProviderRef provider = CGDataProviderCreateWithFilename(filename);
  CHECK(provider);
  CGImageSourceRef source = CGImageSourceCreateWithDataProvider(provider, nullptr);
  CHECK(source);

  CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr);
  CFNumberRef orientation = static_cast<CFNumberRef>(CFDictionaryGetValue(properties, kCGImagePropertyOrientation));
  CFNumberGetValue(orientation, kCFNumberIntType, &orientation_int);
  printf("Orientation: %d\n", orientation_int);
  NSDictionary* options = @{(id)kCGImageSourceDecodeToHDR: @(YES)};

  CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, (CFDictionaryRef)options);
  CHECK(image);
  return image;
}

uint8_t avif_irot_angle = 0;
uint8_t avif_imir_mode = 0;

void CGAffineTransformToAVIF(CGAffineTransform t, uint8_t* irot_angle, uint8_t* imir_mode) {
  *imir_mode = 0;
  if (t.a == 1 && t.b == 0 && t.c == 0 && t.d == 1) {
    *irot_angle = 0;
  } else if (t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0) {
    *irot_angle = 3;
  } else if (t.a == -1 && t.b == 0 && t.c == 0 && t.d == -1) {
    *irot_angle = 2;
  } else if (t.a == 0 && t.b == -1 && t.c == 1 && t.d == -1) {
    *irot_angle = 1;
  } else {
    printf("Failed to convert CGAFffineTransform\n");
  }
}

void DrawStuff(CGImageRef cg_image, const char* outname) {
  const int width = CGImageGetWidth(cg_image);
  const int height = CGImageGetHeight(cg_image);
  const int kColors = 4;
  const int kBytesPerColor = 4;

  float* pixels = new float[kColors*width*height];
  memset(pixels, 0, kBytesPerColor*kColors*width*height);

  CGColorSpaceRef cs = CGImageGetColorSpace(cg_image);
  CFShow(CGColorSpaceGetName(cs));

  // cg_image = CGImageCreateCopyWithColorSpace(cg_image, CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
  CGContextRef ctx = CGBitmapContextCreate(
      pixels, width, height, 8*kBytesPerColor, kBytesPerColor*kColors*width,
      // CGColorSpaceCreateWithName(kCGColorSpaceSRGB),
      cs,
      kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Host|kCGBitmapFloatComponents);
  CHECK(ctx);

  CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), cg_image);
  CFRelease(ctx);

  


    int returnCode = 1;
    avifRWData avifOutput = AVIF_DATA_EMPTY;

    avifImage * image = avifImageCreate(width, height, 10, AVIF_PIXEL_FORMAT_YUV420);
    image->colorPrimaries = AVIF_COLOR_PRIMARIES_BT2020;
    image->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_SMPTE2084;
    // image->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_HLG;

    if (CFStringCompare(kCGColorSpaceDisplayP3_PQ, CGColorSpaceGetName(cs), 0) == kCFCompareEqualTo) {
      image->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_SMPTE2084;
      image->colorPrimaries = AVIF_COLOR_PRIMARIES_SMPTE432;
    } else {
      CHECK(0);
    }

    image->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT2020_NCL;
   // image->transformFlags = AVIF_TRANSFORM_IROT;
   // image->irot.angle = avif_irot_angle;


  switch (orientation_int) {
      case 1:
          image->transformFlags = 0;
          image->irot.angle = 0;
          image->imir.mode = 0; 
          break;
      case 2:
          image->transformFlags = AVIF_TRANSFORM_IMIR;
          image->irot.angle = 0;
          image->imir.mode = 1;
          break;
      case 3:
          image->transformFlags = AVIF_TRANSFORM_IROT;
          image->irot.angle = 2;
          image->imir.mode = 0;
          break;
      case 4:
          image->transformFlags = AVIF_TRANSFORM_IMIR;
          image->irot.angle = 0;
          image->imir.mode = 0;
          break;
      case 5:
          image->transformFlags = AVIF_TRANSFORM_IROT | AVIF_TRANSFORM_IMIR;
          image->irot.angle = 1;
          image->imir.mode = 0;
          break;
      case 6:
          image->transformFlags = AVIF_TRANSFORM_IROT;
          image->irot.angle = 3;
          image->imir.mode = 0;
          break;
      case 7:
          image->transformFlags = AVIF_TRANSFORM_IROT | AVIF_TRANSFORM_IMIR;
          image->irot.angle = 3;
          image->imir.mode = 0;
          break;
      case 8:
          image->transformFlags = AVIF_TRANSFORM_IROT;
          image->irot.angle = 1;
          image->imir.mode = 0;
          break;
  }



    image->yuvRange = AVIF_RANGE_LIMITED;
    avifImageAllocatePlanes(image, AVIF_PLANES_YUV);
    {

      int plane_width = image->width;
      int plane_height = image->height;

      for (int y = 0; y < plane_height; ++y) {
        uint16_t* out_y_row = (uint16_t*)(image->yuvPlanes[AVIF_CHAN_Y] + y*image->yuvRowBytes[AVIF_CHAN_Y]);
        for (int x = 0; x < plane_width; ++x) {
          const float* rgb = pixels + kColors * (y * width + x);
          uint16_t yuv[3];
          RGBtoYUV16(rgb, yuv);
          out_y_row[x] = yuv[0] >> 6;
        }
      }
    }
    {
      int plane_width = image->width / 2;
      int plane_height = image->height / 2;
      for (int y = 0; y < plane_height; ++y) {
        uint16_t* out_u_row = (uint16_t*)(image->yuvPlanes[AVIF_CHAN_U] + y*image->yuvRowBytes[AVIF_CHAN_U]);
        uint16_t* out_v_row = (uint16_t*)(image->yuvPlanes[AVIF_CHAN_V] + y*image->yuvRowBytes[AVIF_CHAN_V]);
        for (int x = 0; x < plane_width; ++x) {
          const float* rgb = pixels + kColors * (2 * y * width + 2*x);
          uint16_t yuv[3];
          RGBtoYUV16(rgb, yuv);
          out_u_row[x] = yuv[1] >> 6;
          out_v_row[x] = yuv[2] >> 6;
        }
      }
    }

    avifEncoder * encoder = NULL;
    encoder = avifEncoderCreate();
    encoder->maxThreads = 8;
    encoder->speed = 10;

    printf("Going to encode...\n");

    // Call avifEncoderAddImage() for each image in your sequence
    // Only set AVIF_ADD_IMAGE_FLAG_SINGLE if you're not encoding a sequence
    // Use avifEncoderAddImageGrid() instead with an array of avifImage* to make a grid image
    avifResult addImageResult = avifEncoderAddImage(encoder, image, 1, AVIF_ADD_IMAGE_FLAG_SINGLE);
    if (addImageResult != AVIF_RESULT_OK) {
        fprintf(stderr, "Failed to add image to encoder: %s\n", avifResultToString(addImageResult));
        exit(1);
    }

    printf("Finishing encode\n");

    avifResult finishResult = avifEncoderFinish(encoder, &avifOutput);
    if (finishResult != AVIF_RESULT_OK) {
        fprintf(stderr, "Failed to finish encode: %s\n", avifResultToString(finishResult));
        exit(1);
    }

    printf("Encode success: %zu total bytes\n", avifOutput.size);

    char filename[1024];
    static int counter = 0;
    sprintf(filename, "out%05d.avif", counter);
    if (outname) {
      sprintf(filename, "%s", outname);
    }
    counter += 1;
    FILE * f = fopen(filename, "wb");
    size_t bytesWritten = fwrite(avifOutput.data, 1, avifOutput.size, f);
    fclose(f);
    if (bytesWritten != avifOutput.size) {
        fprintf(stderr, "Failed to write %zu bytes\n", avifOutput.size);
        exit(1);
    }
    printf("Wrote %s\n", filename);

    if (image) {
        avifImageDestroy(image);
    }
    if (encoder) {
        avifEncoderDestroy(encoder);
    }
    avifRWDataFree(&avifOutput);


}

int main(int argc, char* argv[]) {
  if (argc != 2 && argc != 3) {
    printf("Usage: %s input.heic [output.avif]\n", argv[0]);
    return 1;
  }

  CGImageRef image = LoadImage(argv[1]);
  DrawStuff(image, argc > 2 ? argv[2] : nullptr);
  return 0;
}
