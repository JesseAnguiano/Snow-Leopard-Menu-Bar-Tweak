#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>
#import <stdint.h>
#import <string.h>

#import "Runtime.h"
#import "SelectionRenderer.h"

// Snow Leopard menu selection.
//
// AppKit keeps ownership of tracking. The tweak only owns the blue selection
// pixels and the presentation of the two private text fields used by
// NSContextMenuItemView on Sequoia: _titleTextField and
// _keyEquivalentTextField. While a submenu is open, the parent row gets a
// visual-only latch. The Snow Leopard submenu arrow is installed during the
// item's initial layout/draw as well as highlight changes, so it is visible
// before the pointer ever enters the row.

const char SLSnowLeopardBlueSelectionMarker[] SL_CAPABILITY_EXPORT =
    "snowLeopardBlueSelection=modular-v2 "
    "compatibility=sequoia15 "
    "topMenu=unified "
    "renderer=shared-exact35 "
    "menuSurfaces=popup,context,dock "
    "submenuParentText=direct-textfield-v1 "
    "submenuArrow=native-field-snowleopard-v2-initial "
    "menuText=appkit-fields";

typedef id (*InitFn)(id, SEL);
typedef void (*SetBoolFn)(id, SEL, BOOL);
typedef void (*SetHighlightedFn)(id, SEL, BOOL, id);
typedef void (*HighlightMenuItemViewFn)(id, SEL, id, BOOL);
typedef NSRect (*SelectionFrameFn)(id, SEL, id);
typedef void (*DrawRectFn)(id, SEL, NSRect);
typedef void (*VoidMethodFn)(id, SEL);

static InitFn OriginalSelectionInit = NULL;
static SetBoolFn OriginalMenuItemViewSetHighlighted = NULL;
static SetHighlightedFn OriginalContextHighlight = NULL;
static HighlightMenuItemViewFn OriginalCocoaHighlightMenuItemView = NULL;
static SelectionFrameFn OriginalContextSelectionFrame = NULL;
static DrawRectFn OriginalContextItemDrawRect = NULL;
static VoidMethodFn OriginalContextItemLayout = NULL;

static Class SelectionClass = Nil;
static Class MenuItemViewClass = Nil;
static Class CocoaMenuClass = Nil;
static Class ContextMenuClass = Nil;
static Class ContextMenuItemViewClass = Nil;

static Ivar BackingViewIvar = NULL;
static Ivar DisableAnimationsIvar = NULL;
static Ivar MenuItemIvar = NULL;
static Ivar TitleTextFieldIvar = NULL;
static Ivar KeyEquivalentTextFieldIvar = NULL;
static SEL MenuItemSelector = NULL;
static SEL IsHighlightedSelector = NULL;

static BOOL HooksInstalled = NO;
static NSUInteger InstallAttempts = 0;

static BOOL IsPopupWindow(NSWindow *window);
static NSMenuItem *MenuItemForContextItemView(NSView *itemView);

static char SelectionFilmKey;
static char CurrentHighlightedItemKey;
static char LatchedSubmenuParentKey;
static char SelectionBackingKey;
static char SelectionBackingFilmKey;

@interface SLBlueSelectionFilmView : NSView
@end

@interface SLBlueWeakViewBox : NSObject
@property(nonatomic, weak) NSView *view;
@end


@interface SLBluePendingSelection : NSObject
@property(nonatomic, strong) id selectionRect;
@property(nonatomic) NSUInteger attemptsLeft;
@end

@implementation SLBlueWeakViewBox
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



static SLBlueSelectionFilmView *SelectionFilmForView(NSView *view,
    const void *key) {
    SLBlueSelectionFilmView *film = objc_getAssociatedObject(view, key);
    if (!film) {
        film = [[SLBlueSelectionFilmView alloc] initWithFrame:view.bounds];
        film.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        objc_setAssociatedObject(view, key, film,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    film.frame = view.bounds;
    return film;
}

static void SetSelectionFilm(NSView *view, BOOL highlighted) {
    if (!view) return;
    SLBlueSelectionFilmView *film = objc_getAssociatedObject(
        view, &SelectionFilmKey);
    if (!film && highlighted) {
        film = SelectionFilmForView(view, &SelectionFilmKey);
    }
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
    SLBlueSelectionFilmView *film = SelectionFilmForView(
        backing, &SelectionBackingFilmKey);
    film.hidden = NO;
    if (film.superview != backing || backing.subviews.lastObject != film) {
        [film removeFromSuperviewWithoutNeedingDisplay];
        [backing addSubview:film positioned:NSWindowAbove relativeTo:nil];
    }
    [film setNeedsDisplay:YES];
}

static SLBlueWeakViewBox *WeakViewBox(id owner, const void *key, BOOL create) {
    if (!owner) return nil;
    SLBlueWeakViewBox *box = objc_getAssociatedObject(owner, key);
    if (!box && create) {
        box = [SLBlueWeakViewBox new];
        objc_setAssociatedObject(owner, key, box,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return box;
}

static NSMenuItem *MenuItemForContextItemView(NSView *itemView) {
    if (!itemView) return nil;

    if (MenuItemIvar) {
        id value = object_getIvar(itemView, MenuItemIvar);
        if ([value isKindOfClass:NSMenuItem.class]) return value;
    }

    if (MenuItemSelector && [itemView respondsToSelector:MenuItemSelector]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(itemView,
            MenuItemSelector);
        if ([value isKindOfClass:NSMenuItem.class]) return value;
    }

    id fallback = SLObjectIvar(itemView, "_item");
    return [fallback isKindOfClass:NSMenuItem.class] ? fallback : nil;
}

static id PopupSelectionOwner(NSView *itemView, id fallback) {
    return itemView.window ?: fallback;
}


static NSTextField *TitleFieldForItemView(NSView *itemView) {
    if (!itemView || !TitleTextFieldIvar) return nil;
    id value = object_getIvar(itemView, TitleTextFieldIvar);
    return [value isKindOfClass:NSTextField.class] ? value : nil;
}

static NSTextField *ArrowFieldForItemView(NSView *itemView) {
    if (!itemView || !KeyEquivalentTextFieldIvar) return nil;
    id value = object_getIvar(itemView, KeyEquivalentTextFieldIvar);
    return [value isKindOfClass:NSTextField.class] ? value : nil;
}

static NSImage *SnowLeopardArrowImage(BOOL highlighted, BOOL enabled,
    BOOL rtl) {
    static NSImage *images[2][3] = {{ nil }};
    NSUInteger state = !enabled ? 2 : (highlighted ? 1 : 0);
    NSUInteger direction = rtl ? 1 : 0;
    NSImage *cached = images[direction][state];
    if (cached) return cached;

    NSColor *color = !enabled
        ? [NSColor colorWithCalibratedWhite:0.62 alpha:1.0]
        : (highlighted ? NSColor.whiteColor
            : [NSColor colorWithCalibratedWhite:0.16 alpha:1.0]);

    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(7.0, 10.0)];
    [image lockFocus];
    NSBezierPath *arrow = [NSBezierPath bezierPath];
    if (rtl) {
        [arrow moveToPoint:NSMakePoint(6.75, 0.0)];
        [arrow lineToPoint:NSMakePoint(0.25, 5.0)];
        [arrow lineToPoint:NSMakePoint(6.75, 10.0)];
    } else {
        [arrow moveToPoint:NSMakePoint(0.25, 0.0)];
        [arrow lineToPoint:NSMakePoint(6.75, 5.0)];
        [arrow lineToPoint:NSMakePoint(0.25, 10.0)];
    }
    [arrow closePath];
    [color setFill];
    [arrow fill];
    [image unlockFocus];
    image.template = NO;
    images[direction][state] = image;
    return image;
}

static void ReplaceNativeSubmenuArrow(NSTextField *field, BOOL highlighted,
    BOOL enabled, BOOL rtl) {
    if (!field) return;

    NSImage *image = SnowLeopardArrowImage(highlighted, enabled, rtl);
    NSAttributedString *oldValue = field.attributedStringValue;
    if (oldValue.length == 1) {
        id oldAttachment = [oldValue attribute:NSAttachmentAttributeName
            atIndex:0 effectiveRange:NULL];
        if ([oldAttachment isKindOfClass:NSTextAttachment.class] &&
            ((NSTextAttachment *)oldAttachment).image == image &&
            field.alignment == NSTextAlignmentCenter) {
            return;
        }
    }

    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image = image;

    NSDictionary<NSAttributedStringKey, id> *oldAttributes = nil;
    if (oldValue.length) {
        oldAttributes = [oldValue attributesAtIndex:0 effectiveRange:NULL];
    }
    NSMutableDictionary<NSAttributedStringKey, id> *attributes =
        oldAttributes ? [oldAttributes mutableCopy] : [NSMutableDictionary dictionary];
    attributes[NSAttachmentAttributeName] = attachment;

    NSAttributedString *replacement = [[NSAttributedString alloc]
        initWithString:@"\uFFFC" attributes:attributes];
    field.attributedStringValue = replacement;
    field.alignment = NSTextAlignmentCenter;
}

static void ApplyContextItemTextAndArrow(NSView *itemView,
    BOOL visuallyHighlighted) {
    NSMenuItem *item = MenuItemForContextItemView(itemView);
    if (!item) return;

    NSColor *textColor = !item.enabled
        ? NSColor.disabledControlTextColor
        : (visuallyHighlighted ? NSColor.selectedMenuItemTextColor
            : NSColor.labelColor);

    NSTextField *titleField = TitleFieldForItemView(itemView);
    if (titleField) titleField.textColor = textColor;

    if (item.submenu) {
        NSTextField *arrowField = ArrowFieldForItemView(itemView);
        if (arrowField) {
            arrowField.textColor = textColor;
            BOOL rtl = itemView.userInterfaceLayoutDirection ==
                NSUserInterfaceLayoutDirectionRightToLeft;
            ReplaceNativeSubmenuArrow(arrowField, visuallyHighlighted,
                item.enabled, rtl);
        }
    }
}

static BOOL IsLatchedSubmenuParent(NSView *itemView) {
    if (!itemView) return NO;
    id owner = PopupSelectionOwner(itemView, nil);
    SLBlueWeakViewBox *latched = WeakViewBox(
        owner, &LatchedSubmenuParentKey, NO);
    return latched.view == itemView;
}

static BOOL NativeHighlightForContextItemView(NSView *itemView) {
    if (!itemView || !IsHighlightedSelector ||
        ![itemView respondsToSelector:IsHighlightedSelector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(itemView,
        IsHighlightedSelector);
}

static void RefreshContextItemPresentation(NSView *itemView) {
    if (!itemView) return;
    BOOL visual = NativeHighlightForContextItemView(itemView) ||
        IsLatchedSubmenuParent(itemView);
    ApplyContextItemTextAndArrow(itemView, visual);
}

static void BlueContextItemDrawRect(id object, SEL selector, NSRect dirtyRect) {
    NSView *itemView = [object isKindOfClass:NSView.class] ? object : nil;

    // Seed the private key-equivalent field before AppKit draws subviews. This
    // is the path that makes the Snow Leopard arrow visible on the very first
    // frame, rather than waiting for the first highlight transition.
    RefreshContextItemPresentation(itemView);
    OriginalContextItemDrawRect(object, selector, dirtyRect);

    // AppKit may refresh the field while drawing/layout is settling. Reapply
    // once after its draw pass so the child NSTextLayer keeps our attachment.
    RefreshContextItemPresentation(itemView);
}

static void BlueContextItemLayout(id object, SEL selector) {
    OriginalContextItemLayout(object, selector);
    NSView *itemView = [object isKindOfClass:NSView.class] ? object : nil;
    RefreshContextItemPresentation(itemView);
}

static void BlueMenuItemViewSetHighlighted(id object, SEL selector,
    BOOL highlighted) {
    OriginalMenuItemViewSetHighlighted(object, selector, highlighted);
    if (!ContextMenuItemViewClass ||
        ![object isKindOfClass:ContextMenuItemViewClass]) return;

    NSView *itemView = (NSView *)object;
    BOOL visual = highlighted || IsLatchedSubmenuParent(itemView);
    SetSelectionFilm(itemView, visual);
    ApplyContextItemTextAndArrow(itemView, visual);
}

static void ClearLatchedSubmenuParent(id owner) {
    SLBlueWeakViewBox *box = WeakViewBox(owner, &LatchedSubmenuParentKey, NO);
    NSView *view = box.view;
    if (!view) return;
    box.view = nil;
    BOOL nativeHighlight = NativeHighlightForContextItemView(view);
    SetSelectionFilm(view, nativeHighlight);
    ApplyContextItemTextAndArrow(view, nativeHighlight);
}

static void LatchSubmenuParent(id owner, NSView *itemView) {
    if (!owner || !itemView) return;
    SLBlueWeakViewBox *box = WeakViewBox(owner, &LatchedSubmenuParentKey, YES);
    if (box.view && box.view != itemView) {
        NSView *oldParent = box.view;
        SetSelectionFilm(oldParent, NO);
        ApplyContextItemTextAndArrow(oldParent, NO);
    }
    box.view = itemView;
    SetSelectionFilm(itemView, YES);
    ApplyContextItemTextAndArrow(itemView, YES);
}

static void ClearPopupSelectionState(NSWindow *window) {
    if (!window) return;
    ClearLatchedSubmenuParent(window);
    SLBlueWeakViewBox *current = WeakViewBox(
        window, &CurrentHighlightedItemKey, NO);
    if (current.view) {
        SetSelectionFilm(current.view, NO);
        ApplyContextItemTextAndArrow(current.view, NO);
        current.view = nil;
    }
}

static void ClearAllPopupSelectionStates(void) {
    for (NSWindow *window in NSApp.windows) {
        if (IsPopupWindow(window)) ClearPopupSelectionState(window);
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
    objc_setAssociatedObject(backing, &SelectionBackingKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

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
    CALayer *active = [activeObject isKindOfClass:CALayer.class]
        ? activeObject : nil;
    CALayer *inactive = [inactiveObject isKindOfClass:CALayer.class]
        ? inactiveObject : nil;

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
    static const NSTimeInterval delays[] = { 0.0, 0.025, 0.10, 0.25 };
    __weak NSView *weakBacking = backing;
    for (NSUInteger index = 0;
         index < sizeof(delays) / sizeof(delays[0]);
         index++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(delays[index] * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                StyleSelectionBacking(weakBacking);
            });
    }
}

static void StopPendingTimerIfIdle(void) {
    if (PendingSelections.count || !PendingSelectionTimer) return;
    dispatch_source_cancel(PendingSelectionTimer);
    PendingSelectionTimer = nil;
}

static void EnsurePendingTimer(void) {
    if (PendingSelectionTimer) return;
    PendingSelectionTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(PendingSelectionTimer,
        dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC),
        10 * NSEC_PER_MSEC, 1 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(PendingSelectionTimer, ^{
        for (NSUInteger index = PendingSelections.count; index > 0; index--) {
            SLBluePendingSelection *pending = PendingSelections[index - 1];
            id candidate = BackingViewIvar
                ? object_getIvar(pending.selectionRect, BackingViewIvar)
                : nil;
            NSView *backing = [candidate isKindOfClass:NSView.class]
                ? candidate : nil;
            if (backing.window) {
                FinishSelectionBacking(backing);
                [PendingSelections removeObjectAtIndex:index - 1];
            } else if (pending.attemptsLeft <= 1) {
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
            ? candidate : nil;
        if (backing.window) {
            FinishSelectionBacking(backing);
            return;
        }
        if (!PendingSelections) PendingSelections = [NSMutableArray array];
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
    if (!object || !DisableAnimationsIvar) return;
    uint8_t *address = (uint8_t *)(__bridge void *)object +
        ivar_getOffset(DisableAnimationsIvar);
    *((BOOL *)address) = YES;
}

static id BlueSelectionInit(id object, SEL selector) {
    DisableSelectionAnimations(object);
    id result = OriginalSelectionInit(object, selector);
    DisableSelectionAnimations(result);
    TrackSelectionBacking(result);
    return result;
}

// ============================================================
// CONTEXT MENU TRACKING
// ============================================================

static void BlueContextHighlight(id object, SEL selector, BOOL highlighted,
    id menuItemView) {
    NSView *itemView = ContextMenuItemViewClass &&
        [menuItemView isKindOfClass:ContextMenuItemViewClass]
        ? menuItemView : nil;

    OriginalContextHighlight(object, selector, highlighted, menuItemView);
    if (!itemView) return;

    id owner = PopupSelectionOwner(itemView, object);
    SLBlueWeakViewBox *current = WeakViewBox(
        owner, &CurrentHighlightedItemKey, YES);
    SLBlueWeakViewBox *latched = WeakViewBox(
        owner, &LatchedSubmenuParentKey, NO);

    if (highlighted) {
        if (latched.view && latched.view != itemView) {
            NSView *oldParent = latched.view;
            latched.view = nil;
            SetSelectionFilm(oldParent, NO);
            ApplyContextItemTextAndArrow(oldParent, NO);
        }
        if (current.view && current.view != itemView) {
            SetSelectionFilm(current.view, NO);
            ApplyContextItemTextAndArrow(current.view, NO);
        }
        current.view = itemView;
        SetSelectionFilm(itemView, YES);
        ApplyContextItemTextAndArrow(itemView, YES);
        return;
    }

    BOOL keepParent = latched.view == itemView;
    SetSelectionFilm(itemView, keepParent);
    ApplyContextItemTextAndArrow(itemView, keepParent);
    if (!keepParent && current.view == itemView) current.view = nil;
}

static void BlueCocoaHighlightMenuItemView(id object, SEL selector,
    id menuItemView, BOOL shouldOpenSubmenu) {
    NSView *itemView = ContextMenuItemViewClass &&
        [menuItemView isKindOfClass:ContextMenuItemViewClass]
        ? menuItemView : nil;
    NSMenuItem *item = MenuItemForContextItemView(itemView);

    if (itemView && shouldOpenSubmenu && item.submenu) {
        id owner = PopupSelectionOwner(itemView, object);
        LatchSubmenuParent(owner, itemView);
    }

    OriginalCocoaHighlightMenuItemView(object, selector, menuItemView,
        shouldOpenSubmenu);

    if (itemView) {
        BOOL nativeHighlight = NO;
        if ([itemView respondsToSelector:NSSelectorFromString(@"isHighlighted")]) {
            nativeHighlight = ((BOOL (*)(id, SEL))objc_msgSend)(itemView,
                NSSelectorFromString(@"isHighlighted"));
        }
        BOOL visual = nativeHighlight || IsLatchedSubmenuParent(itemView);
        SetSelectionFilm(itemView, visual);
        ApplyContextItemTextAndArrow(itemView, visual);
    }
}

static NSView *MenuRootForItemView(NSView *itemView) {
    NSView *candidate = itemView;
    NSView *widest = itemView;
    while (candidate) {
        if (NSWidth(candidate.bounds) > NSWidth(widest.bounds)) widest = candidate;
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

static NSRect BlueContextSelectionFrame(id object, SEL selector,
    id itemViewObject) {
    NSRect frame = OriginalContextSelectionFrame(object, selector,
        itemViewObject);
    NSView *itemView = [itemViewObject isKindOfClass:NSView.class]
        ? itemViewObject : nil;
    NSView *root = MenuRootForItemView(itemView);
    CGFloat left = root ? NSMinX(root.bounds) : 0.0;
    CGFloat width = root ? NSWidth(root.bounds) : 0.0;
    if (isfinite(left) && isfinite(width) && width > 0.0 &&
        isfinite(frame.origin.y) && isfinite(frame.size.height) &&
        frame.size.height > 0.0) {
        frame.origin.x = left;
        frame.size.width = width;
    }
    return frame;
}

static BOOL ResolveABI(void) {
    SelectionClass = NSClassFromString(@"NSMenuSelectionRect");
    MenuItemViewClass = NSClassFromString(@"NSMenuItemView");
    CocoaMenuClass = NSClassFromString(@"NSCocoaMenuImpl");
    ContextMenuClass = NSClassFromString(@"NSContextMenuImpl");
    ContextMenuItemViewClass = NSClassFromString(@"NSContextMenuItemView");
    if (!SelectionClass || !MenuItemViewClass || !CocoaMenuClass ||
        !ContextMenuClass || !ContextMenuItemViewClass ||
        ![ContextMenuItemViewClass isSubclassOfClass:MenuItemViewClass]) {
        return NO;
    }

    MenuItemSelector = sel_registerName("menuItem");
    IsHighlightedSelector = sel_registerName("isHighlighted");

    Method initMethod = SLOwnInstanceMethod(SelectionClass, @selector(init));
    Method highlightedSetter = class_getInstanceMethod(
        MenuItemViewClass, NSSelectorFromString(@"setHighlighted:"));
    Method contextMethod = SLOwnInstanceMethod(ContextMenuClass,
        NSSelectorFromString(@"_setHighlighted:menuItemView:"));
    Method cocoaHighlightMethod = SLOwnInstanceMethod(CocoaMenuClass,
        NSSelectorFromString(@"_highlightMenuItemView:shouldOpenSubmenu:"));
    Method selectionFrameMethod = SLOwnInstanceMethod(ContextMenuClass,
        NSSelectorFromString(@"_selectionLayerFrameForView:"));
    Method contextItemDrawMethod = SLOwnInstanceMethod(ContextMenuItemViewClass,
        @selector(drawRect:));
    Method contextItemLayoutMethod = class_getInstanceMethod(
        ContextMenuItemViewClass, @selector(layout));

    BackingViewIvar = class_getInstanceVariable(SelectionClass, "_backingView");
    DisableAnimationsIvar = class_getInstanceVariable(SelectionClass,
        "_disableAnimations");
    MenuItemIvar = class_getInstanceVariable(MenuItemViewClass, "_menuItem");
    TitleTextFieldIvar = class_getInstanceVariable(MenuItemViewClass,
        "_titleTextField");
    KeyEquivalentTextFieldIvar = class_getInstanceVariable(
        ContextMenuItemViewClass, "_keyEquivalentTextField");
    const char *backingType = BackingViewIvar
        ? ivar_getTypeEncoding(BackingViewIvar) : NULL;
    const char *disableType = DisableAnimationsIvar
        ? ivar_getTypeEncoding(DisableAnimationsIvar) : NULL;

    return SLMethodMatches(initMethod, "@16@0:8") &&
        highlightedSetter != NULL &&
        SLMethodMatches(contextMethod, "v28@0:8B16@20") &&
        SLMethodMatches(cocoaHighlightMethod, "v28@0:8@16B24") &&
        selectionFrameMethod != NULL && contextItemDrawMethod != NULL &&
        contextItemLayoutMethod != NULL && TitleTextFieldIvar &&
        KeyEquivalentTextFieldIvar && backingType && backingType[0] == '@' &&
        disableType && strcmp(disableType, "B") == 0;
}

static void InstallHooks(void);

static void ScheduleHookRetry(void) {
    if (InstallAttempts++ >= 250) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
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
    Method highlightedSetter = class_getInstanceMethod(
        MenuItemViewClass, NSSelectorFromString(@"setHighlighted:"));
    Method contextMethod = SLOwnInstanceMethod(ContextMenuClass,
        NSSelectorFromString(@"_setHighlighted:menuItemView:"));
    Method cocoaHighlightMethod = SLOwnInstanceMethod(CocoaMenuClass,
        NSSelectorFromString(@"_highlightMenuItemView:shouldOpenSubmenu:"));
    Method selectionFrameMethod = SLOwnInstanceMethod(ContextMenuClass,
        NSSelectorFromString(@"_selectionLayerFrameForView:"));
    Method contextItemDrawMethod = SLOwnInstanceMethod(ContextMenuItemViewClass,
        @selector(drawRect:));
    Method ownContextItemLayoutMethod = SLOwnInstanceMethod(
        ContextMenuItemViewClass, @selector(layout));
    Method resolvedContextItemLayoutMethod = class_getInstanceMethod(
        ContextMenuItemViewClass, @selector(layout));

    OriginalSelectionInit = (InitFn)method_getImplementation(initMethod);
    OriginalMenuItemViewSetHighlighted =
        (SetBoolFn)method_getImplementation(highlightedSetter);
    OriginalContextHighlight =
        (SetHighlightedFn)method_getImplementation(contextMethod);
    OriginalCocoaHighlightMenuItemView =
        (HighlightMenuItemViewFn)method_getImplementation(cocoaHighlightMethod);
    OriginalContextSelectionFrame =
        (SelectionFrameFn)method_getImplementation(selectionFrameMethod);
    OriginalContextItemDrawRect =
        (DrawRectFn)method_getImplementation(contextItemDrawMethod);
    OriginalContextItemLayout = (VoidMethodFn)method_getImplementation(
        resolvedContextItemLayoutMethod);

    if (!OriginalSelectionInit || !OriginalMenuItemViewSetHighlighted ||
        !OriginalContextHighlight || !OriginalCocoaHighlightMenuItemView ||
        !OriginalContextSelectionFrame || !OriginalContextItemDrawRect ||
        !OriginalContextItemLayout) {
        return;
    }

    // NSContextMenuItemView inherits -layout on this Sequoia build. Add a
    // subclass-local override before swizzling anything else so a failure here
    // cannot leave a half-installed hook set that would recurse on retry.
    if (!ownContextItemLayoutMethod) {
        const char *layoutTypes = method_getTypeEncoding(
            resolvedContextItemLayoutMethod);
        if (!class_addMethod(ContextMenuItemViewClass, @selector(layout),
                (IMP)BlueContextItemLayout, layoutTypes)) {
            return;
        }
    }

    method_setImplementation(initMethod, (IMP)BlueSelectionInit);
    method_setImplementation(highlightedSetter,
        (IMP)BlueMenuItemViewSetHighlighted);
    method_setImplementation(contextMethod, (IMP)BlueContextHighlight);
    method_setImplementation(cocoaHighlightMethod,
        (IMP)BlueCocoaHighlightMenuItemView);
    method_setImplementation(selectionFrameMethod,
        (IMP)BlueContextSelectionFrame);
    method_setImplementation(contextItemDrawMethod,
        (IMP)BlueContextItemDrawRect);
    if (ownContextItemLayoutMethod) {
        method_setImplementation(ownContextItemLayoutMethod,
            (IMP)BlueContextItemLayout);
    }

    HooksInstalled = YES;
}

__attribute__((constructor))
static void SnowLeopardMenuSelectionLoad(void) {
    if (!SLIsDockOrRegularApplicationProcess()) return;

    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSMenuDidEndTrackingNotification
        object:nil
        queue:NSOperationQueue.mainQueue
        usingBlock:^(__unused NSNotification *note) {
            ClearAllPopupSelectionStates();
        }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
            InstallHooks();
        });
}
