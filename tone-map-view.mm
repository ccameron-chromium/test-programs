// To build and run:
// clang++ tone-map-view.mm -framework Cocoa -framework QuartzCore -framework IOSurface -framework AVFoundation -framework CoreMedia -framework Metal -framework MetalKit -fobjc-arc && ./a.out
#include <AVFoundation/AVFoundation.h>
#include <Cocoa/Cocoa.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>
#include <QuartzCore/CALayer.h>
#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>

enum Mode {
  kPQ = 0,
  kHLG = 1,
};

const int width = 1280;
const int height = 300;
CALayer* root_layer = nil;

CVPixelBufferRef pixel_buffers[2];
CALayer* layer = nil;
AVSampleBufferDisplayLayer* av_layer = nil;

id<MTLDevice> device;
id<MTLCommandQueue> commandQueue = nil;
CAMetalLayer* metal_layer = nil;

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
CVPixelBufferRef CreateIOSurfaceUsingCVPixelBuffer(Mode mode) {
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
  switch (mode) {
    case kPQ:
      CVBufferSetAttachment(pixel_buffer,
                            kCVImageBufferTransferFunctionKey,
                            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                            kCVAttachmentMode_ShouldPropagate);
      break;
    case kHLG:
      CVBufferSetAttachment(pixel_buffer,
                            kCVImageBufferTransferFunctionKey,
                            kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                            kCVAttachmentMode_ShouldPropagate);
      break;
  }
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
  // printf("IOSurfaceGetPlaneCount: %lu\n", plane_count);
  if (plane_count == 0)
    plane_count = 1;
  for (size_t plane = 0; plane < plane_count; ++plane) {
    // printf("Plane %d\n", (int)plane);
    size_t plane_width = IOSurfaceGetWidthOfPlane(io_surface, plane);
    size_t plane_height = IOSurfaceGetHeightOfPlane(io_surface, plane);
    uint8_t* dst_data = reinterpret_cast<uint8_t*>(
        IOSurfaceGetBaseAddressOfPlane(io_surface, plane));
    size_t dst_stride = IOSurfaceGetBytesPerRowOfPlane(io_surface, plane);
    size_t dst_bpe  = IOSurfaceGetBytesPerElementOfPlane(io_surface, plane);
    // printf("  IOSurfaceGetBaseAddressOfPlane: %p\n", dst_data);
    // printf("  IOSurfaceGetWidthOfPlane: %lu\n", plane_width);
    // printf("  IOSurfaceGetHeightOfPlane: %lu\n", plane_height);
    // printf("  IOSurfaceGetBytesPerElementOfPlane: %lu\n", dst_bpe);
    // printf("  IOSurfaceGetBytesPerRowOfPlane: %lu\n", dst_stride);
    // printf("  Pointer to end of plane: %p\n",
    //     dst_data + plane_height * dst_stride);
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
void InitializeAVLayer(CVPixelBufferRef pixel_buffer) {
  if (!av_layer) {
    av_layer = [[AVSampleBufferDisplayLayer alloc] init];
    [root_layer addSublayer:av_layer];
    [av_layer setFrame:CGRectMake(10, 10, width, height)];
  }
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

// Draw a gradient using Metal
void DrawMetalLayer(CAMetalLayer* metal_layer, Mode mode, float max_value) {
  if (!device) {
    device = MTLCreateSystemDefaultDevice();
    commandQueue = [device newCommandQueue];
  }

  uint32_t trfn = 0;
  metal_layer.device = device;

  metal_layer.wantsExtendedDynamicRangeContent = YES;
  if (mode == kPQ) {
    trfn = 1;
    metal_layer.pixelFormat = MTLPixelFormatRGBA16Float;
    metal_layer.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    metal_layer.EDRMetadata = [CAEDRMetadata HDR10MetadataWithMinLuminance:0.0
                                                              maxLuminance:max_value
                                                        opticalOutputScale:100.0];
  }
  if (mode == kHLG) {
    trfn = 2;
    metal_layer.pixelFormat = MTLPixelFormatRGBA16Float;
    metal_layer.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    metal_layer.EDRMetadata = [CAEDRMetadata HLGMetadata];
  }

  id<MTLRenderPipelineState> renderPipelineState = nil;
  if (!renderPipelineState) {
    const char* cSource = ""
        "#include <metal_stdlib>\n"
        "#include <simd/simd.h>\n"
        "using namespace metal;\n"
        "\n"
        "typedef struct {\n"
        "    float4 clipSpacePosition [[position]];\n"
        "    float color;\n"
        "} RasterizerData;\n"
        "\n"
        "float ToLinearHLG(float v) {\n"
        "  constexpr float a = 0.17883277;\n"
        "  constexpr float b = 0.28466892;\n"
        "  constexpr float c = 0.55991073;\n"
        "  v = max(0.f, v);\n"
        "  if (v <= 0.5f)\n"
        "    return (v * 2.f) * (v * 2.f);\n"
        "  return exp((v - c) / a) + b;\n"
        "}\n"
        "\n"
        "float ToLinearPQ(float v) {\n"
        "  const float c1 =  107.0 / 128.0;\n"
        "  const float c2 = 2413.0 / 128.0;\n"
        "  const float c3 = 2392.0 / 128.0;\n"
        "  const float m1 = 1305.0 / 8192.0;\n"
        "  const float m2 = 2523.0 / 32.0;\n"
        "  const float p = pow(v, 1.0 / m2);\n"
        "  return pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1);\n"
        "}\n"
        "\n"
        "vertex RasterizerData vertexShader(\n"
        "    uint vertexID [[vertex_id]],\n"
        "    constant vector_float2 *positions[[buffer(0)]]) {\n"
        "  RasterizerData out;\n"
        "  out.clipSpacePosition = vector_float4(0.0, 0.0, 0.0, 1.0);\n"
        "  out.clipSpacePosition.xy = positions[vertexID].xy;\n"
        "  out.color = 0.5*(positions[vertexID].x + 1);\n"
        "  return out;\n"
        "}\n"
        "\n"
        "fragment float4 fragmentShader(RasterizerData in [[stage_in]],\n"
        "                               constant uint32_t& oetf[[buffer(0)]],\n"
        "                               constant float& max_value[[buffer(1)]]) {\n"
        "    float v = max_value * in.color;\n"
        "    if (oetf == 1) {\n"
        "      v = 100.0 * ToLinearPQ(v);\n"
        "    }\n"
        "    if (oetf == 2) {\n"
        "      v = ToLinearHLG(v);\n"
        "    }\n"
        "    return float4(v, v, v, 1.0);\n"
        "}\n"
        "";
 
    id<MTLLibrary> library = nil;
    {
      NSError* error = nil;
      NSString* source = [[NSString alloc] initWithCString:cSource
                                                  encoding:NSASCIIStringEncoding];
      MTLCompileOptions* options = [[MTLCompileOptions alloc] init];
      library = [device newLibraryWithSource:source
                                     options:options
                                       error:&error];
      if (error)
        NSLog(@"Failed to compile shader: %@", error);
    }
    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"vertexShader"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"fragmentShader"];
    {
      NSError* error = nil;
      MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
      desc.label = @"Simple Pipeline";
      desc.vertexFunction = vertexFunction;
      desc.fragmentFunction = fragmentFunction;
      desc.colorAttachments[0].pixelFormat = metal_layer.pixelFormat;
      renderPipelineState = [device newRenderPipelineStateWithDescriptor:desc
                                                                   error:&error];
      if (error)
        NSLog(@"Failed to create render pipeline state: %@", error);
    }
  }

  id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
  id<CAMetalDrawable> drawable = [metal_layer nextDrawable];
  CHECK(drawable);
  id<MTLRenderCommandEncoder> encoder = nil;
  {
    MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.colorAttachments[0].texture = drawable.texture;
    desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    desc.colorAttachments[0].storeAction = MTLStoreActionStore;
    desc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1.0);
    encoder = [commandBuffer renderCommandEncoderWithDescriptor:desc];
  }
  {
    MTLViewport viewport;
    viewport.originX = 0;
    viewport.originY = 0;
    viewport.width = width;
    viewport.height = height;
    viewport.znear = -1.0;
    viewport.zfar = 1.0;
    [encoder setViewport:viewport];
    [encoder setRenderPipelineState:renderPipelineState];
    vector_float2 positions[6] = {
      {  1,  -1 }, { -1,  -1 }, {  1,   1 },
      {  1,   1 }, { -1,   1 }, { -1,  -1 },
    };
    [encoder setVertexBytes:positions
                     length:sizeof(positions)
                    atIndex:0];
    [encoder setFragmentBytes:&trfn
                       length:sizeof(trfn)
                      atIndex:0];
    [encoder setFragmentBytes:&max_value
                       length:sizeof(max_value)
                      atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:6];
  }
  [encoder endEncoding];

  [commandBuffer presentDrawable:drawable];
  [commandBuffer commit];
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

  int c = [characters characterAtIndex:0];
  switch (c) {
    case 'h':
      printf("Drawing HLG with maximum value 0.75\n");
      WriteGradientToPixelBuffer(pixel_buffers[kHLG], 0.75);
      InitializeAVLayer(pixel_buffers[kHLG]);
      DrawMetalLayer(metal_layer, kHLG, 0.75);
      break;
    case 'p': {
      static float value = k203NitSignal;
      printf("Drawing PQ with maximum pixel value: %1.03f\n", value);
      WriteGradientToPixelBuffer(pixel_buffers[kPQ], value);
      InitializeAVLayer(pixel_buffers[kPQ]);
      DrawMetalLayer(metal_layer, kPQ, value);
      if (value == k203NitSignal) {
        value = k100NitSignal;
      } else if (value == k100NitSignal) {
        value = k203NitSignal;
      }
      break;
    }
    case 'q':
      [NSApp terminate:nil];
      break;
    default:
      break;
  }
}
@end

int main(int argc, char* argv[]) {
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

  NSMenu* menubar = [NSMenu alloc];
  [NSApp setMainMenu:menubar];

  NSWindow* window = [[MainWindow alloc]
    initWithContentRect:NSMakeRect(100, 100, 20+width, 20+height*2)
    styleMask:NSWindowStyleMaskResizable | NSWindowStyleMaskTitled
    backing:NSBackingStoreBuffered
    defer:NO];

  root_layer = [[CALayer alloc] init];
  [[window contentView] setLayer:root_layer];
  [[window contentView] setWantsLayer:YES];

  pixel_buffers[kPQ] = CreateIOSurfaceUsingCVPixelBuffer(kPQ);
  pixel_buffers[kHLG] = CreateIOSurfaceUsingCVPixelBuffer(kHLG);

  {
    metal_layer = [[CAMetalLayer alloc] init];
    [root_layer addSublayer:metal_layer];
    [root_layer setBackgroundColor:CGColorGetConstantColor(kCGColorWhite)];
    [metal_layer setFrame:CGRectMake(10, 10 + height, width, height)];
  }

  [window setTitle:@"HLG rendering example!"];
  [window makeKeyAndOrderFront:nil];

  printf("Press 'p' to view PQ\n");
  printf("Press 'h' to view HLG\n");
  printf("The background is a sRGB-white CAMetalLayer.\n");
  printf("On the top is a sRGB-linear CAMetalLayer with HLG-or-PQ-to-linear math done.\n");
  printf("On the bottom half of the screen is an HLG-or-PQ AVSampleBufferDisplayLayer.\n");

  [NSApp activateIgnoringOtherApps:YES];
  [NSApp run];
  return 0;
}

