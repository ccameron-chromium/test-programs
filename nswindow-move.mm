// clang++ nswindow-resize.mm -framework Cocoa
#include <Cocoa/Cocoa.h>

@interface MainWindow : NSWindow
@end

@interface MainWindowDelegate : NSObject<NSWindowDelegate>
@end

MainWindow* window;
MainWindowDelegate* delegate;

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
  }
}

- (void) mouseDown:(NSEvent *) event {
  printf("mouseDown!\n");
  [super mouseDown:event];
}

- (void) mouseUp:(NSEvent *) event {
  printf("mouseUp!\n");
  [super mouseUp:event];
}

- (void)sendEvent:(NSEvent*)event {
  NSEventType type = [event type];
  if (type == NSEventTypeLeftMouseUp) {
    printf("sendEvent LeftMouseUp\n");
  }
  [super sendEvent:event];
  if (type == NSEventTypeLeftMouseUp) {
    printf("          LeftMouseUp done\n");
  }
}

@end

@implementation MainWindowDelegate
- (NSSize) windowWillResize:(NSWindow *) sender 
                     toSize:(NSSize) frameSize {
  printf("WindowWillResize: %fx%f ... \n", frameSize.width, frameSize.height);
  return frameSize;
}

- (void) windowWillStartLiveResize:(NSNotification *) notification {
  printf("Started live resize!\n");
}

- (void) windowDidEndLiveResize:(NSNotification *) notification {
  printf("Stopped live resize!\n");
}

- (void) windowWillMove:(NSNotification *) notification {
  printf("windowWillMove\n");
}

- (void) windowDidMove:(NSNotification *) notification {
  printf("windowDidMove %fx%f\n", [window frame].origin.x, [window frame].origin.y);
}

@end


int main(int argc, char* argv[]) {
  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

  NSMenu* menubar = [NSMenu alloc];
  [NSApp setMainMenu:menubar];

  window = [[MainWindow alloc]
    initWithContentRect:NSMakeRect(0, 0, 400, 400)
    styleMask:NSWindowStyleMaskResizable | NSWindowStyleMaskTitled
    backing:NSBackingStoreBuffered
    defer:NO];
  [window setOpaque:YES];

  delegate = [[MainWindowDelegate alloc] init];
  [window setDelegate:delegate];

  [window setTitle:@"Resize test"];
  [window makeKeyAndOrderFront:nil];

  [NSApp activateIgnoringOtherApps:YES];
  [NSApp run];
  return 0;
}

