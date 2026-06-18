// clang++ vt-decompression-to-av-display.mm -framework AVFoundation -framework QuartzCore -framework CoreMedia -framework VideoToolbox -framework Cocoa -framework IOSurface -O2 && ./a.out test.mov

#include <Cocoa/Cocoa.h>
#include <AVFoundation/AVFoundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VTDecompressionSession.h>
#include <map>
#include <deque>
#include <stdio.h>

#define CHECK(x) \
  do { \
    if (!(x)) { \
      fprintf(stderr, "Failed: '%s' at %s:%d\n", #x, __FILE__, __LINE__); \
      exit(1); \
    } \
  } while (0)

@interface MainWindow : NSWindow
- (void)tick;
@end

AVAssetReaderOutput* asset_reader_output = nil;
AVAsset* asset = nil;
AVAssetTrack* video_track = nil;
AVAssetReader* asset_reader = nil;

MainWindow* window = nil;
int width = 0;
int height = 0;

int frame_count = 0;

CALayer* background_layer = nil;
VTDecompressionSessionRef vt_decompression_session = 0;
AVSampleBufferDisplayLayer* sample_display_layer = nil;
typedef std::map<CFAbsoluteTime, CVImageBufferRef> TimeToFrameMap;
TimeToFrameMap decoded_images;
std::deque<CVImageBufferRef> displayed_images;
CVPixelBufferRef displaying_cv_pixel_buffer = nullptr;

void DumpPixelBuffer(CVPixelBufferRef pixel_buffer) {
  IOSurfaceRef io_surface = CVPixelBufferGetIOSurface(pixel_buffer);

  // Overriding this seems not to do anything...
  // CVBufferSetAttachment(pixel_buffer, CFSTR("CGColorSpace"), kCGColorSpaceSRGB, kCVAttachmentMode_ShouldPropagate);

  // But overriding this does!
  // This will make the color space be sRGB
  // IOSurfaceSetValue(io_surface, CFSTR("IOSurfaceColorSpace"), kCGColorSpaceSRGB);

  // And this will make the color space be Rec709 (signal value 10 maps to sRGB 24!).
  // IOSurfaceSetValue(io_surface, CFSTR("IOSurfaceColorSpace"), CFSTR(""));
  // IOSurfaceSetValue(io_surface, CFSTR("IOSurfaceColorSpace"), kCGColorSpaceITUR_709);

  CFShow(pixel_buffer);
  CFShow(io_surface);
  CFShow(IOSurfaceCopyAllValues(io_surface));


  if (CVPixelBufferLockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly)) {
    return;
  }
  int width = CVPixelBufferGetWidth(pixel_buffer);
  int height = CVPixelBufferGetHeight(pixel_buffer);

  uint8_t yuv[3];
  int x = 400;
  int y = 400;
  if (x >= width || y >= height)
    return;

  {
    uint8_t* in_y = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, 0);
    size_t in_y_stride = CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, 0);

    uint8_t* in_y_row = (uint8_t*)(in_y + y*in_y_stride);
    yuv[0] = in_y_row[x];
  }
  {
    uint8_t* in_uv = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, 1);
    size_t in_uv_stride = CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, 1);

    uint8_t* in_uv_row = (uint8_t*)(in_uv + (y/2)*in_uv_stride);
    yuv[1] = in_uv_row[2*(x/2)];
    yuv[2] = in_uv_row[2*(x/2)+1];
  }


  const float Rec709_limited_yuv_to_rgb[] = {
        1.164384f, -0.000000f,  1.792741f,  0.000000f, -0.972945f,
        1.164384f, -0.213249f, -0.532909f,  0.000000f,  0.301483f,
        1.164384f,  2.112402f, -0.000000f,  0.000000f, -1.133402f,
        0.000000f,  0.000000f,  0.000000f,  1.000000f,  0.000000f,
  };

  const float* m = Rec709_limited_yuv_to_rgb;
  uint8_t r = std::round(255*(m[ 0]*yuv[0]/255.f + m[ 1]*yuv[1]/255.f + m[ 2]*yuv[2]/255.f + m[ 4]));
  uint8_t g = std::round(255*(m[ 5]*yuv[0]/255.f + m[ 6]*yuv[1]/255.f + m[ 7]*yuv[2]/255.f + m[ 9]));
  uint8_t b = std::round(255*(m[10]*yuv[0]/255.f + m[11]*yuv[1]/255.f + m[12]*yuv[2]/255.f + m[14]));

  printf("400,400 has y:%u,u:%u,v:%u -> r:%u,g:%u,b:%u\n", yuv[0], yuv[1], yuv[2], r,g,b);
  CVPixelBufferUnlockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
}

// Read an entire mp4 file in filename into cm_sample_buffers_from_asset_reader.
std::deque<CMSampleBufferRef> cm_sample_buffers_from_asset_reader;
void ReadFileFromDisk(const char* filename) {
  NSURL* url = [NSURL fileURLWithPath:[[NSString alloc]
      initWithUTF8String:filename]];

  asset = [AVAsset assetWithURL:url];
  dispatch_semaphore_t sema = dispatch_semaphore_create(0);
  [asset loadTracksWithMediaType:AVMediaTypeVideo completionHandler:^(NSArray<AVAssetTrack *> * _Nullable tracks, NSError * _Nullable error) {
    if (tracks.count > 0) {
      video_track = [tracks[0] retain];
    }
    dispatch_semaphore_signal(sema);
  }];
  dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
  dispatch_release(sema);

  asset_reader_output = [[AVAssetReaderTrackOutput alloc]
      initWithTrack:video_track outputSettings:nil];
  NSError* error = nil;
  asset_reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
  CHECK(!error);
  [asset_reader addOutput:asset_reader_output];
  [asset_reader startReading];

  /*
  printf("getting orientation\n");
  fflush(stdout);
  CGAffineTransformToAVIF([video_track preferredTransform],
                          &avif_irot_angle,
                          &avif_imir_mode);
  printf("angle:%d, mode:%d\n", avif_irot_angle, avif_imir_mode);
  */
}

// Initialize the CALayer, which will have its contents set to each frame.
void InitializeLayer() {
  [sample_display_layer removeFromSuperlayer];
  [sample_display_layer release];
  sample_display_layer = nil;

  sample_display_layer = [[AVSampleBufferDisplayLayer alloc] init];
  [sample_display_layer setBackgroundColor:CGColorGetConstantColor(kCGColorBlack)];
  [background_layer addSublayer:sample_display_layer];
  [sample_display_layer setFrame:CGRectMake(0, 0, width/2, height/2)];
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
    CMVideoFormatDescriptionRef cm_video_format_description) {
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
  if (0)
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
    // CFDictionarySetValue(pixel_buffer_attributes,
    //     kCVPixelBufferWidthKey, 
    //     CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &cm_video_dimensions.width));
    // CFDictionarySetValue(pixel_buffer_attributes,
    //     kCVPixelBufferHeightKey,
    //     CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &cm_video_dimensions.height));

    // This makes a big difference. Without it we get some &xvo format that... boh.
    int32_t pixel_format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFDictionarySetValue(
        pixel_buffer_attributes,
        kCVPixelBufferPixelFormatTypeKey,
        CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pixel_format));

    // Also doesn't seem to matter.
    // CFDictionarySetValue(pixel_buffer_attributes,
    //     kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey, kCFBooleanTrue);
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

IOSurfaceRef g_io_surface = 0;

void DecodeSeveralFrames() {
  while (decoded_images.size() < 8) {
    CMSampleBufferRef cm_sample_buffer =
      [asset_reader_output copyNextSampleBuffer];
    if (!cm_sample_buffer) {
      printf("No more samples.\n");
      [asset_reader cancelReading];
      [asset_reader_output release];
      [asset_reader release];
      [asset release];
      return;
    }

    // Pull the video format description from the sample buffer.
    CMVideoFormatDescriptionRef cm_video_format_description =
      CMSampleBufferGetFormatDescription(cm_sample_buffer);
    if (!cm_video_format_description) {
      printf("Sample had no video description\n");
      CFShow(cm_sample_buffer);
      continue;
    }

    // Ensure that we have a compatible VTDecompressionSession.
    PrepareDecompressionSessionForCMSampleBuffer(cm_video_format_description);

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
}

void DisplayNextDecodedFrame(CVPixelBufferRef cv_pixel_buffer) {
  if (displaying_cv_pixel_buffer) {
    CFRelease(displaying_cv_pixel_buffer);
    displaying_cv_pixel_buffer = nullptr;
    frame_count += 1;
  }
  displaying_cv_pixel_buffer = cv_pixel_buffer;
  DumpPixelBuffer(cv_pixel_buffer);
  
  CHECK(cv_pixel_buffer);
  OSStatus status;

/*
  CVBufferSetAttachment(cv_pixel_buffer,
                        kCVImageBufferTransferFunctionKey,
                        kCVImageBufferTransferFunction_ITU_R_709_2,
                        // kCVImageBufferTransferFunction_sRGB,
                        // kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                        kCVAttachmentMode_ShouldPropagate);
*/

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

  [sample_display_layer.sampleBufferRenderer flush];
  [sample_display_layer.sampleBufferRenderer enqueueSampleBuffer:sample_buffer];

  CFRelease(sample_buffer);
  CFRelease(video_info);
}

@implementation MainWindow
- (void)keyDown:(NSEvent *)event {
  if ([event isARepeat]) return;
  NSString *characters = [event charactersIgnoringModifiers];
  if ([characters length] != 1) return;
  switch ([characters characterAtIndex:0]) {
    case 'q':
      [NSApp terminate:nil];
      break;
    case 's':
      break;
    case ' ':
      [self tick];
      break;
  }
}

- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }

- (void)tick {
  DecodeSeveralFrames();
  if (decoded_images.empty()) {
    [self performSelector:@selector(tick) withObject:nil afterDelay:0.1];
    return;
  }

  // Don't stuff the layer.
  if (![sample_display_layer.sampleBufferRenderer isReadyForMoreMediaData]) {
    printf("Not ready for more media\n");
    return;
  }

  // Draw the frame with the first timestamp.
  TimeToFrameMap::iterator map_iter = decoded_images.begin();
  float time = map_iter->first;
  CVPixelBufferRef cv_pixel_buffer = map_iter->second;
  decoded_images.erase(map_iter);

  DisplayNextDecodedFrame(cv_pixel_buffer);

  // The decoded images list should never grow beyond 8.
  CHECK(decoded_images.size() < 8);

  // [self performSelector:@selector(tick) withObject:nil afterDelay:0.0001];

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
  DecodeSeveralFrames();
  CVPixelBufferRef pixel_buffer = decoded_images.begin()->second;
  width = CVPixelBufferGetWidth(pixel_buffer);
  height = CVPixelBufferGetHeight(pixel_buffer);

  window = [[MainWindow alloc]
    initWithContentRect:NSMakeRect(100, 100, width/2, height/2)
    styleMask:0
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
  [window tick];

  [NSApp activateIgnoringOtherApps:YES];
  [NSApp run];
  return 0;
}
