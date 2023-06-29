// clang++ gen_avif_staircase.cc -lavif -O2 && ./a.out

#include <stdio.h>
#include <stdlib.h>
#include "avif/avif.h"

#define CHECK(x) \
  do { \
    if (!(x)) { \
      fprintf(stderr, "Failed: '%s' at %s:%d\n", #x, __FILE__, __LINE__); \
      exit(1); \
    } \
  } while (0)

uint8_t avif_irot_angle = 0;
uint8_t avif_imir_mode = 0;

void DumpPixelBuffer(const char* filename, uint16_t trc) {
  const int kNumSteps = 17;
  int width = 64 * kNumSteps;
  int height = 64;

    int returnCode = 1;
    avifRWData avifOutput = AVIF_DATA_EMPTY;

    avifImage * image = avifImageCreate(width, height, 10, AVIF_PIXEL_FORMAT_YUV420);
    image->colorPrimaries = AVIF_COLOR_PRIMARIES_BT2020;
    image->transferCharacteristics = trc; // AVIF_TRANSFER_CHARACTERISTICS_HLG;
    image->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_IDENTITY; // AVIF_MATRIX_COEFFICIENTS_BT2020_NCL;
    image->transformFlags = AVIF_TRANSFORM_IROT;
    image->irot.angle = 0;
    image->yuvRange = AVIF_RANGE_FULL;
    avifImageAllocatePlanes(image, AVIF_PLANES_YUV);
    {
      int plane_width = image->width;
      int plane_height = image->height;
      for (int y = 0; y < plane_height; ++y) {
        uint16_t* out_y_row = (uint16_t*)(image->yuvPlanes[AVIF_CHAN_Y] + y*image->yuvRowBytes[AVIF_CHAN_Y]);
        for (int x = 0;  x < plane_width; ++x) {
          uint16_t step = (x * kNumSteps) / plane_width;
          uint16_t grey = 1024 * (step * 1.f / (kNumSteps - 1));
          out_y_row[x] = grey;
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
          uint16_t step = (x * kNumSteps) / plane_width;
          uint16_t grey = 1024 * (step * 1.f / (kNumSteps - 1));
          out_u_row[x] = grey;
          out_v_row[x] = grey;
        }
      }
    }

    avifEncoder * encoder = NULL;
    encoder = avifEncoderCreate();
    encoder->maxThreads = 8;
    // AVIF_QUANTIZER_WORST_QUALITY , AVIF_QUANTIZER_LOSSLESS
    encoder->minQuantizer = AVIF_QUANTIZER_LOSSLESS;
    encoder->maxQuantizer = AVIF_QUANTIZER_LOSSLESS;
    encoder->minQuantizerAlpha = AVIF_QUANTIZER_LOSSLESS;
    encoder->maxQuantizerAlpha = AVIF_QUANTIZER_LOSSLESS;
    // encoder->speed = 10;

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
  DumpPixelBuffer("staircase-srgb.avif", AVIF_TRANSFER_CHARACTERISTICS_SRGB);
  DumpPixelBuffer("staircase-hlg.avif", AVIF_TRANSFER_CHARACTERISTICS_HLG);
  DumpPixelBuffer("staircase-pq.avif", AVIF_TRANSFER_CHARACTERISTICS_SMPTE2084);
  return 0;
}
