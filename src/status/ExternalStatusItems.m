#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>

#import "Runtime.h"
#import "Protocol.h"
#import "SelectionRenderer.h"
#import "StatusSelectionIPC.h"

const char SLSnowLeopardExternalStatusCapabilities[] =
    "snowLeopardExternalStatus=modular-v2 owner=unified";

/*
 * Snow Leopard styling for third-party NSStatusItem owners.
 *
 * This module runs inside the application that creates the status item,
 * including LSUIElement menu-bar applications. It changes the title and
 * template tint before AppKit replicates the status item into SystemUIServer.
 *
 * Non-template images are deliberately preserved, so coloured application
 * icons do not become black.
 */

typedef void (*SetStringFn)(id, SEL, NSString *);
typedef void (*SetAttributedStringFn)(
    id, SEL, NSAttributedString *);
typedef void (*SetBoolFn)(id, SEL, BOOL);
typedef void (*SetColorFn)(id, SEL, NSColor *);
typedef void (*SetImageFn)(id, SEL, NSImage *);
typedef void (*DrawRectFn)(id, SEL, NSRect);
typedef void (*DrawStatusItemBackgroundFn)(id, SEL, NSRect, BOOL);
typedef BOOL (*BoolNoArgFn)(id, SEL);
typedef float (*FloatNoArgFn)(id, SEL);

static SetStringFn OriginalSetTitle = NULL;
static SetAttributedStringFn OriginalSetAttributedTitle = NULL;
static SetBoolFn OriginalSetHighlighted = NULL;
static SetColorFn OriginalSetContentTintColor = NULL;
static SetImageFn OriginalSetImage = NULL;
static DrawRectFn OriginalDrawRect = NULL;
static DrawStatusItemBackgroundFn OriginalDrawStatusItemBackground = NULL;
static BoolNoArgFn OriginalAllowItemDragging = NULL;
static FloatNoArgFn OriginalPreferredPosition = NULL;

static Class StatusBarButtonClass = Nil;
static Class StatusItemClass = Nil;
static BOOL HooksInstalled = NO;
static BOOL InstallationCommitted = NO;
static NSUInteger InstallAttempt = 0;

static char RawAttributedTitleKey;
static char LogicalHighlightedKey;
static char ExternalSelectionUnderlayKey;
static __thread BOOL ApplyingStatusStyle = NO;

static BOOL RemoteHostedSelectionActive = NO;
static NSString *RemoteHostedWindowTitle = nil;
static NSHashTable<NSButton *> *TrackedStatusButtons = nil;
static id ExternalSelectionObserver = nil;
static NSUInteger LogicalHighlightLogCount = 0;
static NSUInteger RemoteSelectionLogCount = 0;
static NSUInteger ExternalBackgroundLogCount = 0;
static NSUInteger SpotlightWhiteRedrawLogCount = 0;
static __weak NSButton *ExternalLocalActiveButton = nil;
static NSTimeInterval ExternalLocalSelectionStartedAt = 0.0;
static id ExternalLocalMouseMonitor = nil;
static id ExternalGlobalMouseMonitor = nil;
static NSStatusItem *SpotlightRightMarginItem = nil;
static CGFloat SpotlightNativeItemLength = 0.0;

static void InstallExternalLocalSelectionMonitors(void);
static void SetExternalBlueUnderlay(NSButton *button, BOOL selected);

static BOOL IsSpotlightRightMarginButton(NSButton *button) {
    if (!button) return NO;
    if (SpotlightRightMarginItem &&
        button == SpotlightRightMarginItem.button) {
        return YES;
    }
    return [button.identifier
        isEqualToString:SL_SPOTLIGHT_RIGHT_MARGIN_ANCHOR_IDENTIFIER];
}

static BOOL IsMainSpotlightButton(NSButton *button) {
    if (!button) return NO;

    /*
     * Spotlight vive en su propio proceso. No usar window.title para
     * identificar Item-0: ese título no es estable durante todas las
     * rutas de dibujo/selección de Sequoia.
     */
    if (![NSBundle.mainBundle.bundleIdentifier
            isEqualToString:SLBundleIDSpotlight]) {
        return NO;
    }

    /*
     * Nunca considerar como Spotlight principal el antiguo ancla/spacer.
     * En la implementación actual ya no se crea, pero conservamos este
     * guard por seguridad.
     */
    if (IsSpotlightRightMarginButton(button)) {
        return NO;
    }

    return YES;
}

static BOOL IsEligibleStatusItemOwner(void) {
    // Unlike normal apps, menu-bar owners may intentionally be LSUIElement.
    return SLIsEligibleApplicationProcess(YES);
}

static BOOL LogicalStatusHighlighted(NSButton *button) {
    NSNumber *stored = objc_getAssociatedObject(
        button, &LogicalHighlightedKey);

    return stored
        ? stored.boolValue
        : button.isHighlighted;
}

static NSColor *DesiredStatusColour(NSButton *button) {
    BOOL highlighted =
        RemoteHostedSelectionActive ||
        LogicalStatusHighlighted(button);

    return highlighted
        ? NSColor.whiteColor
        : NSColor.blackColor;
}

static NSAttributedString *AttributedTitleWithColour(
    NSAttributedString *source,
    NSColor *colour
) {
    if (!source.length) return source;

    NSMutableAttributedString *result =
        [source mutableCopy];

    [result addAttribute:NSForegroundColorAttributeName
                   value:colour
                   range:NSMakeRange(0, result.length)];

    return result.copy;
}

static void SetTintDirectly(
    NSButton *button,
    NSColor *colour
) {
    if (!OriginalSetContentTintColor) return;

    NSColor *current = button.contentTintColor;
    BOOL same =
        current == colour ||
        (current && [current isEqual:colour]);

    if (!same) {
        OriginalSetContentTintColor(
            button,
            @selector(setContentTintColor:),
            colour);
    }
}

static void SetAttributedTitleDirectly(
    NSButton *button,
    NSAttributedString *source,
    NSColor *colour
) {
    if (!OriginalSetAttributedTitle || !source.length) return;

    NSAttributedString *styled =
        AttributedTitleWithColour(source, colour);

    NSAttributedString *current =
        button.attributedTitle;

    if (![current isEqualToAttributedString:styled]) {
        OriginalSetAttributedTitle(
            button,
            @selector(setAttributedTitle:),
            styled);
    }
}

@interface SLExternalBlueSelectionUnderlay : NSView
@end

@implementation SLExternalBlueSelectionUnderlay

- (BOOL)isOpaque {
    return NO;
}

- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    SLDrawSharedSnowLeopardSelection(self);
}

@end

static void SetExternalBlueUnderlay(
    NSButton *button,
    BOOL selected
) {
    if (!button ||
        IsSpotlightRightMarginButton(button)) {
        return;
    }

    NSView *contentView = button.window.contentView;
    if (!contentView) return;

    /*
     * Spotlight mide 18 pt más únicamente para dejar el margen derecho
     * de Snow Leopard. El fondo azul no debe ocupar esos 18 pt.
     */
    NSRect underlayFrame = contentView.bounds;

    if (IsMainSpotlightButton(button) &&
        SpotlightNativeItemLength > 0.0) {
        underlayFrame.size.width = MIN(
            SpotlightNativeItemLength,
            NSWidth(contentView.bounds));
    }

    SLExternalBlueSelectionUnderlay *underlay =
        objc_getAssociatedObject(
            button, &ExternalSelectionUnderlayKey);

    if (!underlay && selected) {
        underlay = [[SLExternalBlueSelectionUnderlay alloc]
            initWithFrame:underlayFrame];
        /*
         * Spotlight tiene un ancho de layout 18 pt mayor que su zona visual.
         * Su selección debe conservar ancho fijo y dejar que únicamente
         * el margen derecho absorba cualquier cambio del superview.
         */
        if (IsMainSpotlightButton(button) &&
            SpotlightNativeItemLength > 0.0) {
            underlay.autoresizingMask =
                NSViewMaxXMargin | NSViewHeightSizable;
        } else {
            underlay.autoresizingMask =
                NSViewWidthSizable | NSViewHeightSizable;
        }
        underlay.hidden = YES;
        [contentView
            addSubview:underlay
            positioned:NSWindowBelow
            relativeTo:nil];
        objc_setAssociatedObject(
            button,
            &ExternalSelectionUnderlayKey,
            underlay,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        SLLog([NSString stringWithFormat:
            @"external-status blue underlay created process=%@ "
             "window=%@ frame=%@",
            NSProcessInfo.processInfo.processName,
            button.window.title ?: @"",
            NSStringFromRect(contentView.bounds)]);
    }

    if (!underlay) return;

    underlay.frame = underlayFrame;
    underlay.hidden = !selected;
    if (selected) {
        [underlay setNeedsDisplay:YES];
        [underlay displayIfNeeded];
    }
}

static void ApplyStatusButtonStyle(NSButton *button) {
    if (!button ||
        ![button isKindOfClass:StatusBarButtonClass] ||
        IsSpotlightRightMarginButton(button)) {
        return;
    }

    if (!TrackedStatusButtons) {
        TrackedStatusButtons =
            [NSHashTable weakObjectsHashTable];
    }

    [TrackedStatusButtons addObject:button];
    InstallExternalLocalSelectionMonitors();

    if (ApplyingStatusStyle) {
        return;
    }

    ApplyingStatusStyle = YES;

    @try {
        NSColor *colour = DesiredStatusColour(button);

        /*
         * contentTintColor changes ordinary titles and template images.
         * AppKit does not tint non-template images, preserving coloured
         * third-party icons.
         */
        SetTintDirectly(button, colour);

        NSAttributedString *rawTitle =
            objc_getAssociatedObject(
                button, &RawAttributedTitleKey);

        /*
         * When the application did not explicitly assign an attributed
         * title, AppKit may still generate one internally. Use that as the
         * drawing source so plain titles also become black.
         */
        NSAttributedString *source =
            rawTitle.length
                ? rawTitle
                : button.attributedTitle;

        SetAttributedTitleDirectly(
            button, source, colour);
    }
    @finally {
        ApplyingStatusStyle = NO;
    }

    SetExternalBlueUnderlay(
        button,
        RemoteHostedSelectionActive ||
            LogicalStatusHighlighted(button));
    [button setNeedsDisplay:YES];
}

static void SnowLeopardDrawStatusItemBackground(
    id statusItem,
    SEL selector,
    NSRect rect,
    BOOL highlighted
) {
    NSButton *button = nil;
    if ([statusItem respondsToSelector:@selector(button)]) {
        button = ((id (*)(id, SEL))objc_msgSend)(
            statusItem, @selector(button));
    }

    if (statusItem == SpotlightRightMarginItem ||
        IsSpotlightRightMarginButton(button)) {
        OriginalDrawStatusItemBackground(statusItem, selector, rect, NO);
        return;
    }

    BOOL effectiveHighlighted = highlighted ||
        (button && LogicalStatusHighlighted(button)) ||
        RemoteHostedSelectionActive;

    // Suppress the modern capsule but retain AppKit's normal background path.
    OriginalDrawStatusItemBackground(statusItem, selector, rect, NO);

    if (button) {
        NSNumber *previousLogicalState = objc_getAssociatedObject(
            button, &LogicalHighlightedKey);
        objc_setAssociatedObject(
            button,
            &LogicalHighlightedKey,
            @(effectiveHighlighted),
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ApplyStatusButtonStyle(button);
        objc_setAssociatedObject(
            button,
            &LogicalHighlightedKey,
            previousLogicalState,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (ExternalBackgroundLogCount++ < 48) {
        SLLog([NSString stringWithFormat:
            @"external-status background draw process=%@ bundle=%@ "
             "highlighted=%d effective=%d rect=%@",
            NSProcessInfo.processInfo.processName,
            NSBundle.mainBundle.bundleIdentifier,
            highlighted,
            effectiveHighlighted,
            NSStringFromRect(rect)]);
    }

    if (!effectiveHighlighted || !button) return;

    /*
     * ApplyStatusButtonStyle() ya actualizó el underlay de Spotlight.
     * No llamar al renderer directamente sobre el botón porque su bounds
     * incluye los 18 pt reservados para el margen derecho.
     */
    if (IsMainSpotlightButton(button)) {
        /*
         * Spotlight tiene 18 pt extra únicamente para su posición.
         * El underlay anterior puede terminar adaptándose al ancho
         * completo de la ventana, así que para Spotlight lo apagamos
         * y dibujamos el azul directamente con clipping explícito.
         */
        SetExternalBlueUnderlay(button, NO);

        [NSGraphicsContext saveGraphicsState];
        NSRect clipRect = button.bounds;
        if (NSWidth(clipRect) > SL_SPOTLIGHT_RIGHT_MARGIN_LENGTH) {
            clipRect.size.width = NSWidth(clipRect) - SL_SPOTLIGHT_RIGHT_MARGIN_LENGTH;
        }
        [NSBezierPath clipRect:clipRect];
        SLDrawSharedSnowLeopardSelection(button);
        [NSGraphicsContext restoreGraphicsState];

        return;
    }

    SLDrawSharedSnowLeopardSelection(button);
}

static BOOL SnowLeopardAllowItemDragging(id statusItem, SEL selector) {
    if ([NSBundle.mainBundle.bundleIdentifier
            isEqualToString:SLBundleIDSpotlight]) {
        if (statusItem == SpotlightRightMarginItem) {
            return NO;
        }
        return YES;
    }
    return OriginalAllowItemDragging
        ? OriginalAllowItemDragging(statusItem, selector)
        : NO;
}

static float SnowLeopardPreferredPosition(id statusItem, SEL selector) {
    if ([NSBundle.mainBundle.bundleIdentifier
            isEqualToString:SLBundleIDSpotlight] &&
        [statusItem respondsToSelector:@selector(autosaveName)]) {
        NSString *autosaveName = ((id (*)(id, SEL))objc_msgSend)(
            statusItem, @selector(autosaveName));
        if ([autosaveName isEqualToString:@"Item-0"]) {
            return SL_SPOTLIGHT_RUNTIME_PREFERRED_POSITION;
        }
        if (statusItem == SpotlightRightMarginItem) {
            return 1.0f;
        }
    }
    return OriginalPreferredPosition
        ? OriginalPreferredPosition(statusItem, selector)
        : 0.0f;
}

static NSString *NormalizedStatusIdentifier(
    NSString *value
) {
    if (!value.length) return @"";

    NSString *lowercase =
        value.lowercaseString;

    NSMutableString *result =
        [NSMutableString string];

    NSCharacterSet *allowed =
        NSCharacterSet.alphanumericCharacterSet;

    for (NSUInteger index = 0;
         index < lowercase.length;
         index++) {
        unichar character =
            [lowercase characterAtIndex:index];

        if ([allowed characterIsMember:character]) {
            [result appendFormat:@"%C", character];
        }
    }

    return result.copy;
}

static BOOL HostedWindowTitleMatchesCurrentProcess(
    NSString *windowTitle
) {
    if ([NSBundle.mainBundle.bundleIdentifier
            isEqualToString:SLBundleIDSpotlight] &&
        [windowTitle isEqualToString:@"Item-0"]) {
        return YES;
    }

    NSString *titleToken =
        NormalizedStatusIdentifier(windowTitle);

    if (titleToken.length < 4) return NO;

    NSBundle *bundle =
        NSBundle.mainBundle;

    NSString *bundleName =
        bundle.bundlePath
            .lastPathComponent
            .stringByDeletingPathExtension;

    NSString *bundleTail =
        bundle.bundleIdentifier.pathExtension;

    NSArray<NSString *> *candidates = @[
        NSProcessInfo.processInfo.processName ?: @"",
        bundle.executablePath.lastPathComponent ?: @"",
        bundleName ?: @"",
        bundleTail ?: @""
    ];

    for (NSString *candidate in candidates) {
        NSString *token =
            NormalizedStatusIdentifier(candidate);

        if (token.length >= 4 &&
            [titleToken containsString:token]) {
            return YES;
        }
    }

    return NO;
}

static void SetExternalLocalSelection(
    NSButton *button,
    BOOL selected,
    BOOL broadcast
) {
    NSButton *previous = ExternalLocalActiveButton;
    if (previous && (!selected || previous != button)) {
        objc_setAssociatedObject(
            previous, &LogicalHighlightedKey, @NO,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        OriginalSetHighlighted(
            previous, @selector(setHighlighted:), NO);
        ApplyStatusButtonStyle(previous);
        [previous setNeedsDisplay:YES];
        if (broadcast) SLPostExternalStatusSelection(previous, NO);
    }

    if (!selected || !button) {
        ExternalLocalActiveButton = nil;
        ExternalLocalSelectionStartedAt = 0.0;
        return;
    }

    ExternalLocalActiveButton = button;
    ExternalLocalSelectionStartedAt =
        NSDate.timeIntervalSinceReferenceDate;
    objc_setAssociatedObject(
        button, &LogicalHighlightedKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    OriginalSetHighlighted(button, @selector(setHighlighted:), NO);
    ApplyStatusButtonStyle(button);
    [button setNeedsDisplay:YES];
    [button displayIfNeeded];
    if (broadcast) SLPostExternalStatusSelection(button, YES);

    SLLog([NSString stringWithFormat:
        @"external-status local-selection selected=1 process=%@ "
         "window=%@ frame=%@",
        NSProcessInfo.processInfo.processName,
        button.window.title ?: @"",
        NSStringFromRect(button.window.frame)]);
}

static NSButton *ExternalStatusButtonAtScreenPoint(NSPoint point) {
    Class statusWindowClass = NSClassFromString(@"NSStatusBarWindow");
    for (NSWindow *window in NSApp.windows.reverseObjectEnumerator) {
        if (!statusWindowClass ||
            ![window isKindOfClass:statusWindowClass] ||
            !window.visible ||
            !NSPointInRect(
                point,
                NSInsetRect(window.frame, 0.0, -1.0)) ||
            ![window respondsToSelector:NSSelectorFromString(@"statusItem")]) {
            continue;
        }
        id item = ((id (*)(id, SEL))objc_msgSend)(
            window, NSSelectorFromString(@"statusItem"));
        if (item == SpotlightRightMarginItem) {
            continue;
        }
        if (![item respondsToSelector:@selector(button)]) continue;
        id button = ((id (*)(id, SEL))objc_msgSend)(
            item, @selector(button));
        if ([button isKindOfClass:StatusBarButtonClass]) {
            return button;
        }
    }
    return nil;
}

static void HandleExternalLocalMousePoint(NSPoint point) {
    NSButton *candidate = ExternalStatusButtonAtScreenPoint(point);
    NSButton *active = ExternalLocalActiveButton;
    NSTimeInterval elapsed = active
        ? NSDate.timeIntervalSinceReferenceDate -
            ExternalLocalSelectionStartedAt
        : 0.0;

    if (candidate) {
        if (candidate == active) {
            if (elapsed >= 0.35) {
                SetExternalLocalSelection(nil, NO, YES);
            }
            return;
        }
        SetExternalLocalSelection(candidate, YES, YES);
        return;
    }

    if (active && elapsed >= 0.12) {
        SetExternalLocalSelection(nil, NO, YES);
    }
}

static void InstallExternalLocalSelectionMonitors(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            InstallExternalLocalSelectionMonitors();
        });
        return;
    }
    NSEventMask mask = NSEventMaskLeftMouseDown |
        NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown;
    if (!ExternalLocalMouseMonitor) {
        ExternalLocalMouseMonitor = [NSEvent
            addLocalMonitorForEventsMatchingMask:mask
            handler:^NSEvent *(NSEvent *event) {
                HandleExternalLocalMousePoint(NSEvent.mouseLocation);
                return event;
            }];
    }
    if (!ExternalGlobalMouseMonitor) {
        ExternalGlobalMouseMonitor = [NSEvent
            addGlobalMonitorForEventsMatchingMask:mask
            handler:^(NSEvent *event) {
                (void)event;
                NSPoint point = NSEvent.mouseLocation;
                dispatch_async(dispatch_get_main_queue(), ^{
                    HandleExternalLocalMousePoint(point);
                });
            }];
    }
}

static void ApplyRemoteSelectionToTrackedButtons(void) {
    for (NSButton *button
         in TrackedStatusButtons.allObjects) {
        if (![button
                isKindOfClass:
                    StatusBarButtonClass] ||
            IsSpotlightRightMarginButton(button)) {
            continue;
        }

        /*
         * El estado lógico se conserva aparte. AppKit siempre
         * recibe NO para no exportar la cápsula moderna.
         */
        OriginalSetHighlighted(
            button,
            @selector(setHighlighted:),
            NO);

        ApplyStatusButtonStyle(button);
    }
}

static void HandleExternalSelectionNotification(
    NSNotification *notification
) {
    NSDictionary *userInfo =
        notification.userInfo;

    BOOL selected =
        [userInfo[@"selected"] boolValue];

    pid_t sourcePID =
        (pid_t)[userInfo[@"sourcePID"] intValue];

    NSString *windowTitle =
        [userInfo[@"windowTitle"]
            isKindOfClass:NSString.class]
        ? userInfo[@"windowTitle"]
        : @"";

    if (sourcePID > 0 && sourcePID != getpid()) {
        if (selected) {
            SetExternalLocalSelection(nil, NO, NO);
            if (RemoteHostedSelectionActive) {
                RemoteHostedSelectionActive = NO;
                RemoteHostedWindowTitle = nil;
                ApplyRemoteSelectionToTrackedButtons();
            }
        }
        return;
    }

    if (selected) {
        if (sourcePID != getpid() &&
            !HostedWindowTitleMatchesCurrentProcess(windowTitle)) {
            return;
        }

        RemoteHostedSelectionActive =
            YES;

        RemoteHostedWindowTitle =
            windowTitle.copy;
    } else {
        if (!RemoteHostedSelectionActive) {
            return;
        }

        if (windowTitle.length &&
            RemoteHostedWindowTitle.length &&
            ![windowTitle
                isEqualToString:
                    RemoteHostedWindowTitle]) {
            return;
        }

        RemoteHostedSelectionActive =
            NO;

        RemoteHostedWindowTitle =
            nil;
    }

    ApplyRemoteSelectionToTrackedButtons();

    if (RemoteSelectionLogCount++ < 64) {
        SLLog([NSString stringWithFormat:
            @"external-status remote-selection "
             "process=%@ bundle=%@ selected=%d "
             "windowTitle=%@ buttons=%lu",
            NSProcessInfo.processInfo.processName,
            NSBundle.mainBundle.bundleIdentifier,
            selected,
            windowTitle,
            (unsigned long)
                TrackedStatusButtons.allObjects.count]);
    }
}

static void InstallExternalSelectionObserver(void) {
    if (ExternalSelectionObserver) return;

    ExternalSelectionObserver =
        [NSDistributedNotificationCenter.defaultCenter
            addObserverForName:
                SLExternalStatusSelectionNotificationName
            object:nil
            queue:NSOperationQueue.mainQueue
            usingBlock:^(
                NSNotification *notification
            ) {
                HandleExternalSelectionNotification(
                    notification);
            }];

    SLLog([NSString stringWithFormat:
        @"external-status selection observer "
         "process=%@ bundle=%@",
        NSProcessInfo.processInfo.processName,
        NSBundle.mainBundle.bundleIdentifier]);
}

static void SnowLeopardSetTitle(
    id object,
    SEL selector,
    NSString *title
) {
    OriginalSetTitle(object, selector, title);

    objc_setAssociatedObject(
        object,
        &RawAttributedTitleKey,
        nil,
        OBJC_ASSOCIATION_ASSIGN);

    ApplyStatusButtonStyle((NSButton *)object);
}

static void SnowLeopardSetAttributedTitle(
    id object,
    SEL selector,
    NSAttributedString *title
) {
    NSButton *button = (NSButton *)object;

    if (ApplyingStatusStyle) {
        OriginalSetAttributedTitle(
            object, selector, title);
        return;
    }

    objc_setAssociatedObject(
        button,
        &RawAttributedTitleKey,
        title.length ? title.copy : nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSColor *colour =
        DesiredStatusColour(button);

    NSAttributedString *styled =
        AttributedTitleWithColour(title, colour);

    OriginalSetAttributedTitle(
        object, selector, styled);

    SetTintDirectly(button, colour);
}

static void SnowLeopardSetHighlighted(
    id object,
    SEL selector,
    BOOL highlighted
) {
    NSButton *button =
        (NSButton *)object;

    if (IsSpotlightRightMarginButton(button)) {
        OriginalSetHighlighted(object, selector, NO);
        return;
    }

    objc_setAssociatedObject(
        button,
        &LogicalHighlightedKey,
        @(highlighted),
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    /*
     * La selección lógica sigue controlando el texto, pero
     * AppKit recibe NO para impedir la cápsula nativa remota.
     */
    OriginalSetHighlighted(
        object,
        selector,
        NO);

    ApplyStatusButtonStyle(button);

    if (LogicalHighlightLogCount++ < 64) {
        SLLog([NSString stringWithFormat:
            @"external-status logical-highlight "
             "process=%@ bundle=%@ requested=%d "
             "native=%d remote=%d title=%@ "
             "template=%d",
            NSProcessInfo.processInfo.processName,
            NSBundle.mainBundle.bundleIdentifier,
            highlighted,
            button.isHighlighted,
            RemoteHostedSelectionActive,
            button.title ?: @"",
            button.image.isTemplate]);
    }
}

static void SnowLeopardSetContentTintColor(
    id object,
    SEL selector,
    NSColor *requestedColour
) {
    if (ApplyingStatusStyle) {
        OriginalSetContentTintColor(
            object, selector, requestedColour);
        return;
    }

    NSButton *button = (NSButton *)object;
    if (IsSpotlightRightMarginButton(button)) {
        OriginalSetContentTintColor(
            object, selector, requestedColour);
        return;
    }
    NSColor *desired =
        DesiredStatusColour(button);

    OriginalSetContentTintColor(
        object, selector, desired);
}

static void SnowLeopardSetImage(
    id object,
    SEL selector,
    NSImage *image
) {
    OriginalSetImage(object, selector, image);

    if (IsSpotlightRightMarginButton((NSButton *)object)) {
        return;
    }

    /*
     * The image itself is not changed or marked as template. Reapplying the
     * tint affects only template images and the accompanying title.
     */
    ApplyStatusButtonStyle((NSButton *)object);
}

static NSImage *SpotlightSelectedWhiteImage(NSButton *button) {
    if (![NSBundle.mainBundle.bundleIdentifier
            isEqualToString:SLBundleIDSpotlight] ||
        ![button.window.title isEqualToString:@"Item-0"] ||
        !button.image) {
        return nil;
    }

    NSImage *source = button.image;
    NSSize size = source.size;
    if (size.width <= 0.0 || size.height <= 0.0) return nil;

    // This exact Apple Spotlight item is monochrome even when another theme
    // supplies a non-template replacement. Cache one source/result per button.
    static char whiteImageCacheKey;
    NSArray *cached = objc_getAssociatedObject(button, &whiteImageCacheKey);
    if (cached.count == 2 && cached[0] == source) return cached[1];
    NSImage *whiteImage = [[NSImage alloc] initWithSize:size];
    [whiteImage lockFocus];
    NSRect localRect = NSMakeRect(0.0, 0.0, size.width, size.height);
    [source drawInRect:localRect
              fromRect:NSZeroRect
             operation:NSCompositingOperationSourceOver
              fraction:1.0
        respectFlipped:NO
                 hints:nil];
    [NSColor.whiteColor setFill];
    NSRectFillUsingOperation(
        localRect, NSCompositingOperationSourceAtop);
    [whiteImage unlockFocus];
    whiteImage.template = NO;
    objc_setAssociatedObject(button, &whiteImageCacheKey, @[source, whiteImage],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (SpotlightWhiteRedrawLogCount++ < 24) {
        SLLog(
            @"spotlight selected icon white single-pass active template-only");
    }
    return whiteImage;
}

static void SnowLeopardStatusDrawRect(
    id object,
    SEL selector,
    NSRect dirtyRect
) {
    NSButton *button = (NSButton *)object;
    if (IsSpotlightRightMarginButton(button)) {
        OriginalDrawRect(object, selector, dirtyRect);
        return;
    }
    ApplyStatusButtonStyle(button);
    BOOL selected = RemoteHostedSelectionActive ||
        LogicalStatusHighlighted(button);
    NSButtonCell *cell = (NSButtonCell *)button.cell;
    NSImage *originalCellImage = nil;
    NSImage *whiteImage = selected
        ? SpotlightSelectedWhiteImage(button)
        : nil;
    if (whiteImage && cell) {
        originalCellImage = cell.image;
        cell.image = whiteImage;
    }
    @try {
        if (IsMainSpotlightButton(button) &&
            SpotlightNativeItemLength > 0.0 &&
            cell) {

            /*
             * El item completo mide 18 pt más, pero el icono se dibuja
             * solamente dentro de su ancho original. Los 18 pt adicionales
             * quedan exclusivamente a la derecha del icono.
             */
            NSRect contentFrame = button.bounds;

            contentFrame.size.width = MIN(
                SpotlightNativeItemLength,
                NSWidth(button.bounds));

            /*
             * Snow Leopard muestra Spotlight visualmente más grande.
             * Cambiar sólo el tamaño de dibujo, no el layout del item.
             */
            NSImage *spotlightDrawImage = cell.image;
            NSSize spotlightSavedSize =
                spotlightDrawImage ? spotlightDrawImage.size : NSZeroSize;

            if (spotlightDrawImage &&
                spotlightSavedSize.width > 0.0 &&
                spotlightSavedSize.height > 0.0) {

                spotlightDrawImage.size = NSMakeSize(
                    spotlightSavedSize.width * 1.15,
                    spotlightSavedSize.height * 1.15);
            }

            [cell drawWithFrame:contentFrame
                         inView:button];

            if (spotlightDrawImage &&
                spotlightSavedSize.width > 0.0 &&
                spotlightSavedSize.height > 0.0) {

                spotlightDrawImage.size =
                    spotlightSavedSize;
            }

        } else {
            OriginalDrawRect(object, selector, dirtyRect);
        }

    } @finally {
        if (whiteImage && cell) {
            cell.image = originalCellImage;
        }
    }
}

static BOOL PreflightStatusButtonMethods(void) {
    if (!StatusBarButtonClass || !StatusItemClass) return NO;

    return
        class_getInstanceMethod(
            StatusBarButtonClass,
            @selector(setTitle:)) &&
        class_getInstanceMethod(
            StatusBarButtonClass,
            @selector(setAttributedTitle:)) &&
        class_getInstanceMethod(
            StatusBarButtonClass,
            @selector(setHighlighted:)) &&
        class_getInstanceMethod(
            StatusBarButtonClass,
            @selector(setContentTintColor:)) &&
        class_getInstanceMethod(
            StatusBarButtonClass,
            @selector(setImage:)) &&
        class_getInstanceMethod(
            StatusBarButtonClass,
            @selector(drawRect:)) &&
        class_getInstanceMethod(
            StatusItemClass,
            @selector(drawStatusBarBackgroundInRect:withHighlight:)) &&
        class_getInstanceMethod(
            StatusItemClass,
            NSSelectorFromString(@"_allowItemDragging")) &&
        class_getInstanceMethod(
            StatusItemClass,
            NSSelectorFromString(@"_preferredPosition"));
}

static void InstallStatusButtonHooks(void);

static void RefreshSpotlightOrderingState(NSString *reason) {
    if (![NSBundle.mainBundle.bundleIdentifier
            isEqualToString:SLBundleIDSpotlight]) {
        return;
    }

    Class statusWindowClass = NSClassFromString(@"NSStatusBarWindow");
    for (NSWindow *window in NSApp.windows.copy) {
        if (!statusWindowClass ||
            ![window isKindOfClass:statusWindowClass] ||
            ![window respondsToSelector:NSSelectorFromString(@"statusItem")]) {
            continue;
        }
        id item = ((id (*)(id, SEL))objc_msgSend)(
            window, NSSelectorFromString(@"statusItem"));
        if (!item || ![item respondsToSelector:@selector(autosaveName)]) {
            continue;
        }
        NSString *autosaveName = ((id (*)(id, SEL))objc_msgSend)(
            item, @selector(autosaveName));
        if (![autosaveName isEqualToString:@"Item-0"]) continue;

        /*
         * Snow Leopard deja un pequeño espacio vacío a la DERECHA de
         * Spotlight. En vez de crear otro NSStatusItem, ampliamos Item-0.
         */
        if (SpotlightNativeItemLength <= 0.0) {
            CGFloat nativeLength = ((NSStatusItem *)item).length;

            if (nativeLength <= 0.0) {
                nativeLength = NSWidth(window.frame);
            }

            if (nativeLength > 0.0) {
                SpotlightNativeItemLength = nativeLength;
            }
        }

        if (SpotlightNativeItemLength > 0.0) {
            CGFloat desiredLength =
                SpotlightNativeItemLength + SL_SPOTLIGHT_RIGHT_MARGIN_LENGTH;

            if (((NSStatusItem *)item).length != desiredLength) {
                ((NSStatusItem *)item).length = desiredLength;
            }
        }

        SEL updateFlags = NSSelectorFromString(@"_updateItemFlags");
        SEL updateReplicants = NSSelectorFromString(@"_updateReplicants");
        SEL move = NSSelectorFromString(
            @"_moveToScreenContainingActiveMenuBar");
        // Do not reload the old persisted position here. The hook below is
        // the sole runtime ordering source and updateFlags publishes it.
        if ([item respondsToSelector:updateFlags]) {
            ((void (*)(id, SEL))objc_msgSend)(item, updateFlags);
        }
        if ([item respondsToSelector:updateReplicants]) {
            ((void (*)(id, SEL))objc_msgSend)(item, updateReplicants);
        }
        if ([item respondsToSelector:move]) {
            (void)((id (*)(id, SEL))objc_msgSend)(item, move);
        }
        SLLog([NSString stringWithFormat:
            @"spotlight ordering state refreshed preferred=%.0f "
             "drag=enabled reason=%@ frame=%@",
            SL_SPOTLIGHT_RUNTIME_PREFERRED_POSITION, reason ?: @"unknown",
            NSStringFromRect(window.frame)]);
        break;
    }
}

static void ScheduleSpotlightOrderingRefresh(void) {
    RefreshSpotlightOrderingState(@"install");
    NSArray<NSNumber *> *delays = @[@0.05, @0.30, @1.00];
    for (NSNumber *delay in delays) {
        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                RefreshSpotlightOrderingState(
                    [NSString stringWithFormat:@"%@s", delay]);
            });
    }
}

static void InstallSpotlightRightMarginSpacer(void) {
    if (![NSBundle.mainBundle.bundleIdentifier
            isEqualToString:SLBundleIDSpotlight]) {
        return;
    }

    /*
     * No crear un segundo NSStatusItem.
     * El margen derecho ahora forma parte del propio Item-0.
     */
    SLLog([NSString stringWithFormat:
        @"spotlight right margin integrated into Item-0 width=%.0f",
        SL_SPOTLIGHT_RIGHT_MARGIN_LENGTH]);
}

static void RetryInstallation(void) {
    if (HooksInstalled || InstallationCommitted) return;

    if (InstallAttempt++ >= 60) {
        SLLog([NSString stringWithFormat:
            @"external-status install aborted process=%@ "
             "bundle=%@ pid=%d",
            NSProcessInfo.processInfo.processName,
            NSBundle.mainBundle.bundleIdentifier,
            getpid()]);
        return;
    }

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            100 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
            InstallStatusButtonHooks();
        });
}

static void InstallStatusButtonHooks(void) {
    if (HooksInstalled ||
        InstallationCommitted ||
        !IsEligibleStatusItemOwner()) {
        return;
    }

    StatusBarButtonClass =
        NSClassFromString(@"NSStatusBarButton");
    StatusItemClass =
        NSClassFromString(@"NSStatusItem");

    if (!PreflightStatusButtonMethods()) {
        RetryInstallation();
        return;
    }

    /*
     * Capture the complete implementation chain before creating any subclass
     * override. This allows coexistence with hooks installed earlier.
     */
    OriginalSetTitle =
        (SetStringFn)SLResolvedImplementation(
            StatusBarButtonClass,
            @selector(setTitle:));

    OriginalSetAttributedTitle =
        (SetAttributedStringFn)SLResolvedImplementation(
            StatusBarButtonClass,
            @selector(setAttributedTitle:));

    OriginalSetHighlighted =
        (SetBoolFn)SLResolvedImplementation(
            StatusBarButtonClass,
            @selector(setHighlighted:));

    OriginalSetContentTintColor =
        (SetColorFn)SLResolvedImplementation(
            StatusBarButtonClass,
            @selector(setContentTintColor:));

    OriginalSetImage =
        (SetImageFn)SLResolvedImplementation(
            StatusBarButtonClass,
            @selector(setImage:));

    OriginalDrawRect =
        (DrawRectFn)SLResolvedImplementation(
            StatusBarButtonClass,
            @selector(drawRect:));

    OriginalDrawStatusItemBackground =
        (DrawStatusItemBackgroundFn)SLResolvedImplementation(
            StatusItemClass,
            @selector(drawStatusBarBackgroundInRect:withHighlight:));

    OriginalAllowItemDragging =
        (BoolNoArgFn)SLResolvedImplementation(
            StatusItemClass,
            NSSelectorFromString(@"_allowItemDragging"));

    OriginalPreferredPosition =
        (FloatNoArgFn)SLResolvedImplementation(
            StatusItemClass,
            NSSelectorFromString(@"_preferredPosition"));

    if (!OriginalSetTitle ||
        !OriginalSetAttributedTitle ||
        !OriginalSetHighlighted ||
        !OriginalSetContentTintColor ||
        !OriginalSetImage ||
        !OriginalDrawRect ||
        !OriginalDrawStatusItemBackground ||
        !OriginalAllowItemDragging ||
        !OriginalPreferredPosition) {
        RetryInstallation();
        return;
    }

    InstallationCommitted = YES;

    BOOL installed =
        SLInstallOverrideHook(StatusBarButtonClass, @selector(setTitle:), NULL,
            (IMP)SnowLeopardSetTitle, NULL) &&
        SLInstallOverrideHook(StatusBarButtonClass, @selector(setAttributedTitle:), NULL,
            (IMP)SnowLeopardSetAttributedTitle, NULL) &&
        SLInstallOverrideHook(StatusBarButtonClass, @selector(setHighlighted:), NULL,
            (IMP)SnowLeopardSetHighlighted, NULL) &&
        SLInstallOverrideHook(StatusBarButtonClass, @selector(setContentTintColor:), NULL,
            (IMP)SnowLeopardSetContentTintColor, NULL) &&
        SLInstallOverrideHook(StatusBarButtonClass, @selector(setImage:), NULL,
            (IMP)SnowLeopardSetImage, NULL) &&
        SLInstallOverrideHook(StatusBarButtonClass, @selector(drawRect:), NULL,
            (IMP)SnowLeopardStatusDrawRect, NULL) &&
        SLInstallOverrideHook(StatusItemClass, @selector(drawStatusBarBackgroundInRect:withHighlight:), NULL,
            (IMP)SnowLeopardDrawStatusItemBackground, NULL) &&
        SLInstallOverrideHook(StatusItemClass, NSSelectorFromString(@"_allowItemDragging"), NULL,
            (IMP)SnowLeopardAllowItemDragging, NULL) &&
        SLInstallOverrideHook(StatusItemClass, NSSelectorFromString(@"_preferredPosition"), NULL,
            (IMP)SnowLeopardPreferredPosition, NULL);

    if (!installed) {
        SLLog([NSString stringWithFormat:
            @"external-status partial installation process=%@ "
             "bundle=%@ pid=%d",
            NSProcessInfo.processInfo.processName,
            NSBundle.mainBundle.bundleIdentifier,
            getpid()]);
        return;
    }

    HooksInstalled = YES;

    InstallExternalSelectionObserver();
    InstallSpotlightRightMarginSpacer();
    ScheduleSpotlightOrderingRefresh();

    SLLog([NSString stringWithFormat:
        @"external-status installed process=%@ bundle=%@ pid=%d",
        NSProcessInfo.processInfo.processName,
        NSBundle.mainBundle.bundleIdentifier,
        getpid()]);
    SLLog([NSString stringWithFormat:
        @"external-status blue background active process=%@ bundle=%@",
        NSProcessInfo.processInfo.processName,
        NSBundle.mainBundle.bundleIdentifier]);
    SLLog([NSString stringWithFormat:
        @"spotlight layout override preferred=%.0f drag=enabled "
         "margin=%.0f integrated",
        SL_SPOTLIGHT_RUNTIME_PREFERRED_POSITION, SL_SPOTLIGHT_RIGHT_MARGIN_LENGTH]);
}

__attribute__((constructor))
static void SnowLeopardExternalStatusItemsLoad(void) {
    if (!SLRuntimeIsMacOSSequoia()) return;
    if (!IsEligibleStatusItemOwner()) return;

    dispatch_async(
        dispatch_get_main_queue(), ^{
            InstallStatusButtonHooks();
        });
}
