// clang++ cg.mm -framework Cocoa -framework QuartzCore && ./a.out
// Press q to quit.
// See the printf-ed comments below.
#include <Cocoa/Cocoa.h>
#include <QuartzCore/CALayer.h>
#include <QuartzCore/QuartzCore.h>

@interface MyLayer : CALayer
@end

@interface MainWindow : NSWindow
@end

@interface MyLayerDelegate : NSObject <CALayerDelegate>
@end

MainWindow* window = nil;
MyLayer* my_layer = nil;
int width = 32*16;
int height = 64;
CGRect draw_rect;

@implementation MyLayer
- (void)drawInContext:(CGContextRef)ctx {
  for (size_t i = 0; i < 17; ++i) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
    CGFloat components[4] = {i/8.f, 0, 0, 1};
    CGColorRef color = CGColorCreate(space, components);
    CGContextSetFillColorWithColor(ctx, color);
    CFRelease(color);
    CGContextFillRect(ctx, CGRectMake(i*32, 32, 32, 32));
  }
  {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    CGFloat components[4] = {1, 0, 0, 1};
    CGColorRef color = CGColorCreate(space, components);
    CGContextSetFillColorWithColor(ctx, color);
    CFRelease(color);
    CGContextFillRect(ctx, CGRectMake(0, 0, 32, 32));
  }
}
@end

@implementation MainWindow
- (void)keyDown:(NSEvent *)event {
  if ([event isARepeat])
    return;

  NSString *characters = [event charactersIgnoringModifiers];
  if ([characters length] != 1)
    return;

  switch ([characters characterAtIndex:0]) {
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
    initWithContentRect:NSMakeRect(0, 0, width, height)
    styleMask:NSWindowStyleMaskResizable | NSWindowStyleMaskTitled
    backing:NSBackingStoreBuffered
    defer:NO];
  [window setOpaque:YES];

  CALayer* layer = [[CALayer alloc] init];
  [[window contentView] setLayer:layer];
  [[window contentView] setWantsLayer:YES];

  my_layer = [[MyLayer alloc] init];

  [my_layer setShouldRasterize:YES];
  [my_layer setDrawsAsynchronously:NO];

  CGFloat components[4] = {0, 2, 0, 1};
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
  CGColorRef color = CGColorCreate(space, components);

  [layer addSublayer:my_layer];
  [my_layer setFrame:CGRectMake(0, 0, width, height)];
  [my_layer setBackgroundColor:color];
  [my_layer setNeedsDisplay];
  
  [window setTitle:@"Test"];
  [window makeKeyAndOrderFront:nil];

  printf("This program draws the same content to a CALayer and to an sRGB bitmap\n");
  printf("The content is a gradient in kCGColorSpaceExtendedSRGB with red going from 0 to 2\n");
  printf("When drawn to a CGBitmapContext, the color saturates and stops changing when red>1\n");
  printf("In the CALayer, the gradient becomes a pale orange when red>1\n");
  printf("The background of the CALayer is color(srgb 0 2 0)\n");

  printf("\n");
  printf("Rendering to a bitmap context and reading it back. The graident is:\n");
  {
    uint32_t* pixels = new uint32_t[width*height];
    memset(pixels, 0, 4*width*height);

    CGContextRef ctx = CGBitmapContextCreate(
        pixels, width, height, 8, 4*width, CGColorSpaceCreateWithName(kCGColorSpaceSRGB), kCGImageAlphaPremultipliedLast|kCGImageByteOrder32Little);
    CFShow(ctx);
    [my_layer drawInContext:ctx];
    CFRelease(ctx);
    printf("The gradient is:\n");
    for (int x = 0; x < width; x += 16) {
      printf("    At %d,%d, the color is %x\n", x, 0, pixels[x]);
    }
    printf("The color(display-p3 1 0 0) is: %x\n", pixels[32*width]);
  }

  [NSApp activateIgnoringOtherApps:YES];
  [NSApp run];
  return 0;
}

