// clang++ color-match.mm -framework Metal -framework MetalKit -framework Cocoa -framework QuartzCore -fobjc-arc -g && ./a.out
#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>
#include <IOSurface/IOSurface.h>

const int width = 512;
const int height = 512;

id<MTLDevice> device = nil;
id<MTLRenderPipelineState> renderPipelineState = nil;
CAMetalLayer* metalLayers[2] = {nil, nil};

void CreateRenderPipelineState() {
  const char* cSource = ""
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
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    renderPipelineState = [device newRenderPipelineStateWithDescriptor:desc
                                                                 error:&error];
    if (error)
      NSLog(@"Failed to create render pipeline state: %@", error);
  }
}

void Draw(CAMetalLayer* metalLayer, MTLPixelFormat pixelFormat, float red, float green, float blue) {
  device = MTLCreateSystemDefaultDevice();
  id<MTLCommandQueue> commandQueue = [device newCommandQueue];
  id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];

  metalLayer.device = device;
  metalLayer.pixelFormat = pixelFormat;

  id<CAMetalDrawable> drawable = [metalLayer nextDrawable];

  id<MTLRenderCommandEncoder> encoder = nil;
  {
    MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.colorAttachments[0].texture = drawable.texture;
    desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    desc.colorAttachments[0].storeAction = MTLStoreActionStore;
    desc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1.0);
    encoder = [commandBuffer renderCommandEncoderWithDescriptor:desc];
  }

  CreateRenderPipelineState();
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
      {  1,  -1 },
      { -1,  -1 },
      {  1,   1 },

      {  1,   1 },
      { -1,   1 },
      { -1,  -1 },
    };
    [encoder setVertexBytes:positions
                     length:sizeof(positions)
                    atIndex:0];
    vector_float4 colors[6] = {
      { red, green, blue, 1 },
      { red, green, blue, 1 },
      { red, green, blue, 1 },
      { red, green, blue, 1 },
      { red, green, blue, 1 },
      { red, green, blue, 1 },
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

  switch ([characters characterAtIndex:0]) {
    case ' ':
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

  NSWindow* window = [[MainWindow alloc]
    initWithContentRect:NSMakeRect(0, 0, width*2, height)
    styleMask:NSWindowStyleMaskResizable | NSWindowStyleMaskTitled
    backing:NSBackingStoreBuffered
    defer:NO];
  [window setOpaque:YES];

  metalLayers[0] = [[CAMetalLayer alloc] init];
  metalLayers[1] = [[CAMetalLayer alloc] init];
  
  CALayer* rootLayer = [[CALayer alloc] init];
  [[window contentView] setLayer:rootLayer];
  [[window contentView] setWantsLayer:YES];
  [rootLayer addSublayer:metalLayers[0]];
  [rootLayer addSublayer:metalLayers[1]];

  [metalLayers[0] setFrame:CGRectMake(0, 0, width, height)];
  [metalLayers[1] setFrame:CGRectMake(width, 0, width, height)];

  [window setTitle:@"Tiny Metal App"];
  [window makeKeyAndOrderFront:nil];

  // Draw color(srgb 2 0 0) to a floating-point buffer.
  metalLayers[0].colorspace = CGColorSpaceCreateWithName(
      kCGColorSpaceExtendedSRGB);
  Draw(metalLayers[0], MTLPixelFormatRGBA16Float, 2.0, 0.0, 0.0);
  metalLayers[1].wantsExtendedDynamicRangeContent = NO;
  printf("Left: color(srgb 2 0 0) drawn to floating-pointer buffer\n");
  
  // Draw color(srgb 2 0 0) to a unorm buffer.
  metalLayers[0].colorspace = CGColorSpaceCreateWithName(
      kCGColorSpaceExtendedSRGB);
  metalLayers[1].wantsExtendedDynamicRangeContent = NO;
  Draw(metalLayers[1], MTLPixelFormatBGRA8Unorm, 2.0, 0.0, 0.0);
  printf("Right: color(srgb 2 0 0) drawn to fixed-point buffer\n");

  [NSApp activateIgnoringOtherApps:YES];
  [NSApp run];
  return 0;
}

