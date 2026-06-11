// Test program to verify the sampling behavior of x420 IOSurfaces.
// clang++ mtl-iosurface-x420.mm -framework Metal -framework MetalKit -framework Cocoa -framework QuartzCore -fobjc-arc && ./a.out
#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>
#include <IOSurface/IOSurface.h>

const int width = 640;
const int height = 480;

id<MTLDevice> device = nil;
id<MTLRenderPipelineState> renderPipelineState = nil;

id<MTLTexture> y_tex;
id<MTLTexture> uv_tex;
id<MTLTexture> rgba_tex;

uint16_t y_value = 1023;
uint16_t u_value = 65530;
uint16_t v_value = 65472;

void CreateRenderPipelineState() {
  if (renderPipelineState)
    return;
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
      "  return out;\n"
      "}\n"
      "\n"
      "fragment float4 fragmentShader(RasterizerData in [[stage_in]],\n"
      "                               texture2d<float> y_tex [[texture(0)]],\n"
      "                               texture2d<float> uv_tex [[texture(1)]]) {\n"
      "    sampler s(mag_filter::linear, min_filter::linear);\n"
      "    float r = y_tex.sample(s, in.texCoord).r;\n"
      "    float2 gb = uv_tex.sample(s, in.texCoord).rg;\n"
      "    return float4(r, gb.x, gb.y, 1.0);\n"
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
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Unorm;
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
  id<MTLCommandQueue> commandQueue = [device newCommandQueue];
  id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];

  id<MTLRenderCommandEncoder> encoder = nil;
  {
    MTLRenderPassDescriptor* desc = [MTLRenderPassDescriptor renderPassDescriptor];
    desc.colorAttachments[0].texture = rgba_tex;
    desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    desc.colorAttachments[0].storeAction = MTLStoreActionStore;
    desc.colorAttachments[0].clearColor = MTLClearColorMake(
        0.5,
        0.5,
        0.5,
        1.0);
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
    [encoder setFragmentTexture:y_tex atIndex:0];
    [encoder setFragmentTexture:uv_tex atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:6];
  }
  [encoder endEncoding];

  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];

  // Read back values
  uint16_t *result = (uint16_t *)malloc(width * height * 4 * sizeof(uint16_t));
  [rgba_tex getBytes:result
         bytesPerRow:width * 4 * sizeof(uint16_t)
          fromRegion:MTLRegionMake2D(0, 0, width, height)
         mipmapLevel:0];
  printf("Read back: R=%u, G=%u, B=%u, A=%u\n", result[0], result[1], result[2], result[3]);
  free(result);
}

int main(int argc, char* argv[]) {
  printf("Usage: ./a.out [Y [U [V]]]\n");

  if (argc > 1) {
    y_value = atoi(argv[1]);
  }
  if (argc > 2) {
    u_value = atoi(argv[2]);
  }
  if (argc > 3) {
    v_value = atoi(argv[3]);
  }
  printf("Writing Y=%u, U=%u, V=%u\n", y_value, u_value, v_value);

  // Select MTLDevice to use.
  NSArray<id<MTLDevice>>* devices = MTLCopyAllDevices();
  if (!device) {
    for (id<MTLDevice> test_device in devices) {
      if (!device || [test_device isLowPower])
        device = test_device;
    }
  }

  // Create IOSurface with 'x420' format
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
  
  // Populate IOSurface (Y and UV planes)
  IOSurfaceLock(surface, 0, NULL);
  uint16_t* y_ptr = (uint16_t *)IOSurfaceGetBaseAddressOfPlane(surface, 0);
  size_t y_stride = IOSurfaceGetBytesPerRowOfPlane(surface, 0) / 2;
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      y_ptr[y * y_stride + x] = y_value; // Y
    }
  }

  uint16_t* uv_ptr = (uint16_t *)IOSurfaceGetBaseAddressOfPlane(surface, 1);
  size_t uv_stride = IOSurfaceGetBytesPerRowOfPlane(surface, 1) / 2;
  for (int y = 0; y < height / 2; ++y) {
    for (int x = 0; x < width / 2; ++x) {
      uv_ptr[y * uv_stride + x * 2]     = u_value; // U
      uv_ptr[y * uv_stride + x * 2 + 1] = v_value; // V
    }
  }
  IOSurfaceUnlock(surface, 0, NULL);

  // Bind planes to textures
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

  // Create destination 16-bit RGBA texture
  MTLTextureDescriptor *rgba_desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Unorm
                                   width:width
                                  height:height
                               mipmapped:NO];
  rgba_desc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
  rgba_tex = [device newTextureWithDescriptor:rgba_desc];

  CreateRenderPipelineState();
  Draw();
  return 0;
}

