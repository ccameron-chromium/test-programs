/*
Build and run using:
clang++ vt-decompression-to-av-display.mm \
  -framework Cocoa -framework QuartzCore \
  -framework AVFoundation -framework CoreMedia -framework VideoToolbox \
  -framework IOSurface -framework Metal -framework MetalKit \
  && ./a.out test.mov
*/

#include <Cocoa/Cocoa.h>
#include <AVFoundation/AVFoundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>
#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>
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

int decompression_pixel_format = kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange;
// Also try kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

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
CALayer* contents_layer = nil;
CAMetalLayer* metal_layer = nil;
typedef std::map<CFAbsoluteTime, CVImageBufferRef> TimeToFrameMap;
TimeToFrameMap decoded_images;
std::deque<CVImageBufferRef> displayed_images;
CVPixelBufferRef displaying_cv_pixel_buffer = nullptr;

void DrawWithMetal(IOSurfaceRef io_surface) {
  static id<MTLDevice> device = nil;
  static id<MTLRenderPipelineState> renderPipelineState = nil;

  if (!device) {
    NSArray<id<MTLDevice>>* devices = MTLCopyAllDevices();
    if (!device) {
      for (id<MTLDevice> test_device in devices) {
        if (!device || [test_device isLowPower])
          device = test_device;
      }
    }
  }

  if (!renderPipelineState) {
    const char* shader_source = ""
        "#include <metal_stdlib>\n"
        "#include <simd/simd.h>\n"
        "using namespace metal;\n"
        "typedef struct {\n"
        "    float4 clipSpacePosition [[position]];\n"
        "    float2 texCoord;\n"
        "} RasterizerData;\n"
        "\n"
        "vertex RasterizerData vertexShader(\n"
        "    uint vertexID [[vertex_id]],\n"
        "    constant vector_float2 *positions[[buffer(0)]]) {\n"
        "  RasterizerData out;\n"
        "  out.clipSpacePosition = vector_float4(positions[vertexID], 0.0, 1.0);\n"
        "  out.texCoord = positions[vertexID] * 0.5 + 0.5;\n"
        "  out.texCoord.y = 1.0 - out.texCoord.y;\n"
        "  out.texCoord.xy *= 4.0;\n"
        "  return out;\n"
        "}\n"
        "\n"
        "fragment float4 fragmentShader(RasterizerData in [[stage_in]],\n"
        "                               texture2d<float> y_tex [[texture(0)]],\n"
        "                               texture2d<float> uv_tex [[texture(1)]]) {\n"
        "    sampler s(mag_filter::linear, min_filter::linear);\n"
        "    float4 yuv1 = float4(y_tex.sample(s, in.texCoord).r,\n"
        "                         uv_tex.sample(s, in.texCoord).rg,\n"
        "                         1.0);\n"
        "    float4x4 yuv2rgb = float4x4(1.164384, -0.000000,  1.596027, -0.874202,\n"
        "                                1.164384, -0.391762, -0.812968,  0.531668,\n"
        "                                1.164384,  2.017232,  0.000000, -1.085631,\n"
        "                                0.0,       0.0,       0.0,       1.0);\n"
        "    return transpose(yuv2rgb) * yuv1;\n"
        "}\n"
        "";
 
    id<MTLLibrary> library = nil;
    {
      NSError* error = nil;
      NSString* source = [[NSString alloc] initWithCString:shader_source
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
      desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
      desc.colorAttachments[0].blendingEnabled = YES;
      desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
      desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
      desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
      desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
 
      renderPipelineState = [device newRenderPipelineStateWithDescriptor:desc
                                                                   error:&error];
      if (error)
        NSLog(@"Failed to create render pipeline state: %@", error);
    }
  }

  if (!metal_layer) {
    metal_layer = [[CAMetalLayer alloc] init];
    metal_layer.device = device;
    metal_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    metal_layer.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

    [background_layer addSublayer:metal_layer];

    printf("CAMetalLayer setContents: is in top-right\n");
    [metal_layer setFrame:CGRectMake(width/4, height/4, width/4, height/4)];
  }

  MTLPixelFormat y_format;
  MTLPixelFormat uv_format;
  switch (IOSurfaceGetPixelFormat(io_surface)) {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange:
      y_format = MTLPixelFormatR8Unorm;
      uv_format = MTLPixelFormatRG8Unorm;
      break;
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange:
      y_format = MTLPixelFormatR16Unorm;
      uv_format = MTLPixelFormatRG16Unorm;
      break;
    default:
      CHECK(!"unrecognized format...\n");
  }

  // Bind planes to textures
  MTLTextureDescriptor *y_desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:y_format
                                   width:width
                                  height:height
                               mipmapped:NO];
  y_desc.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> y_tex = [device newTextureWithDescriptor:y_desc iosurface:io_surface plane:0];

  MTLTextureDescriptor *uv_desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:uv_format
                                   width:width/2
                                  height:height/2
                               mipmapped:NO];
  uv_desc.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> uv_tex = [device newTextureWithDescriptor:uv_desc iosurface:io_surface plane:1];

  if (!y_tex || !uv_tex) {
    NSLog(@"Failed to create Metal textures from IOSurface planes");
    exit(1);
  }

  id<MTLCommandQueue> commandQueue = [device newCommandQueue];
  id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
  id<CAMetalDrawable> drawable = [metal_layer nextDrawable];

  id<MTLRenderCommandEncoder> encoder = nil;
  {
    MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.colorAttachments[0].texture = drawable.texture;
    desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    desc.colorAttachments[0].storeAction = MTLStoreActionStore;
    desc.colorAttachments[0].clearColor = MTLClearColorMake(0.5, 0.5, 0.5, 1.0);
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
      { 1, -1 }, { -1, -1 }, { -1, 1 }, { -1, 1 }, { 1, 1 }, { 1, -1 },
    };
    [encoder setVertexBytes:positions
                     length:sizeof(positions)
                    atIndex:0];
    [encoder setFragmentTexture:y_tex atIndex:0];
    [encoder setFragmentTexture:uv_tex atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:6];
  }
  [encoder endEncoding];

  [commandBuffer presentDrawable:drawable];
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];

}

void DumpIOSurface(IOSurfaceRef io_surface) {
  printf("================= DumpIOSurface =================\n");

  // Overriding this seems not to do anything...
  // CVBufferSetAttachment(pixel_buffer, CFSTR("CGColorSpace"), kCGColorSpaceSRGB, kCVAttachmentMode_ShouldPropagate);

  // But overriding this does!
  // This will make the color space be sRGB
  // IOSurfaceSetValue(io_surface, CFSTR("IOSurfaceColorSpace"), kCGColorSpaceSRGB);

  // And this will make the color space be Rec709 (signal value 10 maps to sRGB 24!).
  // IOSurfaceSetValue(io_surface, CFSTR("IOSurfaceColorSpace"), CFSTR(""));
  // IOSurfaceSetValue(io_surface, CFSTR("IOSurfaceTransferFunction"), kCVImageBufferTransferFunction_sRGB);


  CFShow(io_surface);
  CFShow(IOSurfaceCopyAllValues(io_surface));

  if (!io_surface)
    return;

  if (IOSurfaceLock(io_surface, kIOSurfaceLockReadOnly, nullptr)) {
    printf("*!*!*!*! Failed to lock IOSurface!\n");
    return;
  }
  printf("Locked IOSurface, dumping\n");
  int width = IOSurfaceGetWidth(io_surface);
  int height = IOSurfaceGetHeight(io_surface);
  printf("  width:%d, height:%d\n", width, height);

  constexpr size_t kMaxNumPlanes = 4;
  size_t num_planes = IOSurfaceGetPlaneCount(io_surface);
  for (size_t p = 0; p < num_planes; ++p) {
    size_t width     = IOSurfaceGetWidthOfPlane(io_surface, p);
    size_t height    = IOSurfaceGetHeightOfPlane(io_surface, p);
    size_t row_bytes = IOSurfaceGetBytesPerRowOfPlane(io_surface, p);
    size_t pixel_bytes = IOSurfaceGetBytesPerElementOfPlane(io_surface, p);
    void* base = IOSurfaceGetBaseAddressOfPlane(io_surface, p);
    printf("  plane:%d width:%d, height:%d, row_bytes:%d, pixel_bytes:%d\n",
        (int)p, (int)width, (int)height, (int)row_bytes, (int)pixel_bytes);
  }

  IOSurfaceUnlock(io_surface, kIOSurfaceLockReadOnly, nullptr);
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
}

// Initialize the CALayer, which will have its contents set to each frame.
void InitializeLayer() {
  printf("AVSampleBufferDisplayLayer is in bottom-left\n");
  printf("CALayer setContents: is in top-left\n");

  [sample_display_layer removeFromSuperlayer];
  [sample_display_layer release];
  sample_display_layer = [[AVSampleBufferDisplayLayer alloc] init];
  [sample_display_layer setFrame:CGRectMake(0, 0, width/4, height/4)];
  [background_layer addSublayer:sample_display_layer];

  [contents_layer removeFromSuperlayer];
  [contents_layer release];
  contents_layer = [[CALayer alloc] init];
  [contents_layer setFrame:CGRectMake(0, height/4, width/4, height/4)];
  [background_layer addSublayer:contents_layer];
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
    int32_t pixel_format = decompression_pixel_format;

    CFDictionarySetValue(
        pixel_buffer_attributes,
        kCVPixelBufferPixelFormatTypeKey,
        CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pixel_format));

/*
    // Setting properties here was thought to override the color space, but it
    // appears not to (but maybe it only overrides somet things ...).
    CFDictionarySetValue(
        pixel_buffer_attributes,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferTransferFunction_sRGB);
    CFDictionarySetValue(
        pixel_buffer_attributes,
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferColorPrimaries_ITU_R_709_2);
    CFDictionarySetValue(
        pixel_buffer_attributes,
        kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    CFDictionarySetValue(
        pixel_buffer_attributes,
        kCVImageBufferCGColorSpaceKey,
        CFSTR(""));
*/
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

void PrintCMSampleBufferAttachments(CMSampleBufferRef cm_sample_buffer, const char* label) {
  printf("===== CMSampleBuffer attachments: %s =====\n", label);
  fflush(stdout);
  CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, cm_sample_buffer, kCMAttachmentMode_ShouldPropagate);
  if (attachments) {
    printf("Buffer-level attachments (ShouldPropagate):\n");
    fflush(stdout);
    CFShow(attachments);
    CFRelease(attachments);
  }
  attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, cm_sample_buffer, kCMAttachmentMode_ShouldNotPropagate);
  if (attachments) {
    printf("Buffer-level attachments (ShouldNotPropagate):\n");
    fflush(stdout);
    CFShow(attachments);
    CFRelease(attachments);
  }
  CFArrayRef sample_attachments = CMSampleBufferGetSampleAttachmentsArray(cm_sample_buffer, NO);
  if (sample_attachments) {
    printf("Sample-level attachments:\n");
    fflush(stdout);
    CFShow(sample_attachments);
  }
  CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(cm_sample_buffer);
  if (format) {
    CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(format);
    if (extensions) {
      printf("Format description extensions:\n");
      fflush(stdout);
      CFShow(extensions);
    }
  }
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

    PrintCMSampleBufferAttachments(cm_sample_buffer, "from disk");

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
  /*
  // To override the color space, we need to strip the CGColorSpace attachment,
  // and set the kCVImageBufferTransferFunctionKey. The CGColorSpace attachment
  // appears have higher precedence.
  CVBufferRemoveAttachment(cv_pixel_buffer, CFSTR("CGColorSpace"));
  CVBufferRemoveAttachment(cv_pixel_buffer, CFSTR("DolbyVisionRPUData"));
  CVBufferRemoveAttachment(cv_pixel_buffer, CFSTR("AmbientViewingEnvironment"));

  // Setting this value will propagate it all the way down to the IOSurface.
  CVBufferSetAttachment(cv_pixel_buffer,
      kCVImageBufferTransferFunctionKey,
      kCVImageBufferTransferFunction_ITU_R_709_2,
      kCVAttachmentMode_ShouldPropagate);
  */

  printf("===== CVBufferCopyAttachments =====\n");
  CFShow(CVBufferCopyAttachments(cv_pixel_buffer, kCVAttachmentMode_ShouldNotPropagate));
  CFShow(CVBufferCopyAttachments(cv_pixel_buffer, kCVAttachmentMode_ShouldPropagate));


  if (displaying_cv_pixel_buffer) {
    CFRelease(displaying_cv_pixel_buffer);
    displaying_cv_pixel_buffer = nullptr;
    frame_count += 1;
  }
  displaying_cv_pixel_buffer = cv_pixel_buffer;
  CHECK(cv_pixel_buffer);

  // Stuff IOSurface to contents of layer.
  IOSurfaceRef io_surface = CVPixelBufferGetIOSurface(cv_pixel_buffer);
  DumpIOSurface(io_surface);
  [contents_layer setContents:(id)io_surface];

  // Draw it with metal.
  DrawWithMetal(io_surface);
  
  // Create the CMVideoFormatDescription.
  OSStatus status;
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

  PrintCMSampleBufferAttachments(sample_buffer, "for display");

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
    styleMask:NSWindowStyleMaskTitled
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

  [window setTitle:@"VTDecompressionSession AVSampleBufferDisplayLayer CALayer+IOSurface, Metal test"];
  [window makeKeyAndOrderFront:nil];
  [window tick];

  [NSApp activateIgnoringOtherApps:YES];
  [NSApp run];
  return 0;
}
