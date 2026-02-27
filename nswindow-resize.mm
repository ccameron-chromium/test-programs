// clang++ nswindow-resize.mm -framework Cocoa
#include <Cocoa/Cocoa.h>

@interface MainWindow : NSWindow
@end

@interface MainWindowDelegate : NSObject<NSWindowDelegate>
@end

MainWindow* window;
MainWindowDelegate* delegate;
bool in_live_resize = false;
bool pending_resize = false;
NSSize pending_resize_size;
NSPoint live_resize_anchor;

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
  printf("exit mouseDown!\n");
}

- (void) doDeferredResize {
  // [self performSelector:@selector(doDeferredResize) withObject:nil afterDelay:0.2];
  if (!pending_resize) {
    printf("Tick, no deferred resize\n");
    return;
  }

  NSRect frame = [self frame];
  printf("About to deferred resize %fx%f->%fx%f!\n",
      frame.size.width, frame.size.height,
      pending_resize_size.width, pending_resize_size.height);
  frame.size = pending_resize_size;
  [self setFrame:frame display:YES animate:NO];
  pending_resize = false;
}


@end

@implementation MainWindowDelegate
- (NSSize) windowWillResize:(NSWindow *) sender 
                     toSize:(NSSize) frameSize {
  if (!in_live_resize) {
    return frameSize;
  }

  printf("WindowWillResize: %fx%f ... ", frameSize.width, frameSize.height);
  if (!pending_resize) {
    printf("deferring\n");
    pending_resize = true;
    pending_resize_size = frameSize;

  [NSTimer scheduledTimerWithTimeInterval:0.2
                                   target:window
                                 selector:@selector(doDeferredResize)
                                 userInfo:nil
                                  repeats:YES];

  } else {
    printf("skipping!\n");
  }
  printf("  Run loop %p\n", [NSRunLoop currentRunLoop]);
  return [window frame].size;
}

- (void) windowWillStartLiveResize:(NSNotification *) notification {
  printf("Started live resize!\n");
  printf("  Run loop %p\n", [NSRunLoop currentRunLoop]);
  in_live_resize = true;
  // We need to figure out which corner is being used for the live resize here.
  NSPoint p = [window mouseLocationOutsideOfEventStream];
  NSRect frame = [window frame];
  live_resize_anchor = p;
}

- (void) windowDidEndLiveResize:(NSNotification *) notification {
  printf("Stopped live resize!\n");
  in_live_resize = false;
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
  // [window performSelector:@selector(doDeferredResize) withObject:nil afterDelay:0.2];


  [window setTitle:@"Resize test"];
  [window makeKeyAndOrderFront:nil];

  [NSApp activateIgnoringOtherApps:YES];
  [NSApp run];
  return 0;
}

