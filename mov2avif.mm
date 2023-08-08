// Dump the first frame of a mov file.
// clang++ mov2avif.mm -framework AVFoundation -framework QuartzCore -framework CoreMedia -framework VideoToolbox -framework Cocoa -lavif -O2 && ./a.out test.mov

#include <Cocoa/Cocoa.h>
#include <AVFoundation/AVFoundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VTDecompressionSession.h>
#include <map>
#include <deque>
#include <stdio.h>

#include "avif/avif.h"

#define CHECK(x) \
  do { \
    if (!(x)) { \
      fprintf(stderr, "Failed: '%s' at %s:%d\n", #x, __FILE__, __LINE__); \
      exit(1); \
    } \
  } while (0)

CALayer* background_layer = nil;
VTDecompressionSessionRef vt_decompression_session = 0;
AVSampleBufferDisplayLayer* sample_display_layer = nil;
typedef std::map<CFAbsoluteTime, CVImageBufferRef> TimeToFrameMap;
TimeToFrameMap decoded_images;
std::deque<CVImageBufferRef> displayed_images;
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

void DumpPixelBuffer(CVPixelBufferRef pixel_buffer) {
  CVPixelBufferLockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
  int width = CVPixelBufferGetWidth(pixel_buffer);
  int height = CVPixelBufferGetHeight(pixel_buffer);

    int returnCode = 1;
    avifRWData avifOutput = AVIF_DATA_EMPTY;

    avifImage * image = avifImageCreate(width, height, 10, AVIF_PIXEL_FORMAT_YUV420);
    image->colorPrimaries = AVIF_COLOR_PRIMARIES_BT2020;
    image->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_HLG;
    image->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT2020_NCL;
    image->transformFlags = AVIF_TRANSFORM_IROT;
    image->irot.angle = avif_irot_angle;
    image->yuvRange = AVIF_RANGE_LIMITED;
    avifImageAllocatePlanes(image, AVIF_PLANES_YUV);
    {

      int plane_width = image->width;
      int plane_height = image->height;

      uint8_t* in_y = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, 0);
      size_t in_y_stride = CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, 0);
      CHECK(plane_width == CVPixelBufferGetWidthOfPlane(pixel_buffer, 0));
      CHECK(plane_height == CVPixelBufferGetHeightOfPlane(pixel_buffer, 0));

      for (int y = 0; y < plane_height; ++y) {
        uint16_t* in_y_row = (uint16_t*)(in_y + y*in_y_stride);
        uint16_t* out_y_row = (uint16_t*)(image->yuvPlanes[AVIF_CHAN_Y] + y*image->yuvRowBytes[AVIF_CHAN_Y]);
        for (int x = 0; x < plane_width; ++x) {
          out_y_row[x] = in_y_row[x] >> 6;
        }
      }
    }
    {
      uint8_t* in_uv = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, 1);
      size_t in_uv_stride = CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, 1);

      int plane_width = image->width / 2;
      int plane_height = image->height / 2;
      for (int y = 0; y < plane_height; ++y) {
        uint16_t* in_uv_row = (uint16_t*)(in_uv + y*in_uv_stride);
        uint16_t* out_u_row = (uint16_t*)(image->yuvPlanes[AVIF_CHAN_U] + y*image->yuvRowBytes[AVIF_CHAN_U]);
        uint16_t* out_v_row = (uint16_t*)(image->yuvPlanes[AVIF_CHAN_V] + y*image->yuvRowBytes[AVIF_CHAN_V]);
        for (int x = 0; x < plane_width; ++x) {
          out_u_row[x] = in_uv_row[2*x] >> 6;
          out_v_row[x] = in_uv_row[2*x+1] >> 6;
        }
      }
    }

    avifEncoder * encoder = NULL;
    encoder = avifEncoderCreate();
    encoder->maxThreads = 8;
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

    char filename[1024];
    static int counter = 0;
    sprintf(filename, "out%05d.avif", counter);
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
  
  CVPixelBufferUnlockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
  exit(0);
}

// Read an entire mp4 file in filename into cm_sample_buffers_from_asset_reader.
std::deque<CMSampleBufferRef> cm_sample_buffers_from_asset_reader;
void ReadFileFromDisk(const char* filename) {
  AVAssetReaderOutput* asset_reader_output = nil;
  AVAsset* asset = nil;
  AVAssetTrack* video_track = nil;
  AVAssetReader* asset_reader = nil;

  NSURL* url = [NSURL fileURLWithPath:[[NSString alloc]
      initWithUTF8String:filename]];

  asset = [AVAsset assetWithURL:url];
  video_track = [[asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
  asset_reader_output = [[AVAssetReaderTrackOutput alloc]
      initWithTrack:video_track outputSettings:nil];
  NSError* error = nil;
  asset_reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
  CHECK(!error);
  [asset_reader addOutput:asset_reader_output];
  [asset_reader startReading];


  printf("getting orientation\n");
  fflush(stdout);
  CGAffineTransformToAVIF([video_track preferredTransform],
                          &avif_irot_angle,
                          &avif_imir_mode);
  printf("angle:%d, mode:%d\n", avif_irot_angle, avif_imir_mode);

  printf("Reading the entire stream from disk...\n");
  while (1) {
    CMSampleBufferRef cm_sample_buffer =
        [asset_reader_output copyNextSampleBuffer];
    if (!cm_sample_buffer)
      break;

    // CFShow(cm_sample_buffer);
    cm_sample_buffers_from_asset_reader.push_back(cm_sample_buffer);
  }
  printf("Done.\n");

  [asset_reader cancelReading];
  [asset_reader_output release];
  [asset_reader release];
  [asset release];
}

// Initialize the CALayer, which will have its contents set to each frame.
void InitializeLayer() {
  [sample_display_layer removeFromSuperlayer];
  [sample_display_layer release];
  sample_display_layer = nil;

  sample_display_layer = [[AVSampleBufferDisplayLayer alloc] init];
  [sample_display_layer setBackgroundColor:CGColorGetConstantColor(kCGColorBlack)];
  [background_layer addSublayer:sample_display_layer];
  [sample_display_layer setFrame:CGRectMake(0, 0, 1240, 690)];
}

static void DecompressionSessionOutputCallback(
    void* decompression_output_refcon,
    void* source_frame_refcon,
    OSStatus status,
    VTDecodeInfoFlags info_flags,
    CVImageBufferRef image_buffer,
    CMTime presentation_time_stamp,
    CMTime presentation_duration) {
  CHECK(image_buffer);
  CHECK(!status);
  CHECK(CFGetTypeID(image_buffer) == CVPixelBufferGetTypeID());
  CFRetain(image_buffer);

  CFAbsoluteTime key_time = CMTimeGetSeconds(presentation_time_stamp);
  if (decoded_images[key_time])
    CFRelease(decoded_images[key_time]);
  decoded_images[key_time] = image_buffer;
}

// This will re-allocate a VTDecompressionSession that is capable of decoding
// |cm_sample_buffer|, if needed.
void PrepareDecompressionSessionForCMSampleBuffer(
    CMSampleBufferRef cm_sample_buffer) {
  CHECK(cm_sample_buffer);

  // Retrieve the CMVideoFormatDescription.
  CMVideoFormatDescriptionRef cm_video_format_description =
      CMSampleBufferGetFormatDescription(cm_sample_buffer);
  CHECK(cm_video_format_description);

  // If we already have initialized the VTDecompressionSession, and it can
  // accept this |cm_sample_buffer|, we're done.
  if (vt_decompression_session) {
    if (VTDecompressionSessionCanAcceptFormatDescription(
        vt_decompression_session, cm_video_format_description)) {
      return;
    }
    printf("Creating a new VTDecompressionSession\n");
    VTDecompressionSessionWaitForAsynchronousFrames(vt_decompression_session);
    CFRelease(vt_decompression_session);
    vt_decompression_session = 0;
  } else {
    printf("Creating first VTDecompressionSession\n");
  }

  // Construct the decoder configuration.
  CFMutableDictionaryRef decoder_parameters = CFDictionaryCreateMutable(
      kCFAllocatorDefault,
      0,
      &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CHECK(decoder_parameters);
  {
    CFDictionarySetValue(decoder_parameters,
        kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder,
        kCFBooleanTrue);
  }

  // Construct the output pixel buffer attributes.
  // This doen'st help.
  CFMutableDictionaryRef pixel_buffer_attributes = CFDictionaryCreateMutable(
      kCFAllocatorDefault,
      0,
      &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CHECK(pixel_buffer_attributes);
  {
    // Retrieve the video dimensions (for the output pixel buffer attributes).
    CMVideoDimensions cm_video_dimensions =
        CMVideoFormatDescriptionGetDimensions(cm_video_format_description);

    // None of these seem to make any difference.
    CFDictionarySetValue(pixel_buffer_attributes,
        kCVPixelBufferWidthKey, 
        CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &cm_video_dimensions.width));
    CFDictionarySetValue(pixel_buffer_attributes,
        kCVPixelBufferHeightKey,
        CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &cm_video_dimensions.height));

    // This makes a big difference. Without it we get some &xvo format that... boh.
    int32_t pixel_format = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    CFDictionarySetValue(
        pixel_buffer_attributes,
        kCVPixelBufferPixelFormatTypeKey,
        CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pixel_format));

    // Also doesn't seem to matter.
    CFDictionarySetValue(pixel_buffer_attributes,
        kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey, kCFBooleanTrue);
  }

  // Configure the frame-is-decoded callback.
  VTDecompressionOutputCallbackRecord vt_decompression_callback_record;
  {
    vt_decompression_callback_record.decompressionOutputCallback =
        DecompressionSessionOutputCallback;
    vt_decompression_callback_record.decompressionOutputRefCon = 0;
  }

  // Allocate the VTDecompressionSession.
  OSStatus decompression_session_create_status = VTDecompressionSessionCreate(
      kCFAllocatorDefault,
      cm_video_format_description,
      decoder_parameters,
      pixel_buffer_attributes,
      &vt_decompression_callback_record,
      &vt_decompression_session);
  if (decompression_session_create_status) {
    printf("Failed VTDecompressionSessionCreate ... this is usually because hardware\n");
    printf("acceleration wasn't present ... sometimes quitting Chrome makes it re-appear.\n");
  }
  CHECK(!decompression_session_create_status);

  CFRelease(decoder_parameters);
  CFRelease(pixel_buffer_attributes);
}

void DecodeNextFrame() {
  // Loop through the compressed samples ad infinitum.
  CMSampleBufferRef cm_sample_buffer = cm_sample_buffers_from_asset_reader.front();
  cm_sample_buffers_from_asset_reader.pop_front();
  cm_sample_buffers_from_asset_reader.push_back(cm_sample_buffer);
  CHECK(cm_sample_buffer);
  
  // Pull the video format description from the sample buffer.
  CMVideoFormatDescriptionRef cm_video_format_description =
      CMSampleBufferGetFormatDescription(cm_sample_buffer);
  if (!cm_video_format_description)
    return DecodeNextFrame();

  // Ensure that we have a compatible VTDecompressionSession.
  PrepareDecompressionSessionForCMSampleBuffer(cm_sample_buffer);

  // Decode the frame. Use synchronous decode so that we don't have to think
  // about locking the various structures.
  VTDecodeFrameFlags decode_flags = 0; // kVTDecodeFrame_EnableAsynchronousDecompression;
  void* source_frame_ref_con = 0;
  VTDecodeInfoFlags info_flags_out;
  OSStatus decompression_session_decode_frame_status =
      VTDecompressionSessionDecodeFrame(
          vt_decompression_session,
          cm_sample_buffer,
          decode_flags,
          source_frame_ref_con,
          &info_flags_out);
  CHECK(!decompression_session_decode_frame_status);
}

IOSurfaceRef g_io_surface = 0;

void DisplayNextDecodedFrame(CVPixelBufferRef cv_pixel_buffer) {
  printf("DisplayNextDecodedFrame\n");
  CFShow(cv_pixel_buffer);
  DumpPixelBuffer(cv_pixel_buffer);

  CHECK(cv_pixel_buffer);
  OSStatus status;

  // Create the CMVideoFormatDescription.
  CMVideoFormatDescriptionRef video_info = NULL;
  status = CMVideoFormatDescriptionCreateForImageBuffer(NULL, cv_pixel_buffer, &video_info);
  CHECK(!status);
  CHECK(video_info);

  // Create the CMSampleTimingInfo.
  CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};

  // Create the CMSampleBuffer.
  CMSampleBufferRef sample_buffer = nullptr;
  status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, cv_pixel_buffer, YES, NULL, NULL, video_info, &timing, &sample_buffer);
  CHECK(!status);
  CHECK(sample_buffer);

  // Set attachments on the CMSampleBuffer.
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample_buffer, YES);
  CHECK(attachments);
  CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
  CHECK(dict);
  CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);

  [sample_display_layer flush];
  [sample_display_layer enqueueSampleBuffer:sample_buffer];

  CFRelease(sample_buffer);
  CFRelease(video_info);
}

@interface MainWindow : NSWindow
- (void)tick;
@end

@implementation MainWindow
- (void)keyDown:(NSEvent *)event {
  if ([event isARepeat]) return;
  NSString *characters = [event charactersIgnoringModifiers];
  if ([characters length] != 1) return;
  switch ([characters characterAtIndex:0]) {
    case 'q': [NSApp terminate:nil]; break;
  }
}

- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }

- (void)tick {
  [self performSelector:@selector(tick) withObject:nil afterDelay:0.01];

  // Decode 8 frames at a time to give some hope to getting them in order.
  while (decoded_images.size() < 8) 
    DecodeNextFrame();

/*
  // Don't stuff the layer.
  if (![sample_display_layer isReadyForMoreMediaData]) {
    printf("Not ready for more media\n");
    return;
  }
*/

  // Draw the frame with the first timestamp.
  TimeToFrameMap::iterator map_iter = decoded_images.begin();
  CVPixelBufferRef cv_pixel_buffer = map_iter->second;
  decoded_images.erase(map_iter);
  DisplayNextDecodedFrame(cv_pixel_buffer);
  CFRelease(cv_pixel_buffer);

  // The decoded images list should never grow beyond 8.
  CHECK(decoded_images.size() < 8);
}
@end

int main(int argc, char* argv[]) {
  if (argc != 2) {
    printf("Usage: %s file_to_play.mp4\n", argv[0]);
    return 1;
  }

  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

  NSMenu* menubar = [NSMenu alloc];
  [NSApp setMainMenu:menubar];

  ReadFileFromDisk(argv[1]);

  MainWindow* window = [[MainWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 1240, 690)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  [window setOpaque:YES];
  [window setBackgroundColor:[NSColor blackColor]];
  [window setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];

  NSView* view = [window contentView];
  background_layer = [[CALayer alloc] init];
  [view setLayer:background_layer];
  [view setWantsLayer:YES];

  InitializeLayer();

  [window setTitle:@"VTDecompressionSession AVSampleBufferDisplayLayer test"];
  [window makeKeyAndOrderFront:nil];

  // Start the window going.
  [window tick];

  [NSApp activateIgnoringOtherApps:YES];
  [NSApp run];
  return 0;
}
