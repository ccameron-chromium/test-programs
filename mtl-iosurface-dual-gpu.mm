// clang++ mtl-iosurface-dual-gpu.mm -framework Metal -framework MetalKit -framework Cocoa -framework QuartzCore -framework IOSurface -fobjc-arc && ./a.out
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

// This test program shares an IOSurface between two MTLDevices.
// 
// It draws the Mandlebrot set into the IOSurface on the "src" device, and
// then blits the IOSurface into the CAMetalLayer on the left (which is also on
// the "src" device).
// 
// It then blits the IOSurface into the CAMetalLayer on the right (which is on
// the separate "dst" device).

// Use a MTLSharedEvent to synchronize between the two MTLCommandBuffers. This is
// sufficient for correct behavior in the single-GPU case, but insufficient when
// there are two separate MTLDevices.
bool g_use_event = true;

// Make the source command buffer do waitUntilSchedule before committing the
// command buffer to read from the source. If this is done, then the IOSurfaces
// are always synchronized correctly (regardless of the other flags).
bool g_wait_until_scheduled = false;

// If this is true, then re-bind the IOSurface to a texture on both devices
// every frame. If this is used with MTLSharedEvent, that improves
// synchronization for single-stepping frames, but does not fix double-stepping
// frames.
bool g_rebind_iosurface_to_texture_every_frame = false;

// The number of iterations to use in the Mandlebrot rendering. Increase
// or decrease this to simulate more or less GPU work.
// The - and + keys will adjust this,
uint32_t g_mandlebrot_iters = 1024;

// The IOSurface to share.
IOSurfaceRef g_iosurface = nullptr;

// The width and height of the IOSurface.
const int g_iosurface_width = 1024;
const int g_iosurface_height = 1024;

// The width and height of the CAMetalLayers.
const int width = 512;
const int height = 512;

id<MTLDevice> src_device = nil;
id<MTLDevice> dst_device = nil;
id<MTLCommandQueue> src_commandQueue = nil;
id<MTLCommandQueue> dst_commandQueue = nil;
id<MTLRenderPipelineState> mandlebrotRenderPipelineState = nil;
std::map<id<MTLDevice>, id<MTLRenderPipelineState>> blitRenderPipelineState;
CAMetalLayer* src_layer = nil;
CAMetalLayer* dst_layer = nil;

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
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
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
    viewport.width = [target_texture width];
    viewport.height = [target_texture height];
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
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    blitRenderPipelineState[device] = [device newRenderPipelineStateWithDescriptor:desc
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
    viewport.width = [dst_texture width];
    viewport.height = [dst_texture height];
    viewport.znear = -1.0;
    viewport.zfar = 1.0;
    [encoder setViewport:viewport];
    [encoder setRenderPipelineState:blitRenderPipelineState[[commandBuffer device]]];
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

void CreateIOSurface() {
  uint32_t io_format = 'BGRA';
  size_t bytes_per_pixel = 4;
  size_t bytes_per_row = IOSurfaceAlignProperty(
      kIOSurfaceBytesPerRow, g_iosurface_width * bytes_per_pixel);
  size_t bytes_total = IOSurfaceAlignProperty(
      kIOSurfaceAllocSize, g_iosurface_height * bytes_per_row);
  NSDictionary *options = @{
      (id)kIOSurfaceWidth: @(g_iosurface_width),
      (id)kIOSurfaceHeight: @(g_iosurface_height),
      (id)kIOSurfacePixelFormat: @(io_format),
      (id)kIOSurfaceBytesPerElement: @(bytes_per_pixel),
      (id)kIOSurfaceBytesPerRow: @(bytes_per_row),
      (id)kIOSurfaceAllocSize: @(bytes_total),
  };
  g_iosurface = IOSurfaceCreate((CFDictionaryRef)options);
  CHECK(g_iosurface);
}

id<MTLTexture> WrapIOSurface(id<MTLDevice> device, IOSurfaceRef iosurface, uint64_t usage) {
  CHECK(iosurface);
  int iosurface_width = IOSurfaceGetWidth(iosurface);
  int iosurface_height = IOSurfaceGetHeight(iosurface);

  MTLTextureDescriptor* tex_desc = [MTLTextureDescriptor new];
  [tex_desc setTextureType:MTLTextureType2D];
  [tex_desc setUsage:usage];
  [tex_desc setPixelFormat:MTLPixelFormatBGRA8Unorm];
  [tex_desc setWidth:iosurface_width];
  [tex_desc setHeight:iosurface_height];
  [tex_desc setDepth:1];
  [tex_desc setMipmapLevelCount:1];
  [tex_desc setArrayLength:1];
  [tex_desc setSampleCount:1];
  [tex_desc setStorageMode:MTLStorageModeManaged];
  // This doesn't make a difference.
  // [tex_desc setHazardTrackingMode:MTLResourceHazardTrackingModeTracked];
  id<MTLTexture> texture = [device newTextureWithDescriptor:tex_desc
                                                  iosurface:iosurface
                                                      plane:0];
  CHECK(texture);
  return texture;
}

void Draw() {
  if (!src_device) {
    printf("Initialize devices first!\n");
    return;
  }

  // This event is signalled after the "src" device write is completed,
  // and is waited on by the "dst" device before reading.
  static id<MTLSharedEvent> src_event = nil;
  // This event is signalled after the "dst" device read is completed,
  // and is waited on by the "src" device before writing.
  static id<MTLSharedEvent> dst_event = nil;

  // Both events are kept in lock-step values, starting at 0.
  static uint64_t event_value = 0;
  if (!src_event)
    src_event = [src_device newSharedEvent];
  if (!dst_event)
    dst_event = [dst_device newSharedEvent];

  static id<MTLTexture> src_iosurface_texture = nil;
  static id<MTLTexture> dst_iosurface_texture = nil;

  {
    id<MTLCommandBuffer> src_commandBuffer = [src_commandQueue commandBuffer];

    if (g_use_event) {
      // Wait on the event so that we don't write to the IOSurface while
      // the other device is reading from it.
      [src_commandBuffer encodeWaitForEvent:dst_event value:event_value];
    }

    // Draw the Mandlebrot set to the shared IOSurface.
    if (!src_iosurface_texture) {
      src_iosurface_texture = WrapIOSurface(
          src_device, g_iosurface, MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget);
    }
    DrawMandlebrot(src_commandBuffer, src_iosurface_texture);

    if (g_use_event) {
      // Signal the event after our write is done.
      event_value += 1;
      [src_commandBuffer encodeSignalEvent:src_event value:event_value];
    }

    // Draw the shared IOSurface to the CAMetalLayer (this read can overlay with
    // the other device reading).
    id<CAMetalDrawable> src_drawable = [src_layer nextDrawable];
    DrawBlit(src_commandBuffer, src_iosurface_texture, [src_drawable texture]);

    // Present and commit.
    [src_commandBuffer presentDrawable:src_drawable];
    [src_commandBuffer commit];

    if (g_wait_until_scheduled) {
      [src_commandBuffer waitUntilScheduled];
    }

    if (g_rebind_iosurface_to_texture_every_frame) {
      src_iosurface_texture = nil;
    }
  }

  {
    id<MTLCommandBuffer> dst_commandBuffer = [dst_commandQueue commandBuffer];
    
    if (g_use_event) {
      // Wait for the write to the IOSurface to complete.
      [dst_commandBuffer encodeWaitForEvent:src_event value:event_value];
    }

    if (!dst_iosurface_texture) {
      dst_iosurface_texture = WrapIOSurface(
        dst_device, g_iosurface, MTLTextureUsageShaderRead);
    }

    // Draw the shared IOSurface to the CAMetalLayer.
    id<CAMetalDrawable> dst_drawable = [dst_layer nextDrawable];
    DrawBlit(dst_commandBuffer, dst_iosurface_texture, [dst_drawable texture]);

    if (g_use_event) {
      // Signal that our read from the IOSurface is complete, so the src device
      // can safely overwrite it.
      [dst_commandBuffer encodeSignalEvent:dst_event value:event_value];
    }

    [dst_commandBuffer presentDrawable:dst_drawable];
    [dst_commandBuffer commit];

    if (g_wait_until_scheduled) {
      [dst_commandBuffer waitUntilScheduled];
    }

    if (g_rebind_iosurface_to_texture_every_frame) {
      dst_iosurface_texture = nil;
    }
  }
}

void InitializeMetal() {
  NSArray<id<MTLDevice>>* devices = MTLCopyAllDevices();
  for (id<MTLDevice> device in devices) {
    if (![device isLowPower] || !src_device)
      src_device = device;
  }
  for (id<MTLDevice> device in devices) {
    if (device != src_device || !dst_device) {
      dst_device = device;
    }
  }
  if (src_device == dst_device) {
    printf("Using a single GPU\n");
    printf("**** THIS MEANS THAT THIS TESTS NOTHING ****\n");
  } else 
    printf("Using multiple GPUs(!)\n");
  if (g_use_event)
    printf("Using MTLSharedEvent\n");
  else
    printf("Not using MTLSharedEvent\n");
  if (g_wait_until_scheduled)
    printf("Using waitUntilScheduled\n");
  else
    printf("Not using waitUntilScheduled\n");
  if (g_rebind_iosurface_to_texture_every_frame)
    printf("Rebinding IOSurface to MTLTexture every frame\n");
  else
    printf("Not rebinding IOSurface to MTLTexture every frame\n");

  src_commandQueue = [src_device newCommandQueue];
  dst_commandQueue = [dst_device newCommandQueue];

  src_layer = [[CAMetalLayer alloc] init];
  [src_layer setDevice:src_device];
  [src_layer setFramebufferOnly:YES];
  [src_layer setPixelFormat:MTLPixelFormatBGRA8Unorm];

  dst_layer = [[CAMetalLayer alloc] init];
  [dst_layer setDevice:dst_device];
  [dst_layer setFramebufferOnly:YES];
  [dst_layer setPixelFormat:MTLPixelFormatBGRA8Unorm];

  [superlayer addSublayer:src_layer];
  [superlayer addSublayer:dst_layer];
  [src_layer setFrame:CGRectMake(0, 0, width, height)];
  [dst_layer setFrame:CGRectMake(width, 0, width, height)];

  CreateMandlebrotRenderPipelineState(src_device);
  CreateBlitRenderPipelineState(src_device);
  CreateBlitRenderPipelineState(dst_device);
  CreateIOSurface();
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
    case '-':
      if (g_mandlebrot_iters > 1)
        g_mandlebrot_iters /= 2;
      printf("Mandlebrot iters: %d\n", g_mandlebrot_iters);
      break;
    case '=':
      g_mandlebrot_iters *= 2;
      printf("Mandlebrot iters: %d\n", g_mandlebrot_iters);
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
  printf("Press '-' and '+' to decrease or increase the Mandlebrot GPU work\n");

  [window setTitle:@"Test"];
  [window makeKeyAndOrderFront:nil];

  [NSApp activateIgnoringOtherApps:YES];
  [NSApp run];
  return 0;
}

