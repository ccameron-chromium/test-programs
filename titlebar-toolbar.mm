// Build using:
// clang++ titlebar-toolbar.mm -framework Cocoa -framework Quartz && ./a.out

#include <Cocoa/Cocoa.h>

int width = 640;
int height = 480;

@interface MainWindow : NSWindow
@end

@interface MyTitlebarViewController : NSTitlebarAccessoryViewController
@end

MainWindow* window = nil;
MyTitlebarViewController* titlebar_tab_view_controller = nil;
MyTitlebarViewController* titlebar_omni_view_controller = nil;

NSView* titlebar_tab_view = nil;
NSView* titlebar_omni_view = nil;

@implementation MainWindow
- (void)keyDown:(NSEvent *)event {
  if ([event isARepeat])
    return;

  NSString *characters = [event charactersIgnoringModifiers];
  if ([characters length] != 1)
    return;

  switch ([characters characterAtIndex:0]) {
    case 'f':
      [window toggleFullScreen:nil];
      break;
    case 'q':
      [NSApp terminate:nil];
      break;
  }
}
@end

@implementation MyTitlebarViewController
- (void)viewWillAppear {
  [super viewWillAppear];
  printf("viewWillAppear\n");
}

- (void)viewWillTransitionToSize:(NSSize)newSize {
  printf("titlebar will transition to size %fx%f\n", newSize.width, newSize.height);
}
@end

int main(int argc, char* argv[]) {
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

  NSMenu* menubar = [NSMenu alloc];
  [NSApp setMainMenu:menubar];

  NSWindowStyleMask style_mask =
      NSWindowStyleMaskResizable | NSWindowStyleMaskTitled |
      NSWindowStyleMaskFullSizeContentView;
  window = [[MainWindow alloc]
    initWithContentRect:NSMakeRect(200, 200, width, height)
    styleMask:style_mask
    backing:NSBackingStoreBuffered
    defer:NO];
  [window setOpaque:YES];
  window.titleVisibility = NSWindowTitleHidden;

  // Set the window contents to be red.
  {
    CALayer* layer = [[CALayer alloc] init];
    [layer setBounds:CGRectMake(0, 0, width, height)];
    [layer setBackgroundColor:CGColorCreateGenericRGB(1, 0, 0, 1)];
    [[window contentView] setLayer:layer];
    [[window contentView] setWantsLayer:YES];
  }

  titlebar_tab_view_controller = [[MyTitlebarViewController alloc] init];
  titlebar_tab_view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width/2, 100)];

  // Set the tab titlebar's view to be green.
  {
    CALayer* layer = [[CALayer alloc] init];
    [layer setBounds:CGRectMake(0, 0, width, 100)];
    [layer setBackgroundColor:CGColorCreateGenericRGB(0, 1, 0, 1)];
    [titlebar_tab_view setLayer:layer];
    [titlebar_tab_view setWantsLayer:YES];
  }

  [titlebar_tab_view_controller setView:titlebar_tab_view];
  [titlebar_tab_view_controller setLayoutAttribute:NSLayoutAttributeTop];
  
  titlebar_omni_view_controller = [[MyTitlebarViewController alloc] init];
  titlebar_omni_view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width/2, 100)];

  // Set the omni titlebar's view to be blue.
  {
    CALayer* layer = [[CALayer alloc] init];
    [layer setBounds:CGRectMake(0, 0, width, 100)];
    [layer setBackgroundColor:CGColorCreateGenericRGB(0, 0, 1, 1)];
    [titlebar_omni_view setLayer:layer];
    [titlebar_omni_view setWantsLayer:YES];
  }

  [titlebar_omni_view_controller setView:titlebar_omni_view];
  [titlebar_omni_view_controller setLayoutAttribute:NSLayoutAttributeBottom];

  // [window setTitleVisibility:NSWindowTitleHidden];
  // [window setTitlebarAppearsTransparent:YES];
  [window addTitlebarAccessoryViewController:titlebar_tab_view_controller];
  [window addTitlebarAccessoryViewController:titlebar_omni_view_controller];
  // [window setToolbarStyle:NSWindowToolbarStyleUnified];


  [window makeKeyAndOrderFront:nil];

  [NSApp activateIgnoringOtherApps:YES];
  [NSApp run];
  return 0;
}
