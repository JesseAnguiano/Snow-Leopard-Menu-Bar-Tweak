// A separate, click-through surface below the menu. Native replica shadows
// were requested successfully but absent in the user's A/B screenshots.
static const CGFloat SLLowerShadowHeight = 14.0;
static NSInteger SLLowerShadowWindowLevel(void) {
    // Desktop decoration, NOT an overlay on application title bars. Keep the
    // surface above the wallpaper but below desktop icons and normal windows.
    return (NSInteger)CGWindowLevelForKey(kCGDesktopWindowLevelKey) + 1;
}
static const CGFloat SLLowerShadowAlpha[] = {
    .4074,.3704,.2920,.2518,.2131,.1803,.1487,.1223,
    .0909,.0584,.0530,.0323,.0189,.0128,0
};

static BOOL SLLowerShadowAllowed(BOOL active, NSApplicationPresentationOptions options,
                                 NSRect screen, NSRect visible) {
    // Conservative policy: do not leave a floating strip in fullscreen or when
    // automatic menu hiding is enabled, even when the menu temporarily reveals.
    return active && !(options & (NSApplicationPresentationHideMenuBar |
                                  NSApplicationPresentationAutoHideMenuBar)) &&
        NSMaxY(screen) - NSMaxY(visible) > 1.0;
}

static NSRect SLLowerShadowFrame(NSRect screen, NSRect menu) {
    if (NSWidth(screen) <= 0 || NSHeight(menu) <= 0 || NSHeight(menu) >= 80 ||
        fabs(NSMinX(menu) - NSMinX(screen)) > 1 ||
        fabs(NSWidth(menu) - NSWidth(screen)) > 1 ||
        fabs(NSMaxY(menu) - NSMaxY(screen)) > 1) return NSZeroRect;
    return NSMakeRect(NSMinX(screen), NSMinY(menu) - SLLowerShadowHeight,
                      NSWidth(screen), SLLowerShadowHeight);
}

static void SLDrawLowerShadow(CGContextRef context, NSRect bounds) {
    if (!context || NSIsEmptyRect(bounds)) return;
    CGFloat components[15 * 4], locations[15];
    for (NSUInteger i = 0; i < 15; i++) {
        components[i*4] = components[i*4+1] = components[i*4+2] = 0;
        components[i*4+3] = SLLowerShadowAlpha[i];
        locations[i] = (CGFloat)i / 14;
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, locations, 15);
    if (gradient) {
        CGContextDrawLinearGradient(context, gradient,
            CGPointMake(NSMinX(bounds), NSMaxY(bounds)),
            CGPointMake(NSMinX(bounds), NSMinY(bounds)), 0);
        CGGradientRelease(gradient);
    }
    CGColorSpaceRelease(space);
}

@interface SLSnowLeopardMenuBarLowerShadowView : NSView
@end
@implementation SLSnowLeopardMenuBarLowerShadowView
- (BOOL)isOpaque { return NO; }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    SLDrawLowerShadow(NSGraphicsContext.currentContext.CGContext, self.bounds);
}
@end

@interface SLSnowLeopardMenuBarLowerShadowPanel : NSPanel
@end
@implementation SLSnowLeopardMenuBarLowerShadowPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

static NSMutableDictionary<NSNumber *, SLSnowLeopardMenuBarLowerShadowPanel *> *SLLowerShadowPanels;
static void HideMenuBarLowerShadows(void) {
    for (NSPanel *panel in SLLowerShadowPanels.allValues) {
        if (panel.isVisible) [panel orderOut:nil];
    }
}

static void RefreshMenuBarLowerShadows(void) {
    if (!NSApp.isActive || (NSApp.mainWindow.styleMask & NSWindowStyleMaskFullScreen)) {
        HideMenuBarLowerShadows();
        return;
    }
    NSMutableSet<NSNumber *> *liveDisplays = [NSMutableSet set];
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *displayID = screen.deviceDescription[@"NSScreenNumber"];
        if (!displayID || !SLLowerShadowAllowed(YES, NSApp.currentSystemPresentationOptions,
                                               screen.frame, screen.visibleFrame)) continue;
        NSRect frame = NSZeroRect;
        // Four appearance replicas still produce only ONE shadow per display.
        for (NSWindow *replica in KnownMenuBarWindows.allObjects) {
            // NSScreen snapshots need not have pointer identity. Hidden
            // replicas may also lack .screen; exact frame matching below is
            // still required, so use the stable display ID when available.
            NSNumber *replicaDisplay = replica.screen.deviceDescription[@"NSScreenNumber"];
            if (replicaDisplay && ![replicaDisplay isEqual:displayID]) continue;
            if (!objc_getAssociatedObject(BackdropViewForWindow(replica), &SLDirectMaterialTokenKey)) continue;
            frame = SLLowerShadowFrame(screen.frame, replica.frame);
            if (!NSIsEmptyRect(frame)) break;
        }
        if (NSIsEmptyRect(frame)) continue;
        [liveDisplays addObject:displayID];
        if (!SLLowerShadowPanels) SLLowerShadowPanels = [NSMutableDictionary dictionary];
        SLSnowLeopardMenuBarLowerShadowPanel *panel = SLLowerShadowPanels[displayID];
        if (!panel) {
            panel = [[SLSnowLeopardMenuBarLowerShadowPanel alloc] initWithContentRect:frame
                styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                backing:NSBackingStoreBuffered defer:NO];
            panel.opaque = NO;
            panel.backgroundColor = NSColor.clearColor;
            panel.hasShadow = NO;
            panel.ignoresMouseEvents = YES;
            panel.hidesOnDeactivate = YES;
            panel.level = SLLowerShadowWindowLevel();
            panel.collectionBehavior = NSWindowCollectionBehaviorTransient |
                NSWindowCollectionBehaviorMoveToActiveSpace | NSWindowCollectionBehaviorIgnoresCycle;
            panel.contentView = [[SLSnowLeopardMenuBarLowerShadowView alloc]
                initWithFrame:NSMakeRect(0, 0, NSWidth(frame), NSHeight(frame))];
            SLLowerShadowPanels[displayID] = panel;
            SLLog([NSString stringWithFormat:@"lower-shadow created process=%@ display=%@ height=14 clickThrough=1",
                       NSProcessInfo.processInfo.processName, displayID]);
        }
        if (!NSEqualRects(panel.frame, frame)) [panel setFrame:frame display:YES];
        if (!panel.isVisible || !panel.isOnActiveSpace) [panel orderFront:nil];
    }
    for (NSNumber *displayID in SLLowerShadowPanels.allKeys.copy) {
        if (![liveDisplays containsObject:displayID]) {
            [SLLowerShadowPanels[displayID] orderOut:nil];
            [SLLowerShadowPanels removeObjectForKey:displayID];
        }
    }
}

static void ArmMenuBarLowerShadowObservers(void) {
    static NSMutableArray *tokens;
    if (tokens) return;
    tokens = [NSMutableArray array];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[NSApplicationDidResignActiveNotification,
             NSApplicationDidHideNotification, NSApplicationWillTerminateNotification,
             NSWindowWillEnterFullScreenNotification]) {
        [tokens addObject:[center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) { HideMenuBarLowerShadows(); }]];
    }
    for (NSNotificationName name in @[NSApplicationDidChangeScreenParametersNotification,
             NSWindowDidExitFullScreenNotification]) {
        [tokens addObject:[center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) { RefreshMenuBarLowerShadows(); }]];
    }
    [tokens addObject:[NSWorkspace.sharedWorkspace.notificationCenter
        addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(__unused NSNotification *note) { RefreshMenuBarLowerShadows(); }]];
}
