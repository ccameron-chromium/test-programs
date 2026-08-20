// To build and run:
// clang++ av-sample-buffer-2094-50.mm -framework Cocoa -framework QuartzCore -framework IOSurface -framework AVFoundation -framework CoreMedia -fobjc-arc && ./a.out
#include <AVFoundation/AVFoundation.h>
#include <Cocoa/Cocoa.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>
#include <QuartzCore/CALayer.h>
#include <ImageIO/ImageIO.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <vector>
#include <string>

enum Mode {
  kPQ = 0,
};

const int width = 1280;
const int height = 720;
CALayer* root_layer = nil;

AVSampleBufferDisplayLayer* av_layer = nil;

CFStringRef kCMSampleAttachmentKey_SMPTE2094_50Data = CFSTR("SMPTE2094-50Data");

struct TestFrame {
  // The number of nits that HDR reference white is set to in the matdata in `data`.
  float nits;
  // The signal value for that number of nits.
  float signal;
  // The 2094-50 metadata.
  std::vector<uint8_t> data;
  // The pixels (which are the same for all frames, but with a square moving to
  // indicate which frame is active).
  CVPixelBufferRef pixel_buffer;
};

std::vector<TestFrame> test_frames = {
  {1,      0.14994573, { 0x00, 0xc0, 0x00, 0x05, 0x00, 0x00, 0x04 }, nullptr},
  {5,      0.24784770, { 0x00, 0xc0, 0x00, 0x19, 0x00, 0x00, 0x04 }, nullptr},
  {43.8,   0.42777145, { 0x00, 0xc0, 0x00, 0xdb, 0x00, 0x00, 0x04 }, nullptr},
  {80,     0.48585677, { 0x00, 0xc0, 0x01, 0x90, 0x00, 0x00, 0x04 }, nullptr},
  {100,    0.50807842, { 0x00, 0xc0, 0x01, 0xf4, 0x00, 0x00, 0x04 }, nullptr},
  {203,    0.58068888, { 0x00, 0x40, 0x00, 0x00, 0x04 }, nullptr},
  {500,    0.67658481, { 0x00, 0xc0, 0x09, 0xc4, 0x00, 0x00, 0x04 }, nullptr},
  {1000,   0.75182710, { 0x00, 0xc0, 0x13, 0x88, 0x00, 0x00, 0x04 }, nullptr},
};


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

// Write |path| to |pixel_buffer|. Draw a 10x10 black square at centerX, centerY.
void WriteImageToPixelBuffer(CVPixelBufferRef pixel_buffer, float signal, const char* path, int centerX, int centerY);

// Draw |pixel_buffer| using an AVSampleBufferDisplayLayer.
void UpdateAVLayer(const TestFrame& frame) {
  CHECK(av_layer);
  OSStatus os_status = noErr;

  CMVideoFormatDescriptionRef video_info;
  os_status = CMVideoFormatDescriptionCreateForImageBuffer(
      nullptr, frame.pixel_buffer, &video_info);
  CHECK(os_status == noErr);

  // The frame time doesn't matter because we will specify to display
  // immediately.
  CMTime frame_time = CMTimeMake(0, 1);
  CMSampleTimingInfo timing_info = {frame_time, frame_time, kCMTimeInvalid};

  CMSampleBufferRef sample_buffer;
  os_status = CMSampleBufferCreateForImageBuffer(
      nullptr, frame.pixel_buffer, YES, nullptr, nullptr, video_info, &timing_info,
      &sample_buffer);
  CHECK(os_status == noErr);

  // Get the CMSampleBuffer attachment dictionary.
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(sample_buffer, YES);
  CHECK(attachments);
  CHECK(CFArrayGetCount(attachments) >= 1);
  CFMutableDictionaryRef attachments_dictionary =
      reinterpret_cast<CFMutableDictionaryRef>(
          const_cast<void*>(CFArrayGetValueAtIndex(attachments, 0)));
  CHECK(attachments_dictionary);

  //  Specify to display immediately
  CFDictionarySetValue(attachments_dictionary,
                       kCMSampleAttachmentKey_DisplayImmediately,
                       kCFBooleanTrue);

  // Specify the 2094-50 HDR metadata.
  CFDataRef metadata_data = CFDataCreate(kCFAllocatorDefault, frame.data.data(), frame.data.size());
  CFDictionarySetValue(attachments_dictionary,
                       kCMSampleAttachmentKey_SMPTE2094_50Data,
                       metadata_data);
  CFRelease(metadata_data);

  [av_layer enqueueSampleBuffer:sample_buffer];

  AVQueuedSampleBufferRenderingStatus status = [av_layer status];
  CHECK(status == AVQueuedSampleBufferRenderingStatusRendering);
}


void CycleFrames(int frame_index) {
  const auto& frame = test_frames[frame_index];
  printf("Drawing frame %d (%f nits)\n", frame_index, frame.nits);
  UpdateAVLayer(frame);
  
  int next_index = (frame_index + 1) % test_frames.size();
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    CycleFrames(next_index);
  });
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

  for (size_t i = 0; i < test_frames.size(); ++i) {
    test_frames[i].pixel_buffer = CreateIOSurfaceUsingCVPixelBuffer();
    WriteImageToPixelBuffer(test_frames[i].pixel_buffer, test_frames[i].signal, "staircase-pq.png", 80 + 160 * i, 80);
  }

  [window setTitle:@"SMPTE ST 2094-50 metadata test"];
  [window makeKeyAndOrderFront:nil];

  printf("If the SMPTE ST 2094-50 metadata is attached correctly, then\n");
  printf("this video will be a solid white with a black dot moving across\n");
  printf("the screen. If it is attached incorrectly, the background will\n");
  printf("change color as the dot moves\n\n");
  CycleFrames(0);

  [NSApp activateIgnoringOtherApps:YES];
  [NSApp run];
  return 0;
}

//
//
// Frame pixel value initialization code...
//
//

// Write |path| to |pixel_buffer|. Draw a black dot at centerX, centerY.
void WriteImageToPixelBuffer(CVPixelBufferRef pixel_buffer, float signal, const char* path, int centerX, int centerY) {
  IOSurfaceRef io_surface = CVPixelBufferGetIOSurface(pixel_buffer);
  CHECK(io_surface);

  IOReturn r = IOSurfaceLock(io_surface, 0, nullptr);
  CHECK(r == kIOReturnSuccess);

  // m is the full-range RGB to video-range YUV matrix for BT2020.
  const float m[] = {
        0.224951f,  0.580575f,  0.050779f,  0.000000f,  0.062561f,
       -0.122296f, -0.315632f,  0.437928f,  0.000000f,  0.500489f,
        0.437928f, -0.402706f, -0.035222f,  0.000000f,  0.500489f,
  };

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
        constexpr float kMaxYUV = 65472.f;
        float grey = signal;

        // Put a black dot at centerX,centerY.
        float distX = centerX - x * width / (plane_width - 1.f);
        float distY = centerY - y * height / (plane_height - 1.f);
        if (distX * distX + distY * distY < 10*10) {
          grey = 0.f;
        }
        
        float r_val = grey;
        float g_val = grey;
        float b_val = grey;
        float y_val  = m[ 0]*r_val + m[ 1]*g_val + m[ 2]*b_val + m[ 4];
        float cb_val = m[ 5]*r_val + m[ 6]*g_val + m[ 7]*b_val + m[ 9];
        float cr_val = m[10]*r_val + m[11]*g_val + m[12]*b_val + m[14];

        if (plane == 0) {
          uint16_t* dst_pixel = (uint16_t*)(dst_data + y*dst_stride + dst_bpe*x);
          dst_pixel[0] = (int)(kMaxYUV * y_val + 0.5f);
        } else {
          uint16_t* dst_pixel = (uint16_t*)(dst_data + y*dst_stride + dst_bpe*x);
          dst_pixel[0] = (int)(kMaxYUV * cb_val + 0.5f);
          dst_pixel[1] = (int)(kMaxYUV * cr_val + 0.5f);
        }
      }
    }
  }

  r = IOSurfaceUnlock(io_surface, 0, nullptr);
  CHECK(r == kIOReturnSuccess);
}

