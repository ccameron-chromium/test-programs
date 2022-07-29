// clang++ mtl-layer-iosurfaces.mm -framework Metal -framework MetalKit -framework Cocoa -framework QuartzCore -fobjc-arc && ./a.out
#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>
#include <IOSurface/IOSurface.h>

const MTLPixelFormat pixelFormat = MTLPixelFormatBGRA8Unorm;
const int width = 64;
const int height = 64;
const int num_tiles_1d = 8;
CALayer* super_layers[8*8] = {nil};
CAMetalLayer* metal_layers[8*8] = {nil};
CALayer* contentLayer = nil;

id<MTLDevice> device = nil;
id<MTLCommandQueue> commandQueue = nil;
id<MTLRenderPipelineState> renderPipelineState = nil;

void DumpIOSurfaceCount() {
  system("ioclasscount IOSurface");
}

CAMetalLayer* AllocateMetalLayerIfNeeded(int tile) {
  CAMetalLayer* metal_layer = metal_layers[tile];
  if (metal_layer)
    return metal_layer;
  int tx = tile % num_tiles_1d;
  int ty = tile / num_tiles_1d;
  metal_layer = [[CAMetalLayer alloc] init];
  metal_layers[tile] = metal_layer;
  [super_layers[tile] addSublayer:metal_layer];
  [metal_layer setFrame:CGRectMake(0, 0, width, height)];
  metal_layer.device = device;
  metal_layer.pixelFormat = pixelFormat;
  metal_layer.colorspace = CGColorSpaceCreateDeviceRGB();
  metal_layer.colorspace = CGColorSpaceCreateWithName(
      kCGColorSpaceDisplayP3);
  return metal_layer;
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
    renderPipelineState = [device newRenderPipelineStateWithDescriptor:desc
                                                                 error:&error];
    if (error)
      NSLog(@"Failed to create render pipeline state: %@", error);
  }
}

void Draw(int tile) {
  id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];

  CAMetalLayer* metal_layer = AllocateMetalLayerIfNeeded(tile);
  id<CAMetalDrawable> drawable = [metal_layer nextDrawable];

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
        r[color_index],
        g[color_index],
        b[color_index],
        1.0);
    encoder = [commandBuffer renderCommandEncoderWithDescriptor:desc];
    color_index = (color_index + 1) % kColorCount;
  }

  {
    static float rgb = 0;
    rgb += 1/9.f;
    if (rgb > 1)
      rgb = 0;

    MTLViewport viewport;
    viewport.originX = 0;
    viewport.originY = 0;
    viewport.width = width;
    viewport.height = height;
    viewport.znear = -1.0;
    viewport.zfar = 1.0;
    [encoder setViewport:viewport];
    [encoder setRenderPipelineState:renderPipelineState];
    vector_float2 positions[3] = {
      {  0.5,  -0.5 },
      { -0.5,  -0.5 },
      {    0,   0.5 },
    };
    [encoder setVertexBytes:positions
                     length:sizeof(positions)
                    atIndex:0];
    vector_float4 colors[3] = {
      { rgb, rgb, rgb, 1 },
      { rgb, rgb, rgb, 1 },
      { rgb, rgb, rgb, 1 },
    };
    [encoder setVertexBytes:colors
                     length:sizeof(colors)
                    atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:3];
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

  static int current_tile = 0;
  switch ([characters characterAtIndex:0]) {
    case 'q':
      [NSApp terminate:nil];
      break;
    case '1':
      for (int tile = 0; tile < num_tiles_1d * num_tiles_1d; ++tile) {
        AllocateMetalLayerIfNeeded(tile);
      }
      DumpIOSurfaceCount();
      break;
    case '2':
      Draw(current_tile);
      DumpIOSurfaceCount();
      current_tile = (current_tile + 1) %
                     (num_tiles_1d * num_tiles_1d);
      break;
    case '3':
      current_tile = (current_tile + num_tiles_1d * num_tiles_1d - 1) %
                     (num_tiles_1d * num_tiles_1d);
      Draw(current_tile);
      DumpIOSurfaceCount();
      break;
    case '4':
      for (int tile = 0; tile < num_tiles_1d * num_tiles_1d; ++tile) {
        Draw(tile);
      }
      DumpIOSurfaceCount();
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
    initWithContentRect:NSMakeRect(0, 0, num_tiles_1d*width, num_tiles_1d*height)
    styleMask:NSWindowStyleMaskResizable | NSWindowStyleMaskTitled
    backing:NSBackingStoreBuffered
    defer:NO];
  [window setOpaque:YES];

  contentLayer = [[CALayer alloc] init];
  [[window contentView] setLayer:contentLayer];
  [[window contentView] setWantsLayer:YES];

  // Use the low power GPU, if there is one.
  NSArray<id<MTLDevice>>* devices = MTLCopyAllDevices();
  if (!device) {
    for (id<MTLDevice> test_device in devices) {
      if (!device || [test_device isLowPower])
        device = test_device;
    }
  }
  commandQueue = [device newCommandQueue];

  // Set up the grid of superlayers.
  for (int x = 0; x < num_tiles_1d; ++x) {
    for (int y = 0; y < num_tiles_1d; ++y) {
      CALayer* super_layer = [[CALayer alloc] init];
      [contentLayer addSublayer:super_layer];
      [super_layer setFrame:CGRectMake(width*x, height*y, width, height)];
      super_layers[num_tiles_1d*x+y] = super_layer;
    }
  }

  printf("This will print the number of IOSurfaces allocated.\n");
  printf("The goal is to see if:\n");
  printf("- IOSurfaces are lazily allocated by CAMetalLayer (they are).\n");
  printf("- IOSurfaces shared between CAMetalLayers (they aren't).\n");
  printf("\n");
  printf("Press 1 to allocate all of the tiles\n");
  printf("Press 2 to draw just the next tile\n");
  printf("Press 3 to draw just the previous tile\n");
  printf("Press 4 to draw all of the tiles\n");

  [window setTitle:@"IOSurface per CALayer"];
  [window makeKeyAndOrderFront:nil];
  DumpIOSurfaceCount();

  [NSApp activateIgnoringOtherApps:YES];
  [NSApp run];
  return 0;
}

