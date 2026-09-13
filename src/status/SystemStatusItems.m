#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <unistd.h>

#import "Runtime.h"
#import "Protocol.h"
#import "SelectionRenderer.h"
#import "StatusSelectionIPC.h"
#import "Performance.h"

const char SLSnowLeopardSystemStatusCapabilities[] =
    "snowLeopardSystemStatus=modular-v2 owner=unified";

// Apple/system-owned right-side status-item module for the Unified dylib.
//
// The Ammonia blacklist and runtime process guards limit where this code runs.
// Exact process identity is validated again before private hooks are installed.
//
// Colour policy:
//   - template NSImage/NSButton content is tinted black or white directly;
//   - text is tinted directly;
//   - the legacy whole-view CIFalseColor fallback is enabled only when the
//     status item is demonstrably monochrome. Coloured images and custom
//     coloured drawing are preserved.

typedef void (*DrawStatusBackgroundFn)(id, SEL, NSRect *, NSView *, BOOL);
typedef void (*SetStatusBarViewFn)(id, SEL, NSView *);
typedef float (*FloatNoArgFn)(id, SEL);
typedef void (*SetBoolValueFn)(id, SEL, BOOL);

extern void SLStatusIconReplacementSetHighlighted(
    NSView *statusItemView,
    BOOL highlighted
);

static DrawStatusBackgroundFn OriginalDrawStatusBackground = NULL;
static SetStatusBarViewFn OriginalSetStatusBarView = NULL;
static FloatNoArgFn OriginalStatusItemPreferredPosition = NULL;
static SetBoolValueFn OriginalStatusItemSetVisible = NULL;
static Class SystemStatusBarClass = Nil;
static Class StatusBarWindowClass = Nil;
static Ivar StatusViewIvar = NULL;
static const void *BlackFilterKey = &BlackFilterKey;
static const void *WhiteFilterKey = &WhiteFilterKey;
static const void *OriginalContentTintKey = &OriginalContentTintKey;
static const void *ImageChromaticCacheKey = &ImageChromaticCacheKey;
static const void *LayerChromaticCacheKey = &LayerChromaticCacheKey;
static const void *DidOverrideContentTintKey = &DidOverrideContentTintKey;
static const void *SnapshotHasChromaticContentKey =
    &SnapshotHasChromaticContentKey;
static const void *ColourScanPendingKey = &ColourScanPendingKey;
static const void *LastColourScanTimeKey = &LastColourScanTimeKey;
static NSUInteger DrawLogCount = 0;
static NSUInteger SeedLogCount = 0;
static NSUInteger ColourScanLogCount = 0;
static NSUInteger ClockOrderingLogCount = 0;
static __thread BOOL CapturingStatusItemSnapshot = NO;
static dispatch_source_t StatusAppearanceTimer = nil;

static BOOL SLViewTreeContainsSpotlightRightMarginAnchor(NSView *view) {
    if (!view) return NO;
    if ([view.identifier
            isEqualToString:SL_SPOTLIGHT_RIGHT_MARGIN_ANCHOR_IDENTIFIER]) {
        return YES;
    }
    for (NSView *subview in view.subviews) {
        if (SLViewTreeContainsSpotlightRightMarginAnchor(subview)) {
            return YES;
        }
    }
    return NO;
}

static BOOL SLIsSpotlightRightMarginWindow(NSWindow *window) {
    if (!window) return NO;
    return [window.title isEqualToString:SL_SPOTLIGHT_RIGHT_MARGIN_WINDOW_TITLE] ||
        SLViewTreeContainsSpotlightRightMarginAnchor(window.contentView);
}

static BOOL IsExactAllowedProcess(void) {
    return SLIsExactControlCenterProcess() ||
           SLIsExactSystemUIServerProcess() ||
           SLIsExactSpotlightProcess();
}

typedef struct {
    BOOL hasTemplateImage;
    BOOL hasChromaticContent;
    BOOL hasText;
} SLStatusVisualScan;

typedef struct {
    BOOL preserveColour;
    BOOL hasTemplateImage;
    BOOL hasText;
    NSUInteger filterCount;
} SLStatusRefreshResult;

static CIFilter *MonochromeFalseColourFilter(NSView *view, BOOL white) {
    const void *key = white ? WhiteFilterKey : BlackFilterKey;
    CIFilter *filter = objc_getAssociatedObject(view, key);
    if (filter) return filter;
    filter = [CIFilter filterWithName:@"CIFalseColor"];
    if (!filter) return nil;
    [filter setDefaults];
    CGFloat value = white ? 1.0 : 0.0;
    CIColor *colour = [CIColor colorWithRed:value green:value blue:value alpha:1.0];
    [filter setValue:colour forKey:@"inputColor0"];
    [filter setValue:colour forKey:@"inputColor1"];
    objc_setAssociatedObject(view, key, filter,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return filter;
}

static NSUInteger SetMonochromeFilterEnabled(NSView *view, BOOL enabled, BOOL white) {
    CALayer *layer = view.layer;
    if (!layer) return 0;
    CIFilter *filter = MonochromeFalseColourFilter(view, white);
    if (!filter) return layer.filters.count;
    CIFilter *opposite = MonochromeFalseColourFilter(view, !white);

    NSMutableArray *filters = [NSMutableArray array];
    BOOL found = NO;
    for (id candidate in layer.filters ?: @[]) {
        if (candidate == filter) {
            found = YES;
        } else if (candidate != opposite) {
            [filters addObject:candidate];
        }
    }
    BOOL oppositeFound = [layer.filters containsObject:opposite];
    if (found == enabled && !oppositeFound) return layer.filters.count;
    if (enabled) [filters addObject:filter];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.filters = filters.count ? filters.copy : nil;
    [CATransaction commit];
    [layer setNeedsDisplay];
    [view setNeedsDisplay:YES];
    return filters.count;
}

static NSUInteger SetBlackFilterEnabled(NSView *view, BOOL enabled) {
    return SetMonochromeFilterEnabled(view, enabled, NO);
}

static BOOL BitmapContainsChromaticPixels(NSBitmapImageRep *bitmap) {
    if (!bitmap || bitmap.pixelsWide <= 0 || bitmap.pixelsHigh <= 0) {
        return NO;
    }

    NSInteger longestSide = MAX(bitmap.pixelsWide, bitmap.pixelsHigh);
    NSInteger step = MAX((NSInteger)1, longestSide / 64);
    NSUInteger visiblePixels = 0;
    NSUInteger chromaticPixels = 0;

    for (NSInteger y = 0; y < bitmap.pixelsHigh; y += step) {
        for (NSInteger x = 0; x < bitmap.pixelsWide; x += step) {
            NSColor *pixel = [bitmap colorAtX:x y:y];
            NSColor *rgb =
                [pixel colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            if (!rgb) continue;

            CGFloat red = 0.0;
            CGFloat green = 0.0;
            CGFloat blue = 0.0;
            CGFloat alpha = 0.0;
            [rgb getRed:&red green:&green blue:&blue alpha:&alpha];
            if (alpha < 0.12) continue;
            visiblePixels++;

            CGFloat maximum = MAX(red, MAX(green, blue));
            CGFloat minimum = MIN(red, MIN(green, blue));
            CGFloat delta = maximum - minimum;
            CGFloat saturation = maximum > 0.001 ? delta / maximum : 0.0;
            if (delta >= 0.075 && saturation >= 0.10) {
                chromaticPixels++;
            }
        }
    }

    if (visiblePixels == 0 || chromaticPixels < 2) return NO;
    return ((double)chromaticPixels / (double)visiblePixels) >= 0.005;
}

static BOOL ImageContainsChromaticPixels(NSImage *image) {
    if (!image || image.isTemplate) return NO;
    NSNumber *cached = objc_getAssociatedObject(image, ImageChromaticCacheKey);
    if (cached) return cached.boolValue;

    const size_t dimension = 32;
    CGColorSpaceRef colourSpace =
        CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!colourSpace) return NO;
    CGContextRef bitmapContextRef = CGBitmapContextCreate(
        NULL, dimension, dimension, 8, dimension * 4, colourSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colourSpace);
    if (!bitmapContextRef) return NO;

    CGContextClearRect(bitmapContextRef,
                       CGRectMake(0.0, 0.0, dimension, dimension));
    NSGraphicsContext *oldContext = NSGraphicsContext.currentContext;
    NSGraphicsContext *bitmapContext = [NSGraphicsContext
        graphicsContextWithCGContext:bitmapContextRef flipped:NO];
    [NSGraphicsContext setCurrentContext:bitmapContext];
    [image drawInRect:NSMakeRect(0.0, 0.0, dimension, dimension)
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0
       respectFlipped:NO
                hints:nil];
    [NSGraphicsContext setCurrentContext:oldContext];

    CGImageRef renderedImage = CGBitmapContextCreateImage(bitmapContextRef);
    CGContextRelease(bitmapContextRef);
    if (!renderedImage) return NO;
    NSBitmapImageRep *bitmap =
        [[NSBitmapImageRep alloc] initWithCGImage:renderedImage];
    CGImageRelease(renderedImage);
    BOOL result = BitmapContainsChromaticPixels(bitmap);
    objc_setAssociatedObject(image, ImageChromaticCacheKey, @(result),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

static BOOL LayerTreeContainsChromaticContent(CALayer *layer) {
    if (!layer || layer.hidden || layer.opacity <= 0.01) return NO;

    id contents = layer.contents;
    if (contents) {
        CFTypeRef contentsRef = (__bridge CFTypeRef)contents;
        if (CFGetTypeID(contentsRef) == CGImageGetTypeID()) {
            // One immutable CGImage/result pair per layer, replaced on content
            // change. Do not wrap and rasterize the same image on every seed.
            NSArray *cached = objc_getAssociatedObject(layer, LayerChromaticCacheKey);
            if (!cached || cached[0] != contents) {
                NSImage *image = [[NSImage alloc] initWithCGImage:(__bridge CGImageRef)contents
                                                            size:NSZeroSize];
                cached = @[contents, @(ImageContainsChromaticPixels(image))];
                objc_setAssociatedObject(layer, LayerChromaticCacheKey, cached,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if ([cached[1] boolValue]) return YES;
        } else {
            objc_setAssociatedObject(layer, LayerChromaticCacheKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
    } else {
        objc_setAssociatedObject(layer, LayerChromaticCacheKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }

    for (CALayer *sublayer in layer.sublayers ?: @[]) {
        if (LayerTreeContainsChromaticContent(sublayer)) return YES;
    }
    return NO;
}

static void ScanStatusVisuals(NSView *view, SLStatusVisualScan *scan) {
    if (!view || !scan || view.hidden || view.alphaValue <= 0.01) return;

    if ([view isKindOfClass:NSImageView.class]) {
        NSImage *image = ((NSImageView *)view).image;
        if (image.isTemplate) scan->hasTemplateImage = YES;
        if (ImageContainsChromaticPixels(image)) {
            scan->hasChromaticContent = YES;
        }
    } else if ([view isKindOfClass:NSButton.class]) {
        NSButton *button = (NSButton *)view;
        NSImage *image = button.image;
        NSImage *alternateImage = button.alternateImage;
        if (image.isTemplate || alternateImage.isTemplate) {
            scan->hasTemplateImage = YES;
        }
        if (ImageContainsChromaticPixels(image) ||
            ImageContainsChromaticPixels(alternateImage)) {
            scan->hasChromaticContent = YES;
        }
        if (button.title.length || button.attributedTitle.length) {
            scan->hasText = YES;
        }
    } else if ([view isKindOfClass:NSTextField.class]) {
        if (((NSTextField *)view).stringValue.length) scan->hasText = YES;
    }

    if (LayerTreeContainsChromaticContent(view.layer)) {
        scan->hasChromaticContent = YES;
    }
    for (NSView *subview in view.subviews.copy) {
        ScanStatusVisuals(subview, scan);
    }
}

static void StoreOriginalContentTintIfNeeded(id control, NSColor *tint) {
    if (objc_getAssociatedObject(control, DidOverrideContentTintKey)) return;
    objc_setAssociatedObject(control, DidOverrideContentTintKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(control, OriginalContentTintKey,
                             tint ?: (id)NSNull.null,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void RestoreImageViewTint(NSImageView *imageView) {
    if (!objc_getAssociatedObject(imageView, DidOverrideContentTintKey)) return;
    id original = objc_getAssociatedObject(imageView, OriginalContentTintKey);
    imageView.contentTintColor = original == NSNull.null ? nil : original;
    objc_setAssociatedObject(imageView, OriginalContentTintKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(imageView, DidOverrideContentTintKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
}

static void RestoreButtonTint(NSButton *button) {
    if (!objc_getAssociatedObject(button, DidOverrideContentTintKey)) return;
    id original = objc_getAssociatedObject(button, OriginalContentTintKey);
    button.contentTintColor = original == NSNull.null ? nil : original;
    objc_setAssociatedObject(button, OriginalContentTintKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(button, DidOverrideContentTintKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
}

static void ApplySelectiveTint(NSView *view, NSColor *colour) {
    if (!view || view.hidden || view.alphaValue <= 0.01) return;

    if ([view isKindOfClass:NSImageView.class]) {
        NSImageView *imageView = (NSImageView *)view;
        if (imageView.image.isTemplate) {
            StoreOriginalContentTintIfNeeded(imageView,
                                             imageView.contentTintColor);
            if (![imageView.contentTintColor isEqual:colour]) imageView.contentTintColor = colour;
        } else {
            RestoreImageViewTint(imageView);
        }
    } else if ([view isKindOfClass:NSButton.class]) {
        NSButton *button = (NSButton *)view;
        BOOL hasTemplateImage =
            button.image.isTemplate || button.alternateImage.isTemplate;
        BOOL hasTitle = button.title.length || button.attributedTitle.length;
        if (hasTemplateImage || hasTitle) {
            StoreOriginalContentTintIfNeeded(button, button.contentTintColor);
            if (![button.contentTintColor isEqual:colour]) button.contentTintColor = colour;
        } else {
            RestoreButtonTint(button);
        }
    } else if ([view isKindOfClass:NSTextField.class]) {
        NSTextField *field = (NSTextField *)view;
        if (![field.textColor isEqual:colour]) field.textColor = colour;
    }

    for (CALayer *layer in view.layer.sublayers ?: @[]) {
        if ([layer isKindOfClass:CATextLayer.class]) {
            CATextLayer *textLayer = (CATextLayer *)layer;
            CGColorRef desired = colour.CGColor;
            if (!textLayer.foregroundColor || !CGColorEqualToColor(textLayer.foregroundColor, desired))
                textLayer.foregroundColor = desired;
        }
    }
    for (NSView *subview in view.subviews.copy) {
        ApplySelectiveTint(subview, colour);
    }
}

static BOOL CachedSnapshotHasChromaticContent(NSView *view) {
    NSNumber *value = objc_getAssociatedObject(
        view, SnapshotHasChromaticContentKey);
    return value.boolValue;
}

static BOOL CaptureViewContainsChromaticContent(NSView *view) {
    if (!view || NSIsEmptyRect(view.bounds) || CapturingStatusItemSnapshot) {
        return NO;
    }

    SetBlackFilterEnabled(view, NO);
    CapturingStatusItemSnapshot = YES;
    BOOL result = NO;
    @try {
        NSBitmapImageRep *bitmap =
            [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        if (bitmap) {
            [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
            result = BitmapContainsChromaticPixels(bitmap);
        }
    } @catch (NSException *exception) {
        SLLog([NSString stringWithFormat:
            @"system-status colour snapshot failed view=%@ exception=%@",
            NSStringFromClass(view.class), exception.name]);
    } @finally {
        CapturingStatusItemSnapshot = NO;
    }
    return result;
}

static BOOL IsAttachedStatusItemView(NSView *view) {
    return view && StatusBarWindowClass &&
        [view.window isKindOfClass:StatusBarWindowClass];
}

static BOOL IsKnownAppleMonochromeStatusItem(NSView *view) {
    if (!view || !view.window) return NO;

    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    if ([bundleID isEqualToString:SLBundleIDSpotlight]) return YES;
    if (![bundleID isEqualToString:SLBundleIDControlCenter] &&
        ![bundleID isEqualToString:SLBundleIDSystemUIServer]) {
        return NO;
    }

    NSString *title = view.window.title ?: @"";
    static NSSet<NSString *> *knownTitles = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        knownTitles = [NSSet setWithArray:@[
            @"Clock", @"Bluetooth", @"NowPlaying", @"Sound",
            @"Battery", @"WiFi", @"BentoBox", @"Spotlight",
            @"Item-0", @"AirPlay", @"Display", @"FocusModes",
            @"ScreenMirroring", @"UserSwitcher", @"TimeMachine",
            @"VPN"
        ]];
    });

    if ([knownTitles containsObject:title]) return YES;
    NSString *className = NSStringFromClass(view.class);
    return [className containsString:@"ControlCenterApp"] &&
        [className containsString:@"StatusItemView"];
}

static BOOL StatusItemHasVisibleBlueUnderlay(NSView *view) {
    NSView *contentView = view.window.contentView;
    for (NSView *subview in contentView.subviews.copy) {
        if ([NSStringFromClass(subview.class)
                isEqualToString:@"SLSnowLeopardRightSelectionView"] &&
            !subview.hidden && subview.alphaValue > 0.01) {
            return YES;
        }
    }
    return NO;
}

static SLStatusRefreshResult RefreshStatusItemAppearance(
    NSView *view, BOOL highlighted) {
    SLStatusRefreshResult result = {0};
    if (!IsAttachedStatusItemView(view) ||
        SLIsSpotlightRightMarginWindow(view.window)) return result;

    SLStatusVisualScan scan = {0};
    ScanStatusVisuals(view, &scan);
    result.hasTemplateImage = scan.hasTemplateImage;
    result.hasText = scan.hasText;
    result.preserveColour = scan.hasChromaticContent ||
        CachedSnapshotHasChromaticContent(view);

    NSColor *colour = highlighted ? NSColor.whiteColor : NSColor.blackColor;
    ApplySelectiveTint(view, colour);

    /*
     * Las vistas de Control Center dibujan sus símbolos monocromos dentro de
     * SwiftUI y normalmente no exponen un NSImageView que podamos teñir.
     * Para esas vistas Apple conocidas sí se permite el filtro completo.
     *
     * NSStatusItemReplicantView y NSStatusItemHostingView pueden contener una
     * réplica remota de un icono perteneciente a una aplicación externa. Su
     * contenido original no siempre está disponible como NSImage o CGImage,
     * por lo que una captura puede parecer monocromática aunque el icono tenga
     * color. Nunca se debe aplicar CIFalseColor a esas vistas completas.
     */
    BOOL isAppleControlCenterStatusItem =
        IsKnownAppleMonochromeStatusItem(view);

    BOOL shouldUseWholeViewFilter =
        !highlighted &&
        !result.preserveColour &&
        isAppleControlCenterStatusItem;

    // The hosted Clock is SwiftUI: contentTintColor does not recolour its
    // glyphs. Only tint its foreground view, never the content view containing
    // the blue sibling underlay or a third-party coloured status item.
    BOOL whiteClock = highlighted && isAppleControlCenterStatusItem &&
        [view.window.title isEqualToString:@"Clock"] &&
        view != view.window.contentView;

    if (shouldUseWholeViewFilter || whiteClock) view.wantsLayer = YES;
    result.filterCount =
        SetMonochromeFilterEnabled(view, shouldUseWholeViewFilter || whiteClock, whiteClock);
    return result;
}

static void SeedStatusItemView(NSView *view, NSString *phase) {
    if (!IsAttachedStatusItemView(view)) return;
    BOOL highlighted = StatusItemHasVisibleBlueUnderlay(view);
    SLStatusRefreshResult result =
        RefreshStatusItemAppearance(view, highlighted);
    if (SeedLogCount++ < 24) {
        SLLog([NSString stringWithFormat:
            @"system-status seed phase=%@ view=%@ layer=%d preserveColour=%d "
             "template=%d text=%d filters=%lu",
            phase, NSStringFromClass(view.class), view.layer != nil,
            result.preserveColour, result.hasTemplateImage, result.hasText,
            (unsigned long)result.filterCount]);
    }
}

static void ScheduleColourClassification(NSView *view, NSString *phase,
                                         NSTimeInterval delay) {
    if (!SLStatusSnapshotAllowed(IsAttachedStatusItemView(view), CapturingStatusItemSnapshot,
                                 NSBundle.mainBundle.bundleIdentifier) ||
        objc_getAssociatedObject(view, ColourScanPendingKey)) {
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *lastValue = objc_getAssociatedObject(view, LastColourScanTimeKey);
    if (lastValue && now - lastValue.doubleValue < 5.0) return;

    objc_setAssociatedObject(view, ColourScanPendingKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak NSView *weakView = view;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(delay * (NSTimeInterval)NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            NSView *strongView = weakView;
            if (!strongView) return;
            if (!IsAttachedStatusItemView(strongView)) {
                objc_setAssociatedObject(strongView, ColourScanPendingKey, nil, OBJC_ASSOCIATION_ASSIGN);
                return;
            }

            @autoreleasepool {
            BOOL hasColour =
                CaptureViewContainsChromaticContent(strongView);
            objc_setAssociatedObject(
                strongView, SnapshotHasChromaticContentKey, @(hasColour),
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(
                strongView, LastColourScanTimeKey,
                @(CACurrentMediaTime()),
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            SLStatusRefreshResult result = RefreshStatusItemAppearance(
                strongView,
                StatusItemHasVisibleBlueUnderlay(strongView));
            objc_setAssociatedObject(strongView, ColourScanPendingKey, nil, OBJC_ASSOCIATION_ASSIGN);
            if (ColourScanLogCount++ < 24) {
                SLLog([NSString stringWithFormat:
                    @"system-status colour-scan phase=%@ view=%@ colour=%d "
                     "preserveColour=%d filters=%lu",
                    phase, NSStringFromClass(strongView.class), hasColour,
                    result.preserveColour,
                    (unsigned long)result.filterCount]);
            }
            }
        });
}

static void SetSnowLeopardStatusBarView(id window, SEL selector,
                                        NSView *itemView) {
    OriginalSetStatusBarView(window, selector, itemView);
    if (SLIsSpotlightRightMarginWindow(itemView.window)) return;
    SLStatusIconReplacementSetHighlighted(itemView, NO);
    SeedStatusItemView(itemView, @"attached");
    ScheduleColourClassification(itemView, @"attached", 0.05);
    __weak NSView *weakItemView = itemView;
    dispatch_async(dispatch_get_main_queue(), ^{
        SeedStatusItemView(weakItemView, @"next-runloop");
    });
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
            SeedStatusItemView(weakItemView, @"100ms");
            ScheduleColourClassification(weakItemView, @"100ms", 0.0);
        });
}

static NSUInteger SeedExistingStatusWindows(NSString *phase) {
    if (!StatusBarWindowClass || !StatusViewIvar) return 0;
    NSUInteger count = 0;
    for (NSWindow *window in NSApp.windows.copy) {
        if (![window isKindOfClass:StatusBarWindowClass]) continue;
        if (SLIsSpotlightRightMarginWindow(window)) continue;
        NSView *statusView = object_getIvar(window, StatusViewIvar);
        if (!statusView) continue;
        SeedStatusItemView(statusView, phase);
        ScheduleColourClassification(statusView, phase, 0.05);
        count++;
    }
    return count;
}

// SLRightStatusSelectionUnderlay
//
// Cada elemento derecho vive en su propio NSStatusBarWindow.
// Sequoia conserva su geometría host nativa; la vista SwiftUI y su selección
// usan los bounds reales entregados por NSStatusBarWindow.
//
// Esta vista dibuja el gradiente Snow Leopard directamente sobre
// NSStatusBarContentView y se coloca debajo del icono. No depende
// del contexto gráfico privado ni del rectángulo de ancho negativo.

@interface SLSnowLeopardRightSelectionView : NSView
@end

@implementation SLSnowLeopardRightSelectionView

- (BOOL)isOpaque {
    return YES;
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

static char SLRightSelectionViewKey;

static SLSnowLeopardRightSelectionView *
SLRightSelectionViewForStatusItem(
    NSView *statusItemView,
    BOOL create
) {
    if (!statusItemView) {
        return nil;
    }

    NSWindow *window =
        statusItemView.window;

    if (SLIsSpotlightRightMarginWindow(window)) {
        return nil;
    }

    NSView *contentView =
        window.contentView;

    if (!window ||
        !contentView ||
        ![NSStringFromClass(window.class)
            isEqualToString:
                @"NSStatusBarWindow"] ||
        ![NSStringFromClass(contentView.class)
            isEqualToString:
                @"NSStatusBarContentView"]) {
        return nil;
    }

    id existing =
        objc_getAssociatedObject(
            contentView,
            &SLRightSelectionViewKey);

    if ([existing
            isKindOfClass:
                SLSnowLeopardRightSelectionView.class]) {
        return existing;
    }

    if (!create) {
        return nil;
    }

    SLSnowLeopardRightSelectionView *selectionView =
        [[SLSnowLeopardRightSelectionView alloc]
            initWithFrame:contentView.bounds];

    selectionView.autoresizingMask =
        NSViewWidthSizable |
        NSViewHeightSizable;

    selectionView.hidden = YES;
    selectionView.alphaValue = 1.0;
    selectionView.wantsLayer = YES;

    selectionView.layer.cornerRadius =
        0.0;

    selectionView.layer.masksToBounds =
        NO;

    NSView *iconContainer =
        contentView.subviews.firstObject;

    if (iconContainer) {
        [contentView
            addSubview:selectionView
            positioned:NSWindowBelow
            relativeTo:iconContainer];
    } else {
        [contentView
            addSubview:selectionView];
    }

    objc_setAssociatedObject(
        contentView,
        &SLRightSelectionViewKey,
        selectionView,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    SLLog(
        [NSString stringWithFormat:
            @"right selection underlay created "
             "process=%@ window=%ld frame=%@",
            NSProcessInfo.processInfo.processName,
            (long)window.windowNumber,
            NSStringFromRect(contentView.bounds)]);

    return selectionView;
}

static BOOL SLSetRightSelectionVisible(
    NSView *statusItemView,
    BOOL highlighted
) {
    if (SLIsSpotlightRightMarginWindow(statusItemView.window)) {
        return NO;
    }
    SLStatusIconReplacementSetHighlighted(
        statusItemView,
        highlighted);

    SLSnowLeopardRightSelectionView *selectionView =
        SLRightSelectionViewForStatusItem(
            statusItemView,
            highlighted);

    if (!selectionView) {
        return NO;
    }

    NSView *contentView =
        selectionView.superview;

    if (!contentView) {
        return NO;
    }

    selectionView.frame =
        contentView.bounds;

    if (!highlighted) {
        selectionView.hidden = YES;
        return YES;
    }

    selectionView.hidden = NO;

    [selectionView
        setNeedsDisplay:YES];

    [selectionView
        displayIfNeeded];

    return YES;
}

// SLHostedAndClockSelectionPersistence
//
// Hay dos rutas que no conservan el estado highlighted normal:
//
// 1. Los status items de terceros alojados por Control Center usan
//    NSStatusItemHostingView y reciben directamente mouseDown:.
//
// 2. Clock devuelve highlighted=NO antes de que aparezca la ventana
//    de Notification Center.
//
// Este bloque conserva la vista azul ya existente y solamente añade
// la detección correcta de duración para esas dos rutas.

typedef void (*SLHostedMouseEventFunction)(
    id,
    SEL,
    NSEvent *
);

static SLHostedMouseEventFunction
    SLOriginalHostedMouseDown = NULL;

static __weak NSView *
    SLActiveHostedStatusView = nil;

static NSTimeInterval
    SLHostedSelectionStartedAt = 0.0;

static id
    SLHostedGlobalMouseMonitor = nil;

static id
    SLHostedLocalMouseMonitor = nil;

static id
    SLHostedLocalKeyMonitor = nil;

static id
    SLHostedCoordinationObserver = nil;

static NSUInteger
    SLSpotlightPanelWatchGeneration = 0;
static dispatch_source_t SLSpotlightPanelWatchTimer;
static NSTimeInterval SLSpotlightPanelWatchCurrentInterval;
static NSMutableArray *SLSpotlightPanelWatchObservers;

static BOOL
    SLSpotlightPanelWasVisible = NO;

static __weak NSView *
    SLClockTrackedStatusView = nil;

static BOOL
    SLClockWatchActive = NO;

static BOOL
    SLClockPanelSeen = NO;

static NSTimeInterval
    SLClockGraceDeadline = 0.0;

static NSTimeInterval
    SLClockWatchStartedAt = 0.0;

static NSTimeInterval
    SLClockImmediateCloseSuppressUntil = 0.0;

static NSUInteger
    SLClockWatchGeneration = 0;

static void SLClearHostedStatusSelection(void);

static NSTimeInterval SLCurrentTime(void) {
    return
        NSDate.timeIntervalSinceReferenceDate;
}

static BOOL SLIsClockStatusView(
    NSView *view
) {
    if (!view.window) {
        return NO;
    }

    NSString *title =
        view.window.title;

    return
        [title isEqualToString:@"Clock"];
}

static BOOL SLNotificationCenterWindowFrame(
    NSRect *frameOut
) {
    if (frameOut) *frameOut = NSZeroRect;

    CFArrayRef rawWindows =
        CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly |
            kCGWindowListExcludeDesktopElements,
            kCGNullWindowID);

    if (!rawWindows) {
        return NO;
    }

    NSArray *windows =
        CFBridgingRelease(rawWindows);

    for (NSDictionary *dictionary in windows) {
        NSString *owner =
            dictionary[
                (__bridge NSString *)
                kCGWindowOwnerName
            ];

        NSString *name =
            dictionary[
                (__bridge NSString *)
                kCGWindowName
            ];

        NSNumber *layer =
            dictionary[
                (__bridge NSString *)
                kCGWindowLayer
            ];

        NSNumber *alpha =
            dictionary[
                (__bridge NSString *)
                kCGWindowAlpha
            ];

        NSDictionary *boundsDictionary =
            dictionary[
                (__bridge NSString *)
                kCGWindowBounds
            ];

        if (![owner
                isKindOfClass:NSString.class]) {
            owner = @"";
        }

        if (![name
                isKindOfClass:NSString.class]) {
            name = @"";
        }

        NSString *ownerLower =
            owner.lowercaseString;

        BOOL nameMatches =
            [name
                isEqualToString:
                    @"Notification Center"];

        BOOL ownerMatches =
            [ownerLower
                containsString:
                    @"notification"] ||
            [ownerLower
                containsString:
                    @"notificaciones"];

        BOOL layerMatches =
            !layer ||
            (
                layer.integerValue >= 20 &&
                layer.integerValue <= 30
            );

        BOOL alphaMatches =
            !alpha ||
            alpha.doubleValue > 0.01;

        if (
            (nameMatches || ownerMatches) &&
            layerMatches &&
            alphaMatches
        ) {
            if (frameOut &&
                [boundsDictionary
                    isKindOfClass:NSDictionary.class]) {
                CGRect quartzBounds = CGRectZero;
                if (CGRectMakeWithDictionaryRepresentation(
                        (__bridge CFDictionaryRef)
                            boundsDictionary,
                        &quartzBounds)) {
                    CGRect mainDisplay =
                        CGDisplayBounds(CGMainDisplayID());
                    *frameOut = NSMakeRect(
                        CGRectGetMinX(quartzBounds),
                        CGRectGetMaxY(mainDisplay) -
                            CGRectGetMaxY(quartzBounds),
                        CGRectGetWidth(quartzBounds),
                        CGRectGetHeight(quartzBounds));
                }
            }
            return YES;
        }
    }

    return NO;
}

static BOOL SLNotificationCenterIsVisible(void) {
    return SLNotificationCenterWindowFrame(NULL);
}

static BOOL SLPointIsInsideNotificationCenter(
    NSPoint screenPoint
) {
    NSRect frame = NSZeroRect;
    if (!SLNotificationCenterWindowFrame(&frame)) {
        return NO;
    }

    if (NSIsEmptyRect(frame)) {
        /* No apagues el reloj si Quartz no entregó bounds fiables. */
        return YES;
    }

    return NSPointInRect(
        screenPoint,
        NSInsetRect(frame, -8.0, -8.0));
}

static void SLApplyClockSelection(
    NSView *view,
    BOOL selected
) {
    if (!view) {
        return;
    }

    SLSetRightSelectionVisible(
        view,
        selected);

    (void)RefreshStatusItemAppearance(
        view,
        selected);

    if (!selected) {
        ScheduleColourClassification(
            view,
            @"clock-watch-close",
            0.05);
    }
}

static void SLClockWatchTick(
    NSUInteger generation
) {
    if (
        generation !=
            SLClockWatchGeneration ||
        !SLClockWatchActive
    ) {
        return;
    }

    NSView *view =
        SLClockTrackedStatusView;

    if (!view ||
        !view.window) {
        SLClockWatchActive = NO;
        SLClockWatchStartedAt = 0.0;
        SLClockTrackedStatusView = nil;
        return;
    }

    BOOL visible =
        SLNotificationCenterIsVisible();

    NSTimeInterval now =
        SLCurrentTime();

    if (visible) {
        BOOL firstVisible =
            !SLClockPanelSeen;

        SLClockPanelSeen = YES;

        SLApplyClockSelection(
            view,
            YES);

        if (firstVisible) {
            SLLog(
                @"clock notification visible=1");
        }

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(
                    0.02 *
                    NSEC_PER_SEC)),
            dispatch_get_main_queue(),
            ^{
                SLClockWatchTick(
                    generation);
            });

        return;
    }

    if (
        !SLClockPanelSeen &&
        now < SLClockGraceDeadline
    ) {
        SLApplyClockSelection(
            view,
            YES);

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(
                    0.10 *
                    NSEC_PER_SEC)),
            dispatch_get_main_queue(),
            ^{
                SLClockWatchTick(
                    generation);
            });

        return;
    }

    SLClockWatchActive = NO;
    SLClockPanelSeen = NO;
    SLClockWatchStartedAt = 0.0;
    SLClockTrackedStatusView = nil;

    if (SLActiveHostedStatusView == view) {
        SLClearHostedStatusSelection();
    } else {
        SLApplyClockSelection(
            view,
            NO);
    }

    SLLog(
        @"clock notification visible=0 immediate poll=20ms");
}

static void SLBeginClockNotificationWatch(
    NSView *view
) {
    if (!view) {
        return;
    }

    SLClockWatchGeneration++;

    NSUInteger generation =
        SLClockWatchGeneration;

    SLClockTrackedStatusView =
        view;

    SLClockWatchActive =
        YES;

    SLClockWatchStartedAt =
        SLCurrentTime();

    SLClockPanelSeen =
        SLNotificationCenterIsVisible();

    SLClockGraceDeadline =
        SLCurrentTime() + 0.35;

    SLApplyClockSelection(
        view,
        YES);

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(
                0.05 *
                NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            SLClockWatchTick(
                generation);
        });
}

static BOOL SLClockSelectionShouldPersist(
    NSView *view
) {
    return
        SLClockWatchActive &&
        view &&
        SLClockTrackedStatusView == view;
}

static void SLCancelClockSelectionExceptView(
    NSView *view
) {
    if (!SLClockWatchActive) {
        return;
    }

    NSView *trackedView =
        SLClockTrackedStatusView;

    if (view && trackedView == view) {
        return;
    }

    /* Invalidate every delayed tick before hiding the old clock underlay. */
    SLClockWatchGeneration++;
    SLClockWatchActive = NO;
    SLClockPanelSeen = NO;
    SLClockGraceDeadline = 0.0;
    SLClockWatchStartedAt = 0.0;
    SLClockTrackedStatusView = nil;

    if (trackedView) {
        SLApplyClockSelection(
            trackedView,
            NO);
    }

    SLLog(
        @"clock selection cancelled for status switch");
}

// SLHostedAppearanceDelegatedToOwner
//
// Control Center conserva el rectángulo azul y la duración de la
// selección. El proceso propietario recibe el estado lógico para
// volver blanco únicamente el texto, sin filtrar el CALayerHost.

static void SLSetHostedStatusSelection(
    NSView *view,
    BOOL selected
) {
    if (!view) return;

    SLSetRightSelectionVisible(
        view,
        selected);

    /*
     * Conserva la ruta visual existente como fallback, pero ya
     * no aplica CIFalseColor al contenido remoto completo.
     */
    (void)RefreshStatusItemAppearance(
        view,
        selected);

    SLPostExternalStatusSelection(view, selected);

    if (!selected) {
        ScheduleColourClassification(
            view,
            @"hosted-close",
            0.05);
    }

    SLLog([NSString stringWithFormat:
        @"hosted appearance delegated "
         "selected=%d window=%ld title=%@",
        selected,
        (long)view.window.windowNumber,
        view.window.title ?: @""]);
}

static void SLClearHostedStatusSelection(void) {
    NSView *view =
        SLActiveHostedStatusView;

    SLActiveHostedStatusView =
        nil;

    SLHostedSelectionStartedAt =
        0.0;

    if (view) {
        SLSetHostedStatusSelection(
            view,
            NO);

        SLLog(
            @"hosted selection active=0");
    }
}

static void SLInstallHostedCoordinationObserver(void) {
    if (SLHostedCoordinationObserver) return;
    SLHostedCoordinationObserver =
        [NSDistributedNotificationCenter.defaultCenter
            addObserverForName:SLExternalStatusSelectionNotificationName
            object:nil
            queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *notification) {
                NSDictionary *info = notification.userInfo;
                if (![info[@"selected"] boolValue]) return;
                pid_t sourcePID = (pid_t)[info[@"sourcePID"] intValue];
                if (sourcePID <= 0 || sourcePID == getpid()) return;

                SLCancelClockSelectionExceptView(nil);
                SLClearHostedStatusSelection();
                SLLog([NSString stringWithFormat:
                    @"right selection globally superseded "
                     "sourcePID=%d sourceBundle=%@ window=%@",
                    sourcePID,
                    info[@"sourceBundle"] ?: @"",
                    info[@"windowTitle"] ?: @""]);
            }];
}

static void SLClearHostedSelectionExceptWindow(
    NSWindow *window
) {
    NSView *active =
        SLActiveHostedStatusView;

    if (!active) {
        return;
    }

    if (window &&
        active.window == window) {
        return;
    }

    SLClearHostedStatusSelection();
}

static BOOL SLPointIsInsideActiveHostedWindow(
    NSPoint screenPoint
) {
    NSView *active =
        SLActiveHostedStatusView;

    NSWindow *window =
        active.window;

    return
        window &&
        NSPointInRect(
            screenPoint,
            window.frame);
}

static void SLHostedStatusMouseDown(
    id object,
    SEL selector,
    NSEvent *event
) {
    NSView *view =
        [object isKindOfClass:NSView.class]
        ? (NSView *)object
        : nil;

    BOOL wasAlreadyActive =
        view &&
        SLActiveHostedStatusView == view;

    if (wasAlreadyActive) {
        /*
         * El segundo clic sobre el mismo status item normalmente
         * cierra su menú.
         */
        SLClearHostedStatusSelection();
    } else if (view) {
        SLCancelClockSelectionExceptView(
            view);

        SLClearHostedStatusSelection();

        SLActiveHostedStatusView =
            view;

        SLHostedSelectionStartedAt =
            SLCurrentTime();

        SLSetHostedStatusSelection(
            view,
            YES);

        if (SLIsClockStatusView(view)) {
            SLBeginClockNotificationWatch(view);
        }

        SLLog(
            [NSString stringWithFormat:
                @"hosted selection active=1 "
                 "window=%ld title=%@ class=%@",
                (long)view.window.windowNumber,
                view.window.title ?: @"",
                NSStringFromClass(
                    view.class)]);
    }

    NSTimeInterval start =
        SLCurrentTime();

    SLOriginalHostedMouseDown(
        object,
        selector,
        event);

    NSTimeInterval elapsed =
        SLCurrentTime() - start;

    /*
     * Algunos status items hacen el seguimiento de NSMenu de forma
     * síncrona. En ese caso mouseDown: sólo regresa cuando el menú
     * ya se cerró.
     */
    if (
        !wasAlreadyActive &&
        view &&
        SLActiveHostedStatusView == view &&
        elapsed >= 0.75
    ) {
        SLClearHostedStatusSelection();
    }

    SLLog(
        [NSString stringWithFormat:
            @"hosted mouseDown returned elapsed=%.3f",
            elapsed]);
}

// SLHostedWindowHitTesting
//
// Los status items externos alojados mediante NSSceneHostingView y
// CALayerHost pueden recibir sus eventos en el proceso remoto, por
// lo que NSStatusItemHostingView mouseDown: no siempre se ejecuta
// dentro de Control Center.
//
// Los monitores de NSEvent sí permiten obtener la posición global.
// Con esa posición localizamos el NSStatusBarWindow correspondiente
// y activamos el mismo underlay azul que ya usan los iconos Apple.

static NSView *SLHostedStatusViewForWindow(
    NSWindow *window
) {
    if (!window) {
        return nil;
    }

    if (SLIsSpotlightRightMarginWindow(window)) {
        return nil;
    }

    Class statusWindowClass =
        NSClassFromString(
            @"NSStatusBarWindow");

    if (
        !statusWindowClass ||
        ![window
            isKindOfClass:
                statusWindowClass]
    ) {
        return nil;
    }

    Ivar statusViewIvar =
        class_getInstanceVariable(
            [window class],
            "_statusView");

    if (!statusViewIvar) {
        statusViewIvar =
            class_getInstanceVariable(
                statusWindowClass,
                "_statusView");
    }

    if (!statusViewIvar) {
        return nil;
    }

    const char *type =
        ivar_getTypeEncoding(
            statusViewIvar);

    if (!type ||
        type[0] != '@') {
        return nil;
    }

    id value =
        object_getIvar(
            window,
            statusViewIvar);

    if (![value isKindOfClass:NSView.class]) {
        return nil;
    }

    // The validated _statusView is authoritative for every right-side item.
    // Restricting this to NSStatusItemHostingView omitted Apple items hosted
    // by SystemUIServer and some SwiftUI-backed Control Center items.
    return (NSView *)value;
}

static NSView *SLHostedStatusViewAtScreenPoint(
    NSPoint screenPoint
) {
    NSArray<NSWindow *> *windows =
        NSApp.windows.copy;

    for (NSWindow *window in windows) {
        if (
            !window.visible ||
            window.alphaValue <= 0.01 ||
            !NSPointInRect(
                screenPoint,
                NSInsetRect(
                    window.frame,
                    0.0,
                    -1.0))
        ) {
            continue;
        }

        NSView *statusView =
            SLHostedStatusViewForWindow(
                window);

        if (statusView) {
            return statusView;
        }
    }

    return nil;
}

static void SLActivateHostedStatusViewFromScreen(
    NSView *view
) {
    if (!view ||
        !view.window) {
        return;
    }

    SLCancelClockSelectionExceptView(
        view);

    if (
        SLActiveHostedStatusView &&
        SLActiveHostedStatusView != view
    ) {
        SLClearHostedStatusSelection();
    }

    if (SLActiveHostedStatusView == view) {
        return;
    }

    SLActiveHostedStatusView =
        view;

    SLHostedSelectionStartedAt =
        SLCurrentTime();

    SLSetHostedStatusSelection(
        view,
        YES);

    if (SLIsClockStatusView(view)) {
        SLBeginClockNotificationWatch(view);
    }

    SLLog(
        [NSString stringWithFormat:
            @"hosted selection active=1 "
             "source=screen-hit "
             "window=%ld title=%@ "
             "class=%@ frame=%@",
            (long)view.window.windowNumber,
            view.window.title ?: @"",
            NSStringFromClass(view.class),
            NSStringFromRect(
                view.window.frame)]);
}

static NSView *SLSpotlightStatusView(void) {
    for (NSWindow *window in NSApp.windows.copy) {
        if (![window.title isEqualToString:@"Item-0"]) {
            continue;
        }

        NSView *view =
            SLHostedStatusViewForWindow(window);
        if (view) return view;
    }

    return nil;
}

static BOOL SLSpotlightPanelIsVisible(void) {
    for (NSWindow *window in NSApp.windows.copy) {
        if (!window.visible ||
            window.alphaValue <= 0.01 ||
            SLHostedStatusViewForWindow(window)) {
            continue;
        }

        NSRect frame = window.frame;
        if (NSWidth(frame) >= 100.0 &&
            NSHeight(frame) >= 50.0) {
            return YES;
        }
    }

    return NO;
}

static void SLSpotlightPanelWatchTick(
    NSUInteger generation
) {
    if (generation != SLSpotlightPanelWatchGeneration ||
        ![NSBundle.mainBundle.bundleIdentifier
            isEqualToString:SLBundleIDSpotlight]) {
        return;
    }

    BOOL visible = SLSpotlightPanelIsVisible();
    NSView *statusView = SLSpotlightStatusView();

    if (visible && statusView) {
        if (SLActiveHostedStatusView != statusView) {
            SLActivateHostedStatusViewFromScreen(statusView);
        }
    } else if (!visible &&
               SLActiveHostedStatusView == statusView) {
        SLClearHostedStatusSelection();
    }

    if (visible != SLSpotlightPanelWasVisible) {
        SLLog([NSString stringWithFormat:
            @"spotlight panel selection source=window-visibility "
             "visible=%d",
            visible]);
        SLSpotlightPanelWasVisible = visible;
    }

    NSTimeInterval interval = SLSpotlightWatchInterval(visible, NSApp.isActive);
    if (SLSpotlightPanelWatchTimer && interval != SLSpotlightPanelWatchCurrentInterval) {
        SLSpotlightPanelWatchCurrentInterval = interval;
        uint64_t nanos = (uint64_t)(interval * NSEC_PER_SEC);
        dispatch_source_set_timer(SLSpotlightPanelWatchTimer,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)nanos), nanos,
            (uint64_t)(0.1 * nanos));
    }
}

static void SLStartSpotlightPanelWatch(void) {
    if (SLSpotlightPanelWatchTimer) return;
    SLSpotlightPanelWatchGeneration++;
    NSUInteger generation =
        SLSpotlightPanelWatchGeneration;
    SLSpotlightPanelWasVisible =
        SLSpotlightPanelIsVisible();

    SLSpotlightPanelWatchTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
        0, 0, dispatch_get_main_queue());
    if (!SLSpotlightPanelWatchTimer) return;
    dispatch_source_set_event_handler(SLSpotlightPanelWatchTimer, ^{
        @autoreleasepool { SLSpotlightPanelWatchTick(generation); }
    });
    SLSpotlightPanelWatchCurrentInterval = 0;
    SLSpotlightPanelWatchTick(generation);
    dispatch_resume(SLSpotlightPanelWatchTimer);
    SLSpotlightPanelWatchObservers = [NSMutableArray array];
    for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification,
             NSWindowDidResignKeyNotification, NSApplicationDidBecomeActiveNotification,
             NSApplicationDidResignActiveNotification, NSWindowWillCloseNotification]) {
        [SLSpotlightPanelWatchObservers addObject:[NSNotificationCenter.defaultCenter
            addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    @autoreleasepool { SLSpotlightPanelWatchTick(generation); }
                });
            }]];
    }
    SLLog(@"spotlight keyboard selection watcher active adaptive=50ms-active-500ms-idle");
}

static void SLHandleHostedMouseAtScreenPoint(
    NSPoint screenPoint
) {
    NSView *candidate =
        SLHostedStatusViewAtScreenPoint(
            screenPoint);

    NSView *active =
        SLActiveHostedStatusView;

    NSTimeInterval elapsed =
        active
        ? (
            SLCurrentTime() -
            SLHostedSelectionStartedAt
        )
        : 0.0;

    NSTimeInterval clockElapsed =
        SLClockWatchStartedAt > 0.0
        ? SLCurrentTime() - SLClockWatchStartedAt
        : 0.0;

    if (candidate) {
        if (SLIsClockStatusView(candidate) &&
            SLCurrentTime() <
                SLClockImmediateCloseSuppressUntil) {
            return;
        }

        if (SLIsClockStatusView(candidate) &&
            SLClockWatchActive &&
            SLClockPanelSeen &&
            clockElapsed >= 0.12) {
            SLClockImmediateCloseSuppressUntil =
                SLCurrentTime() + 0.20;
            SLCancelClockSelectionExceptView(nil);
            if (active == candidate) {
                SLClearHostedStatusSelection();
            }
            SLLog(
                @"clock selection immediate close trigger=clock-toggle");
            return;
        }

        if (active == candidate) {
            /*
             * Ignora la segunda ruta del mismo clic inicial.
             * Un clic posterior sobre el mismo icono cierra
             * normalmente su menú y retira el azul.
             */
            if (elapsed >= 0.35) {
                SLClearHostedStatusSelection();
            }

            return;
        }

        SLActivateHostedStatusViewFromScreen(
            candidate);

        return;
    }

    if (SLClockWatchActive &&
        SLClockPanelSeen &&
        !SLPointIsInsideNotificationCenter(screenPoint)) {
        NSView *clockView = SLClockTrackedStatusView;
        SLCancelClockSelectionExceptView(nil);
        if (active == clockView) {
            SLClearHostedStatusSelection();
        }
        SLLog(
            @"clock selection immediate close trigger=outside-click");
    }

    if (
        active &&
        elapsed >= 0.20 &&
        !SLPointIsInsideActiveHostedWindow(
            screenPoint)
    ) {
        SLClearHostedStatusSelection();
    }
}

static void SLInstallHostedMouseMonitors(void) {
    NSEventMask mask =
        NSEventMaskLeftMouseDown |
        NSEventMaskRightMouseDown |
        NSEventMaskOtherMouseDown;

    if (!SLHostedLocalMouseMonitor) {
        SLHostedLocalMouseMonitor =
            [NSEvent
                addLocalMonitorForEventsMatchingMask:
                    mask
                handler:^NSEvent *(NSEvent *event) {
                    NSPoint screenPoint =
                        NSEvent.mouseLocation;

                    SLHandleHostedMouseAtScreenPoint(
                        screenPoint);

                    return event;
                }];
    }

    if (!SLHostedGlobalMouseMonitor) {
        SLHostedGlobalMouseMonitor =
            [NSEvent
                addGlobalMonitorForEventsMatchingMask:
                    mask
                handler:^(NSEvent *event) {
                    (void)event;

                    NSPoint screenPoint =
                        NSEvent.mouseLocation;

                    dispatch_async(
                        dispatch_get_main_queue(),
                        ^{
                            SLHandleHostedMouseAtScreenPoint(
                                screenPoint);
                        });
                }];
    }

    if (!SLHostedLocalKeyMonitor) {
        SLHostedLocalKeyMonitor = [NSEvent
            addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
            handler:^NSEvent *(NSEvent *event) {
                if (event.keyCode == 53 &&
                    SLClockWatchActive) {
                    NSView *clockView =
                        SLClockTrackedStatusView;
                    SLCancelClockSelectionExceptView(nil);
                    if (SLActiveHostedStatusView == clockView) {
                        SLClearHostedStatusSelection();
                    }
                    SLLog(
                        @"clock selection immediate close trigger=escape");
                }
                return event;
            }];
    }

    SLInstallHostedCoordinationObserver();

    SLLog(
        @"hosted window hit-testing active");
}

static void SLInstallHostedStatusSelectionHooks(void) {
    NSString *bundleID =
        NSBundle.mainBundle.bundleIdentifier;

    BOOL isControlCenter =
        [bundleID isEqualToString:SLBundleIDControlCenter];
    BOOL isSystemUIServer =
        [bundleID isEqualToString:SLBundleIDSystemUIServer];
    BOOL isSpotlight =
        [bundleID isEqualToString:SLBundleIDSpotlight];

    if (!isControlCenter && !isSystemUIServer && !isSpotlight) {
        return;
    }

    Class hostingClass =
        NSClassFromString(
            @"NSStatusItemHostingView");

    Method mouseDownMethod =
        hostingClass
        ? class_getInstanceMethod(
            hostingClass,
            @selector(mouseDown:))
        : NULL;

    /* The screen-space monitor is Sequoia's primary path and must not depend
     * on the Tahoe-era NSStatusItemHostingView class. */
    SLInstallHostedMouseMonitors();

    if (isSpotlight) {
        SLStartSpotlightPanelWatch();
    }

    SLLog(
        @"all right status items blue-selection=enabled");

    if (!isControlCenter || !mouseDownMethod) {
        SLLog(
            @"hosted status mouse hook unavailable; "
             "sequoia monitor fallback active");

        SLLog(
            @"clock notification watch active");

        return;
    }

    IMP current =
        method_getImplementation(
            mouseDownMethod);

    if (current !=
        (IMP)SLHostedStatusMouseDown) {
        SLOriginalHostedMouseDown =
            (SLHostedMouseEventFunction)
                current;

        method_setImplementation(
            mouseDownMethod,
            (IMP)SLHostedStatusMouseDown);
    }

    SLLog(
        @"hosted status mouse hook active");

    SLLog(
        @"clock notification watch active");
}

static void DrawSnowLeopardStatusBackground(
    id statusBar,
    SEL selector,
    NSRect *rect,
    NSView *view,
    BOOL highlighted
) {
    NSRect entryRect =
        rect
        ? *rect
        : NSZeroRect;

    /*
     * La cápsula moderna permanece desactivada.
     * El estado real se usa solamente para nuestro underlay.
     */
    OriginalDrawStatusBackground(
        statusBar,
        selector,
        rect,
        view,
        NO);

    if (CapturingStatusItemSnapshot) {
        return;
    }

    BOOL effectiveHighlighted =
        highlighted;

    if (view) {
        if (highlighted) {
            SLCancelClockSelectionExceptView(
                view);
        }

        if (SLIsClockStatusView(view)) {
            /*
             * SwiftUI puede dejar highlighted=YES después de cerrar
             * Notification Center. Para Clock sólo son válidos el clic
             * capturado y la vigilancia de la ventana real.
             */
            effectiveHighlighted =
                SLClockSelectionShouldPersist(view) ||
                SLActiveHostedStatusView == view;
        }

        /*
         * Sequoia resets AppKit's highlighted bit as soon as a SwiftUI
         * popover takes focus. Keep only the item selected by the mouse
         * monitor blue until the next status click or an outside click.
         */
        if (SLActiveHostedStatusView == view) {
            effectiveHighlighted =
                YES;
        }

        if (highlighted) {
            SLClearHostedSelectionExceptWindow(
                view.window);
        }
    }

    SLStatusRefreshResult result =
        {0};

    BOOL underlayReady =
        NO;

    if (view) {
        underlayReady =
            SLSetRightSelectionVisible(
                view,
                effectiveHighlighted);

        result =
            RefreshStatusItemAppearance(
                view,
                effectiveHighlighted);

        if (!effectiveHighlighted) {
            ScheduleColourClassification(
                view,
                @"draw",
                0.05);
        }
    }

    if (DrawLogCount++ < 96) {
        NSString *viewClass =
            view
            ? NSStringFromClass(view.class)
            : @"nil";

        SLLog(
            [NSString stringWithFormat:
                @"system-status draw highlighted=%d "
                 "effective=%d view=%@ "
                 "layer=%d preserveColour=%d "
                 "template=%d text=%d filters=%lu "
                 "underlay=%d entry=%@",
                highlighted,
                effectiveHighlighted,
                viewClass,
                view.layer != nil,
                result.preserveColour,
                result.hasTemplateImage,
                result.hasText,
                (unsigned long)result.filterCount,
                underlayReady,
                NSStringFromRect(entryRect)]);
    }
}

static void ScheduleExistingStatusWindowSeeds(void) {
    SeedExistingStatusWindows(@"existing-now");
    dispatch_async(dispatch_get_main_queue(), ^{
        SeedExistingStatusWindows(@"existing-next-runloop");
    });
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
            SeedExistingStatusWindows(@"existing-250ms");
        });
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            SeedExistingStatusWindows(@"existing-1s");
        });
}

static void StartStatusAppearanceMonitor(void) {
    if (StatusAppearanceTimer) return;

    StatusAppearanceTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER,
        0,
        0,
        dispatch_get_main_queue());
    if (!StatusAppearanceTimer) return;

    dispatch_source_set_timer(
        StatusAppearanceTimer,
        dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
        500 * NSEC_PER_MSEC,
        50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(StatusAppearanceTimer, ^{
        @autoreleasepool { SeedExistingStatusWindows(@"continuous-monitor"); }
    });
    dispatch_resume(StatusAppearanceTimer);
    SLLog(@"statusAppearance=continuous-black-monochrome-v2 interval=500ms");
}

static void RefreshClockOrderingState(NSString *reason) {
    if (![NSBundle.mainBundle.bundleIdentifier
            isEqualToString:SLBundleIDControlCenter]) {
        return;
    }

    Class statusWindowClass = NSClassFromString(@"NSStatusBarWindow");
    SEL statusItemSelector = NSSelectorFromString(@"statusItem");
    SEL autosaveNameSelector = NSSelectorFromString(@"autosaveName");
    SEL restoreSelector = NSSelectorFromString(
        @"_restorePreferencesFromAutosaveName");
    SEL preferredSelector = NSSelectorFromString(@"_preferredPosition");
    SEL updateFlagsSelector = NSSelectorFromString(@"_updateItemFlags");
    SEL updateReplicantsSelector = NSSelectorFromString(@"_updateReplicants");
    SEL moveSelector = NSSelectorFromString(
        @"_moveToScreenContainingActiveMenuBar");

    for (NSWindow *window in NSApp.windows.copy) {
        if (!statusWindowClass ||
            ![window isKindOfClass:statusWindowClass] ||
            ![window respondsToSelector:statusItemSelector]) {
            continue;
        }

        id statusItem = ((id (*)(id, SEL))objc_msgSend)(
            window, statusItemSelector);
        if (!statusItem) continue;

        NSString *autosaveName =
            [statusItem respondsToSelector:autosaveNameSelector]
                ? ((id (*)(id, SEL))objc_msgSend)(
                    statusItem, autosaveNameSelector)
                : nil;
        BOOL isClock = [window.title isEqualToString:@"Clock"] ||
            [autosaveName isEqualToString:@"Clock"];
        if (!isClock) continue;

        /*
         * The status item exists before Ammonia injects the Unified dylib. Reload
         * its saved order and resend the item flags after _systemClock has
         * been neutralised; otherwise the already-published CGS item remains
         * hard-pinned at the physical right edge for the entire process.
         */
        if ([statusItem respondsToSelector:restoreSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(statusItem, restoreSelector);
        }
        if ([statusItem respondsToSelector:updateFlagsSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(statusItem, updateFlagsSelector);
        }
        if ([statusItem respondsToSelector:updateReplicantsSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(
                statusItem, updateReplicantsSelector);
        }
        if ([statusItem respondsToSelector:moveSelector]) {
            (void)((id (*)(id, SEL))objc_msgSend)(statusItem, moveSelector);
        }

        float preferred = -1.0f;
        if ([statusItem respondsToSelector:preferredSelector]) {
            preferred = ((float (*)(id, SEL))objc_msgSend)(
                statusItem, preferredSelector);
        }
        if (ClockOrderingLogCount++ < 12) {
            SLLog([NSString stringWithFormat:
                @"clock ordering state refreshed preferred=%.0f "
                 "autosave=%@ reason=%@ frame=%@",
                preferred,
                autosaveName ?: @"nil",
                reason ?: @"unknown",
                NSStringFromRect(window.frame)]);
        }
        break;
    }
}

static void ScheduleClockOrderingRefresh(void) {
    RefreshClockOrderingState(@"install");
    NSArray<NSNumber *> *delays = @[@0.05, @0.30, @1.00];
    for (NSNumber *delay in delays) {
        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                RefreshClockOrderingState(
                    [NSString stringWithFormat:@"%@s", delay]);
            });
    }
}

static void InstallStatusHooks(void) {
    if (OriginalDrawStatusBackground || OriginalSetStatusBarView ||
        !IsExactAllowedProcess()) {
        return;
    }

    SystemStatusBarClass = NSClassFromString(@"NSSystemStatusBar");
    StatusBarWindowClass = NSClassFromString(@"NSStatusBarWindow");
    if (!SystemStatusBarClass || !StatusBarWindowClass) {
        SLLog(@"system-status install aborted: AppKit classes unavailable");
        return;
    }

    SEL drawSelector = NSSelectorFromString(
        @"drawBackgroundInRect:inView:highlight:");
    Method drawMethod =
        SLOwnInstanceMethod(SystemStatusBarClass, drawSelector);
    SEL setViewSelector = NSSelectorFromString(@"setStatusBarView:");
    Method setViewMethod =
        SLOwnInstanceMethod(StatusBarWindowClass, setViewSelector);
    const char *drawEncoding =
        drawMethod ? method_getTypeEncoding(drawMethod) : NULL;
    const char *setViewEncoding =
        setViewMethod ? method_getTypeEncoding(setViewMethod) : NULL;
    StatusViewIvar =
        SLOwnInstanceVariable(StatusBarWindowClass, "_statusView");
    const char *statusViewType =
        StatusViewIvar ? ivar_getTypeEncoding(StatusViewIvar) : NULL;

    if (!drawEncoding || strcmp(drawEncoding,
            "v36@0:8^{CGRect={CGPoint=dd}{CGSize=dd}}16@24B32") != 0 ||
        !setViewEncoding || strcmp(setViewEncoding, "v24@0:8@16") != 0 ||
        !statusViewType || strcmp(statusViewType, "@\"NSView\"") != 0 ||
        class_getSuperclass(StatusBarWindowClass) != NSWindow.class) {
        SLLog(@"system-status install aborted: unexpected AppKit ABI");
        return;
    }

    OriginalSetStatusBarView =
        (SetStatusBarViewFn)method_getImplementation(setViewMethod);
    OriginalDrawStatusBackground =
        (DrawStatusBackgroundFn)method_getImplementation(drawMethod);
    if (!OriginalSetStatusBarView || !OriginalDrawStatusBackground) return;

    method_setImplementation(
        setViewMethod, (IMP)SetSnowLeopardStatusBarView);
    method_setImplementation(
        drawMethod, (IMP)DrawSnowLeopardStatusBackground);
    SLLog([NSString stringWithFormat:
        @"system-status install process=%@ bundle=%@ pid=%d installed=1",
        NSProcessInfo.processInfo.processName,
        NSBundle.mainBundle.bundleIdentifier, getpid()]);
    SLLog(@"right selection underlay active geometry=sequoia-native-untouched");
    if ([NSBundle.mainBundle.bundleIdentifier
            isEqualToString:SLBundleIDSpotlight]) {
        SLLog(@"spotlight selected icon white single-pass active template-only");
    }
    ScheduleExistingStatusWindowSeeds();
    StartStatusAppearanceMonitor();
    SLLog(@"performance spotlightSnapshots=off layerColourCache=last-image tintWrites=on-change spotlightWatch=adaptive");
    ScheduleClockOrderingRefresh();
}

static BOOL SnowLeopardStatusItemSystemClock(id statusItem, SEL selector) {
    (void)statusItem;
    (void)selector;
    // Disable AppKit's special clock pin so the normal preferred-position
    // ordering can place Clock/date immediately to the left of Spotlight.
    return NO;
}

static BOOL SnowLeopardStatusItemAllowDragging(id statusItem, SEL selector) {
    (void)statusItem;
    (void)selector;
    return YES;
}

static float SnowLeopardStatusItemPreferredPosition(
    id statusItem,
    SEL selector
) {
    if ([statusItem respondsToSelector:@selector(autosaveName)]) {
        NSString *autosaveName = ((id (*)(id, SEL))objc_msgSend)(
            statusItem, @selector(autosaveName));
        if ([autosaveName isEqualToString:@"Clock"]) {
            return SL_CLOCK_RUNTIME_PREFERRED_POSITION;
        }
    }
    return OriginalStatusItemPreferredPosition
        ? OriginalStatusItemPreferredPosition(statusItem, selector)
        : 0.0f;
}

static void SnowLeopardStatusItemSetVisible(
    id statusItem,
    SEL selector,
    BOOL visible
) {
    NSString *autosaveName =
        [statusItem respondsToSelector:@selector(autosaveName)]
            ? ((id (*)(id, SEL))objc_msgSend)(
                statusItem, @selector(autosaveName))
            : nil;
    if ([autosaveName isEqualToString:@"BentoBox"]) {
        OriginalStatusItemSetVisible(statusItem, selector, NO);
        // Preserve enforcement without opening a log on every setter call.
        static NSUInteger hideLogCount;
        if (hideLogCount < 4) {
            hideLogCount++;
            SLLog(@"control center BentoBox hidden setVisible=0");
        }
        return;
    }
    OriginalStatusItemSetVisible(statusItem, selector, visible);
}

static void HideControlCenterBentoBox(NSString *reason) {
    if (![NSBundle.mainBundle.bundleIdentifier
            isEqualToString:SLBundleIDControlCenter] ||
        !OriginalStatusItemSetVisible) {
        return;
    }
    Class statusWindowClass = NSClassFromString(@"NSStatusBarWindow");
    SEL statusItemSelector = NSSelectorFromString(@"statusItem");
    for (NSWindow *window in NSApp.windows.copy) {
        if (!statusWindowClass ||
            ![window isKindOfClass:statusWindowClass] ||
            ![window respondsToSelector:statusItemSelector]) continue;
        id item = ((id (*)(id, SEL))objc_msgSend)(
            window, statusItemSelector);
        NSString *autosaveName =
            [item respondsToSelector:@selector(autosaveName)]
                ? ((id (*)(id, SEL))objc_msgSend)(
                    item, @selector(autosaveName))
                : nil;
        if (![autosaveName isEqualToString:@"BentoBox"]) continue;
        OriginalStatusItemSetVisible(item, @selector(setVisible:), NO);
        SLLog([NSString stringWithFormat:
            @"control center BentoBox hidden setVisible=0 reason=%@",
            reason ?: @"unknown"]);
        break;
    }
}

static void ScheduleControlCenterBentoBoxHide(void) {
    HideControlCenterBentoBox(@"install");
    NSArray<NSNumber *> *delays = @[@0.05, @0.30, @1.00];
    for (NSNumber *delay in delays) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                HideControlCenterBentoBox(
                    [NSString stringWithFormat:@"%@s", delay]);
            });
    }
}

static void InstallClockRightEdgeUnpin(void) {
    if (![NSBundle.mainBundle.bundleIdentifier
            isEqualToString:SLBundleIDControlCenter]) {
        return;
    }

    Class statusItemClass = NSClassFromString(@"NSStatusItem");
    Method systemClockMethod = SLOwnInstanceMethod(
        statusItemClass, NSSelectorFromString(@"_systemClock"));
    Method allowDraggingMethod = SLOwnInstanceMethod(
        statusItemClass, NSSelectorFromString(@"_allowItemDragging"));
    Method preferredPositionMethod = SLOwnInstanceMethod(
        statusItemClass, NSSelectorFromString(@"_preferredPosition"));
    Method setVisibleMethod = SLOwnInstanceMethod(
        statusItemClass, @selector(setVisible:));
    if (!systemClockMethod ||
        strcmp(method_getTypeEncoding(systemClockMethod), "B16@0:8") != 0 ||
        !allowDraggingMethod ||
        strcmp(method_getTypeEncoding(allowDraggingMethod), "B16@0:8") != 0 ||
        !preferredPositionMethod ||
        strcmp(method_getTypeEncoding(preferredPositionMethod), "f16@0:8") != 0 ||
        !setVisibleMethod ||
        strcmp(method_getTypeEncoding(setVisibleMethod), "v20@0:8B16") != 0) {
        SLLog(@"clock right-edge unpin aborted: unexpected AppKit ABI");
        return;
    }

    IMP current = method_getImplementation(systemClockMethod);
    if (current == (IMP)SnowLeopardStatusItemSystemClock) return;
    OriginalStatusItemPreferredPosition = (FloatNoArgFn)
        method_getImplementation(preferredPositionMethod);
    OriginalStatusItemSetVisible = (SetBoolValueFn)
        method_getImplementation(setVisibleMethod);
    method_setImplementation(
        systemClockMethod, (IMP)SnowLeopardStatusItemSystemClock);
    method_setImplementation(
        allowDraggingMethod, (IMP)SnowLeopardStatusItemAllowDragging);
    method_setImplementation(
        preferredPositionMethod,
        (IMP)SnowLeopardStatusItemPreferredPosition);
    method_setImplementation(
        setVisibleMethod,
        (IMP)SnowLeopardStatusItemSetVisible);
    SLLog([NSString stringWithFormat:
        @"clock layout override active preferred=%.0f drag=enabled",
        SL_CLOCK_RUNTIME_PREFERRED_POSITION]);
    ScheduleControlCenterBentoBoxHide();
}

__attribute__((constructor))
static void SnowLeopardSystemStatusItemsLoad(void) {
    if (!SLRuntimeIsMacOSSequoia() || !IsExactAllowedProcess()) return;
    InstallClockRightEdgeUnpin();
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{ InstallStatusHooks(); });
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{ SLInstallHostedStatusSelectionHooks(); });
}
