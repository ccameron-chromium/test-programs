// To build and run:
// clang++ av-sample-buffer-2094-50.mm -framework Cocoa -framework QuartzCore -framework IOSurface -framework AVFoundation -framework CoreMedia -fobjc-arc && ./a.out
// 
// To run, you will need staircase-pq.png in your working directory.
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
  // The 2094-50 metadata.
  std::vector<uint8_t> data;
  // The pixels (which are the same for all frames, but with a square moving to
  // indicate which frame is active).
  CVPixelBufferRef pixel_buffer;
};

std::vector<TestFrame> test_frames = {
  {1,    { 0x00, 0xc0, 0x00, 0x05, 0x00, 0x00, 0x04 }, nullptr},
  {5,    { 0x00, 0xc0, 0x00, 0x19, 0x00, 0x00, 0x04 }, nullptr},
  {43.8, { 0x00, 0xc0, 0x00, 0xdb, 0x00, 0x00, 0x04 }, nullptr},
  {80,   { 0x00, 0xc0, 0x01, 0x90, 0x00, 0x00, 0x04 }, nullptr},
  {100,  { 0x00, 0xc0, 0x01, 0xf4, 0x00, 0x00, 0x04 }, nullptr},
  {203,  { 0x00, 0x40, 0x00, 0x00, 0x04 }, nullptr},
  {500,  { 0x00, 0xc0, 0x09, 0xc4, 0x00, 0x00, 0x04 }, nullptr},
  {1000, { 0x00, 0xc0, 0x13, 0x88, 0x00, 0x00, 0x04 }, nullptr},
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
void WriteImageToPixelBuffer(CVPixelBufferRef pixel_buffer, const char* path, int centerX, int centerY);

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
    WriteImageToPixelBuffer(test_frames[i].pixel_buffer, "staircase-pq.png", 80 + 160 * i, 720 - 80);
  }

  [window setTitle:@"Single-process PQ example!"];
  [window makeKeyAndOrderFront:nil];

  printf("Cycling through %zu test frames at 2 FPS\n", test_frames.size());
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

// Write |path| to |pixel_buffer|. Draw a 10x10 black square at centerX, centerY.
void WriteImageToPixelBuffer(CVPixelBufferRef pixel_buffer, const char* path, int centerX, int centerY) {
  NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
  CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
  CHECK(source);
  CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
  CHECK(image);
  CFRelease(source);

  std::vector<uint16_t> rgb_data(width * height * 4);
  CGColorSpaceRef color_space = CGImageGetColorSpace(image);
  if (!color_space) {
    color_space = CGColorSpaceCreateDeviceRGB();
  } else {
    CGColorSpaceRetain(color_space);
  }
  
  CGContextRef context = CGBitmapContextCreate(
      rgb_data.data(), width, height, 16, width * 8, color_space,
      kCGBitmapByteOrder16Host | kCGImageAlphaNoneSkipLast);
  CHECK(context);
  // Disable interpolation and anti-aliasing to get the cleanest pixel transfer
  CGContextSetInterpolationQuality(context, kCGInterpolationNone);
  CGContextSetShouldAntialias(context, false);
  
  CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);

  // Draw a black square (10x10).
  CGContextSetRGBFillColor(context, 0, 0, 0, 1);
  CGContextFillRect(context, CGRectMake(centerX - 5, centerY - 5, 10, 10));

  CGContextRelease(context);
  CGColorSpaceRelease(color_space);
  CGImageRelease(image);

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
        constexpr float kMaxRGB = 65535.f;
        constexpr float kMaxYUV = 65472.f;
        if (plane == 0) {
          uint16_t* src_pixel = &rgb_data[(y * width + x) * 4];
          float r_val = src_pixel[0] / kMaxRGB;
          float g_val = src_pixel[1] / kMaxRGB;
          float b_val = src_pixel[2] / kMaxRGB;
          float y_val = m[0]*r_val + m[1]*g_val + m[2]*b_val + m[4];

          uint16_t* dst_pixel = (uint16_t*)(dst_data + y*dst_stride + dst_bpe*x);
          dst_pixel[0] = (int)(kMaxYUV * y_val + 0.5f);
        } else {
          // Chroma plane (interleaved CbCr)
          // Average 2x2 neighborhood for chroma subsampling.
          float cb_sum = 0;
          float cr_sum = 0;
          for (size_t dy = 0; dy < 2; ++dy) {
            for (size_t dx = 0; dx < 2; ++dx) {
              size_t sx = 2 * x + dx;
              size_t sy = 2 * y + dy;
              uint16_t* src_pixel = &rgb_data[(sy * width + sx) * 4];
              float r_val = src_pixel[0] / kMaxRGB;
              float g_val = src_pixel[1] / kMaxRGB;
              float b_val = src_pixel[2] / kMaxRGB;
              cb_sum += m[5]*r_val + m[6]*g_val + m[7]*b_val + m[9];
              cr_sum += m[10]*r_val + m[11]*g_val + m[12]*b_val + m[14];
            }
          }
          uint16_t* dst_pixel = (uint16_t*)(dst_data + y*dst_stride + dst_bpe*x);
          dst_pixel[0] = (int)(kMaxYUV * (cb_sum / 4.f) + 0.5f);
          dst_pixel[1] = (int)(kMaxYUV * (cr_sum / 4.f) + 0.5f);
        }
      }
    }
  }

  r = IOSurfaceUnlock(io_surface, 0, nullptr);
  CHECK(r == kIOReturnSuccess);
}

