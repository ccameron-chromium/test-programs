// clang++ oscilloscope.mm -framework Metal -framework MetalKit -framework Cocoa -framework QuartzCore -fobjc-arc -g && ./a.out
#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>
#include <vector>
#include <list>
#include <pthread.h>

const int width = 512;
const int height = 512;

const size_t kSampleCount = 5000;

std::vector<float> sample_times;
std::vector<float> sample_currents;

id<MTLDevice> device = nil;
id<MTLCommandQueue> commandQueue = nil;
id<MTLRenderPipelineState> renderPipelineState = nil;
CAMetalLayer* metalLayer = nil;

pthread_t read_samples_thread;
pthread_mutex_t read_samples_mutex;

struct Sample {
  float time;
  float current;
  float voltage;
};

float sample_timebase = 0;
float sample_period = 1000/60;
float sample_max_time = 0;
bool on_sample_on_main_sample_pending = false;
std::list<Sample> samples_on_input_thread;
std::list<Sample> samples_on_main_thread;

void Draw();

///////

void OnSampleOnMainThread() {
  pthread_mutex_lock(&read_samples_mutex);
  samples_on_main_thread = samples_on_input_thread;
  sample_max_time = samples_on_main_thread.back().time;
  on_sample_on_main_sample_pending = false;
  pthread_mutex_unlock(&read_samples_mutex);
  printf("OnSampleOnMainThread %f!\n", sample_max_time);
  Draw();
}

void OnSampleOnInputThread(float time, float current, float voltage) {
  Sample sample;
  sample.time = time;
  sample.current = current;
  sample.voltage = voltage;

  pthread_mutex_lock(&read_samples_mutex);
  samples_on_input_thread.push_front(sample);
  if (samples_on_input_thread.size() > 1000)
    samples_on_input_thread.pop_back();

  if (!on_sample_on_main_sample_pending) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 0.f),
                   dispatch_get_main_queue(), ^{
      OnSampleOnMainThread();
    });
    on_sample_on_main_sample_pending = true;
  }
  pthread_mutex_unlock(&read_samples_mutex);
}

void* ReadSamplesThreadProc(void*) {
  std::vector<uint8_t> line;
  while (1) {
    const size_t kBufferSize = 256;
    uint8_t buffer[kBufferSize];
    size_t bytes_read = read(0, (char*)buffer, kBufferSize);
    for (size_t i = 0; i < bytes_read; ++i) {
      if (buffer[i] == '\n') {
        line.push_back(0);
        {
          float time = 0;
          float current = 0;
          float voltage = 0;
          int assigned = 0;
          int parsed = sscanf((const char*)line.data(), "%f %f %f", &time, &current, &voltage);
          if (parsed != 3) {
            printf("Failed to parse line: \"%s\"\n", line.data());
          } else {
            OnSampleOnInputThread(time, current, voltage);
          }
        }
        line.clear();
      } else {
        line.push_back(buffer[i]);
      }
    }
  }
  return nullptr;
}

void CreateRenderPipelineState() {
  const char* cSource = ""
      "#include <metal_stdlib>\n"
      "#include <simd/simd.h>\n"
      "using namespace metal;\n"
      "typedef struct {\n"
      "    float4 clipSpacePosition [[position]];\n"
      "} RasterizerData;\n"
      "\n"
      "vertex RasterizerData vertexShader(\n"
      "    uint vertexID [[vertex_id]],\n"
      "    constant vector_float2 *positions[[buffer(0)]],\n"
      "    constant vector_float4 *colors[[buffer(1)]]) {\n"
      "  RasterizerData out;\n"
      "  out.clipSpacePosition = vector_float4(0.0, 0.0, 0.0, 1.0);\n"
      "  out.clipSpacePosition.xy = positions[vertexID].xy;\n"
      "  return out;\n"
      "}\n"
      "\n"
      "fragment float4 fragmentShader(RasterizerData in [[stage_in]]) {\n"
      "    return float4(1.0, 1.0, 1.0, 1.0);\n"
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



void Draw() {
  if (!device) {
    device = MTLCreateSystemDefaultDevice();
    commandQueue = [device newCommandQueue];
    metalLayer.device = device;
    metalLayer.pixelFormat = MTLPixelFormatRGBA16Float;
    CreateRenderPipelineState();
  }

  id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
  id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
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

    std::vector<float> positions;
    for (const auto& sample : samples_on_main_thread) {
      float x = (sample_max_time - sample.time) / sample_period;
      if (x > 1)
        break;
      float y = (sample.current / 1000.f);
      positions.push_back(x);
      positions.push_back(y);
    }
    [encoder setVertexBytes:positions.data()
                     length:positions.size() * sizeof(float)
                    atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeLineStrip
                vertexStart:0
                vertexCount:positions.size() / 2];
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
    initWithContentRect:NSMakeRect(0, 0, width, height)
    styleMask:NSWindowStyleMaskResizable | NSWindowStyleMaskTitled
    backing:NSBackingStoreBuffered
    defer:NO];
  [window setOpaque:YES];

  metalLayer = [[CAMetalLayer alloc] init];
  
  CALayer* rootLayer = [[CALayer alloc] init];
  [[window contentView] setLayer:rootLayer];
  [[window contentView] setWantsLayer:YES];
  [rootLayer addSublayer:metalLayer];

  [metalLayer setFrame:CGRectMake(0, 0, width, height)];

  [window setTitle:@"Tiny Metal App"];
  [window makeKeyAndOrderFront:nil];

  Draw();

  pthread_mutex_init(&read_samples_mutex, nullptr);
  pthread_create(&read_samples_thread, nullptr, ReadSamplesThreadProc, nullptr);

  [NSApp activateIgnoringOtherApps:YES];
  [NSApp run];
  return 0;
}

