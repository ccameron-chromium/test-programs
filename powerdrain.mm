// Compile with:
// clang++ powerdrain.mm -framework Quartz -framework OpenGL -framework Cocoa
// ./a.out 0 0 1 20 1
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/GLU.h>
#include <OpenGL/GLext.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>

const GLuint tex_size = 4096;
int g_num_quads = 0;
int g_num_textures = 0;
int g_num_threads = 0;
uint64_t g_num_fib = 0;
int g_num_msec_to_sleep = 0;

double GetTimestamp() {
  static double start = CFAbsoluteTimeGetCurrent();
  return CFAbsoluteTimeGetCurrent() - start;
}

uint64_t Fib(uint64_t n) {
  if (n == 1)
    return 1;
  if (n == 2)
    return 1;
  return Fib(n - 1) + Fib(n - 2);
}

void* FibThreadMain(void*) {
  return (void*)Fib(g_num_fib);
}

CGLContextObj context = NULL;

void FullscreenQuadsInitialize() {
  // Create the GL context and make it current.
  {
    context = NULL;
    CGLError error;
    CGLPixelFormatAttribute attribs[] = {
        kCGLPFAAllowOfflineRenderers, (CGLPixelFormatAttribute)1,
        (CGLPixelFormatAttribute)0,
    };
    CGLPixelFormatObj pixel_format;
    GLint npix;
    error = CGLChoosePixelFormat(attribs, &pixel_format, &npix);
    CGLContextObj share_group_context = NULL;
    error = CGLCreateContext (pixel_format, share_group_context, &context);

    CGLSetCurrentContext(context);
  }

  // Initialize the GL framebuffer.
  {
    GLuint texture;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, tex_size, tex_size, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glBindTexture(GL_TEXTURE_2D, 0);
    GLuint framebuffer;
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);

    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
      printf("GL Framebuffer incomplete, quitting\n");
      exit(1);
    }
    if (glGetError() != GL_NO_ERROR) {
      printf("GL Framebuffer initialization error, quitting\n");
      exit(1);
    }
  }

  // Initialize the GL textures.
  for (int i = 0; i < g_num_textures; ++i) {
    GLuint texture;
    glGenTextures(1, &texture);
    glActiveTexture(GL_TEXTURE0 + i);
    glBindTexture(GL_TEXTURE_2D, texture);
    glEnable(GL_TEXTURE_2D);
    void* temp_data = malloc(tex_size*tex_size*4);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, tex_size, tex_size, 0, GL_RGBA, GL_UNSIGNED_BYTE, temp_data);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    free(temp_data);
    if (glGetError() != GL_NO_ERROR) {
      printf("GL Texture initialization error, quitting\n");
      exit(1);
    }
  }

  // Initialize the drawing state.
  {
    glViewport(0, 0, tex_size, tex_size);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(-1, 1, -1, 1, -1, 1);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    // glEnable(GL_BLEND);
    glDisable(GL_CULL_FACE);
    glColor4f(1, 0, 0, 0.1);

    if (glGetError() != GL_NO_ERROR) {
      printf("GL State initialization error, quitting\n");
      exit(1);
    }
  }

  CGLSetCurrentContext(NULL);
}

void FullscreenQuadsDraw(int quad_count) {
  CGLSetCurrentContext(context);

  if (glGetError() != GL_NO_ERROR) {
    printf("GL Error before drawing quads\n");
    exit(1);
  }

  // Draw as many fullscreen quads as requested.
  GLuint query;
  glGenQueries(1, &query);
  glBeginQuery(GL_SAMPLES_PASSED, query);
  glBegin(GL_QUADS);
  for (int i = 0; i < quad_count; ++i) {
    glVertex3f(-1, -1, 0);
    glVertex3f(-1,  1, 0);
    glVertex3f( 1,  1, 0);
    glVertex3f( 1, -1, 0);
  }
  glEnd();
  glEndQuery(GL_SAMPLES_PASSED);

  // Use a busy-loop to ramp up the CPU, too.
  while (1) {
    GLint available;
    glGetQueryObjectiv(query, GL_QUERY_RESULT_AVAILABLE, &available);
    if (available)
      break;
  }

  CGLSetCurrentContext(NULL);
}

void* FullscreenQuadsThreadMain(void*) {
  FullscreenQuadsDraw(g_num_quads);
  return NULL;
}

int main(int argc, char* argv[]) {
  if (argc != 6) {
    printf("./a.out [# gpu quad] [# gpu textures] [# fib threads] [# fib to compute] [# msec to sleep]\n");
    printf("(start with 1, 1, and increase until it takes too long\n");
    return 1;
  }
  g_num_quads = atoi(argv[1]);
  g_num_textures = atoi(argv[2]);
  g_num_threads = atoi(argv[3]);
  g_num_fib = atoi(argv[4]);
  g_num_msec_to_sleep = atoi(argv[5]);

  FullscreenQuadsInitialize();

  while (1) {
    double time_start = GetTimestamp();

    FullscreenQuadsDraw(g_num_quads);
    pthread_t threads[16];
    for (int i = 0; i < g_num_threads; ++i) {
      pthread_create(&threads[i], NULL, FibThreadMain, NULL);
    }
    pthread_create(&threads[g_num_threads], NULL, FullscreenQuadsThreadMain, NULL);

    for (int i = 0; i < g_num_threads; ++i) {
      pthread_join(threads[i], NULL);
    }
    pthread_join(threads[g_num_threads], NULL);

    if (g_num_msec_to_sleep)
      usleep(g_num_msec_to_sleep * 1000);

    double time_stop = GetTimestamp();
    double time = time_stop - time_start;
    fflush(stdout);
  }

  return 0;
}
