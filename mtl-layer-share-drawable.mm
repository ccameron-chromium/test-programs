// clang++ mtl-layer-share-drawable.mm -framework Metal -framework MetalKit -framework Cocoa -framework QuartzCore -framework IOSurface -fobjc-arc && ./a.out
#include <IOSurface/IOSurface.h>
#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>
#include <QuartzCore/CALayer.h>
#include <QuartzCore/QuartzCore.h>
#include <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <list>
#include <map>
#include <vector>

// This test program has two CAMetalLayers. It draws the Mandlebrot set to the
// layer on the left, and then blits the drawable's contents to the layer on
// the right.
// * This was originally implemented to determine if framebufferOnly prevents
//   wrapping the drawable's IOSurface in a texture and sampling from it anyway.
//   It doesn't.
// * The two layers can use different MTLDevices (via g_use_dual_gpu).
// * Different synchronization mechanisms are also allowed.
// * When single-stepping frames, the content should always be the same (if
//   synchronization is not done right, then the right will often pick up an
//   older frame).
// * The left and right layers do not present at the same time (especially
//   during continuous animation).

// Set to true to attempt to use multiple GPUs, if the system has them. If this
// is done, then the Mandlebrot set will try to avoid using the low power GPU.
bool g_use_dual_gpu = true;

// Whether or not to set framebufferOnly on the CAMetalLayers. This seems
// not to make a behavioral difference.
bool g_set_framebuffer_only = false;

// Use a MTLSharedEvent to synchronize between the two MTLCommandBuffers. This is
// sufficient for correct behavior in the single-GPU case.
bool g_use_event = true;

// Make the source command buffer do waitUntilSchedule before committing the
// command buffer to read from the source. This is necessary to get correct
// results when using dual GPU sharing using IOSurfaces (presumably because
// it allows the commands to page the IOSurface across).
bool g_wait_until_scheduled = false;

// If this is true, then re-bind the IOSurface to a texture every frame.
bool g_rebind_iosurface_to_texture_every_frame = false;

// The number of iterations to use in the Mandlebrot rendering. Increase
// or decrease this to simulate more or less GPU work.
// The - and + keys will adjust this,
uint32_t g_mandlebrot_iters = 1024;

// How to share drawable resources. In ViaIOSurface, the drawable's IOSurface
// is pulled out, and wrapped in a new texture (this is the only option for
// the dual-GPU case). If Direct, then the MTLTexture is reused directly.
enum ShareMode {
  kShareViaIOSurface,
  kShareDirect,
};
ShareMode share_mode = kShareViaIOSurface;

// Whether or not to continuously animate. This can be toggled by pressing 'c'.
bool g_continuous = false;

// Whether or not to print how much time is spent drawing the Mandlebrot set.
bool g_print_gpu_time = false;

const MTLPixelFormat pixelFormat = MTLPixelFormatBGRA8Unorm;
const int width = 512;
const int height = 512;

id<MTLDevice> src_device = nil;
id<MTLDevice> dst_device = nil;
id<MTLCommandQueue> src_commandQueue = nil;
id<MTLCommandQueue> dst_commandQueue = nil;
id<MTLRenderPipelineState> mandlebrotRenderPipelineState = nil;
id<MTLRenderPipelineState> blitRenderPipelineState = nil;
CAMetalLayer* src_layer = nil;
CAMetalLayer* dst_layer = nil;

int64_t src_drawables_in_flight = 0;
int64_t dst_drawables_in_flight = 0;
NSWindow* window = nil;
CALayer* superlayer = nil;

#define CHECK(x) \
  do { \
    if (!(x)) { \
      fprintf(stderr, "Failed: '%s' at %s:%d\n", #x, __FILE__, __LINE__); \
      exit(1); \
    } \
  } while (0)

void CreateMandlebrotRenderPipelineState(id<MTLDevice> device) {
  const char* cSource = ""
      "#include <metal_stdlib>\n"
      "#include <simd/simd.h>\n"
      "using namespace metal;\n"
      "typedef struct {\n"
      "    float4 clipSpacePosition [[position]];\n"
      "    float2 p;\n"
      "    float4 color;\n"
      "} RasterizerData;\n"
      "\n"
      "vertex RasterizerData vertexShader(\n"
      "    uint vertexID [[vertex_id]],\n"
      "    constant vector_float2 *positions[[buffer(0)]],\n"
      "    constant vector_float4 *colors[[buffer(1)]]) {\n"
      "  RasterizerData out;\n"
      "  out.clipSpacePosition = vector_float4(0.0, 0.0, 0.0, 1.0);\n"
      "  out.clipSpacePosition.xy = positions[vertexID].xy;\n"
      "  out.p = positions[vertexID].xy;\n"
      "  out.color = colors[vertexID];\n"
      "  return out;\n"
      "}\n"
      "\n"
      "fragment float4 fragmentShader(RasterizerData in [[stage_in]],\n"
      "                               constant uint32_t& max_iter [[buffer(1)]]) {\n"
      "    float x0 = 0.125 * in.p.x - 1.31;\n"
      "    float y0 = 0.125 * in.p.y - 0.05;\n"
      "    float x = 0;\n"
      "    float y = 0;\n"
      "    float iter = 0;\n"
      "    while (iter < max_iter and x*x + y*y <= 4) {\n"
      "      float x_temp = x*x - y*y + x0;\n"
      "      y = 2*x*y + y0;\n"
      "      x = x_temp;\n"
      "      iter += 1;\n"
      "    }\n"
      "    if (iter < max_iter)\n"
      "      return float4(in.color.rgb * sqrt(iter / 100), 1.0);\n"
      "    return float4(in.color.rgb, 1.0);\n"
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
    desc.colorAttachments[0].pixelFormat = pixelFormat;
    mandlebrotRenderPipelineState = [device newRenderPipelineStateWithDescriptor:desc
                                                                 error:&error];
    if (error)
      NSLog(@"Failed to create render pipeline state: %@", error);
  }
}

void DrawMandlebrot(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> target_texture) {
  id<MTLRenderCommandEncoder> encoder = nil;
  {
    MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.colorAttachments[0].texture = target_texture;
    desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    desc.colorAttachments[0].storeAction = MTLStoreActionStore;
    desc.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    encoder = [commandBuffer renderCommandEncoderWithDescriptor:desc];
  }

  {
    const int kColorCount = 7;
    const float colors_r[kColorCount] = {1, 0, 0, 0, 1, 1, 1};
    const float colors_g[kColorCount] = {0, 1, 0, 1, 0, 1, 1};
    const float colors_b[kColorCount] = {0, 0, 1, 1, 1, 0, 1};
    static int color_index = 0;
    float r = colors_r[color_index];
    float g = colors_g[color_index];
    float b = colors_b[color_index];
    color_index = (color_index + 1) % kColorCount;

    MTLViewport viewport;
    viewport.originX = 0;
    viewport.originY = 0;
    viewport.width = width;
    viewport.height = height;
    viewport.znear = -1.0;
    viewport.zfar = 1.0;
    [encoder setViewport:viewport];
    [encoder setRenderPipelineState:mandlebrotRenderPipelineState];
    vector_float2 positions[3] = {
      {  0.9,  -0.9 },
      { -0.9,  -0.9 },
      {  0.0,   0.9 },
    };
    [encoder setVertexBytes:positions
                     length:sizeof(positions)
                    atIndex:0];
    vector_float4 colors[3] = {
      { r, g, b, 1 },
      { r, g, b, 1 },
      { r, g, b, 1 },
    };
    [encoder setVertexBytes:colors
                     length:sizeof(colors)
                    atIndex:1];
    [encoder setFragmentBytes:&g_mandlebrot_iters
                       length:sizeof(g_mandlebrot_iters)
                      atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:3];
  }

  [encoder endEncoding];
}

void CreateBlitRenderPipelineState(id<MTLDevice> device) {
  const char* cSource = ""
      "#include <metal_stdlib>\n"
      "#include <simd/simd.h>\n"
      "using metal::float4;\n"
      "using metal::texture2d;\n"
      "using metal::sampler;\n"
      "\n"
      "typedef struct {\n"
      "    float4 clipSpacePosition [[position]];\n"
      "    float2 texcoord;\n"
      "} RasterizerData;\n"
      "\n"
      "vertex RasterizerData vertexShader(\n"
      "    uint vertexID [[vertex_id]],\n"
      "    constant vector_float2 *positions[[buffer(0)]],\n"
      "    constant vector_float2 *texcoords[[buffer(1)]]) {\n"
      "  RasterizerData out;\n"
      "  out.clipSpacePosition = vector_float4(0.0, 0.0, 0.0, 1.0);\n"
      "  out.clipSpacePosition.xy = positions[vertexID].xy;\n"
      "  out.texcoord = texcoords[vertexID].xy;\n"
      "  return out;\n"
      "}\n"
      "\n"
      "fragment float4 fragmentShader(RasterizerData in [[stage_in]],\n"
      "                               texture2d<float> t [[texture(0)]]) {\n"
      "  constexpr sampler s(metal::mag_filter::nearest,\n"
      "                      metal::min_filter::nearest);\n"
      "  float4 color = t.sample(s, in.texcoord);\n"
      "  return float4(color.rgb, 1);\n"
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
    desc.colorAttachments[0].pixelFormat = pixelFormat;
    blitRenderPipelineState = [device newRenderPipelineStateWithDescriptor:desc
                                                                     error:&error];
    if (error)
      NSLog(@"Failed to create render pipeline state: %@", error);
  }
}

void DrawBlit(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> src_texture, id<MTLTexture> dst_texture) {
  id<MTLRenderCommandEncoder> encoder = nil;
  {
    MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.colorAttachments[0].texture = dst_texture;
    desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    desc.colorAttachments[0].storeAction = MTLStoreActionStore;
    desc.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
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
    [encoder setRenderPipelineState:blitRenderPipelineState];
    vector_float2 positions[6] = {
      { -0.9,  -0.9 }, {  0.9,  -0.9 }, {  0.9,   0.9 },
      { -0.9,  -0.9 }, { -0.9,   0.9 }, {  0.9,   0.9 },
    };
    vector_float2 texcoords[6] = {
      { 0, 0 }, { 1, 0 }, { 1, 1 },
      { 0, 0 }, { 0, 1 }, { 1, 1 },
    };
    [encoder setVertexBytes:positions
                     length:sizeof(positions)
                    atIndex:0];
    [encoder setVertexBytes:texcoords
                     length:sizeof(texcoords)
                    atIndex:1];
    [encoder setFragmentTexture:src_texture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:6];
  }

  [encoder endEncoding];
}

id<MTLTexture> WrapIOSurface(id<MTLDevice> device, IOSurfaceRef iosurface) {
  int iosurface_width = IOSurfaceGetWidth(iosurface);
  int iosurface_height = IOSurfaceGetHeight(iosurface);

  MTLTextureDescriptor* tex_desc = [MTLTextureDescriptor new];
  [tex_desc setTextureType:MTLTextureType2D];
  [tex_desc setUsage:MTLTextureUsageShaderRead];
  [tex_desc setPixelFormat:pixelFormat];
  [tex_desc setWidth:iosurface_width];
  [tex_desc setHeight:iosurface_height];
  [tex_desc setDepth:1];
  [tex_desc setMipmapLevelCount:1];
  [tex_desc setArrayLength:1];
  [tex_desc setSampleCount:1];
  [tex_desc setStorageMode:MTLStorageModePrivate];
  return [device newTextureWithDescriptor:tex_desc
                                iosurface:iosurface
                                    plane:0];
}

void Draw();

void DoContinuousDrawIfNeeded() {
  if (!g_continuous)
    return;

  while (src_drawables_in_flight < [src_layer maximumDrawableCount] &&
         dst_drawables_in_flight < [dst_layer maximumDrawableCount]) {
    Draw();
  }
}

void OnSrcPresentedOnMainThread() {
  src_drawables_in_flight -= 1;
  DoContinuousDrawIfNeeded();
}

void OnDstPresentedOnMainThread() {
  dst_drawables_in_flight -= 1;
  DoContinuousDrawIfNeeded();
}

void Draw() {
  if (!src_device) {
    printf("Initialize devices first!\n");
    return;
  }

  CHECK(src_drawables_in_flight < [src_layer maximumDrawableCount]);
  CHECK(dst_drawables_in_flight < [dst_layer maximumDrawableCount]);
  src_drawables_in_flight += 1;
  dst_drawables_in_flight += 1;

  static id<MTLSharedEvent> event = nil;
  static uint64_t event_value = 0;
  if (!event)
    event = [src_device newSharedEvent];
  static std::map<IOSurfaceID, id<MTLTexture>> iosurface_textures;
  id<MTLTexture> src_texture = nil;

  {
    id<CAMetalDrawable> drawable = [src_layer nextDrawable];
    [drawable addPresentedHandler:^(id<MTLDrawable> presentedDrawable) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 0.f),
                     dispatch_get_main_queue(), ^{
        OnSrcPresentedOnMainThread();
      });
    }];

    // Draw the Mandlebrot set to src_layer's drawable, and print the execution time.
    id<MTLCommandBuffer> commandBuffer = [src_commandQueue commandBuffer];
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
      CFTimeInterval executionDuration = cb.GPUEndTime - cb.GPUStartTime;
      if (g_print_gpu_time) {
        printf("Mandlebrot GPU time: %f msec\n", 1000*executionDuration);
      }
    }];

    if (g_use_event) {
      [commandBuffer encodeWaitForEvent:event value:event_value];
    }

    DrawMandlebrot(commandBuffer, [drawable texture]);

    if (g_use_event) {
      event_value += 1;
      [commandBuffer encodeSignalEvent:event value:event_value];
    }

    // Present and commit.
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];

    if (g_wait_until_scheduled) {
      [commandBuffer waitUntilScheduled];
    }

    // Populate src_texture to be shared with dst_device.
    switch (share_mode) {
      case kShareViaIOSurface: {
        // Bind src_layer's drawable's IOSurface to a texture in dst_device
        IOSurfaceRef iosurface = [[drawable texture] iosurface];
        IOSurfaceID ioid = IOSurfaceGetID(iosurface);
        src_texture = iosurface_textures[ioid];
        if (!src_texture) {
          src_texture = WrapIOSurface(dst_device, [[drawable texture] iosurface]);
          if (!g_rebind_iosurface_to_texture_every_frame) {
            iosurface_textures[ioid] = src_texture;
          }
        }
        CHECK(src_texture);
        break;
      }
      case kShareDirect:
        CHECK(src_device == dst_device);
        src_texture = [drawable texture];
        break;
    }
  }

  {
    id<CAMetalDrawable> drawable = [dst_layer nextDrawable];
    [drawable addPresentedHandler:^(id<MTLDrawable> presentedDrawable) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 0.f),
                     dispatch_get_main_queue(), ^{
        OnDstPresentedOnMainThread();
      });
    }];

    id<MTLCommandBuffer> commandBuffer = [dst_commandQueue commandBuffer];
    
    if (g_use_event) {
      [commandBuffer encodeWaitForEvent:event value:event_value];
    }

    DrawBlit(commandBuffer, src_texture, [drawable texture]);

    if (g_use_event) {
      event_value += 1;
      [commandBuffer encodeSignalEvent:event value:event_value];
    }

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
  }
}

void InitializeMetal() {
  NSArray<id<MTLDevice>>* devices = MTLCopyAllDevices();
  for (id<MTLDevice> device in devices) {
    if (![device isLowPower] || !src_device)
      src_device = device;
  }
  if (g_use_dual_gpu) {
    for (id<MTLDevice> device in devices) {
      if (device != src_device || !dst_device)
        dst_device = device;
    }
  } else {
    dst_device = src_device;
  }
  if (src_device == dst_device)
    printf("Using a single GPU\n");
  else
    printf("Using multiple GPUs(!)\n");
  switch (share_mode) {
    case kShareViaIOSurface:
      printf("Sharing textures by wrapping in IOSurface\n");
      break;
    case kShareDirect:
      printf("Sharing textures by sharing MTLTexture directly\n");
  }
  if (g_use_event)
    printf("Using MTLSharedEvent\n");
  else
    printf("Not using MTLSharedEvent\n");
  if (g_wait_until_scheduled)
    printf("Using waitUntilScheduled\n");
  else
    printf("Not using waitUntilScheduled\n");
  if (g_set_framebuffer_only)
    printf("Rebinding IOSurface to MTLTexture every frame\n");
  else
    printf("Not rebinding IOSurface to MTLTexture every frame\n");
  if (g_rebind_iosurface_to_texture_every_frame)
    printf("Using setFrameBufferOnly:YES\n");
  else
    printf("Using setFrameBufferOnly:NO\n");

  src_commandQueue = [src_device newCommandQueue];
  dst_commandQueue = [dst_device newCommandQueue];

  src_layer = [[CAMetalLayer alloc] init];
  [src_layer setDevice:src_device];
  [src_layer setFramebufferOnly:g_set_framebuffer_only];
  [src_layer setPixelFormat:pixelFormat];

  dst_layer = [[CAMetalLayer alloc] init];
  [dst_layer setDevice:dst_device];
  [dst_layer setFramebufferOnly:g_set_framebuffer_only];
  [dst_layer setPixelFormat:pixelFormat];

  [superlayer addSublayer:src_layer];
  [superlayer addSublayer:dst_layer];
  [src_layer setFrame:CGRectMake(0, 0, width, height)];
  [dst_layer setFrame:CGRectMake(width, 0, width, height)];

  CreateMandlebrotRenderPipelineState(src_device);
  CreateBlitRenderPipelineState(dst_device);
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
    case '1':
      Draw();
      break;
    case '2':
      Draw();
      Draw();
      break;
    case 'c':
      g_continuous = !g_continuous;
      DoContinuousDrawIfNeeded();
      break;
    case '-':
      if (g_mandlebrot_iters > 1)
        g_mandlebrot_iters /= 2;
      printf("Mandlebrot iters: %d\n", g_mandlebrot_iters);
      break;
    case '=':
      g_mandlebrot_iters *= 2;
      printf("Mandlebrot iters: %d\n", g_mandlebrot_iters);
      break;
    case 'p':
      printf("Toggling print GPU time\n");
      g_print_gpu_time = !g_print_gpu_time;
      break;
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

  window = [[MainWindow alloc]
    initWithContentRect:NSMakeRect(0, 0, 2*width, height)
    styleMask:NSWindowStyleMaskResizable | NSWindowStyleMaskTitled
    backing:NSBackingStoreBuffered
    defer:NO];
  [window setOpaque:YES];

  superlayer = [[CALayer alloc] init];
  [[window contentView] setLayer:superlayer];
  [[window contentView] setWantsLayer:YES];

  InitializeMetal();
  printf("Press '1' to draw 1 frame\n");
  printf("Press '2' to draw 2 frames\n");
  printf("Press 'c' to draw continuously\n");
  printf("Press 'p' to print the GPU time spent on the Mandlebrot set\n");
  printf("Press '-' and '+' to decrease or increase the Mandlebrot GPU work\n");

  [window setTitle:@"Test"];
  [window makeKeyAndOrderFront:nil];

  [NSApp activateIgnoringOtherApps:YES];
  [NSApp run];
  return 0;
}

