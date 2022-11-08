// clang++ oscilloscope.mm -framework Metal -framework MetalKit -framework Cocoa -framework QuartzCore -fobjc-arc -g && ./a.out
#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>
#include <vector>
#include <list>
#include <pthread.h>

const int width = 1280;
const int height = 512;

const size_t kSampleCount = 5000;

float viz_power_max = 2.f;

std::vector<float> sample_times;
std::vector<float> sample_powers;

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
  float PowerInWatts() const {
    return (current / 1000.f) * (voltage / 1000.f);
  }
};

float sample_timebase = 0;
float sample_period = 1000 * 1.f/60.f;
float sample_max_time = 0;
float viz_max_time = 0;
bool on_sample_on_main_sample_pending = false;
size_t viz_periods = 5;
std::list<Sample> samples_on_input_thread;
std::list<Sample> samples_on_main_thread;

float TimeToX(float t) {
  float x = (viz_max_time - t) / sample_period;
  return 1 - x/2;
}

float PowerToY(float power) {
  return 2 * power / viz_power_max - 1;
}

void UpdateVizMaxTime() {
  viz_max_time = sample_period * (int)((sample_max_time + sample_period) / sample_period);
}

void Draw();

float Score(const std::vector<float>& x, size_t T, size_t len) {
  float x_avg = 0;
  float y_avg = 0;
  for (size_t i = 0; i < len; ++i) {
    float xi = x[i];
    float yi = x[i+T];
    x_avg += xi;
    y_avg += yi;
  }
  x_avg /= len;
  y_avg /= len;

  float x_bar_norm = 0;
  float y_bar_norm = 0;
  for (size_t i = 0; i < len; ++i) {
    float xi = x[i] - x_avg;
    float yi = x[i+T] - y_avg;
    x_bar_norm += xi*xi;
    y_bar_norm += yi*yi;
  }
  x_bar_norm = sqrtf(x_bar_norm);
  y_bar_norm = sqrtf(y_bar_norm);

  float corr = 0;
  for (size_t i = 0; i < len; ++i) {
    float xi = (x[i] - x_avg) / x_bar_norm;
    float yi = (x[i+T] - y_avg) / y_bar_norm;
    corr += xi * yi;
  }
  return corr;
}

void FindBestModes() {
  printf("FindBestModes\n");
  int min_period_samples = 50;
  int max_period_samples = 500;
  std::vector<float> correlations;
  correlations.resize(max_period_samples);

  std::vector<float> powers;
  for (const auto& sample : samples_on_main_thread) {
    powers.push_back(sample.PowerInWatts());
  }

  float max_corr = 0;
  int max_corr_i = 0;
  for (int i = 10; i < 500; ++i) {
    float corr = Score(powers, i, 5*i);
    if (corr > max_corr) {
      max_corr = corr;
      max_corr_i = i;
    }
  }
  float msec = max_corr_i / 10.f;
  float sec = msec / 1000;
  printf("max correlation at %f msec (%f Hz), correlation %f\n",
      max_corr_i / 10.f,
      1.f / sec,
      max_corr);

  sample_period = msec;
  UpdateVizMaxTime();

  Draw();
}

///////

void OnSampleOnMainThread() {
  pthread_mutex_lock(&read_samples_mutex);
  samples_on_main_thread = samples_on_input_thread;
  sample_max_time = samples_on_main_thread.front().time;
  on_sample_on_main_sample_pending = false;
  pthread_mutex_unlock(&read_samples_mutex);
  UpdateVizMaxTime();
  Draw();
}

void OnSampleOnInputThread(float time, float current, float voltage) {
  Sample sample;
  sample.time = time;
  sample.current = current;
  sample.voltage = voltage;

  pthread_mutex_lock(&read_samples_mutex);
  samples_on_input_thread.push_front(sample);
  if (samples_on_input_thread.size() > 10000)
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
      "    constant vector_float2 *positions[[buffer(0)]]) {\n"
      "  RasterizerData out;\n"
      "  out.clipSpacePosition = vector_float4(0.0, 0.0, 0.0, 1.0);\n"
      "  out.clipSpacePosition.xy = positions[vertexID].xy;\n"
      "  return out;\n"
      "}\n"
      "\n"
      "fragment float4 fragmentShader(RasterizerData in [[stage_in]],\n"
      "                               constant float4 &color [[buffer(0)]]) {\n"
      "    return color;\n"
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

  for (int i = 0; i <= viz_power_max; i += 1) {
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
    positions.push_back(-1); positions.push_back(PowerToY(i));
    positions.push_back( 1); positions.push_back(PowerToY(i));
    [encoder setVertexBytes:positions.data()
                     length:positions.size() * sizeof(float)
                    atIndex:0];
    float c = 0;
    switch (i % 4) {
      case 0: c = 1.f/1.f; break;
      case 1: c = 1.f/16.f; break;
      case 2: c = 1.4/4.f; break;
      case 3: c = 1.f/16.f; break;
      default: break;
    }
    float color[4] = {c, c, c, 1.f};
    [encoder setFragmentBytes:color
                       length:sizeof(color)
                      atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeLine
                vertexStart:0
                vertexCount:positions.size() / 2];
  }

  for (size_t i = 0; i < viz_periods; ++i) {
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
    positions.push_back(TimeToX(viz_max_time - i*sample_period)); positions.push_back(-1);
    positions.push_back(TimeToX(viz_max_time - i*sample_period)); positions.push_back( 1);
    [encoder setVertexBytes:positions.data()
                     length:positions.size() * sizeof(float)
                    atIndex:0];
    float color[4] = {0.5, 0.5, 0.5, 1.0};
    [encoder setFragmentBytes:color
                       length:sizeof(color)
                      atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeLine
                vertexStart:0
                vertexCount:positions.size() / 2];
  }

  
  for (size_t i = 0; i < 9; ++i) {
    int dx = 0;
    int dy = 0;
    switch (i) {
      case 0: dx = -1; dy = -1; break;
      case 1: dx = -1; dy =  1; break;
      case 2: dx =  1; dy = -1; break;
      case 3: dx =  1; dy =  1; break;
      case 4: dx =  0; dy = -1; break;
      case 5: dx =  0; dy =  1; break;
      case 6: dx = -1; dy =  0; break;
      case 7: dx =  1; dy =  0; break;
      default: break;
    }
    
  
    MTLViewport viewport;
    viewport.originX = dx;
    viewport.originY = dy;
    viewport.width = width;
    viewport.height = height;
    viewport.znear = -1.0;
    viewport.zfar = 1.0;
    [encoder setViewport:viewport];
    [encoder setRenderPipelineState:renderPipelineState];

    std::vector<float> positions;
    for (const auto& sample : samples_on_main_thread) {
      float x = TimeToX(sample.time);
      if (x < -1)
        break;
      positions.push_back(x);
      positions.push_back(PowerToY(sample.PowerInWatts()));
      if (positions.size() > 2048)
        break;
    }
    [encoder setVertexBytes:positions.data()
                     length:positions.size() * sizeof(float)
                    atIndex:0];
    float cx = (dx == 0) ? 1.0 : 0.5;
    float cy = (dy == 0) ? 1.0 : 0.5;
    float color[4] = {0.0, cx*cy, 0.0, 1.0};
    [encoder setFragmentBytes:color
                       length:sizeof(color)
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
  if ([characters length] != 1) {
    return;
  }

  switch ([characters characterAtIndex:0]) {
    case ' ':
      FindBestModes();
      break;
    case 'q':
      [NSApp terminate:nil];
      break;
    case 0xf700:
      viz_power_max *= 2;
      break;
    case 0xf701:
      viz_power_max /= 2;
      break;
    case 0x2c:
      viz_max_time -= 0.1f;
      break;
    case 0x2e:
      viz_max_time += 0.1f;
      break;
    default:
      printf("Unsupported input 0x%x\n", [characters characterAtIndex:0]);
      break;
  }

  Draw();
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

  [window setTitle:@"BattOr Oscilloscope"];
  [window makeKeyAndOrderFront:nil];

  Draw();

  pthread_mutex_init(&read_samples_mutex, nullptr);
  pthread_create(&read_samples_thread, nullptr, ReadSamplesThreadProc, nullptr);

  [NSApp activateIgnoringOtherApps:YES];
  [NSApp run];
  return 0;
}

