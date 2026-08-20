// To build and run:
// clang++ av-sample-buffer-2094-50.mm -framework Cocoa -framework QuartzCore -framework IOSurface -framework AVFoundation -framework CoreMedia -fobjc-arc && ./a.out
#include <AVFoundation/AVFoundation.h>
#include <Cocoa/Cocoa.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>
#include <QuartzCore/CALayer.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

enum Mode {
  kPQ = 0,
};

const int width = 480;
const int height = 240;
CALayer* root_layer = nil;

CVPixelBufferRef pixel_buffer = nil;
AVSampleBufferDisplayLayer* av_layer = nil;

const float k100NitSignal = 0.508078421517399;
const float k203NitSignal = 0.5806888810416109;
const float k250NitSignal = 0.6025591549907524;
const float k500NitSignal = 0.6765848107833876;
const float k1000NitSignal = 0.751827096247041;
const float k10000NitSignal = 1.0;

#define CHECK(x) \
  do { \
    if (!(x)) { \
      fprintf(stderr, "Failed: '%s' at %s:%d\n", #x, __FILE__, __LINE__); \
      exit(1); \
    } \
  } while (0)

// Create a CVPixelBuffer.
CVPixelBufferRef CreateIOSurfaceUsingCVPixelBuffer() {
  NSDictionary *pixel_buffer_attributes = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
  };

  CVPixelBufferRef pixel_buffer = nullptr;
  CVPixelBufferCreate(
      kCFAllocatorDefault,
      width, height,
      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
      (__bridge CFDictionaryRef)pixel_buffer_attributes, &pixel_buffer);
  CVBufferSetAttachment(pixel_buffer, kCVImageBufferColorPrimariesKey,
                        kCVImageBufferColorPrimaries_ITU_R_2020,
                        kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(pixel_buffer, kCVImageBufferYCbCrMatrixKey,
                        kCVImageBufferYCbCrMatrix_ITU_R_2020,
                        kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(pixel_buffer,
                        kCVImageBufferTransferFunctionKey,
                        kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                        kCVAttachmentMode_ShouldPropagate);
  CHECK(pixel_buffer);
  return pixel_buffer;
}

void GreyToYUV(float grey, float* yuv) {
  const float BT2020_10bit_limited_rgb_to_yuv[] = {
        0.224951f,  0.580575f,  0.050779f,  0.000000f,  0.062561f,
       -0.122296f, -0.315632f,  0.437928f,  0.000000f,  0.500489f,
        0.437928f, -0.402706f, -0.035222f,  0.000000f,  0.500489f,
        0.000000f,  0.000000f,  0.000000f,  1.000000f,  0.000000f,
  };
  const float* m = BT2020_10bit_limited_rgb_to_yuv;
  const float rgb[5] = {grey, grey, grey, 1.f, 1.f};
  for (size_t i = 0; i < 3; ++i) {
    yuv[i] = 0;
    for (size_t j = 0; j < 5; ++j) {
      yuv[i] += m[5*i + j] * rgb[j];
    }
  }
}

// Write a gradient to |pixel_buffer|.
void WriteGradientToPixelBuffer(CVPixelBufferRef pixel_buffer, float max_value) {
  IOSurfaceRef io_surface = CVPixelBufferGetIOSurface(pixel_buffer);
  CHECK(io_surface);

  IOReturn r = IOSurfaceLock(io_surface, 0, nullptr);
  CHECK(r == kIOReturnSuccess);

  size_t plane_count = IOSurfaceGetPlaneCount(io_surface);
  if (plane_count == 0)
    plane_count = 1;
  for (size_t plane = 0; plane < plane_count; ++plane) {
    size_t plane_width = IOSurfaceGetWidthOfPlane(io_surface, plane);
    size_t plane_height = IOSurfaceGetHeightOfPlane(io_surface, plane);
    uint8_t* dst_data = reinterpret_cast<uint8_t*>(
        IOSurfaceGetBaseAddressOfPlane(io_surface, plane));
    size_t dst_stride = IOSurfaceGetBytesPerRowOfPlane(io_surface, plane);
    size_t dst_bpe  = IOSurfaceGetBytesPerElementOfPlane(io_surface, plane);
    for (size_t y = 0; y < plane_height; ++y) {
      for (size_t x = 0; x < plane_width; ++x) {
        float grey = max_value * (x / (plane_width - 1.f));
        float yuv[3];
        GreyToYUV(grey, yuv);

        uint16_t* pixel = (uint16_t*)(dst_data + y*dst_stride + dst_bpe*x);
        float factor = 65535.f;
        if (plane == 0) {
          pixel[0] = (int)(factor * yuv[0] + 0.5f);
        } else {
          pixel[0] = (int)(factor * yuv[1] + 0.5f);
          pixel[1] = (int)(factor * yuv[2] + 0.5f);
        }
      }
    }
  }

  r = IOSurfaceUnlock(io_surface, 0, nullptr);
  CHECK(r == kIOReturnSuccess);
}

// Draw |pixel_buffer| using an AVSampleBufferDisplayLayer.
void UpdateAVLayer(CVPixelBufferRef pixel_buffer) {
  CHECK(av_layer);
  OSStatus os_status = noErr;

  CMVideoFormatDescriptionRef video_info;
  os_status = CMVideoFormatDescriptionCreateForImageBuffer(
      nullptr, pixel_buffer, &video_info);
  CHECK(os_status == noErr);

  // The frame time doesn't matter because we will specify to display
  // immediately.
  CMTime frame_time = CMTimeMake(0, 1);
  CMSampleTimingInfo timing_info = {frame_time, frame_time, kCMTimeInvalid};

  CMSampleBufferRef sample_buffer;
  os_status = CMSampleBufferCreateForImageBuffer(
      nullptr, pixel_buffer, YES, nullptr, nullptr, video_info, &timing_info,
      &sample_buffer);
  CHECK(os_status == noErr);

  // Specify to display immediately via the sample buffer attachments.
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(sample_buffer, YES);
  CHECK(attachments);
  CHECK(CFArrayGetCount(attachments) >= 1);
  CFMutableDictionaryRef attachments_dictionary =
      reinterpret_cast<CFMutableDictionaryRef>(
          const_cast<void*>(CFArrayGetValueAtIndex(attachments, 0)));
  CHECK(attachments_dictionary);
  CFDictionarySetValue(attachments_dictionary,
                       kCMSampleAttachmentKey_DisplayImmediately,
                       kCFBooleanTrue);
  [av_layer enqueueSampleBuffer:sample_buffer];

  AVQueuedSampleBufferRenderingStatus status = [av_layer status];
  CHECK(status == AVQueuedSampleBufferRenderingStatusRendering);
}


@interface MainWindow : NSWindow
@end

@implementation MainWindow
- (void)keyDown:(NSEvent *)event {
  if ([event isARepeat])
    return;

  NSString *characters = [event charactersIgnoringModifiers];
  if ([characters length] != 1)
    return;

  char c = [characters characterAtIndex:0];
  if (c == 'q') {
    [NSApp terminate:nil];
  } else if (c == 'p') {
    static float value = k203NitSignal;
    printf("Drawing PQ\n");
    WriteGradientToPixelBuffer(pixel_buffer, value);
    UpdateAVLayer(pixel_buffer);
    if (value == k203NitSignal) {
      value = k100NitSignal;
    } else {
      value = k203NitSignal;
    }
  }
}
@end

int main(int argc, char* argv[]) {
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

  NSMenu* menubar = [NSMenu alloc];
  [NSApp setMainMenu:menubar];

  NSWindow* window = [[MainWindow alloc]
    initWithContentRect:NSMakeRect(100, 100, 20+width, 20+height)
    styleMask:NSWindowStyleMaskResizable | NSWindowStyleMaskTitled
    backing:NSBackingStoreBuffered
    defer:NO];

  root_layer = [[CALayer alloc] init];
  [[window contentView] setLayer:root_layer];
  [[window contentView] setWantsLayer:YES];

  av_layer = [[AVSampleBufferDisplayLayer alloc] init];
  [av_layer setFrame:CGRectMake(10, 10, width, height)];
  [root_layer addSublayer:av_layer];

  pixel_buffer = CreateIOSurfaceUsingCVPixelBuffer();

  [window setTitle:@"Single-process PQ example!"];
  [window makeKeyAndOrderFront:nil];

  printf("Press 'p' to view PQ\n");
  printf("The window contains an AVSampleBufferDisplayLayer.\n");

  [NSApp activateIgnoringOtherApps:YES];
  [NSApp run];
  return 0;
}
