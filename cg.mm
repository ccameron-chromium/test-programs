// clang++ cg.mm -framework Cocoa -framework QuartzCore && ./a.out
// Press q to quit.
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
int width = 640;
int height = 480;
float shade = 1.0;
CGRect draw_rect;

@implementation MyLayer
- (void)drawInContext:(CGContextRef)ctx {
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
  for (size_t i = 0; i < 17; ++i) {
    CGFloat components[4] = {1 + i/16.f, 0, 0, 1};
    CGColorRef color = CGColorCreate(space, components);
    CGContextSetFillColorWithColor(ctx, color);
    CFRelease(color);
    CGContextFillRect(ctx, CGRectMake(i*32, 0, 32, 32));
  }

  // Dump what they care to tell us about the context (it will give us the
  // context type, which will be kCGContextTypeBitmap or kCGContextTypeUnknown.
  CFShow(ctx);

  // Dump the CALayer's contents (at first there won't be any, but then the next
  // time around it'll be CABackingStore).
  CFShow([self contents]);

  shade -= 0.05;
  if (shade <= 0.6)
    shade = 1.0;
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

  printf("This draws rectangles with color(srgb 1 0 0) to color(srgb 2 0 0) in increments of 1/16\n");
  printf("The background is color(srgb 0 2 0)\n");

  [NSApp activateIgnoringOtherApps:YES];
  [NSApp run];
  return 0;
}
