#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>
#import <stdint.h>
#import <string.h>

#import "Runtime.h"
#import "SelectionRenderer.h"

const char SLSnowLeopardSidebarSelectionCapabilities[] =
    "snowLeopardSidebarSelection=modular-v2 "
    "sidebarStrategy=native-first-with-row-fallback "
    "finderDeselection=post-original "
    "appStoreVibrancy=selected-only";

// Sidebar/source-list selection. AppKit's native selection material is preferred;
// a row-local film is used only when the private material cannot be styled.

typedef void (*VoidFn)(id, SEL);
typedef void (*SetBoolFn)(id, SEL, BOOL);

static VoidFn OriginalNativeSidebarUpdateMaterialLayer = NULL;
static NSMutableDictionary<NSString *, id> *NativeSidebarGradientImageCache = nil;

static BOOL NativeSidebarIsAppStoreProcess = NO;
static BOOL NativeSidebarMaterialHookInstalled = NO;
static Class NativeSidebarBackdropLayerClass = Nil;
static Class NativeSidebarAppStoreTextFieldClass = Nil;
static SEL NativeSidebarCellSelector = NULL;
static SEL NativeSidebarSetBackgroundStyleSelector = NULL;
static SEL NativeSidebarSetContentTintSelector = NULL;
static SEL NativeSidebarSetForegroundColorSelector = NULL;
static SEL NativeSidebarAllowsVibrancySelector = NULL;
static SEL NativeSidebarSetAllowsVibrancySelector = NULL;

static char NativeSidebarAppStoreOriginalVibrancyKey;
static char NativeSidebarFallbackFilmKey;
static char NativeSidebarEffectOriginalHiddenKey;
static char NativeSidebarOriginalSetSelectedIMPKey;
static __thread NSUInteger NativeSidebarMaterialHookDepth = 0;
static __thread NSUInteger NativeSidebarSetSelectedHookDepth = 0;
static __thread Class NativeSidebarCurrentSetSelectedHookClass = Nil;

@interface SLBlueSidebarFallbackView : NSView
@end

@implementation SLBlueSidebarFallbackView

- (BOOL)isOpaque { return YES; }
- (BOOL)isAccessibilityElement { return NO; }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    SLDrawSharedSnowLeopardSelection(self);
}

@end

static CALayer *NativeSidebarLayerIvar(id object, const char *name) {
    id value = SLObjectIvar(object, name);
    return [value isKindOfClass:CALayer.class] ? (CALayer *)value : nil;
}

static NSTableRowView *NativeSidebarRowForView(NSView *view) {
    for (NSView *candidate = view; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:NSTableRowView.class]) {
            return (NSTableRowView *)candidate;
        }
    }
    return nil;
}

static NSTableView *NativeSidebarTableForRow(NSTableRowView *row) {
    if (!row) return nil;
    for (NSView *view = row.superview; view; view = view.superview) {
        if ([view isKindOfClass:NSTableView.class]) return (NSTableView *)view;
    }
    return nil;
}

static BOOL NativeSidebarNameSuggestsSidebar(NSView *view) {
    if (!view) return NO;
    for (NSView *candidate = view; candidate; candidate = candidate.superview) {
        NSString *name = NSStringFromClass(candidate.class).lowercaseString;
        if ([name containsString:@"sidebar"] ||
            [name containsString:@"source"] ||
            [name containsString:@"navigationlist"] ||
            [name containsString:@"navigationoutline"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL NativeSidebarIsRow(NSTableRowView *row) {
    if (!row) return NO;
    NSTableView *table = NativeSidebarTableForRow(row);
    if (!table) return NO;
    if (table.style == NSTableViewStyleSourceList) return YES;
    if (table.selectionHighlightStyle == (NSTableViewSelectionHighlightStyle)1) return YES;
    return NativeSidebarNameSuggestsSidebar(table) || NativeSidebarNameSuggestsSidebar(row);
}

static BOOL NativeSidebarEffectCoversRow(NSVisualEffectView *effect, NSTableRowView *row) {
    if (!effect || !row || NativeSidebarRowForView(effect) != row) return NO;
    NSRect rowBounds = row.bounds;
    if (NSIsEmptyRect(rowBounds)) return NO;
    NSRect effectInRow = [effect convertRect:effect.bounds toView:row];
    NSRect intersection = NSIntersectionRect(effectInRow, rowBounds);
    CGFloat rowArea = NSWidth(rowBounds) * NSHeight(rowBounds);
    CGFloat intersectionArea = NSWidth(intersection) * NSHeight(intersection);
    if (rowArea <= 0.0 || intersectionArea <= 0.0) return NO;
    CGFloat widthCoverage = NSWidth(intersection) / MAX(1.0, NSWidth(rowBounds));
    CGFloat heightCoverage = NSHeight(intersection) / MAX(1.0, NSHeight(rowBounds));
    CGFloat areaCoverage = intersectionArea / rowArea;
    return widthCoverage >= 0.65 && heightCoverage >= 0.65 && areaCoverage >= 0.55;
}

static BOOL NativeSidebarIsSelectionEffect(NSVisualEffectView *effect) {
    if (!effect || effect.material != NSVisualEffectMaterialSelection) return NO;
    NSTableRowView *row = NativeSidebarRowForView(effect);
    if (!row || !row.isSelected || !NativeSidebarIsRow(row)) return NO;
    return NativeSidebarEffectCoversRow(effect, row);
}

static NSVisualEffectView *NativeSidebarFindSelectionEffectInTree(NSView *view, NSTableRowView *row) {
    if (!view || !row) return nil;
    if ([view isKindOfClass:NSVisualEffectView.class]) {
        NSVisualEffectView *effect = (NSVisualEffectView *)view;
        if (effect.material == NSVisualEffectMaterialSelection &&
            NativeSidebarEffectCoversRow(effect, row)) {
            return effect;
        }
    }
    for (NSView *subview in view.subviews) {
        NSVisualEffectView *found = NativeSidebarFindSelectionEffectInTree(subview, row);
        if (found) return found;
    }
    return nil;
}

static BOOL NativeSidebarRGBForColor(CGColorRef color, CGFloat *red, CGFloat *green, CGFloat *blue, CGFloat *alpha) {
    if (!color || !red || !green || !blue || !alpha) return NO;
    CGColorSpaceRef space = CGColorGetColorSpace(color);
    if (!space || CGColorSpaceGetModel(space) != kCGColorSpaceModelRGB) return NO;
    const CGFloat *components = CGColorGetComponents(color);
    size_t count = CGColorGetNumberOfComponents(color);
    if (!components || count < 3) return NO;
    *red = components[0];
    *green = components[1];
    *blue = components[2];
    *alpha = count >= 4 ? components[3] : 1.0;
    return YES;
}

static BOOL NativeSidebarLayerIsBackdrop(CALayer *layer) {
    if (!layer) return NO;
    if (NativeSidebarBackdropLayerClass && [layer isKindOfClass:NativeSidebarBackdropLayerClass]) return YES;
    return [NSStringFromClass(layer.class).lowercaseString containsString:@"backdrop"];
}

static void NativeSidebarFindBestTintLayer(CALayer *layer, NSUInteger depth, CALayer **best, CGFloat *bestSpread) {
    if (!layer || !best || !bestSpread || depth > 6) return;
    if (!NativeSidebarLayerIsBackdrop(layer)) {
        CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
        if (NativeSidebarRGBForColor(layer.backgroundColor, &red, &green, &blue, &alpha)) {
            CGFloat maximum = MAX(red, MAX(green, blue));
            CGFloat minimum = MIN(red, MIN(green, blue));
            CGFloat spread = maximum - minimum;
            if (alpha > 0.01 && spread > *bestSpread) {
                *best = layer;
                *bestSpread = spread;
            }
        }
        for (CALayer *child in layer.sublayers) {
            NativeSidebarFindBestTintLayer(child, depth + 1, best, bestSpread);
        }
    }
}

static CALayer *NativeSidebarTintLayer(NSVisualEffectView *effect) {
    if (!effect) return nil;
    CALayer *roots[2] = {
        NativeSidebarLayerIvar(effect, "_materialLayerActive"),
        NativeSidebarLayerIvar(effect, "_materialLayerInactive")
    };
    for (NSUInteger index = 0; index < 2; index++) {
        CALayer *root = roots[index];
        if (!root || (index == 1 && root == roots[0])) continue;
        CALayer *best = nil;
        CGFloat bestSpread = 0.0;
        for (CALayer *candidate in root.sublayers) {
            NativeSidebarFindBestTintLayer(candidate, 0, &best, &bestSpread);
        }
        if (!best && root.sublayers.count == 0) {
            NativeSidebarFindBestTintLayer(root, 0, &best, &bestSpread);
        }
        if (best && bestSpread >= 0.03) return best;
    }
    return nil;
}

static CGGradientRef NativeSidebarGradient(void) {
    return SLSnowLeopardSelectionGradient();
}

static CGImageRef CreateNativeSidebarSelectionStrip(CGFloat heightPoints, CGFloat scale, BOOL reverse) {
    if (heightPoints <= 0.0 || scale <= 0.0) return NULL;
    size_t widthPixels = (size_t)MAX(1.0, ceil(scale));
    size_t heightPixels = (size_t)MAX(1.0, round(heightPoints * scale));
    size_t bytesPerRow = widthPixels * 4;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!space) return NULL;
    CGContextRef context = CGBitmapContextCreate(NULL, widthPixels, heightPixels, 8, bytesPerRow,
        space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) return NULL;
    CGGradientRef gradient = NativeSidebarGradient();
    if (!gradient) {
        CGContextRelease(context);
        return NULL;
    }
    CGFloat rulePixels = MAX(1.0, round(scale));
    CGFloat middleX = (CGFloat)widthPixels / 2.0;
    CGPoint topPoint = CGPointMake(middleX, (CGFloat)heightPixels - rulePixels);
    CGPoint bottomPoint = CGPointMake(middleX, rulePixels);
    CGPoint start = reverse ? bottomPoint : topPoint;
    CGPoint end = reverse ? topPoint : bottomPoint;
    CGContextDrawLinearGradient(context, gradient, start, end,
        kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGFloat topRed = reverse ? 5.0 / 255.0 : 105.0 / 255.0;
    CGFloat topGreen = reverse ? 47.0 / 255.0 : 134.0 / 255.0;
    CGFloat topBlue = reverse ? 209.0 / 255.0 : 247.0 / 255.0;
    CGFloat bottomRed = reverse ? 105.0 / 255.0 : 5.0 / 255.0;
    CGFloat bottomGreen = reverse ? 134.0 / 255.0 : 47.0 / 255.0;
    CGFloat bottomBlue = reverse ? 247.0 / 255.0 : 209.0 / 255.0;
    CGContextSetRGBFillColor(context, bottomRed, bottomGreen, bottomBlue, 1.0);
    CGContextFillRect(context, CGRectMake(0.0, 0.0, widthPixels, rulePixels));
    CGContextSetRGBFillColor(context, topRed, topGreen, topBlue, 1.0);
    CGContextFillRect(context, CGRectMake(0.0, (CGFloat)heightPixels - rulePixels, widthPixels, rulePixels));
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

static CGImageRef CachedNativeSidebarSelectionStrip(CGFloat heightPoints, CGFloat scale, BOOL reverse) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NativeSidebarGradientImageCache = [NSMutableDictionary dictionary];
    });
    NSInteger pixelHeight = (NSInteger)llround(heightPoints * scale);
    NSInteger pixelScale = (NSInteger)llround(scale * 1000.0);
    NSString *key = [NSString stringWithFormat:@"%ld-%ld-%d", (long)pixelHeight, (long)pixelScale, reverse];
    id cached = NativeSidebarGradientImageCache[key];
    if (cached) return (__bridge CGImageRef)cached;
    CGImageRef image = CreateNativeSidebarSelectionStrip(heightPoints, scale, reverse);
    if (!image) return NULL;
    NativeSidebarGradientImageCache[key] = (__bridge id)image;
    CGImageRelease(image);
    return (__bridge CGImageRef)NativeSidebarGradientImageCache[key];
}

static CGFloat NativeSidebarEffectiveScaleForLayer(CALayer *layer) {
    if (!layer) return 2.0;
    CGFloat scale = layer.contentsScale;
    if (scale <= 0.0) scale = NSScreen.mainScreen.backingScaleFactor;
    if (scale <= 0.0) scale = 2.0;
    return scale;
}

static void NativeSidebarSetBackgroundStyle(id object, NSInteger style) {
    if (object && [object respondsToSelector:NativeSidebarSetBackgroundStyleSelector]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(object, NativeSidebarSetBackgroundStyleSelector, style);
    }
}

static void NativeSidebarSetContentTint(id object, NSColor *color) {
    if (object && color && [object respondsToSelector:NativeSidebarSetContentTintSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(object, NativeSidebarSetContentTintSelector, color);
    }
}

static void NativeSidebarSetCellBackgroundStyle(NSView *view, NSInteger style) {
    if (![view isKindOfClass:NSControl.class] || ![view respondsToSelector:NativeSidebarCellSelector]) return;
    id cell = ((id (*)(id, SEL))objc_msgSend)(view, NativeSidebarCellSelector);
    NativeSidebarSetBackgroundStyle(cell, style);
}

static void NativeSidebarTintTextLayerTree(CALayer *layer, NSColor *color) {
    if (!layer) return;
    NSString *className = NSStringFromClass(layer.class).lowercaseString;
    if ([className containsString:@"textlayer"] && [layer respondsToSelector:NativeSidebarSetForegroundColorSelector]) {
        ((void (*)(id, SEL, CGColorRef))objc_msgSend)(layer, NativeSidebarSetForegroundColorSelector, color.CGColor);
    }
    for (CALayer *child in layer.sublayers) NativeSidebarTintTextLayerTree(child, color);
}

static void NativeSidebarTintTextLayers(CALayer *layer, NSColor *color) {
    if (!layer || !color || NativeSidebarIsAppStoreProcess) return;
    NativeSidebarTintTextLayerTree(layer, color);
}

static BOOL NativeSidebarIsAppStoreDynamicTextField(NSView *view) {
    if (!view || !NativeSidebarIsAppStoreProcess) return NO;
    if (!NativeSidebarAppStoreTextFieldClass) {
        NativeSidebarAppStoreTextFieldClass = NSClassFromString(@"AppStoreKit.DynamicTypeTextField");
    }
    return NativeSidebarAppStoreTextFieldClass && [view isKindOfClass:NativeSidebarAppStoreTextFieldClass];
}

static void NativeSidebarApplyAppStoreVibrancy(NSView *view, BOOL selected) {
    if (!NativeSidebarIsAppStoreDynamicTextField(view) ||
        ![view respondsToSelector:NativeSidebarAllowsVibrancySelector] ||
        ![view respondsToSelector:NativeSidebarSetAllowsVibrancySelector]) return;
    BOOL current = ((BOOL (*)(id, SEL))objc_msgSend)(view, NativeSidebarAllowsVibrancySelector);
    NSNumber *saved = objc_getAssociatedObject(view, &NativeSidebarAppStoreOriginalVibrancyKey);
    if (!saved) {
        saved = @(current);
        objc_setAssociatedObject(view, &NativeSidebarAppStoreOriginalVibrancyKey, saved, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL target = selected ? NO : saved.boolValue;
    if (current != target) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(view, NativeSidebarSetAllowsVibrancySelector, target);
    }
}

static void NativeSidebarApplyContentRecursive(NSView *view, BOOL selected, NSColor *color, NSInteger backgroundStyle) {
    if (!view) return;
    NativeSidebarSetBackgroundStyle(view, backgroundStyle);
    NativeSidebarSetCellBackgroundStyle(view, backgroundStyle);
    BOOL touched = NO;
    if ([view isKindOfClass:NSTextField.class]) {
        NSTextField *field = (NSTextField *)view;
        field.textColor = color;
        field.alphaValue = 1.0;
        touched = YES;
    } else if ([view isKindOfClass:NSImageView.class]) {
        NSImageView *imageView = (NSImageView *)view;
        if (imageView.image.isTemplate) NativeSidebarSetContentTint(imageView, color);
        imageView.alphaValue = 1.0;
        touched = YES;
    } else if ([view isKindOfClass:NSButton.class]) {
        NSButton *button = (NSButton *)view;
        if (button.image.isTemplate) NativeSidebarSetContentTint(button, color);
        button.alphaValue = 1.0;
        touched = YES;
    }
    NativeSidebarApplyAppStoreVibrancy(view, selected);
    if (touched) {
        [view setNeedsDisplay:YES];
        if (view.layer) [view.layer setNeedsDisplay];
    }
    for (NSView *subview in view.subviews) {
        NativeSidebarApplyContentRecursive(subview, selected, color, backgroundStyle);
    }
}

static void NativeSidebarApplyContentToView(NSView *view, BOOL selected) {
    if (!view) return;
    NSColor *color = selected ? NSColor.whiteColor : NSColor.blackColor;
    NativeSidebarApplyContentRecursive(view, selected, color, selected ? 1 : 0);
    if (view.layer) NativeSidebarTintTextLayers(view.layer, color);
    [view setNeedsDisplay:YES];
}

static void NativeSidebarSetEffectSuppressed(NSVisualEffectView *effect, BOOL suppressed) {
    if (!effect) return;
    NSNumber *saved = objc_getAssociatedObject(effect, &NativeSidebarEffectOriginalHiddenKey);
    if (suppressed) {
        if (!saved) {
            objc_setAssociatedObject(effect, &NativeSidebarEffectOriginalHiddenKey,
                @(effect.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        effect.hidden = YES;
    } else if (saved) {
        effect.hidden = saved.boolValue;
        objc_setAssociatedObject(effect, &NativeSidebarEffectOriginalHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void NativeSidebarRestoreSuppressedEffects(NSView *view) {
    if (!view) return;
    if ([view isKindOfClass:NSVisualEffectView.class]) {
        NativeSidebarSetEffectSuppressed((NSVisualEffectView *)view, NO);
    }
    for (NSView *subview in view.subviews) NativeSidebarRestoreSuppressedEffects(subview);
}

static SLBlueSidebarFallbackView *NativeSidebarFallbackForRow(NSTableRowView *row, BOOL create) {
    if (!row) return nil;
    SLBlueSidebarFallbackView *film = objc_getAssociatedObject(row, &NativeSidebarFallbackFilmKey);
    if (!film && create) {
        film = [[SLBlueSidebarFallbackView alloc] initWithFrame:row.bounds];
        film.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        objc_setAssociatedObject(row, &NativeSidebarFallbackFilmKey, film, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return film;
}

static void NativeSidebarSetFallbackVisible(NSTableRowView *row, BOOL visible) {
    SLBlueSidebarFallbackView *film = NativeSidebarFallbackForRow(row, visible);
    if (!film) return;
    if (!visible) {
        film.hidden = YES;
        if (film.superview) [film removeFromSuperviewWithoutNeedingDisplay];
        return;
    }
    film.frame = row.bounds;
    film.hidden = NO;
    if (film.superview != row || row.subviews.firstObject != film) {
        [film removeFromSuperviewWithoutNeedingDisplay];
        [row addSubview:film positioned:NSWindowBelow relativeTo:nil];
    }
    [film setNeedsDisplay:YES];
}

static BOOL ApplyNativeSidebarSnowLeopardGradient(NSVisualEffectView *effect) {
    CALayer *tint = NativeSidebarTintLayer(effect);
    if (!tint) return NO;
    CGFloat height = CGRectGetHeight(tint.bounds);
    if (height <= 0.0) return NO;
    CGFloat scale = NativeSidebarEffectiveScaleForLayer(tint);
    CGImageRef image = CachedNativeSidebarSelectionStrip(height, scale, tint.contentsAreFlipped);
    if (!image) return NO;
    tint.backgroundColor = NSColor.clearColor.CGColor;
    tint.contents = (__bridge id)image;
    tint.contentsGravity = kCAGravityResize;
    tint.contentsScale = scale;
    tint.magnificationFilter = kCAFilterLinear;
    tint.minificationFilter = kCAFilterLinear;
    return YES;
}

static void NativeSidebarReconcileRow(NSTableRowView *row) {
    if (!row || !NativeSidebarIsRow(row)) return;
    BOOL selected = row.isSelected;
    if (!selected) {
        NativeSidebarSetFallbackVisible(row, NO);
        NativeSidebarRestoreSuppressedEffects(row);
        NativeSidebarApplyContentToView(row, NO);
        return;
    }

    NSVisualEffectView *effect = NativeSidebarFindSelectionEffectInTree(row, row);
    BOOL nativeApplied = effect && ApplyNativeSidebarSnowLeopardGradient(effect);
    if (effect) NativeSidebarSetEffectSuppressed(effect, !nativeApplied);
    NativeSidebarSetFallbackVisible(row, !nativeApplied);
    NativeSidebarApplyContentToView(row, YES);
}

static SetBoolFn NativeSidebarOriginalSetSelectedForObject(id object, Class afterClass, Class *ownerClass) {
    if (ownerClass) *ownerClass = Nil;
    if (!object) return NULL;
    Class cls = afterClass ? class_getSuperclass(afterClass) : object_getClass(object);
    for (; cls; cls = class_getSuperclass(cls)) {
        NSValue *value = objc_getAssociatedObject((id)cls, &NativeSidebarOriginalSetSelectedIMPKey);
        if (value) {
            if (ownerClass) *ownerClass = cls;
            return (SetBoolFn)value.pointerValue;
        }
        if (cls == NSTableRowView.class) break;
    }
    return NULL;
}

static void NativeSidebarSetSelected(id object, SEL selector, BOOL selected) {
    Class ownerClass = Nil;
    Class afterClass = NativeSidebarSetSelectedHookDepth > 0
        ? NativeSidebarCurrentSetSelectedHookClass
        : Nil;
    SetBoolFn original = NativeSidebarOriginalSetSelectedForObject(object, afterClass, &ownerClass);
    if (!original || !ownerClass) return;

    BOOL outermost = NativeSidebarSetSelectedHookDepth == 0;
    Class previousHookClass = NativeSidebarCurrentSetSelectedHookClass;
    NativeSidebarCurrentSetSelectedHookClass = ownerClass;
    NativeSidebarSetSelectedHookDepth++;
    original(object, selector, selected);

    if (outermost) {
        NSTableRowView *row = [object isKindOfClass:NSTableRowView.class] ? (NSTableRowView *)object : nil;
        if (row && NativeSidebarIsRow(row)) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            NativeSidebarReconcileRow(row);
            [CATransaction commit];
        }
    }

    NativeSidebarSetSelectedHookDepth--;
    NativeSidebarCurrentSetSelectedHookClass = previousHookClass;
}

static void NativeSidebarUpdateMaterialLayer(id object, SEL selector) {
    if (!OriginalNativeSidebarUpdateMaterialLayer) return;
    if (NativeSidebarMaterialHookDepth > 0) {
        OriginalNativeSidebarUpdateMaterialLayer(object, selector);
        return;
    }
    NativeSidebarMaterialHookDepth++;
    OriginalNativeSidebarUpdateMaterialLayer(object, selector);
    NSVisualEffectView *effect = [object isKindOfClass:NSVisualEffectView.class]
        ? (NSVisualEffectView *)object : nil;
    if (NativeSidebarIsSelectionEffect(effect)) {
        NSTableRowView *row = NativeSidebarRowForView(effect);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        BOOL nativeApplied = ApplyNativeSidebarSnowLeopardGradient(effect);
        NativeSidebarSetEffectSuppressed(effect, !nativeApplied);
        NativeSidebarSetFallbackVisible(row, !nativeApplied);
        NativeSidebarApplyContentToView(row, YES);
        [CATransaction commit];
    }
    NativeSidebarMaterialHookDepth--;
}

static BOOL NativeSidebarMethodIsVoidNoArgs(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    return returnType[0] == 'v';
}

static BOOL NativeSidebarMethodIsBoolSetter(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3) return NO;
    char returnType[16] = {0};
    char argumentType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    return returnType[0] == 'v' && (argumentType[0] == 'B' || argumentType[0] == 'c');
}

static BOOL NativeSidebarClassIsRowSubclass(Class cls) {
    for (Class candidate = cls; candidate; candidate = class_getSuperclass(candidate)) {
        if (candidate == NSTableRowView.class) return YES;
    }
    return NO;
}

static BOOL NativeSidebarInstallSetSelectedHookForClass(Class cls) {
    if (!cls || !NativeSidebarClassIsRowSubclass(cls)) return NO;
    Method method = SLOwnInstanceMethod(cls, @selector(setSelected:));
    if (!NativeSidebarMethodIsBoolSetter(method)) return NO;
    IMP current = method_getImplementation(method);
    if (!current) return NO;
    if (current == (IMP)NativeSidebarSetSelected) {
        return objc_getAssociatedObject((id)cls, &NativeSidebarOriginalSetSelectedIMPKey) != nil;
    }
    objc_setAssociatedObject((id)cls, &NativeSidebarOriginalSetSelectedIMPKey,
        [NSValue valueWithPointer:current], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    method_setImplementation(method, (IMP)NativeSidebarSetSelected);
    return YES;
}

static NSUInteger NativeSidebarInstallSetSelectedHooksForLoadedClasses(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return 0;
    __unsafe_unretained Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return 0;
    count = objc_getClassList(classes, count);
    NSUInteger installedCount = 0;
    for (int index = 0; index < count; index++) {
        if (NativeSidebarInstallSetSelectedHookForClass(classes[index])) installedCount++;
    }
    free(classes);
    return installedCount;
}

static BOOL InstallNativeSidebarSelectionHook(void) {
    static BOOL initialized = NO;
    if (initialized) {
        return NativeSidebarMaterialHookInstalled ||
            objc_getAssociatedObject((id)NSTableRowView.class, &NativeSidebarOriginalSetSelectedIMPKey) != nil;
    }
    initialized = YES;

    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    NativeSidebarIsAppStoreProcess =
        [NSProcessInfo.processInfo.processName isEqualToString:@"App Store"] ||
        [bundleIdentifier isEqualToString:@"com.apple.AppStore"];
    NativeSidebarBackdropLayerClass = NSClassFromString(@"CABackdropLayer");
    NativeSidebarCellSelector = sel_registerName("cell");
    NativeSidebarSetBackgroundStyleSelector = sel_registerName("setBackgroundStyle:");
    NativeSidebarSetContentTintSelector = sel_registerName("setContentTintColor:");
    NativeSidebarSetForegroundColorSelector = sel_registerName("setForegroundColor:");
    NativeSidebarAllowsVibrancySelector = sel_registerName("allowsVibrancy");
    NativeSidebarSetAllowsVibrancySelector = sel_registerName("setAllowsVibrancy:");

    SEL materialSelector = sel_registerName("_updateMaterialLayer");
    Method materialMethod = class_getInstanceMethod(NSVisualEffectView.class, materialSelector);
    if (NativeSidebarMethodIsVoidNoArgs(materialMethod)) {
        IMP materialOriginal = method_getImplementation(materialMethod);
        if (materialOriginal && materialOriginal != (IMP)NativeSidebarUpdateMaterialLayer) {
            OriginalNativeSidebarUpdateMaterialLayer = (VoidFn)materialOriginal;
            method_setImplementation(materialMethod, (IMP)NativeSidebarUpdateMaterialLayer);
            NativeSidebarMaterialHookInstalled = YES;
        }
    }

    NSUInteger rowHooks = NativeSidebarInstallSetSelectedHooksForLoadedClasses();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        NativeSidebarInstallSetSelectedHooksForLoadedClasses();
    });

    return NativeSidebarMaterialHookInstalled || rowHooks > 0;
}

// ============================================================
// END NATIVE APPKIT SIDEBAR SELECTION
// ============================================================

__attribute__((constructor))
static void SnowLeopardSidebarSelectionLoad(void) {
    if (!SLRuntimeIsMacOSSequoia() || !SLIsDockOrRegularApplicationProcess()) return;
    InstallNativeSidebarSelectionHook();
}
