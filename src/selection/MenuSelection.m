#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>
#import <stdint.h>
#import <string.h>

#import "Runtime.h"
#import "SelectionRenderer.h"

// Snow Leopard menu-selection owner.
//
// This translation unit owns selection hooks/state for:
//   - pull-down and contextual menus;
//   - Dock contextual menus.
//
// All blue pixels use the shared Snow Leopard renderer. Sidebar behavior lives
// in SidebarSelection.m.

const char SLSnowLeopardBlueSelectionMarker[] =
    "snowLeopardBlueSelection=modular-v2 "
    "compatibility=sequoia15 "
    "topMenu=unified "
    "renderer=shared-exact35 "
    "menuSurfaces=popup,context,dock";

typedef id (*InitFn)(id, SEL);
typedef void (*VoidFn)(id, SEL);
typedef void (*SetBoolFn)(id, SEL, BOOL);
typedef void (*SetHighlightedFn)(id, SEL, BOOL, id);
typedef NSRect (*SelectionFrameFn)(id, SEL, id);

static InitFn OriginalSelectionInit = NULL;
static SetHighlightedFn OriginalContextHighlight = NULL;
static SelectionFrameFn OriginalContextSelectionFrame = NULL;

static Class SelectionClass = Nil;
static Class ContextMenuClass = Nil;
static Class ContextMenuItemViewClass = Nil;

static Ivar BackingViewIvar = NULL;
static Ivar DisableAnimationsIvar = NULL;

static BOOL HooksInstalled = NO;
static NSUInteger InstallAttempts = 0;


static char SelectionFilmKey;
static char TextColourSnapshotKey;
static char CurrentHighlightedItemKey;
static char SelectionBackingKey;
static char SelectionBackingFilmKey;

@interface SLBlueSelectionFilmView : NSView
@end

@interface SLBlueWeakViewBox : NSObject
@property(nonatomic, weak) NSView *view;
@end

@interface SLBlueTextColourSnapshot : NSObject
@property(nonatomic, strong)
    NSMapTable<NSTextField *, NSColor *> *colours;
@end

@interface SLBluePendingSelection : NSObject
@property(nonatomic, strong) id selectionRect;
@property(nonatomic) NSUInteger attemptsLeft;
@end

@implementation SLBlueWeakViewBox
@end

@implementation SLBlueTextColourSnapshot
@end

@implementation SLBluePendingSelection
@end

static NSMutableArray<SLBluePendingSelection *> *PendingSelections = nil;
static dispatch_source_t PendingSelectionTimer = nil;

@implementation SLBlueSelectionFilmView

- (BOOL)isOpaque {
    return YES;
}

- (BOOL)isAccessibilityElement {
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

static void CollectTextColours(NSView *view, NSMapTable<NSTextField *, NSColor *> *colours) {
    if (!view || !colours) {
        return;
    }
    if ([view isKindOfClass:NSTextField.class]) {
        NSTextField *field = (NSTextField *)view;
        if (field.textColor) {
            [colours setObject:field.textColor forKey:field];
        }
    }
    for (NSView *subview in view.subviews) {
        CollectTextColours(subview, colours);
    }
}

static void CaptureTextColours(NSView *view) {
    if (!view || objc_getAssociatedObject(view, &TextColourSnapshotKey)) {
        return;
    }
    SLBlueTextColourSnapshot *snapshot = [SLBlueTextColourSnapshot new];
    snapshot.colours = [NSMapTable weakToStrongObjectsMapTable];
    CollectTextColours(view, snapshot.colours);
    objc_setAssociatedObject(view, &TextColourSnapshotKey, snapshot, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ForceTextWhite(NSView *view) {
    if (!view) return;
    if ([view isKindOfClass:NSTextField.class]) {
        ((NSTextField *)view).textColor = NSColor.whiteColor;
    }
    if ([view isKindOfClass:NSImageView.class]) {
        NSImageView *imageView = (NSImageView *)view;
        if (imageView.image.isTemplate) {
            imageView.contentTintColor = NSColor.whiteColor;
        }
    }
    for (NSView *subview in view.subviews) {
        ForceTextWhite(subview);
    }
}

static void RestoreTextColours(NSView *view) {
    if (!view) return;
    SLBlueTextColourSnapshot *snapshot = objc_getAssociatedObject(view, &TextColourSnapshotKey);
    for (NSTextField *field in snapshot.colours.keyEnumerator) {
        NSColor *colour = [snapshot.colours objectForKey:field];
        if (field && colour) {
            field.textColor = colour;
        }
    }
    objc_setAssociatedObject(view, &TextColourSnapshotKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static SLBlueSelectionFilmView *SelectionFilmForView(NSView *view, const void *key) {
    SLBlueSelectionFilmView *film = objc_getAssociatedObject(view, key);
    if (!film) {
        film = [[SLBlueSelectionFilmView alloc] initWithFrame:view.bounds];
        film.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        objc_setAssociatedObject(view, key, film, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    film.frame = view.bounds;
    return film;
}

static void SetSelectionFilm(NSView *view, BOOL highlighted) {
    if (!view) return;
    SLBlueSelectionFilmView *film = objc_getAssociatedObject(view, &SelectionFilmKey);
    if (!film && highlighted) film = SelectionFilmForView(view, &SelectionFilmKey);
    if (!film) return;
    film.frame = view.bounds;
    film.hidden = !highlighted;
    if (film.superview != view || view.subviews.firstObject != film) {
        [film removeFromSuperviewWithoutNeedingDisplay];
        [view addSubview:film positioned:NSWindowBelow relativeTo:nil];
    }
    if (highlighted) [film setNeedsDisplay:YES];
}

static void SetBackingSelectionFilm(NSView *backing) {
    if (!backing) return;
    SLBlueSelectionFilmView *film = SelectionFilmForView(backing, &SelectionBackingFilmKey);
    film.hidden = NO;
    if (film.superview != backing || backing.subviews.lastObject != film) {
        [film removeFromSuperviewWithoutNeedingDisplay];
        [backing addSubview:film positioned:NSWindowAbove relativeTo:nil];
    }
    [film setNeedsDisplay:YES];
}

static void ApplyHighlight(id owner, NSView *itemView, BOOL highlighted) {
    if (!owner || !itemView) {
        return;
    }
    SLBlueWeakViewBox *box = objc_getAssociatedObject(owner, &CurrentHighlightedItemKey);
    if (!box) {
        box = [SLBlueWeakViewBox new];
        objc_setAssociatedObject(owner, &CurrentHighlightedItemKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (highlighted) {
        CaptureTextColours(itemView);
        if (box.view && box.view != itemView) {
            SetSelectionFilm(box.view, NO);
            RestoreTextColours(box.view);
        }
        box.view = itemView;
        SetSelectionFilm(itemView, YES);
        ForceTextWhite(itemView);
    } else {
        SetSelectionFilm(itemView, NO);
        RestoreTextColours(itemView);
        if (box.view == itemView) {
            box.view = nil;
        }
    }
}

// ============================================================
// MENU BAR / POPUP / DOCK
// ============================================================

static void ResetSelectionLayer(CALayer *layer) {
    if (!layer) return;
    layer.cornerRadius = 0.0;
    layer.mask = nil;
    [layer removeAllAnimations];
}

static BOOL IsPopupWindow(NSWindow *window) {
    if (!window) return NO;
    NSString *name = NSStringFromClass(window.class);
    return [name isEqualToString:@"NSPopupMenuWindow"] ||
        [name isEqualToString:@"NSMenuWindowManagerWindow"];
}

static void StyleSelectionBacking(NSView *backing) {
    if (!backing) return;
    objc_setAssociatedObject(backing, &SelectionBackingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (SLIsTopMenuBarWindow(backing.window)) {
        backing.hidden = YES;
        backing.alphaValue = 0.0;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        backing.layer.opacity = 0.0;
        backing.layer.backgroundColor = NSColor.clearColor.CGColor;
        backing.layer.contents = nil;
        ResetSelectionLayer(backing.layer);
        [CATransaction commit];
        return;
    }
    if (!IsPopupWindow(backing.window)) return;
    backing.wantsLayer = YES;
    id activeObject = SLObjectIvar(backing, "_materialLayerActive");
    id inactiveObject = SLObjectIvar(backing, "_materialLayerInactive");
    CALayer *active = [activeObject isKindOfClass:CALayer.class] ? activeObject : nil;
    CALayer *inactive = [inactiveObject isKindOfClass:CALayer.class] ? inactiveObject : nil;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    backing.layer.backgroundColor = NSColor.clearColor.CGColor;
    backing.layer.contents = nil;
    backing.layer.borderWidth = 0.0;
    backing.layer.masksToBounds = NO;
    ResetSelectionLayer(backing.layer);
    ResetSelectionLayer(active);
    ResetSelectionLayer(inactive);
    active.opacity = 0.0;
    inactive.opacity = 0.0;
    active.backgroundColor = NSColor.clearColor.CGColor;
    inactive.backgroundColor = NSColor.clearColor.CGColor;
    [CATransaction commit];
    SetBackingSelectionFilm(backing);
}

static void FinishSelectionBacking(NSView *backing) {
    StyleSelectionBacking(backing);
    static const NSTimeInterval delays[] = {
        0.0,
        0.025,
        0.10,
        0.25
    };
    __weak NSView *weakBacking = backing;
    for (NSUInteger index = 0; index < sizeof(delays) / sizeof(delays[0]); index++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)( delays[index] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                StyleSelectionBacking(weakBacking);
            });
    }
}

static void StopPendingTimerIfIdle(void) {
    if (PendingSelections.count || !PendingSelectionTimer) {
        return;
    }
    dispatch_source_cancel(PendingSelectionTimer);
    PendingSelectionTimer = nil;
}

static void EnsurePendingTimer(void) {
    if (PendingSelectionTimer) {
        return;
    }
    PendingSelectionTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(PendingSelectionTimer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), 10 * NSEC_PER_MSEC, 1 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(PendingSelectionTimer, ^{
            for (NSUInteger index = PendingSelections.count; index > 0; index--) {
                SLBluePendingSelection *pending = PendingSelections[ index - 1];
                id candidate = BackingViewIvar
                        ? object_getIvar(pending.selectionRect, BackingViewIvar)
                        : nil;
                NSView *backing = [candidate isKindOfClass:NSView.class]
                        ? candidate
                        : nil;
                if (backing.window) {
                    FinishSelectionBacking(backing);
                    [PendingSelections removeObjectAtIndex:index - 1];
                } else if ( pending.attemptsLeft <= 1) {
                    [PendingSelections removeObjectAtIndex:index - 1];
                } else {
                    pending.attemptsLeft--;
                }
            }
            StopPendingTimerIfIdle();
        });
    dispatch_resume(PendingSelectionTimer);
}

static void TrackSelectionBacking(id selectionRect) {
    if (!selectionRect) return;
    void (^work)(void) = ^{
        id candidate = BackingViewIvar
                ? object_getIvar(selectionRect, BackingViewIvar)
                : nil;
        NSView *backing = [candidate isKindOfClass:NSView.class]
                ? candidate
                : nil;
        if (backing.window) {
            FinishSelectionBacking(backing);
            return;
        }
        if (!PendingSelections) {
            PendingSelections = [NSMutableArray array];
        }
        SLBluePendingSelection *pending = [SLBluePendingSelection new];
        pending.selectionRect = selectionRect;
        pending.attemptsLeft = 80;
        [PendingSelections addObject:pending];
        EnsurePendingTimer();
    };
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_async(dispatch_get_main_queue(), work);
    }
}

static void DisableSelectionAnimations(id object) {
    if (!object || !DisableAnimationsIvar) {
        return;
    }
    uint8_t *address = (uint8_t *)
            (__bridge void *)object + ivar_getOffset(DisableAnimationsIvar);
    *((BOOL *)address) = YES;
}

static id BlueSelectionInit(id object, SEL selector) {
    DisableSelectionAnimations(object);
    id result = OriginalSelectionInit(object, selector);
    DisableSelectionAnimations(result);
    TrackSelectionBacking(result);
    return result;
}

static void BlueContextHighlight(id object, SEL selector, BOOL highlighted, id menuItemView) {
    NSView *itemView = ContextMenuItemViewClass && [menuItemView isKindOfClass:ContextMenuItemViewClass]
            ? menuItemView
            : nil;
    if (highlighted) {
        CaptureTextColours(itemView);
    }
    OriginalContextHighlight(object, selector, highlighted, menuItemView);
    ApplyHighlight(object, itemView, highlighted);
}

static NSView *MenuRootForItemView(NSView *itemView) {
    NSView *candidate = itemView;
    NSView *widest = itemView;
    while (candidate) {
        if (NSWidth(candidate.bounds) > NSWidth(widest.bounds)) {
            widest = candidate;
        }
        NSString *name = NSStringFromClass(candidate.class);
        if ([name isEqualToString:@"NSRootMenuWindowBackgroundView"] ||
            [name isEqualToString:@"NSMenuWindowManagerBackgroundView"] ||
            [name isEqualToString:@"NSMenuWindowManagerMenuItemsContainerView"]) {
            return candidate;
        }
        candidate = candidate.superview;
    }
    return widest;
}

static NSRect BlueContextSelectionFrame(id object, SEL selector, id itemViewObject) {
    NSRect frame = OriginalContextSelectionFrame(object, selector, itemViewObject);
    NSView *itemView = [itemViewObject isKindOfClass:NSView.class]
            ? itemViewObject
            : nil;
    NSView *root = MenuRootForItemView(itemView);
    CGFloat left = root
            ? NSMinX(root.bounds)
            : 0.0;
    CGFloat width = root
            ? NSWidth(root.bounds)
            : 0.0;
    if (isfinite(left) && isfinite(width) && width > 0.0 && isfinite(frame.origin.y) && isfinite(frame.size.height) && frame.size.height > 0.0) {
        frame.origin.x = left;
        frame.size.width = width;
    }
    return frame;
}

static BOOL ResolveABI(void) {
    SelectionClass = NSClassFromString(@"NSMenuSelectionRect");
    ContextMenuClass = NSClassFromString(@"NSContextMenuImpl");
    ContextMenuItemViewClass = NSClassFromString(@"NSContextMenuItemView");
    if (!SelectionClass || !ContextMenuClass || !ContextMenuItemViewClass || ![ContextMenuItemViewClass isSubclassOfClass:NSView.class]) {
        return NO;
    }
    Method initMethod = SLOwnInstanceMethod(SelectionClass, @selector(init));
    Method contextMethod = SLOwnInstanceMethod(ContextMenuClass, NSSelectorFromString(@"_setHighlighted:menuItemView:"));
    Method selectionFrameMethod = SLOwnInstanceMethod(ContextMenuClass, NSSelectorFromString(@"_selectionLayerFrameForView:"));
    BackingViewIvar = class_getInstanceVariable(SelectionClass, "_backingView");
    DisableAnimationsIvar = class_getInstanceVariable(SelectionClass, "_disableAnimations");
    const char *backingType = BackingViewIvar
            ? ivar_getTypeEncoding(BackingViewIvar)
            : NULL;
    const char *disableType = DisableAnimationsIvar
            ? ivar_getTypeEncoding(DisableAnimationsIvar)
            : NULL;
    return SLMethodMatches(initMethod, "@16@0:8") &&
        SLMethodMatches(contextMethod, "v28@0:8B16@20") &&
        selectionFrameMethod != NULL &&
        backingType && backingType[0] == '@' &&
        disableType && strcmp(disableType, "B") == 0;
}

static void InstallHooks(void);

static void ScheduleHookRetry(void) {
    if (InstallAttempts++ >= 250) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        InstallHooks();
    });
}

static void InstallHooks(void) {
    if (!SLIsDockOrRegularApplicationProcess() || HooksInstalled) return;
    if (!ResolveABI()) {
        ScheduleHookRetry();
        return;
    }
    Method initMethod = SLOwnInstanceMethod(SelectionClass, @selector(init));
    Method contextMethod = SLOwnInstanceMethod(ContextMenuClass, NSSelectorFromString(@"_setHighlighted:menuItemView:"));
    Method selectionFrameMethod = SLOwnInstanceMethod(ContextMenuClass, NSSelectorFromString(@"_selectionLayerFrameForView:"));
    OriginalSelectionInit = (InitFn)method_getImplementation(initMethod);
    OriginalContextHighlight = (SetHighlightedFn)method_getImplementation(contextMethod);
    OriginalContextSelectionFrame = (SelectionFrameFn)method_getImplementation(selectionFrameMethod);
    if (!OriginalSelectionInit || !OriginalContextHighlight || !OriginalContextSelectionFrame) return;
    method_setImplementation(initMethod, (IMP)BlueSelectionInit);
    method_setImplementation(contextMethod, (IMP)BlueContextHighlight);
    method_setImplementation(selectionFrameMethod, (IMP)BlueContextSelectionFrame);
    HooksInstalled = YES;
}

__attribute__((constructor))
static void SnowLeopardMenuSelectionLoad(void) {
    if (!SLIsDockOrRegularApplicationProcess()) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        InstallHooks();
    });
}

