// clang++ mtl-iosurface-x420.mm -framework Metal -framework MetalKit -framework Cocoa -framework QuartzCore -fobjc-arc && ./a.out
#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>
#include <IOSurface/IOSurface.h>

const MTLPixelFormat pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB; // MTLPixelFormatBGRA8Unorm;
const int width = 640;
const int height = 480;

CAMetalLayer* metalLayer = nil;
CALayer* contentLayer = nil;
CALayer* ioSurfaceLayer = nil;

id<MTLDevice> device = nil;
id<MTLCommandQueue> commandQueue = nil;
id<MTLRenderPipelineState> renderPipelineState = nil;

id<MTLTexture> y_tex;
id<MTLTexture> uv_tex;
id<MTLTexture> rgba_tex;

void AllocateIOSurface() {
  // 1. Create IOSurface with 'x420' format
  // kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange = 'x420'
  NSArray *planes = @[
      @{
          (id)kIOSurfacePlaneWidth: @(width),
          (id)kIOSurfacePlaneHeight: @(height),
          (id)kIOSurfacePlaneBytesPerElement: @(2),
      },
      @{
          (id)kIOSurfacePlaneWidth: @(width / 2),
          (id)kIOSurfacePlaneHeight: @(height / 2),
          (id)kIOSurfacePlaneBytesPerElement: @(4),
      }
  ];
  NSDictionary *dict = @{
      (id)kIOSurfaceWidth: @(width),
      (id)kIOSurfaceHeight: @(height),
      (id)kIOSurfacePixelFormat: @((uint32_t)'x420'),
      (id)kIOSurfacePlaneInfo: planes,
  };
  IOSurfaceRef surface = IOSurfaceCreate((CFDictionaryRef)dict);
  if (!surface) {
    NSLog(@"Failed to create IOSurface");
    exit(1);
  }
  
  // 2. Populate IOSurface (Y and UV planes)
  IOSurfaceLock(surface, 0, NULL);
  uint16_t* y_ptr = (uint16_t *)IOSurfaceGetBaseAddressOfPlane(surface, 0);
  size_t y_stride = IOSurfaceGetBytesPerRowOfPlane(surface, 0) / 2;
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      y_ptr[y * y_stride + x] = 512 << 6; // Neutral gray
    }
  }

  uint16_t* uv_ptr = (uint16_t *)IOSurfaceGetBaseAddressOfPlane(surface, 1);
  size_t uv_stride = IOSurfaceGetBytesPerRowOfPlane(surface, 1) / 2;
  for (int y = 0; y < height / 2; ++y) {
    for (int x = 0; x < width / 2; ++x) {
      uv_ptr[y * uv_stride + x * 2]     = 512 << 6; // U
      uv_ptr[y * uv_stride + x * 2 + 1] = 512 << 6; // V
    }
  }
  IOSurfaceUnlock(surface, 0, NULL);

  // 3. Bind planes to textures
  MTLTextureDescriptor *y_desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Unorm
                                   width:width
                                  height:height
                               mipmapped:NO];
  y_desc.usage = MTLTextureUsageShaderRead;
  y_tex = [device newTextureWithDescriptor:y_desc iosurface:surface plane:0];

  MTLTextureDescriptor *uv_desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Unorm
                                   width:width/2
                                  height:height/2
                               mipmapped:NO];
  uv_desc.usage = MTLTextureUsageShaderRead;
  uv_tex = [device newTextureWithDescriptor:uv_desc iosurface:surface plane:1];

  if (!y_tex || !uv_tex) {
    NSLog(@"Failed to create Metal textures from IOSurface planes");
    exit(1);
  }

  // 4. Create destination 16-bit RGBA texture
  MTLTextureDescriptor *rgba_desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Unorm
                                   width:width
                                  height:height
                               mipmapped:NO];
  rgba_desc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
  rgba_tex = [device newTextureWithDescriptor:rgba_desc];
}

void AllocateMetalLayerIfNeeded() {
  if (metalLayer)
    return;
  metalLayer = [[CAMetalLayer alloc] init];
  {
    CGFloat components[4] = {0.0, 0.0, 0.0, 1.0};
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorRef color = CGColorCreate(space, components);
    [metalLayer setBackgroundColor:color];
  }
  metalLayer.device = device;
  metalLayer.pixelFormat = pixelFormat;
  metalLayer.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  metalLayer.opaque = NO;
}

void CreateRenderPipelineState() {
  if (renderPipelineState)
    return;
  const char* shader_source = ""
      "#include <metal_stdlib>\n"
      "#include <simd/simd.h>\n"
      "using namespace metal;\n"
      "typedef struct {\n"
      "    float4 clipSpacePosition [[position]];\n"
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
      "  out.color = colors[vertexID];\n"
      "  return out;\n"
      "}\n"
      "\n"
      "fragment float4 fragmentShader(RasterizerData in [[stage_in]]) {\n"
      "    return in.color;\n"
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
    desc.colorAttachments[0].pixelFormat = pixelFormat;
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

void Draw() {
  id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
  id<CAMetalDrawable> drawable = [metalLayer nextDrawable];

  CreateRenderPipelineState();

  id<MTLRenderCommandEncoder> encoder = nil;
  {
    const int kColorCount = 7;
    float r[kColorCount] = {1, 0, 0, 0, 1, 1, 1};
    float g[kColorCount] = {0, 1, 0, 1, 0, 1, 1};
    float b[kColorCount] = {0, 0, 1, 1, 1, 0, 1};
    static int color_index = 0;
    MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.colorAttachments[0].texture = drawable.texture;
    desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    desc.colorAttachments[0].storeAction = MTLStoreActionStore;
    desc.colorAttachments[0].clearColor = MTLClearColorMake(
        0.5,
        0.5,
        0.5,
        1.0);
    encoder = [commandBuffer renderCommandEncoderWithDescriptor:desc];
    color_index = (color_index + 1) % kColorCount;
  }

  {
    const float rgb = 0.5;
    const float a = 0.5;

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
      {  1,  -1 },
      { -1,  -1 },
      { -1,   1 },
      { -1,   1 },
      {  1,   1 },
      {  1,  -1 },
    };
    [encoder setVertexBytes:positions
                     length:sizeof(positions)
                    atIndex:0];
    vector_float4 colors[6] = {
      { 1, 0, 1, a },
      { rgb, rgb, rgb, a },
      { rgb, rgb, rgb, a },
      { rgb, rgb, rgb, a },
      { rgb, rgb, rgb, a },
      { rgb, 0, 1, a },
    };
    [encoder setVertexBytes:colors
                     length:sizeof(colors)
                    atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:6];
  }
  [encoder endEncoding];

  [commandBuffer presentDrawable:drawable];
  [commandBuffer commit];

  // 7. Read back values
  uint16_t *result = (uint16_t *)malloc(width * height * 4 * sizeof(uint16_t));
  [rgba_tex getBytes:result
         bytesPerRow:width * 4 * sizeof(uint16_t)
          fromRegion:MTLRegionMake2D(0, 0, width, height)
         mipmapLevel:0];
  NSLog(@"Results (first pixel RGBA16):");
  NSLog(@"R: %u, G: %u, B: %u, A: %u", result[0], result[1], result[2], result[3]);
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

  static int current_tile = 0;
  switch ([characters characterAtIndex:0]) {
    case 'q':
      [NSApp terminate:nil];
      break;
    case '4':
      Draw();
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
    initWithContentRect:NSMakeRect(0, 0, width, height)
    styleMask:NSWindowStyleMaskResizable | NSWindowStyleMaskTitled
    backing:NSBackingStoreBuffered
    defer:NO];
  [window setOpaque:YES];

  contentLayer = [[CALayer alloc] init];
  [[window contentView] setLayer:contentLayer];
  [[window contentView] setWantsLayer:NO];
  [contentLayer setFrame:CGRectMake(0, 0, width, height)];

  // Use the low power GPU, if there is one.
  NSArray<id<MTLDevice>>* devices = MTLCopyAllDevices();
  if (!device) {
    for (id<MTLDevice> test_device in devices) {
      if (!device || [test_device isLowPower])
        device = test_device;
    }
  }
  AllocateMetalLayerIfNeeded();
  AllocateIOSurface();
  commandQueue = [device newCommandQueue];

  // Set up the grid of superlayers.
  [contentLayer addSublayer:metalLayer];
  [metalLayer setFrame:CGRectMake(0, 0, width, height)];

  [window setTitle:@"IOSurface per CALayer"];
  [window makeKeyAndOrderFront:nil];
  Draw();

  [NSApp activateIgnoringOtherApps:YES];
  [NSApp run];
  return 0;
}

