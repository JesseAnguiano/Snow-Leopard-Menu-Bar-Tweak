#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <limits.h>
#import <string.h>
#import <unistd.h>

#import "SnowLeopardEmbeddedAssets.h"
#import "Runtime.h"
#import "Protocol.h"
#import "SelectionRenderer.h"
#import "WallpaperWire.h"

const char SLSnowLeopardUnifiedCapabilities[] =
    "snowLeopardMenuBarUnified=modular-v2 "
    "compatibility=sequoia15 "
    "runtimeResources=0 "
    "selectionOwner=unified-top-status-blueSelection-popup-dock-sidebar "
    "resources=embedded wallpaper=shared-helper";

// Menu-bar core for the Unified dylib.
//
// This module does not load Glow, inspect Glow, or read a Glow theme. It owns
// only the application menu-bar surface: the NSMenuBarReplicantWindow
// background, NSMenuBarItemView title/image colours, the Apple item, and
// top-level menu selection. Popup and status-item behavior live in sibling
// modules that are linked into the same Unified dylib.

typedef id (*InitWithViewFn)(id, SEL, id);
typedef void (*SetColorFn)(id, SEL, NSColor *);
typedef void (*SetBoolFn)(id, SEL, BOOL);
typedef void (*DrawRectFn)(id, SEL, NSRect);
typedef void (*VoidFn)(id, SEL);
typedef void (*LayoutSizeFn)(id, SEL, NSSize);
typedef double (*DoubleFn)(id, SEL);
typedef NSColor *(*ColorFn)(id, SEL);
typedef void (*MenuHighlightFn)(id, SEL, BOOL, id);
typedef void (^ObjectBlock)(id);
typedef void (*ForEachObjectFn)(id, SEL, ObjectBlock);
typedef int (*SLMainConnectionIDFn)(void);
typedef CGError (*SLSetWindowBackgroundBlurRadiusFn)(int, int, int);

static InitWithViewFn OriginalReplicantInit = NULL;
static SetColorFn OriginalReplicantSetBackgroundColor = NULL;
static SetBoolFn OriginalReplicantSetOpaque = NULL;
static LayoutSizeFn OriginalBackingLayout = NULL;
static id (*OriginalRootBackingView)(id, SEL) = NULL;

static DrawRectFn OriginalMenuItemDrawRect = NULL;
static SetBoolFn OriginalMenuItemSetHighlighted = NULL;
static VoidFn OriginalMenuItemLayoutTitle = NULL;
static DoubleFn OriginalMenuItemIdealWidth = NULL;
static ColorFn OriginalTextColor = NULL;
static MenuHighlightFn OriginalMenuBarHighlight = NULL;
static VoidFn OriginalSelectionLayerDidChange = NULL;

static Class ReplicantWindowClass = Nil;
static Class ReplicantFrameClass = Nil;
static Class BackingViewClass = Nil;
static Class MenuBarItemViewClass = Nil;
static Class MenuBarImplClass = Nil;

typedef struct {
    Method initView;
    Method backgroundColor;
    Method opaque;
    Method frameDraw;
    Method frameOpaque;
    Method backingDraw;
    Method backingOpaque;
    Method backingLayout;
    Method rootBackingView;
} SLBackgroundHooks;

typedef struct {
    Method textColor;
    Method draw;
    Method updateAttributes;
    Method idealWidth;
    Method layoutTitle;
    Method highlighted;
} SLTitleHooks;

typedef struct {
    Method highlighted;
    Method selectionLayerChanged;
} SLSelectionHooks;

static SLBackgroundHooks BackgroundHooks;
static SLTitleHooks TitleHooks;
static SLSelectionHooks SelectionHooks;

static Ivar CachedLineIvar = NULL;
static Ivar CachedLineWidthIvar = NULL;
static Ivar DidTruncateLineIvar = NULL;
static Ivar AppleMenuIvar = NULL;
static Ivar ImageViewIvar = NULL;
static Ivar TitleTextFieldIvar = NULL;
static Ivar SelectionBackingViewIvar = NULL;

static BOOL BackgroundHooksInstalled = NO;
static BOOL TitleHooksInstalled = NO;
static BOOL SelectionHooksInstalled = NO;
typedef NS_ENUM(NSUInteger, SLCoreInstallState) {
    SLCoreInstallStateIdle = 0,
    SLCoreInstallStatePreparing,
    SLCoreInstallStateInstalled
};
static SLCoreInstallState CoreInstallState = SLCoreInstallStateIdle;
static NSUInteger InstallAttempt = 0;
static id ActivationObserver = nil;
static id MainMenuObserver = nil;
static NSTimer *WallpaperRefreshTimer = nil;
static char PreparedTitleKey;
static char FilmViewKey;
static char BackdropViewKey;
static char LiveBackdropConfiguredKey;

static char WindowBlurRadiusKey;
static NSHashTable<NSWindow *> *KnownMenuBarWindows;
static BOOL ConfiguringMenuBarBackdrops = NO;
static BOOL BackdropElectionScheduled = NO;
static BOOL NeedsWallpaperFilePolling = NO;

static __thread NSUInteger MenuTitleColourDepth = 0;
static __thread BOOL MenuTitleIsHighlighted = NO;
static const CGFloat SLSnowLeopardAppleMenuItemWidth = 35.0;

/*
 * Sequoia remains the owner of menu-bar height and vertical geometry. The
 * only measured horizontal correction is the 35-point Apple menu item.
 */
static const CGFloat SLSnowLeopardAppleCanvasSize = 22.0;
// The original 10.6 capture downsamples this 6016px wallpaper more strongly
// than a 2880px Retina capture does.  A small source-space blur restores the
// frosted-glass diffusion without erasing the wallpaper's colour.
static const CGFloat SLSnowLeopardWallpaperBlurRadius = 9.0;
static const CGFloat SLSnowLeopardWallpaperBrightness = 0.02;
static const CGFloat SLSnowLeopardWallpaperContrast = 1.15;
static const int SLSnowLeopardWindowServerBlurRadius = 3;

static SLMainConnectionIDFn SLMainConnectionID = NULL;
static SLSetWindowBackgroundBlurRadiusFn
    SLSetWindowBackgroundBlurRadius = NULL;

// Calibrated against the supplied 10.6 screenshot over the original Aurora
// wallpaper.  Snow Leopard varies vertically; opacity is uniform horizontally.
typedef struct {
    CGFloat filmScale;
    CGFloat sheenAlpha;
    BOOL horizontalOpacityEnabled;
    CGFloat leftOpacity;
    CGFloat middleOpacity;
    CGFloat rightOpacity;
} SLMenuBarFilmProfile;

// Every tunable belonging to the normal menu-bar material lives here. The
// film reaches both edges without adding separator rows.
static const SLMenuBarFilmProfile MenuBarFilmProfile = {
    .filmScale = 1.0,
    .sheenAlpha = 0.0,
    .horizontalOpacityEnabled = NO,
    .leftOpacity = 1.0,
    .middleOpacity = 1.0,
    .rightOpacity = 1.0
};
static CGGradientRef MenuBarGradient = NULL;

static CGColorRef MenuBarTopHighlightColor = NULL;
static CGGradientRef MenuBarOpacityGradient = NULL;

@interface SLSnowLeopardMenuBarFilmView : NSView
@end

@interface SLSnowLeopardMenuBarBackdropView : NSView
@end

static CGGradientRef CreateAlphaGradient(
    CGColorSpaceRef space,
    const CGFloat *locations,
    const CGFloat *alphas,
    NSUInteger count,
    CGFloat red,
    CGFloat green,
    CGFloat blue) {
    if (!space || !locations || !alphas || count == 0) return NULL;

    CGColorRef colours[count];
    for (NSUInteger index = 0; index < count; index++) {
        colours[index] = SLCreateSRGBColor(
            red, green, blue, alphas[index]);
    }
    CFArrayRef colourArray = CFArrayCreate(
        kCFAllocatorDefault,
        (const void **)colours,
        count,
        &kCFTypeArrayCallBacks);
    CGGradientRef gradient = CGGradientCreateWithColors(
        space, colourArray, locations);
    CFRelease(colourArray);
    for (NSUInteger index = 0; index < count; index++) {
        CGColorRelease(colours[index]);
    }
    return gradient;
}

static void PreparePalette(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        // Snow Leopard 10.6 composited material, measured in a colour-managed
        // comparison against the supplied 10.6 screenshot.  The original
        // compositor preserves considerably more chroma than a plain white
        // source-over film.  A behind-window adaptive backdrop now performs
        // the Core Image stage; these alphas form the measured Snow Leopard
        // film placed above it.
        //
        // The first Snow Leopard row is a separate one-physical-pixel highlight.
        // These twenty stops reproduce rows 1...20 and are stretched only over
        // the remaining native Sequoia bounds.
        CGFloat menuLocations[] = {
            0.000000000, 0.052631579, 0.105263158, 0.157894737,
            0.210526316, 0.263157895, 0.315789474, 0.368421053,
            0.421052632, 0.473684211, 0.526315789, 0.578947368,
            0.631578947, 0.684210526, 0.736842105, 0.789473684,
            0.842105263, 0.894736842, 0.947368421, 1.000000000
        };

        CGFloat menuAlphas[] = {
            0.83703 * MenuBarFilmProfile.filmScale,
            0.82264 * MenuBarFilmProfile.filmScale,
            0.80843 * MenuBarFilmProfile.filmScale,
            0.79406 * MenuBarFilmProfile.filmScale,
            0.77953 * MenuBarFilmProfile.filmScale,
            0.76442 * MenuBarFilmProfile.filmScale,
            0.74930 * MenuBarFilmProfile.filmScale,
            0.73393 * MenuBarFilmProfile.filmScale,
            0.71861 * MenuBarFilmProfile.filmScale,
            0.70359 * MenuBarFilmProfile.filmScale,
            0.68852 * MenuBarFilmProfile.filmScale,
            0.67296 * MenuBarFilmProfile.filmScale,
            0.65747 * MenuBarFilmProfile.filmScale,
            0.64130 * MenuBarFilmProfile.filmScale,
            0.62398 * MenuBarFilmProfile.filmScale,
            0.60799 * MenuBarFilmProfile.filmScale,
            0.59552 * MenuBarFilmProfile.filmScale,
            0.58004 * MenuBarFilmProfile.filmScale,
            0.56290 * MenuBarFilmProfile.filmScale,
            0.54446 * MenuBarFilmProfile.filmScale
        };

        enum {
            menuStopCount =
                sizeof(menuLocations) /
                sizeof(menuLocations[0])
        };

        MenuBarGradient = CreateAlphaGradient(
            space, menuLocations, menuAlphas, menuStopCount,
            1.0, 1.0, 1.0);
        MenuBarTopHighlightColor =
            SLCreateSRGBColor(1.0, 1.0, 1.0, 0.92437);

        CGFloat opacityLocations[] = {
            0.00,
            0.08,
            0.16,
            0.24,
            0.30,
            0.36,
            0.40,
            0.44,
            0.48,
            0.52,
            0.55,
            0.60,
            0.64,
            0.68,
            0.72,
            0.80,
            0.90,
            1.00
        };

        CGFloat opacityAlphas[] = {
            MenuBarFilmProfile.leftOpacity,
            0.8950,
            0.8800,
            0.8550,
            0.8200,
            0.7750,
            0.7300,
            0.6800,
            0.6250,
            0.5600,
            MenuBarFilmProfile.middleOpacity,
            0.5871,
            0.6433,
            0.6956,
            0.7427,
            0.8193,
            0.8797,
            MenuBarFilmProfile.rightOpacity
        };

        enum {
            opacityStopCount =
                sizeof(opacityLocations) /
                sizeof(opacityLocations[0])
        };

        MenuBarOpacityGradient = CreateAlphaGradient(
            space, opacityLocations, opacityAlphas, opacityStopCount,
            0.0, 0.0, 0.0);
        CGColorSpaceRelease(space);
    });
}

static void DrawVerticalGradient(NSView *view, CGGradientRef gradient,
                                 NSRect bounds) {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    if (!context || !gradient || NSIsEmptyRect(bounds)) return;
    // On a 1440x900 Retina desktop, one logical point becomes two physical
    // pixels. Fill the complete native bounds so no artificial seam appears.
    NSRect gradientBounds = bounds;
    if (NSIsEmptyRect(gradientBounds)) return;
    CGFloat middleX = NSMidX(gradientBounds);
    CGPoint start = CGPointMake(middleX,
        view.isFlipped ? NSMinY(gradientBounds)
                       : NSMaxY(gradientBounds));
    CGPoint end = CGPointMake(middleX,
        view.isFlipped ? NSMaxY(gradientBounds)
                       : NSMinY(gradientBounds));
    CGContextSaveGState(context);
    CGContextClipToRect(context, NSRectToCGRect(gradientBounds));
    CGContextDrawLinearGradient(context, gradient, start, end, 0);
    CGContextRestoreGState(context);
}

static void ApplyHorizontalOpacityMask(NSRect bounds) {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    if (!context || !MenuBarOpacityGradient || NSIsEmptyRect(bounds)) return;
    CGContextSaveGState(context);
    CGContextSetBlendMode(context, kCGBlendModeDestinationIn);
    CGFloat middleY = NSMidY(bounds);
    CGContextDrawLinearGradient(
        context, MenuBarOpacityGradient,
        CGPointMake(NSMinX(bounds), middleY),
        CGPointMake(NSMaxX(bounds), middleY), 0);
    CGContextRestoreGState(context);
}

static void DrawMenuBarFilm(NSView *view, NSRect bounds) {
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    if (!context || !view || NSIsEmptyRect(bounds)) return;

    CGFloat backingScale = view.window.backingScaleFactor;
    if (backingScale <= 0.0) {
        backingScale = view.window.screen.backingScaleFactor;
    }
    if (backingScale <= 0.0) {
        backingScale = NSScreen.mainScreen.backingScaleFactor;
    }
    if (backingScale <= 0.0) backingScale = 1.0;

    // Snow Leopard's top highlight is one device pixel, not one logical point.
    // On the user's 1440 x 900 Retina mode this is exactly 0.5 pt, avoiding the
    // two-pixel white strip produced by earlier attempts.
    CGFloat devicePixel = 1.0 / backingScale;
    devicePixel = MIN(devicePixel, NSHeight(bounds));

    NSRect bodyBounds = bounds;
    if (view.isFlipped) {
        bodyBounds.origin.y += devicePixel;
    }
    bodyBounds.size.height = MAX(0.0, bodyBounds.size.height - devicePixel);
    DrawVerticalGradient(view, MenuBarGradient, bodyBounds);

    CGColorRef topColour = MenuBarTopHighlightColor;
    if (topColour && devicePixel > 0.0) {
        CGFloat topY = view.isFlipped
            ? NSMinY(bounds)
            : NSMaxY(bounds) - devicePixel;
        CGContextSaveGState(context);
        CGContextSetFillColorWithColor(context, topColour);
        CGContextFillRect(
            context,
            CGRectMake(NSMinX(bounds), topY, NSWidth(bounds), devicePixel));
        CGContextRestoreGState(context);
    }

    // A source-atop veil changes only RGB and preserves the film's alpha.
    CGContextSaveGState(context);
    CGContextSetBlendMode(context, kCGBlendModeSourceAtop);
    CGContextSetRGBFillColor(
        context, 1.0, 1.0, 1.0, MenuBarFilmProfile.sheenAlpha);
    CGContextFillRect(context, NSRectToCGRect(bounds));
    CGContextRestoreGState(context);

    if (MenuBarFilmProfile.horizontalOpacityEnabled) {
        ApplyHorizontalOpacityMask(bounds);
    }
}

static void DrawTransparentMenuBarHost(id object, SEL selector,
                                       NSRect dirtyRect) {
    (void)selector;
    (void)dirtyRect;
    if (![object isKindOfClass:NSView.class]) return;
    NSView *view = object;
    NSRect bounds = view.bounds;
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    if (!context || NSIsEmptyRect(bounds)) return;

    CGContextSaveGState(context);
    CGContextClearRect(context, NSRectToCGRect(bounds));
    CGContextRestoreGState(context);
}

static BOOL SnowLeopardFrameIsOpaque(id object, SEL selector) {
    (void)object;
    (void)selector;
    return NO;
}

static void ConfigureTransparentLayer(CALayer *layer, BOOL clearContents,
                                      BOOL clearFilters) {
    if (!layer) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.opaque = NO;
    layer.masksToBounds = YES;
    layer.backgroundColor = NSColor.clearColor.CGColor;
    layer.backgroundFilters = nil;
    layer.compositingFilter = nil;
    if (clearContents) layer.contents = nil;
    if (clearFilters) layer.filters = nil;
    [CATransaction commit];
}

static void ClearLayerBackground(NSView *view) {
    if (view.wantsLayer) ConfigureTransparentLayer(view.layer, YES, YES);
}

static CIImage *CachedDesktopWallpaper = nil;
static NSURL *CachedDesktopWallpaperURL = nil;
static NSURL *ObservedDesktopWallpaperURL = nil;

static BOOL SnowLeopardUsesWindowServerBackdrop(CALayer *layer) {
    Class backdropClass = NSClassFromString(@"CABackdropLayer");
    return backdropClass && layer && [layer isKindOfClass:backdropClass];
}

static BOOL ConfigureLiveBackdrop(CALayer *layer) {
    if (!SnowLeopardUsesWindowServerBackdrop(layer)) return NO;
    if ([objc_getAssociatedObject(layer, &LiveBackdropConfiguredKey) boolValue])
        return YES;
    Class cls = layer.class;
    SEL aware = NSSelectorFromString(@"setWindowServerAware:");
    SEL scale = NSSelectorFromString(@"setScale:");
    SEL filterFactory = NSSelectorFromString(@"filterWithType:");
    Class filterClass = NSClassFromString(@"CAFilter");
    if (!SLMethodMatches(class_getInstanceMethod(cls, aware), "v20@0:8B16") ||
        !SLMethodMatches(class_getInstanceMethod(cls, scale), "v24@0:8d16") ||
        !SLMethodMatches(class_getClassMethod(filterClass, filterFactory),
                       "@24@0:8@16")) return NO;
    id blur = ((id (*)(id, SEL, id))objc_msgSend)(
        filterClass, filterFactory, @"gaussianBlur");
    if (!blur) return NO;
    @try {
        NSArray *keys = [blur valueForKey:@"inputKeys"];
        if (![keys containsObject:@"inputRadius"]) return NO;
        [blur setValue:@(SLSnowLeopardWindowServerBlurRadius)
               forKey:@"inputRadius"];
        if ([keys containsObject:@"inputNormalizeEdges"])
            [blur setValue:@YES forKey:@"inputNormalizeEdges"];
    } @catch (__unused NSException *exception) {
        return NO;
    }
    // Bare compositor blur: no NSVisualEffect material tint beneath our film,
    // and no wallpaper file cache that can freeze or differ in sandboxed apps.
    ((void (*)(id, SEL, BOOL))objc_msgSend)(layer, aware, YES);
    ((void (*)(id, SEL, double))objc_msgSend)(layer, scale, 1.0);
    layer.filters = @[blur];
    objc_setAssociatedObject(layer, &LiveBackdropConfiguredKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static CIImage *SnowLeopardDesktopWallpaperForScreen(NSScreen *screen) {
    NSURL *url = [NSWorkspace.sharedWorkspace desktopImageURLForScreen:screen];
    if (!url) return nil;
    if (!CachedDesktopWallpaper ||
        ![CachedDesktopWallpaperURL isEqual:url]) {
        CIImage *image = [CIImage imageWithContentsOfURL:url];
        if (!image) return nil;
        CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
        [blur setValue:image.imageByClampingToExtent forKey:kCIInputImageKey];
        [blur setValue:@(SLSnowLeopardWallpaperBlurRadius)
             forKey:kCIInputRadiusKey];
        CIImage *blurred = [blur.outputImage imageByCroppingToRect:image.extent];
        if (!blurred) return nil;

        CIFilter *controls = [CIFilter filterWithName:@"CIColorControls"];
        [controls setValue:blurred forKey:kCIInputImageKey];
        [controls setValue:@1.0 forKey:kCIInputSaturationKey];
        [controls setValue:@(SLSnowLeopardWallpaperBrightness)
                    forKey:kCIInputBrightnessKey];
        [controls setValue:@(SLSnowLeopardWallpaperContrast)
                    forKey:kCIInputContrastKey];
        CIImage *processed = controls.outputImage;
        if (!processed) return nil;
        CachedDesktopWallpaperURL = url;
        CachedDesktopWallpaper = processed;
    }
    return CachedDesktopWallpaper;
}

static CGRect SnowLeopardWallpaperSourceRect(
    CGSize imageSize,
    NSRect screenFrame,
    NSRect windowFrame
) {
    if (imageSize.width <= 0 || imageSize.height <= 0 ||
        NSWidth(screenFrame) <= 0 || NSHeight(screenFrame) <= 0 ||
        NSIsEmptyRect(windowFrame)) return CGRectNull;

    // Fill-screen geometry: this is exact for the user's 16:10 wallpaper
    // and still correctly center-crops a different aspect ratio.
    CGFloat scale = MIN(imageSize.width / NSWidth(screenFrame),
                        imageSize.height / NSHeight(screenFrame));
    CGFloat drawnWidth = NSWidth(screenFrame) * scale;
    CGFloat drawnHeight = NSHeight(screenFrame) * scale;
    CGFloat insetX = (imageSize.width - drawnWidth) * 0.5;
    CGFloat insetY = (imageSize.height - drawnHeight) * 0.5;
    return CGRectMake(
        insetX + (NSMinX(windowFrame) - NSMinX(screenFrame)) * scale,
        insetY + (NSMinY(windowFrame) - NSMinY(screenFrame)) * scale,
        NSWidth(windowFrame) * scale,
        NSHeight(windowFrame) * scale);
}

#include "DirectWallpaper.inc"

static BOOL ConfigureSnowLeopardBackdropLayer(
    SLSnowLeopardMenuBarBackdropView *backdrop
) {
    if (!backdrop) return NO;
    backdrop.wantsLayer = YES;
    CALayer *layer = backdrop.layer;
    if (!layer) return NO;
    if (SLApplyDirectWallpaper(backdrop)) return YES;
    if (ConfigureLiveBackdrop(layer)) {
        ConfigureTransparentLayer(layer, NO, NO);
        return YES;
    }

    BOOL hasWallpaperImage =
        SnowLeopardDesktopWallpaperForScreen(backdrop.window.screen) != nil;
    if (!hasWallpaperImage) {
        return NO;
    }
    ConfigureTransparentLayer(layer, NO, YES);
    return hasWallpaperImage;
}

@implementation SLSnowLeopardMenuBarBackdropView

- (CALayer *)makeBackingLayer {
    Class backdropClass = NSClassFromString(@"CABackdropLayer");
    CALayer *layer = backdropClass &&
        [backdropClass isSubclassOfClass:CALayer.class]
        ? [backdropClass layer] : [super makeBackingLayer];
    layer.opaque = NO;
    return layer;
}

- (BOOL)isOpaque { return NO; }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (objc_getAssociatedObject(self, &SLDirectMaterialTokenKey)) return;
    if ([objc_getAssociatedObject(self.layer, &LiveBackdropConfiguredKey)
            boolValue]) return;
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    CIImage *wallpaper = SnowLeopardDesktopWallpaperForScreen(screen);
    CGContextRef graphics = NSGraphicsContext.currentContext.CGContext;
    if (!wallpaper || !graphics || NSIsEmptyRect(self.bounds)) return;
    CGRect source = SnowLeopardWallpaperSourceRect(
        wallpaper.extent.size, screen.frame, self.window.frame);
    if (CGRectIsNull(source) || CGRectIsEmpty(source)) return;
    CIContext *context = [CIContext contextWithCGContext:graphics options:nil];
    [context drawImage:wallpaper
                inRect:NSRectToCGRect(self.bounds)
              fromRect:source];
}

@end

@implementation SLSnowLeopardMenuBarFilmView

- (BOOL)isOpaque {
    return NO;
}

- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    PreparePalette();
    NSRect bounds = self.bounds;
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    if (!context || NSIsEmptyRect(bounds)) return;
    CGContextSaveGState(context);
    CGContextClearRect(context, NSRectToCGRect(bounds));
    CGContextBeginTransparencyLayer(context, NULL);
    DrawMenuBarFilm(self, bounds);
    CGContextEndTransparencyLayer(context);
    CGContextRestoreGState(context);
}

@end

static void ConfigureMenuBarFilmLayer(SLSnowLeopardMenuBarFilmView *film) {
    if (!film) return;
    film.wantsLayer = YES;
    CALayer *layer = film.layer;
    if (!layer) return;

    ConfigureTransparentLayer(layer, NO, YES);
}

static void ResolveWindowServerBlur(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SLMainConnectionID = (SLMainConnectionIDFn)
            dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
        SLSetWindowBackgroundBlurRadius =
            (SLSetWindowBackgroundBlurRadiusFn)
            dlsym(RTLD_DEFAULT, "SLSSetWindowBackgroundBlurRadius");

        if (!SLMainConnectionID || !SLSetWindowBackgroundBlurRadius) {
            void *skyLight = dlopen(
                "/System/Library/PrivateFrameworks/"
                "SkyLight.framework/SkyLight",
                RTLD_LAZY | RTLD_LOCAL);
            if (skyLight) {
                if (!SLMainConnectionID) {
                    SLMainConnectionID = (SLMainConnectionIDFn)
                        dlsym(skyLight, "SLSMainConnectionID");
                }
                if (!SLSetWindowBackgroundBlurRadius) {
                    SLSetWindowBackgroundBlurRadius =
                        (SLSetWindowBackgroundBlurRadiusFn)
                        dlsym(skyLight,
                              "SLSSetWindowBackgroundBlurRadius");
                }
            }
        }
    });
}

static BOOL SetWindowServerBlurRadius(NSWindow *window, int radius) {
    if (!window) return NO;
    NSNumber *configuredRadius =
        objc_getAssociatedObject(window, &WindowBlurRadiusKey);
    if (configuredRadius && configuredRadius.intValue == radius) {
        return YES;
    }
    ResolveWindowServerBlur();
    if (!SLMainConnectionID || !SLSetWindowBackgroundBlurRadius) return NO;

    NSInteger windowNumber = window.windowNumber;
    if (windowNumber <= 0 || windowNumber > INT_MAX) return NO;

    CGError error = SLSetWindowBackgroundBlurRadius(
        SLMainConnectionID(),
        (int)windowNumber,
        radius);
    if (error != kCGErrorSuccess) return NO;

    objc_setAssociatedObject(window, &WindowBlurRadiusKey, @(radius),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static void ScheduleMenuBarBackdropElection(void);
static void ConfigureMenuBarBackdropWindows(void);
static void RefreshExistingMenuBars(void);
static void RefreshMenuBarLowerShadows(void);

static void RefreshDesktopWallpaperIfNeeded(void) {
    RefreshMenuBarLowerShadows();
    if (!NSApp.isActive) return;
    if (SLPollWallpaperFeed()) {
        RefreshExistingMenuBars();
        return;
    }
    // Native backdrop pixels update in the compositor, without reading files.
    // Poll only when a layer actually fell back to the old image renderer.
    if (!NeedsWallpaperFilePolling) return;
    NSScreen *screen = NSScreen.mainScreen;
    NSURL *currentURL =
        [NSWorkspace.sharedWorkspace desktopImageURLForScreen:screen];
    if (ObservedDesktopWallpaperURL == currentURL ||
        [ObservedDesktopWallpaperURL isEqual:currentURL]) return;

    ObservedDesktopWallpaperURL = currentURL;
    CachedDesktopWallpaperURL = nil;
    CachedDesktopWallpaper = nil;
    RefreshExistingMenuBars();
}

static void RegisterMenuBarWindow(NSWindow *window) {
    if (!window || !ReplicantWindowClass ||
        ![window isKindOfClass:ReplicantWindowClass]) return;
    if (!KnownMenuBarWindows) KnownMenuBarWindows = [NSHashTable weakObjectsHashTable];
    if ([KnownMenuBarWindows containsObject:window]) return;
    [KnownMenuBarWindows addObject:window];
    SLLog([NSString stringWithFormat:
        @"background registered process=%@ window=%ld frame=%@ publicList=%d",
        NSProcessInfo.processInfo.processName, (long)window.windowNumber,
        NSStringFromRect(window.frame), [NSApp.windows containsObject:window]]);
    ScheduleMenuBarBackdropElection();
}

static NSView *FindBackingView(NSView *view) {
    if (!view) return nil;
    if (BackingViewClass && [view isKindOfClass:BackingViewClass]) return view;
    for (NSView *subview in view.subviews.copy) {
        NSView *match = FindBackingView(subview);
        if (match) return match;
    }
    return nil;
}

static void EnsureFilmView(NSView *candidate) {
    NSView *backingView = FindBackingView(candidate);
    if (!backingView) return;
    RegisterMenuBarWindow(backingView.window);
    ClearLayerBackground(backingView);
    backingView.layerUsesCoreImageFilters = NO;

    SLSnowLeopardMenuBarBackdropView *backdrop =
        objc_getAssociatedObject(backingView, &BackdropViewKey);
    if (!backdrop) {
        backdrop = [[SLSnowLeopardMenuBarBackdropView alloc]
            initWithFrame:backingView.bounds];
        backdrop.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        objc_setAssociatedObject(backingView, &BackdropViewKey, backdrop,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    backdrop.frame = backingView.bounds;

    SLSnowLeopardMenuBarFilmView *film =
        objc_getAssociatedObject(backingView, &FilmViewKey);
    if (!film) {
        film = [[SLSnowLeopardMenuBarFilmView alloc]
            initWithFrame:backingView.bounds];
        film.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        objc_setAssociatedObject(backingView, &FilmViewKey, film,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    film.frame = backingView.bounds;
    PreparePalette();
    ConfigureMenuBarFilmLayer(film);

    if (backdrop.superview != backingView ||
        backingView.subviews.firstObject != backdrop) {
        [backdrop removeFromSuperviewWithoutNeedingDisplay];
        [backingView addSubview:backdrop
                    positioned:NSWindowBelow
                    relativeTo:backingView.subviews.firstObject];
    }
    if (film.superview != backingView) {
        [film removeFromSuperviewWithoutNeedingDisplay];
        [backingView addSubview:film
                    positioned:NSWindowAbove
                    relativeTo:backdrop];
    }
    [film setNeedsDisplay:YES];
}

static SLSnowLeopardMenuBarFilmView *FilmViewForWindow(NSWindow *window) {
    NSView *backingView = FindBackingView(window.contentView);
    if (!backingView) return nil;
    return objc_getAssociatedObject(backingView, &FilmViewKey);
}

static SLSnowLeopardMenuBarBackdropView *BackdropViewForWindow(NSWindow *window) {
    NSView *backingView = FindBackingView(window.contentView);
    return backingView
        ? objc_getAssociatedObject(backingView, &BackdropViewKey)
        : nil;
}

#include "LowerShadow.inc"

// Hidden replicas are not evidence of overlapping onscreen windows. AppKit
// supplies backing views for different appearances. A lowest-ID "owner" left
// every other variant without a film. Style each supplied backing consistently.

static void ConfigureMenuBarBackdropWindows(void) {
    if (!NSApp || !ReplicantWindowClass || ConfiguringMenuBarBackdrops) return;

    NSMutableArray<NSWindow *> *allReplicants = [NSMutableArray array];
    NSMutableArray<NSWindow *> *visibleReplicants = [NSMutableArray array];
    // AppKit's private replicas may be absent from NSApplication.windows.
    // Discover them from initWithView: and representation.backingViews too.
    NSMutableOrderedSet<NSWindow *> *candidates = [NSMutableOrderedSet orderedSet];
    [candidates addObjectsFromArray:KnownMenuBarWindows.allObjects ?: @[]];
    [candidates addObjectsFromArray:NSApp.windows.copy];
    for (NSWindow *window in candidates) {
        if (![window isKindOfClass:ReplicantWindowClass]) continue;
        [allReplicants addObject:window];
        if (window.isVisible && window.windowNumber > 0) {
            [visibleReplicants addObject:window];
        }
    }
    if (allReplicants.count == 0) return;

    ConfiguringMenuBarBackdrops = YES;
    NeedsWallpaperFilePolling = NO;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSUInteger liveBackdrops = 0;
    NSUInteger directBackdrops = 0;
    for (NSWindow *window in allReplicants) {
        EnsureFilmView(window.contentView);
        SLSnowLeopardMenuBarBackdropView *backdrop = BackdropViewForWindow(window);
        SLSnowLeopardMenuBarFilmView *film = FilmViewForWindow(window);
        BOOL backdropReady = ConfigureSnowLeopardBackdropLayer(backdrop);
        if (objc_getAssociatedObject(backdrop, &SLDirectMaterialTokenKey)) directBackdrops++;
        else if ([objc_getAssociatedObject(backdrop.layer, &LiveBackdropConfiguredKey)
                boolValue]) liveBackdrops++;
        else NeedsWallpaperFilePolling = YES;
        if (backdrop) {
            backdrop.hidden = !backdropReady;
            if (backdropReady) [backdrop setNeedsDisplay:YES];
        }
        if (film) {
            ConfigureMenuBarFilmLayer(film);
            film.hidden = objc_getAssociatedObject(backdrop, &SLDirectMaterialTokenKey) != nil;
            [film setNeedsDisplay:YES];
        }
        SetWindowServerBlurRadius(
            window,
            !backdropReady ? SLSnowLeopardWindowServerBlurRadius : 0);
    }
    [CATransaction commit];
    ConfiguringMenuBarBackdrops = NO;
    RefreshMenuBarLowerShadows();

    static NSString *lastState = nil;
    NSString *state = [NSString stringWithFormat:@"%lu/%lu/%lu/%lu",
        (unsigned long)directBackdrops,
        (unsigned long)liveBackdrops, (unsigned long)allReplicants.count,
        (unsigned long)visibleReplicants.count];
    if (![lastState isEqualToString:state]) {
        lastState = state;
        SLLog([NSString stringWithFormat:
            @"background variants process=%@ directLayers=%lu liveLayers=%lu "
             "total=%lu visibleCandidates=%lu radius=%d visualVerified=0",
            NSProcessInfo.processInfo.processName,
            (unsigned long)directBackdrops,
            (unsigned long)liveBackdrops,
            (unsigned long)allReplicants.count,
            (unsigned long)visibleReplicants.count,
            SLSnowLeopardWindowServerBlurRadius]);
    }
}

static void ScheduleMenuBarBackdropElection(void) {
    if (BackdropElectionScheduled || ConfiguringMenuBarBackdrops) return;
    BackdropElectionScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        BackdropElectionScheduled = NO;
        ConfigureMenuBarBackdropWindows();
    });
}

static void SnowLeopardBackingLayout(id object, SEL selector,
                                     NSSize oldSize) {
    OriginalBackingLayout(object, selector, oldSize);
    if ([object isKindOfClass:NSView.class]) {
        EnsureFilmView(object);
        ScheduleMenuBarBackdropElection();
    }
}

static id SnowLeopardRootBackingView(id object, SEL selector) {
    id view = OriginalRootBackingView(object, selector);
    // A theme can repaint layer.contents inside this getter (observed with
    // Glow). Clean only this menu-bar backing, after calling that getter.
    static BOOL preparing = NO;
    if (!preparing && [view isKindOfClass:NSView.class]) {
        preparing = YES;
        EnsureFilmView(view);
        ScheduleMenuBarBackdropElection();
        preparing = NO;
    }
    return view;
}

static void StyleReplicantWindow(NSWindow *window) {
    if (!window || !ReplicantWindowClass ||
        ![window isKindOfClass:ReplicantWindowClass]) {
        return;
    }

    RegisterMenuBarWindow(window);
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    window.hasShadow = NO;
    window.alphaValue = 1.0;

    NSView *contentView = window.contentView;
    ClearLayerBackground(contentView);
    EnsureFilmView(contentView);
    NSView *frameView = contentView.superview;
    if (frameView && [frameView isKindOfClass:ReplicantFrameClass]) {
        ClearLayerBackground(frameView);
        [frameView setNeedsDisplay:YES];
        [frameView displayIfNeeded];
    }
    ScheduleMenuBarBackdropElection();
}

static id SnowLeopardReplicantInit(id object, SEL selector, id view) {
    id result = OriginalReplicantInit(object, selector, view);
    if ([view isKindOfClass:NSView.class]) EnsureFilmView(view);
    StyleReplicantWindow(result);
    return result;
}

static void SnowLeopardReplicantSetBackgroundColor(id object, SEL selector,
                                                    NSColor *colour) {
    (void)colour;
    OriginalReplicantSetBackgroundColor(object, selector, NSColor.clearColor);
}

static void SnowLeopardReplicantSetOpaque(id object, SEL selector,
                                          BOOL opaque) {
    (void)opaque;
    OriginalReplicantSetOpaque(object, selector, NO);
}

static BOOL ValidateBackgroundABI(void) {
    ReplicantWindowClass = NSClassFromString(@"NSMenuBarReplicantWindow");
    ReplicantFrameClass = NSClassFromString(@"NSMenuBarReplicantWindowFrame");
    BackingViewClass = NSClassFromString(@"_NSMenuBarBackingView");
    Class representationClass = NSClassFromString(@"NSMenuBarRepresentation");
    if (!ReplicantWindowClass || !ReplicantFrameClass || !BackingViewClass ||
        !representationClass ||
        class_getSuperclass(ReplicantWindowClass) != NSWindow.class ||
        ![ReplicantFrameClass isSubclassOfClass:NSView.class] ||
        ![BackingViewClass isSubclassOfClass:NSView.class]) return NO;

    BackgroundHooks = (SLBackgroundHooks) {
        .initView = SLOwnInstanceMethod(
            ReplicantWindowClass, NSSelectorFromString(@"initWithView:")),
        .backgroundColor = class_getInstanceMethod(
            ReplicantWindowClass, @selector(setBackgroundColor:)),
        .opaque = class_getInstanceMethod(
            ReplicantWindowClass, @selector(setOpaque:)),
        .frameDraw = class_getInstanceMethod(
            ReplicantFrameClass, @selector(drawRect:)),
        .frameOpaque = class_getInstanceMethod(
            ReplicantFrameClass, @selector(isOpaque)),
        .backingDraw = class_getInstanceMethod(
            BackingViewClass, @selector(drawRect:)),
        .backingOpaque = class_getInstanceMethod(
            BackingViewClass, @selector(isOpaque)),
        .backingLayout = SLOwnInstanceMethod(
            BackingViewClass, NSSelectorFromString(@"_layoutSubtreeWithOldSize:")),
        .rootBackingView = class_getInstanceMethod(
            representationClass, NSSelectorFromString(@"_rootBackingView")),
    };

    return SLMethodMatches(BackgroundHooks.rootBackingView, "@16@0:8") &&
        SLMethodMatches(BackgroundHooks.initView, "@24@0:8@16") &&
        SLMethodMatches(BackgroundHooks.backgroundColor, "v24@0:8@16") &&
        SLMethodMatches(BackgroundHooks.opaque, "v20@0:8B16") &&
        SLMethodMatches(BackgroundHooks.frameDraw,
            "v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16") &&
        SLMethodMatches(BackgroundHooks.frameOpaque, "B16@0:8") &&
        SLMethodMatches(BackgroundHooks.backingDraw,
            "v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16") &&
        SLMethodMatches(BackgroundHooks.backingOpaque, "B16@0:8") &&
        SLMethodMatches(BackgroundHooks.backingLayout,
            "v32@0:8{CGSize=dd}16");
}

static BOOL InstallBackgroundHooks(void) {
    if (BackgroundHooksInstalled) return YES;
    if (!BackgroundHooks.initView && !ValidateBackgroundABI()) {
        SLLog(@"background install aborted: unexpected AppKit ABI");
        return NO;
    }

    OriginalReplicantInit =
        (InitWithViewFn)method_getImplementation(BackgroundHooks.initView);
    OriginalBackingLayout =
        (LayoutSizeFn)method_getImplementation(BackgroundHooks.backingLayout);
    OriginalRootBackingView = (id (*)(id, SEL))
        method_getImplementation(BackgroundHooks.rootBackingView);
    if (!OriginalReplicantInit || !OriginalBackingLayout ||
        !OriginalRootBackingView) return NO;

    IMP oldBackground = NULL, oldOpaque = NULL;
    IMP oldFrameDraw = NULL, oldFrameOpaque = NULL;
    IMP oldBackingDraw = NULL, oldBackingOpaque = NULL;
    BOOL ready =
        SLInstallOverrideHook(ReplicantWindowClass, @selector(setBackgroundColor:),
            "v24@0:8@16", (IMP)SnowLeopardReplicantSetBackgroundColor,
            &oldBackground) &&
        SLInstallOverrideHook(ReplicantWindowClass, @selector(setOpaque:),
            "v20@0:8B16", (IMP)SnowLeopardReplicantSetOpaque, &oldOpaque) &&
        SLInstallOverrideHook(ReplicantFrameClass, @selector(drawRect:),
            "v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16",
            (IMP)DrawTransparentMenuBarHost, &oldFrameDraw) &&
        SLInstallOverrideHook(ReplicantFrameClass, @selector(isOpaque),
            "B16@0:8", (IMP)SnowLeopardFrameIsOpaque, &oldFrameOpaque) &&
        SLInstallOverrideHook(BackingViewClass, @selector(drawRect:),
            "v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16",
            (IMP)DrawTransparentMenuBarHost, &oldBackingDraw) &&
        SLInstallOverrideHook(BackingViewClass, @selector(isOpaque),
            "B16@0:8", (IMP)SnowLeopardFrameIsOpaque, &oldBackingOpaque);

    if (!ready) {
        SLRestoreOwnHook(ReplicantWindowClass, @selector(setBackgroundColor:),
            (IMP)SnowLeopardReplicantSetBackgroundColor, oldBackground);
        SLRestoreOwnHook(ReplicantWindowClass, @selector(setOpaque:),
            (IMP)SnowLeopardReplicantSetOpaque, oldOpaque);
        SLRestoreOwnHook(ReplicantFrameClass, @selector(drawRect:),
            (IMP)DrawTransparentMenuBarHost, oldFrameDraw);
        SLRestoreOwnHook(ReplicantFrameClass, @selector(isOpaque),
            (IMP)SnowLeopardFrameIsOpaque, oldFrameOpaque);
        SLRestoreOwnHook(BackingViewClass, @selector(drawRect:),
            (IMP)DrawTransparentMenuBarHost, oldBackingDraw);
        SLRestoreOwnHook(BackingViewClass, @selector(isOpaque),
            (IMP)SnowLeopardFrameIsOpaque, oldBackingOpaque);
        SLLog(@"background install aborted: subclass override failed");
        return NO;
    }

    OriginalReplicantSetBackgroundColor = (SetColorFn)oldBackground;
    OriginalReplicantSetOpaque = (SetBoolFn)oldOpaque;
    method_setImplementation(BackgroundHooks.initView,
        (IMP)SnowLeopardReplicantInit);
    method_setImplementation(BackgroundHooks.backingLayout,
        (IMP)SnowLeopardBackingLayout);
    method_setImplementation(BackgroundHooks.rootBackingView,
        (IMP)SnowLeopardRootBackingView);

    BackgroundHooksInstalled = YES;
    PreparePalette();
    SLLog(
        @"background reference "
         "snow-leopard-reference-composited "
         "lowerShadow=reference-strip14-desktop-level-v2 "
         "colorTransfer=reference-srgb-gain-bias-v1 "
         "wallpaperSource=shared-named-pasteboard-v1 "
         "materialDelivery=direct-layer-color-transfer-v2 "
         "material=live-compositor-blur-single-film-v2 "
         "desktopSource=window-server-backdrop-v2 "
         "backdropFactory=nsview-makeBackingLayer-v1 "
         "replicaPolicy=all-appearance-variants-v1 "
         "themeBackground=post-root-getter-cleanup-v1 "
         "replicaDiscovery=weak-registry-and-representations-v1 "
         "menuLayout=refresh-representation-width-cache-v1 "
         "filmScale=1.0 "
         "verticalAlpha=color-managed-reference-rows1-20-window-backdrop "
         "backdropFilter=live-gaussian3-no-material-tint-v2 "
         "fallbackImageStack=gaussian9-brightness0.02-contrast1.15-v1 "
         "horizontalOpacity=uniform "
         "topRule=one-physical-pixel-alpha-0.92437 "
         "bottomRule=none-continuous-film "
         "filmRGB=white "
         "retinaScale=device-pixel-aware "
         "geometry=sequoia-native-untouched");
    SLLog(
        @"background installed snow-leopard-sartfile-material-only geometry=sequoia-native-untouched");
    return YES;
}

static BOOL IsMenuBarItem(id object) {
    return object && MenuBarItemViewClass &&
        [object isKindOfClass:MenuBarItemViewClass];
}

// SLMenuBarReplicaSynchronization
//
// NSMenuBarRepresentation mantiene varias copias independientes
// de cada NSMenuBarItemView. El estado forzado se almacena en
// cada copia para que todas dibujen el mismo gradiente y texto.
static char SLReplicaForcedHighlightKey;
static char SLStoredReplicaItemsKey;
static char SLReplicaSynchronizationTokenKey;

static void SLStoreReplicaForcedHighlight(
    NSView *view,
    BOOL highlighted
) {
    if (!view ||
        !IsMenuBarItem(view)) {
        return;
    }

    objc_setAssociatedObject(
        view,
        &SLReplicaForcedHighlightKey,
        @(highlighted),
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL HighlightState(
    id view
) {
    if (!IsMenuBarItem(view)) {
        return NO;
    }

    NSNumber *forcedState =
        objc_getAssociatedObject(
            view,
            &SLReplicaForcedHighlightKey);

    if (forcedState) {
        return forcedState.boolValue;
    }

    if (![view
            respondsToSelector:
                @selector(isHighlighted)]) {
        return NO;
    }

    return ((BOOL (*)(id, SEL))objc_msgSend)(
        view,
        @selector(isHighlighted));
}

static void WithMenuTitleColour(BOOL highlighted, void (^work)(void)) {
    NSUInteger oldDepth = MenuTitleColourDepth;
    BOOL oldHighlight = MenuTitleIsHighlighted;
    MenuTitleColourDepth = oldDepth + 1;
    MenuTitleIsHighlighted = highlighted;
    @try {
        work();
    } @finally {
        MenuTitleColourDepth = oldDepth;
        MenuTitleIsHighlighted = oldHighlight;
    }
}

static NSColor *SnowLeopardTextColor(id receiver, SEL selector) {
    if (MenuTitleColourDepth > 0) {
        return MenuTitleIsHighlighted ? NSColor.whiteColor
                                      : NSColor.blackColor;
    }
    return OriginalTextColor(receiver, selector);
}

static void InvalidateCachedLine(id view) {
    if (!IsMenuBarItem(view) || !CachedLineIvar ||
        !CachedLineWidthIvar || !DidTruncateLineIvar) {
        return;
    }
    uintptr_t base = (uintptr_t)(__bridge void *)view;
    CFTypeRef *lineSlot =
        (CFTypeRef *)(base + ivar_getOffset(CachedLineIvar));
    CFTypeRef oldLine = *lineSlot;
    if (oldLine) {
        *lineSlot = NULL;
        CFRelease(oldLine);
    }
    *((double *)(base + ivar_getOffset(CachedLineWidthIvar))) = 0.0;
    *((BOOL *)(base + ivar_getOffset(DidTruncateLineIvar))) = NO;
}

static BOOL SLIsAppleMenuItem(id view) {
    if (!IsMenuBarItem(view) || !AppleMenuIvar) return NO;
    uintptr_t base = (uintptr_t)(__bridge void *)view;
    return *((BOOL *)(base + ivar_getOffset(AppleMenuIvar)));
}

static NSBitmapImageRep *SLCreateSnowLeopardAppleContrastRepresentation(
    NSBitmapImageRep *source) {
    if (!source) return nil;
    CIImage *input = [[CIImage alloc] initWithBitmapImageRep:source];
    CIFilter *filter = input ? [CIFilter filterWithName:@"CIColorPolynomial"] : nil;
    if (!filter) return nil;

    [filter setDefaults];
    [filter setValue:input forKey:kCIInputImageKey];
    // Metallic black: RGB' = 0.30 RGB + 0.16 RGB².
    CIVector *rgb = [CIVector vectorWithX:0.0 Y:0.30 Z:0.16 W:0.0];
    // Preserve the tuned edge alpha: A' = A + 1.30 A² - 1.30 A³.
    CIVector *alpha = [CIVector vectorWithX:0.0 Y:1.0 Z:1.30 W:-1.30];
    [filter setValue:rgb forKey:@"inputRedCoefficients"];
    [filter setValue:rgb forKey:@"inputGreenCoefficients"];
    [filter setValue:rgb forKey:@"inputBlueCoefficients"];
    [filter setValue:alpha forKey:@"inputAlphaCoefficients"];

    CIImage *output = [filter valueForKey:kCIOutputImageKey];
    if (!output) return nil;
    static CIContext *context = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ context = [CIContext contextWithOptions:nil]; });
    if (!context) return nil;

    CGImageRef cgImage = [context createCGImage:output fromRect:input.extent];
    if (!cgImage) return nil;
    NSBitmapImageRep *result = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
    CGImageRelease(cgImage);
    if (!result || result.pixelsWide != source.pixelsWide ||
        result.pixelsHigh != source.pixelsHigh) return nil;
    return result;
}

static NSImage *SLCreateEmbeddedRetinaAppleImage(const SLEmbeddedAsset *asset,
                                                  BOOL darkenNormal) {
    if (!asset) return nil;
    NSData *data = [NSData dataWithBytes:asset->bytes length:asset->length];
    NSBitmapImageRep *representation = [[NSBitmapImageRep alloc] initWithData:data];
    if (!representation) return nil;

    BOOL native1x = representation.pixelsWide == 22 && representation.pixelsHigh == 22;
    BOOL retina2x = representation.pixelsWide == 44 && representation.pixelsHigh == 44;
    if (!native1x && !retina2x) return nil;
    if (darkenNormal && retina2x) {
        NSBitmapImageRep *contrasted =
            SLCreateSnowLeopardAppleContrastRepresentation(representation);
        if (contrasted) representation = contrasted;
    }

    NSSize logicalSize = NSMakeSize(SLSnowLeopardAppleCanvasSize,
                                    SLSnowLeopardAppleCanvasSize);
    representation.size = logicalSize;
    NSImage *image = [[NSImage alloc] initWithSize:logicalSize];
    [image addRepresentation:representation];
    image.template = NO;
    return image;
}

static NSImage *SLEmbeddedRetinaAppleImage(BOOL highlighted) {
    static NSImage *normalImage = nil;
    static NSImage *selectedImage = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        normalImage = SLCreateEmbeddedRetinaAppleImage(
            SLEmbeddedAssetNamed("AppleMenuNormal"), YES);
        selectedImage = SLCreateEmbeddedRetinaAppleImage(
            SLEmbeddedAssetNamed("AppleMenuSelected"), NO);
    });
    return highlighted ? selectedImage : normalImage;
}

static char SLEmbeddedRetinaAppleDrawStateKey;

static void SLDrawEmbeddedRetinaApple(NSView *view, BOOL highlighted) {
    if (!view || !SLIsAppleMenuItem(view)) return;
    NSImage *image = SLEmbeddedRetinaAppleImage(highlighted);
    NSRect bounds = view.bounds;
    if (!image || NSIsEmptyRect(bounds) || !NSGraphicsContext.currentContext) return;

    const CGFloat width = highlighted ? SLSnowLeopardAppleCanvasSize : 24.1290322581;
    const CGFloat height = highlighted ? SLSnowLeopardAppleCanvasSize : 23.1578947368;
    NSRect drawRect = NSMakeRect(NSMidX(bounds) - width * 0.5 + 0.5,
                                 NSMidY(bounds) - height * 0.5,
                                 width, height);

    NSGraphicsContext *graphics = NSGraphicsContext.currentContext;
    [NSGraphicsContext saveGraphicsState];
    NSImageInterpolation previous = graphics.imageInterpolation;
    graphics.imageInterpolation = NSImageInterpolationHigh;
    [image drawInRect:drawRect fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver fraction:1.0
      respectFlipped:YES hints:nil];
    graphics.imageInterpolation = previous;
    [NSGraphicsContext restoreGraphicsState];

    NSNumber *oldState = objc_getAssociatedObject(view, &SLEmbeddedRetinaAppleDrawStateKey);
    if (!oldState || oldState.boolValue != highlighted) {
        objc_setAssociatedObject(view, &SLEmbeddedRetinaAppleDrawStateKey,
                                 @(highlighted), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SLLog([NSString stringWithFormat:
            @"apple icon state=%d item=%@ draw=%@ scale=%.2f",
            highlighted, NSStringFromRect(view.frame), NSStringFromRect(drawRect),
            view.window.backingScaleFactor]);
    }
}

static void ApplyDirectItemColours(id view, BOOL highlighted) {
    if (!IsMenuBarItem(view)) return;
    NSColor *colour = highlighted ? NSColor.whiteColor : NSColor.blackColor;

    if (TitleTextFieldIvar) {
        id titleField = object_getIvar(view, TitleTextFieldIvar);
        if ([titleField isKindOfClass:NSTextField.class]) {
            NSTextField *textField = (NSTextField *)titleField;
            textField.textColor = colour;
        }
    }

    if (SLIsAppleMenuItem(view) && ImageViewIvar) {
        id imageView = object_getIvar(view, ImageViewIvar);
        if ([imageView isKindOfClass:NSImageView.class]) {
            ((NSImageView *)imageView).contentTintColor = colour;
        }
    }
}

static void UpdateTitleAttributes(id view) {
    if (!IsMenuBarItem(view)) return;
    BOOL highlighted = HighlightState(view);
    SEL updateSelector = NSSelectorFromString(
        @"_updateAttributesFromItemIncludingFont:includingColor:");
    if ([view respondsToSelector:updateSelector]) {
        WithMenuTitleColour(highlighted, ^{
            ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(
                view, updateSelector, YES, YES);
        });
    }
    ApplyDirectItemColours(view, highlighted);
}

static void PrepareTitleForFirstUse(id view) {
    if (!IsMenuBarItem(view) ||
        objc_getAssociatedObject(view, &PreparedTitleKey)) {
        return;
    }
    objc_setAssociatedObject(view, &PreparedTitleKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UpdateTitleAttributes(view);
    InvalidateCachedLine(view);
}

static void RefreshTitle(id view) {
    if (!IsMenuBarItem(view)) return;
    objc_setAssociatedObject(view, &PreparedTitleKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UpdateTitleAttributes(view);
    InvalidateCachedLine(view);
    [(NSView *)view setNeedsDisplay:YES];
}

static void SLAppendUniqueReplicaItem(
    NSMutableArray<NSView *> *items,
    id candidate
) {
    if (!items ||
        !IsMenuBarItem(candidate)) {
        return;
    }

    if ([items
            indexOfObjectIdenticalTo:
                candidate] == NSNotFound) {
        [items addObject:
            (NSView *)candidate];
    }
}

static id SLReplicaCallObject(
    id object,
    NSString *selectorName
) {
    if (!object ||
        selectorName.length == 0) {
        return nil;
    }

    SEL selector =
        NSSelectorFromString(
            selectorName);

    if (![object
            respondsToSelector:selector]) {
        return nil;
    }

    return ((id (*)(id, SEL))objc_msgSend)(
        object,
        selector);
}

static NSInteger SLReplicaMenuIndexForView(
    id representation,
    NSView *view
) {
    if (!representation ||
        !view) {
        return NSNotFound;
    }

    SEL selector =
        NSSelectorFromString(
            @"menuIndexForView:");

    if (![representation
            respondsToSelector:selector]) {
        return NSNotFound;
    }

    return ((NSInteger (*)(id, SEL, id))objc_msgSend)(
        representation,
        selector,
        view);
}

static id SLReplicaSubviewAtMenuIndex(
    id representation,
    NSInteger menuIndex,
    id backingView
) {
    if (!representation ||
        menuIndex == NSNotFound ||
        !backingView) {
        return nil;
    }

    SEL selector =
        NSSelectorFromString(
            @"_subviewAtMenuIndex:inBackingView:");

    if (![representation
            respondsToSelector:selector]) {
        return nil;
    }

    return ((id (*)(id, SEL, NSInteger, id))objc_msgSend)(
        representation,
        selector,
        menuIndex,
        backingView);
}

static NSArray *SLReplicaBackingViews(
    id representation
) {
    if (!representation) {
        return @[];
    }

    id rawBackingViews = nil;

    Ivar backingViewsIvar =
        class_getInstanceVariable(
            [representation class],
            "_backingViews");

    if (backingViewsIvar) {
        const char *type =
            ivar_getTypeEncoding(
                backingViewsIvar);

        if (type &&
            type[0] == '@') {
            rawBackingViews =
                object_getIvar(
                    representation,
                    backingViewsIvar);
        }
    }

    if (![rawBackingViews
            isKindOfClass:NSArray.class]) {
        rawBackingViews =
            SLReplicaCallObject(
                representation,
                @"backingViews");
    }

    if (![rawBackingViews
            isKindOfClass:NSArray.class]) {
        return @[];
    }

    return [(NSArray *)rawBackingViews copy];
}

static NSArray<NSView *> *
SLResolveMenuBarReplicaItems(
    id menuBarImplementation,
    NSView *sourceItem,
    NSInteger *resolvedMenuIndex
) {
    NSMutableArray<NSView *> *items =
        [NSMutableArray array];

    SLAppendUniqueReplicaItem(
        items,
        sourceItem);

    id representation =
        SLReplicaCallObject(
            menuBarImplementation,
            @"activeRepresentationView");

    if (!representation) {
        if (resolvedMenuIndex) {
            *resolvedMenuIndex =
                NSNotFound;
        }

        return items.copy;
    }

    NSInteger menuIndex =
        SLReplicaMenuIndexForView(
            representation,
            sourceItem);

    if (resolvedMenuIndex) {
        *resolvedMenuIndex =
            menuIndex;
    }

    if (menuIndex == NSNotFound) {
        return items.copy;
    }

    NSArray *backingViews =
        SLReplicaBackingViews(
            representation);

    for (id backingView in backingViews) {
        id correspondingItem =
            SLReplicaSubviewAtMenuIndex(
                representation,
                menuIndex,
                backingView);

        SLAppendUniqueReplicaItem(
            items,
            correspondingItem);
    }

    return items.copy;
}

static NSArray<NSView *> *
SLUnionReplicaItemArrays(
    NSArray<NSView *> *first,
    NSArray<NSView *> *second
) {
    NSMutableArray<NSView *> *result =
        [NSMutableArray array];

    for (NSView *view in first ?: @[]) {
        SLAppendUniqueReplicaItem(
            result,
            view);
    }

    for (NSView *view in second ?: @[]) {
        SLAppendUniqueReplicaItem(
            result,
            view);
    }

    return result.copy;
}

static void SLRedrawReplicaItem(
    NSView *view,
    BOOL highlighted
) {
    if (!view ||
        !IsMenuBarItem(view)) {
        return;
    }

    SLStoreReplicaForcedHighlight(
        view,
        highlighted);

    RefreshTitle(view);

    [view setNeedsDisplay:YES];

    if (!NSIsEmptyRect(view.bounds)) {
        [view
            displayRectIgnoringOpacity:
                view.bounds];
    }

    [view displayIfNeeded];
}

static void SLApplyHighlightToReplicaItems(
    NSArray<NSView *> *items,
    BOOL highlighted
) {
    for (NSView *view in items) {
        SLRedrawReplicaItem(
            view,
            highlighted);
    }
}

static void SLScheduleReplicaSynchronization(
    id menuBarImplementation,
    NSView *sourceItem,
    BOOL highlighted
) {
    if (!menuBarImplementation) {
        return;
    }

    NSObject *token =
        [NSObject new];

    objc_setAssociatedObject(
        menuBarImplementation,
        &SLReplicaSynchronizationTokenKey,
        token,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSInteger menuIndex =
        NSNotFound;

    NSArray<NSView *> *resolvedItems =
        SLResolveMenuBarReplicaItems(
            menuBarImplementation,
            sourceItem,
            &menuIndex);

    NSArray<NSView *> *storedItems =
        objc_getAssociatedObject(
            menuBarImplementation,
            &SLStoredReplicaItemsKey);

    NSArray<NSView *> *initialItems =
        highlighted
        ? resolvedItems
        : SLUnionReplicaItemArrays(
            storedItems,
            resolvedItems);

    if (highlighted &&
        initialItems.count > 0) {
        objc_setAssociatedObject(
            menuBarImplementation,
            &SLStoredReplicaItemsKey,
            initialItems,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    SLApplyHighlightToReplicaItems(
        initialItems,
        highlighted);

    SLLog(
        [NSString stringWithFormat:
            @"replica sync highlighted=%d menuIndex=%ld count=%lu",
            highlighted,
            (long)menuIndex,
            (unsigned long)initialItems.count]);

    static const NSTimeInterval delays[] = {
        0.0,
        0.030,
        0.120,
        0.350,
        0.850
    };

    for (NSUInteger index = 0;
         index < sizeof(delays) / sizeof(delays[0]);
         index++) {
        NSTimeInterval delay =
            delays[index];

        BOOL isLastDelay =
            index + 1 ==
            sizeof(delays) / sizeof(delays[0]);

        __weak id weakMenuBarImplementation =
            menuBarImplementation;

        __weak NSView *weakSourceItem =
            sourceItem;

        NSArray<NSView *> *fallbackItems =
            initialItems.copy;

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(
                    delay * NSEC_PER_SEC)),
            dispatch_get_main_queue(),
            ^{
                id strongMenuBarImplementation =
                    weakMenuBarImplementation;

                if (!strongMenuBarImplementation) {
                    return;
                }

                id currentToken =
                    objc_getAssociatedObject(
                        strongMenuBarImplementation,
                        &SLReplicaSynchronizationTokenKey);

                if (currentToken != token) {
                    return;
                }

                NSView *strongSourceItem =
                    weakSourceItem;

                NSInteger freshMenuIndex =
                    NSNotFound;

                NSArray<NSView *> *freshItems =
                    strongSourceItem
                    ? SLResolveMenuBarReplicaItems(
                        strongMenuBarImplementation,
                        strongSourceItem,
                        &freshMenuIndex)
                    : @[];

                NSArray<NSView *> *targets =
                    SLUnionReplicaItemArrays(
                        fallbackItems,
                        freshItems);

                if (highlighted &&
                    targets.count > 0) {
                    objc_setAssociatedObject(
                        strongMenuBarImplementation,
                        &SLStoredReplicaItemsKey,
                        targets,
                        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }

                SLApplyHighlightToReplicaItems(
                    targets,
                    highlighted);

                if (isLastDelay &&
                    !highlighted) {
                    objc_setAssociatedObject(
                        strongMenuBarImplementation,
                        &SLStoredReplicaItemsKey,
                        nil,
                        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            });
    }
}

static void DrawSelectionGradient(NSView *view) {
    SLDrawSharedSnowLeopardSelection(view);
}

static CTLineRef CachedLineForMenuBarItem(
    id view
) {
    if (!IsMenuBarItem(view) ||
        !CachedLineIvar) {
        return NULL;
    }

    uintptr_t base =
        (uintptr_t)(__bridge void *)view;

    CTLineRef *slot =
        (CTLineRef *)(
            base + ivar_getOffset(CachedLineIvar));

    return slot ? *slot : NULL;
}

static void DrawHighlightedMenuBarTitle(
    NSView *view
) {
    if (!view || !IsMenuBarItem(view)) {
        return;
    }

    CTLineRef line =
        CachedLineForMenuBarItem(view);

    /*
     * En algunas aplicaciones idealWidth crea la línea antes
     * de drawRect; en otras se crea durante layoutTitleIfNeeded.
     */
    if (!line && OriginalMenuItemLayoutTitle) {
        WithMenuTitleColour(YES, ^{
            OriginalMenuItemLayoutTitle(
                view,
                NSSelectorFromString(
                    @"layoutTitleIfNeeded"));
        });

        line =
            CachedLineForMenuBarItem(view);
    }

    if (!line) {
        return;
    }

    CGContextRef context =
        NSGraphicsContext.currentContext.CGContext;

    NSRect bounds = view.bounds;

    if (!context || NSIsEmptyRect(bounds)) {
        return;
    }

    CGFloat ascent = 0.0;
    CGFloat descent = 0.0;

    CGFloat lineWidth =
        (CGFloat)CTLineGetTypographicBounds(
            line,
            &ascent,
            &descent,
            NULL);

    if (!(lineWidth > 0.0)) {
        return;
    }

    CGFloat penOffset =
        (CGFloat)CTLineGetPenOffsetForFlush(
            line,
            0.5,
            NSWidth(bounds));

    CGFloat baseline =
        NSMinY(bounds) +
        floor(
            (
                NSHeight(bounds) -
                ascent -
                descent
            ) * 0.5 +
            descent +
            0.5
        );

    CGContextSaveGState(context);

    /*
     * CoreText trabaja con un eje Y hacia arriba.
     * AppKit usa un NSMenuBarItemView volteado.
     */
    if (view.isFlipped) {
        CGContextTranslateCTM(
            context,
            0.0,
            NSMinY(bounds) + NSMaxY(bounds));

        CGContextScaleCTM(
            context,
            1.0,
            -1.0);
    }

    CGColorRef shadowColour =
        CGColorCreateSRGB(
            0.0,
            28.0 / 255.0,
            119.0 / 255.0,
            0.82);

    CGContextSetShadowWithColor(
        context,
        CGSizeMake(0.0, -1.0),
        0.75,
        shadowColour);

    CGColorRelease(shadowColour);

    CGContextSetTextMatrix(
        context,
        CGAffineTransformIdentity);

    CGContextSetTextPosition(
        context,
        NSMinX(bounds) + penOffset,
        baseline);

    /*
     * La línea fue creada dentro de WithMenuTitleColour(YES),
     * por lo que mantiene los glifos exactos y el color blanco.
     */
    CTLineDraw(line, context);

    CGContextRestoreGState(context);
}

static void DrawHighlightedMenuBarImage(
    NSView *view
) {
    if (!view ||
        !IsMenuBarItem(view) ||
        !ImageViewIvar) {
        return;
    }

    id candidate =
        object_getIvar(
            view,
            ImageViewIvar);

    if (![candidate
            isKindOfClass:NSImageView.class]) {
        return;
    }

    NSImageView *imageView =
        (NSImageView *)candidate;

    NSImage *image =
        imageView.image;

    if (!image) {
        return;
    }

    NSRect imageRect =
        [view convertRect:imageView.bounds
                 fromView:imageView];

    if (NSIsEmptyRect(imageRect)) {
        return;
    }

    CGContextRef context =
        NSGraphicsContext.currentContext.CGContext;

    if (!context) {
        return;
    }

    [NSGraphicsContext saveGraphicsState];

    /*
     * La capa temporal conserva solamente el alfa del icono,
     * que después se rellena de blanco.
     */
    CGContextBeginTransparencyLayer(
        context,
        NULL);

    [image drawInRect:imageRect
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0
       respectFlipped:YES
                hints:nil];

    CGContextSetBlendMode(
        context,
        kCGBlendModeSourceIn);

    CGContextSetFillColorWithColor(
        context,
        NSColor.whiteColor.CGColor);

    CGContextFillRect(
        context,
        NSRectToCGRect(imageRect));

    CGContextEndTransparencyLayer(context);

    [NSGraphicsContext restoreGraphicsState];
}

static void DrawHighlightedMenuBarContents(
    NSView *view
) {
    DrawHighlightedMenuBarImage(view);
    DrawHighlightedMenuBarTitle(view);
}

static void SnowLeopardMenuItemDrawRect(
    id view,
    SEL selector,
    NSRect dirtyRect
) {
    if (!IsMenuBarItem(view)) {

        OriginalMenuItemDrawRect(
            view,
            selector,
            dirtyRect);

        return;
    }

    PrepareTitleForFirstUse(
        view);

    BOOL highlighted =
        HighlightState(
            view);

    /*
     * Apple Menu:
     *
     * El runtime demostró que la manzana moderna
     * proviene del título "", no de un NSImageView.
     *
     * Por eso no llamamos al renderer nativo para
     * este item.
     */
    if (SLIsAppleMenuItem(view)) {

        NSView *appleView =
            (NSView *)view;

        NSGraphicsContext *graphics =
            NSGraphicsContext.currentContext;

        CGContextRef context =
            graphics
            ? graphics.CGContext
            : NULL;

        if (context) {

            CGContextClearRect(
                context,
                NSRectToCGRect(
                    appleView.bounds));
        }

        if (highlighted) {

            DrawSelectionGradient(
                appleView);
        }

        SLDrawEmbeddedRetinaApple(
            appleView,
            highlighted);

        return;
    }

    /*
     * El resto de menús conserva exactamente
     * la ruta estable del tweak.
     */
    if (!highlighted) {

        WithMenuTitleColour(NO, ^{

            OriginalMenuItemDrawRect(
                view,
                selector,
                dirtyRect);
        });

        return;
    }

    WithMenuTitleColour(YES, ^{

        OriginalMenuItemDrawRect(
            view,
            selector,
            dirtyRect);
    });

    DrawSelectionGradient(
        (NSView *)view);

    DrawHighlightedMenuBarContents(
        (NSView *)view);
}

static double SnowLeopardMenuItemIdealWidth(id view, SEL selector) {
    if (!IsMenuBarItem(view)) {
        return OriginalMenuItemIdealWidth(view, selector);
    }
    PrepareTitleForFirstUse(view);
    if (SLIsAppleMenuItem(view)) {
        /*
         * The supplied 10.6 captures place the Apple item at x=10 with a
         * 35-point selection rect. Sequoia reserves 40 points, shifting the
         * complete application-menu row five points to the right.
         */
        return SLSnowLeopardAppleMenuItemWidth;
    }
    __block double width = 0.0;
    BOOL highlighted = HighlightState(view);
    WithMenuTitleColour(highlighted, ^{
        width = OriginalMenuItemIdealWidth(view, selector);
    });
    return width;
}

static void SnowLeopardMenuItemSetHighlighted(id view, SEL selector,
                                              BOOL highlighted) {
    OriginalMenuItemSetHighlighted(view, selector, highlighted);
    RefreshTitle(view);
}

static void SnowLeopardMenuItemLayoutTitle(id view, SEL selector) {
    PrepareTitleForFirstUse(view);
    OriginalMenuItemLayoutTitle(view, selector);
}

static void SuppressNativeSelectionView(NSView *view) {
    if (!view) return;
    view.hidden = YES;
    view.alphaValue = 0.0;
    if (!view.layer) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    view.layer.opacity = 0.0;
    view.layer.backgroundColor = NSColor.clearColor.CGColor;
    view.layer.contents = nil;
    view.layer.mask = nil;
    view.layer.cornerRadius = 0.0;
    [CATransaction commit];
}

static void ScheduleNativeSelectionSuppression(NSView *view) {
    if (!view) return;
    SuppressNativeSelectionView(view);
    static const NSTimeInterval delays[] = {0.0, 0.025, 0.10, 0.25};
    for (NSUInteger index = 0;
         index < sizeof(delays) / sizeof(delays[0]); index++) {
        __weak NSView *weakView = view;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delays[index] * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                SuppressNativeSelectionView(weakView);
            });
    }
}

static void HideNativeSelection(id menuBarImpl) {
    if (!menuBarImpl ||
        ![menuBarImpl isKindOfClass:MenuBarImplClass]) {
        return;
    }
    SEL materialSelector = NSSelectorFromString(@"selectionMaterialView");
    if (![menuBarImpl respondsToSelector:materialSelector]) return;
    id selectionRect =
        ((id (*)(id, SEL))objc_msgSend)(menuBarImpl, materialSelector);
    if (!selectionRect || !SelectionBackingViewIvar) return;
    if ([selectionRect isKindOfClass:NSView.class]) {
        ScheduleNativeSelectionSuppression(selectionRect);
    }
    id backingView = object_getIvar(selectionRect, SelectionBackingViewIvar);
    if ([backingView isKindOfClass:NSView.class]) {
        ScheduleNativeSelectionSuppression(backingView);
    }
}

// SLDirectSelectionRectStateSuppression
//
// NSMenuSelectionRect hereda directamente de NSObject y no
// expone setters para ocultarse. NSMenuBarImpl modifica sus
// campos internos directamente. Se escribe únicamente sobre
// ivars cuya existencia y codificación fueron verificadas.
static BOOL SLWriteSelectionBoolIvar(
    id object,
    Class objectClass,
    const char *ivarName,
    BOOL value
) {
    if (!object ||
        !objectClass ||
        !ivarName) {
        return NO;
    }

    Ivar ivar =
        class_getInstanceVariable(
            objectClass,
            ivarName);

    if (!ivar) {
        return NO;
    }

    const char *type =
        ivar_getTypeEncoding(ivar);

    if (!type ||
        type[0] != 'B') {
        return NO;
    }

    uint8_t *base =
        (uint8_t *)(__bridge void *)object;

    BOOL *slot =
        (BOOL *)(
            base + ivar_getOffset(ivar));

    *slot = value;

    return YES;
}

static BOOL SLWriteSelectionRectIvar(
    id object,
    Class objectClass,
    const char *ivarName,
    CGRect value
) {
    if (!object ||
        !objectClass ||
        !ivarName) {
        return NO;
    }

    Ivar ivar =
        class_getInstanceVariable(
            objectClass,
            ivarName);

    if (!ivar) {
        return NO;
    }

    const char *type =
        ivar_getTypeEncoding(ivar);

    if (!type ||
        type[0] != '{') {
        return NO;
    }

    uint8_t *base =
        (uint8_t *)(__bridge void *)object;

    CGRect *slot =
        (CGRect *)(
            base + ivar_getOffset(ivar));

    *slot = value;

    return YES;
}

static id SLCurrentNativeSelectionRect(
    id menuBarImpl
) {
    if (!menuBarImpl ||
        !MenuBarImplClass ||
        ![menuBarImpl
            isKindOfClass:MenuBarImplClass]) {
        return nil;
    }

    SEL selector =
        NSSelectorFromString(
            @"selectionMaterialView");

    if (![menuBarImpl
            respondsToSelector:selector]) {
        return nil;
    }

    id selectionObject =
        ((id (*)(id, SEL))objc_msgSend)(
            menuBarImpl,
            selector);

    Class selectionClass =
        NSClassFromString(
            @"NSMenuSelectionRect");

    if (!selectionClass ||
        ![selectionObject
            isKindOfClass:selectionClass]) {
        return nil;
    }

    return selectionObject;
}

static BOOL SLForceNativeSelectionRectHidden(
    id menuBarImpl
) {
    id selectionObject =
        SLCurrentNativeSelectionRect(
            menuBarImpl);

    if (!selectionObject) {
        return NO;
    }

    Class selectionClass =
        NSClassFromString(
            @"NSMenuSelectionRect");

    BOOL valid = YES;

    valid =
        SLWriteSelectionRectIvar(
            selectionObject,
            selectionClass,
            "_frame",
            CGRectZero)
        && valid;

    valid =
        SLWriteSelectionRectIvar(
            selectionObject,
            selectionClass,
            "_cachedFrame",
            CGRectZero)
        && valid;

    valid =
        SLWriteSelectionBoolIvar(
            selectionObject,
            selectionClass,
            "_cachedIsHidden",
            YES)
        && valid;

    valid =
        SLWriteSelectionBoolIvar(
            selectionObject,
            selectionClass,
            "_isHidden",
            YES)
        && valid;

    valid =
        SLWriteSelectionBoolIvar(
            selectionObject,
            selectionClass,
            "_shouldCommitChanges",
            YES)
        && valid;

    valid =
        SLWriteSelectionBoolIvar(
            selectionObject,
            selectionClass,
            "_isAnimationStateCached",
            YES)
        && valid;

    valid =
        SLWriteSelectionBoolIvar(
            selectionObject,
            selectionClass,
            "_cachedShouldAnimate",
            NO)
        && valid;

    valid =
        SLWriteSelectionBoolIvar(
            selectionObject,
            selectionClass,
            "_disableAnimations",
            YES)
        && valid;

    if (SelectionBackingViewIvar) {
        id backingView =
            object_getIvar(
                selectionObject,
                SelectionBackingViewIvar);

        if ([backingView
                isKindOfClass:NSView.class]) {
            SuppressNativeSelectionView(
                (NSView *)backingView);
        }
    }

    return valid;
}

static void SLCommitNativeSelectionRectHidden(
    id menuBarImpl
) {
    if (!SLForceNativeSelectionRectHidden(
            menuBarImpl)) {
        return;
    }

    if (OriginalSelectionLayerDidChange) {
        OriginalSelectionLayerDidChange(
            menuBarImpl,
            NSSelectorFromString(
                @"_selectionLayerDidChange"));
    }

    SLForceNativeSelectionRectHidden(
        menuBarImpl);
}

static void SLScheduleNativeSelectionRectSuppression(
    id menuBarImpl
) {
    if (!menuBarImpl ||
        !MenuBarImplClass ||
        ![menuBarImpl
            isKindOfClass:MenuBarImplClass]) {
        return;
    }

    SLCommitNativeSelectionRectHidden(
        menuBarImpl);

    static const NSTimeInterval delays[] = {
        0.0,
        0.025,
        0.100,
        0.300,
        0.800
    };

    for (NSUInteger index = 0;
         index < sizeof(delays) / sizeof(delays[0]);
         index++) {
        __weak id weakMenuBarImpl =
            menuBarImpl;

        NSTimeInterval delay =
            delays[index];

        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(
                    delay * NSEC_PER_SEC)),
            dispatch_get_main_queue(),
            ^{
                id strongMenuBarImpl =
                    weakMenuBarImpl;

                if (!strongMenuBarImpl) {
                    return;
                }

                SLCommitNativeSelectionRectHidden(
                    strongMenuBarImpl);
            });
    }
}


static void SLPublishTopLevelPopupAnchor(
    NSView *menuItemView,
    BOOL highlighted
) {
    if (!highlighted ||
        !menuItemView ||
        !IsMenuBarItem(menuItemView) ||
        !menuItemView.window) {
        return;
    }

    NSRect itemInWindow =
        [menuItemView convertRect:menuItemView.bounds
                           toView:nil];

    NSRect itemOnScreen =
        [menuItemView.window
            convertRectToScreen:itemInWindow];

    if (NSIsEmptyRect(itemOnScreen)) {
        return;
    }

    NSDictionary *userInfo = @{
        @"minX": @(NSMinX(itemOnScreen)),
        @"maxX": @(NSMaxX(itemOnScreen))
    };

    [[NSNotificationCenter defaultCenter]
        postNotificationName:
            SL_TOP_LEVEL_POPUP_ANCHOR_NOTIFICATION
                      object:nil
                    userInfo:userInfo];
}

static void SnowLeopardMenuBarHighlight(
    id object,
    SEL selector,
    BOOL highlighted,
    id menuItemView
) {
    NSView *sourceItem =
        IsMenuBarItem(menuItemView)
        ? (NSView *)menuItemView
        : nil;

    if (sourceItem) {
        SLStoreReplicaForcedHighlight(
            sourceItem,
            highlighted);
    }

    OriginalMenuBarHighlight(
        object,
        selector,
        highlighted,
        menuItemView);

    SLPublishTopLevelPopupAnchor(
        sourceItem,
        highlighted);

    SLScheduleNativeSelectionRectSuppression(
        object);

    SLScheduleReplicaSynchronization(
        object,
        sourceItem,
        highlighted);
}

static void SnowLeopardSelectionLayerDidChange(
    id object,
    SEL selector
) {
    SLForceNativeSelectionRectHidden(
        object);

    OriginalSelectionLayerDidChange(
        object,
        selector);

    SLForceNativeSelectionRectHidden(
        object);
}

static BOOL ValidateTitleABI(void) {
    TitleHooks = (SLTitleHooks) {
        .textColor = class_getClassMethod(NSColor.class, @selector(textColor)),
        .draw = SLOwnInstanceMethod(MenuBarItemViewClass, @selector(drawRect:)),
        .updateAttributes = SLOwnInstanceMethod(MenuBarItemViewClass,
            NSSelectorFromString(@"_updateAttributesFromItemIncludingFont:includingColor:")),
        .idealWidth = SLOwnInstanceMethod(MenuBarItemViewClass,
            NSSelectorFromString(@"idealWidth")),
        .layoutTitle = SLOwnInstanceMethod(MenuBarItemViewClass,
            NSSelectorFromString(@"layoutTitleIfNeeded")),
        .highlighted = class_getInstanceMethod(
            MenuBarItemViewClass, @selector(setHighlighted:)),
    };

    CachedLineIvar = class_getInstanceVariable(MenuBarItemViewClass, "_cachedLine");
    CachedLineWidthIvar = class_getInstanceVariable(MenuBarItemViewClass, "_cachedLineWidth");
    DidTruncateLineIvar = class_getInstanceVariable(MenuBarItemViewClass, "_didTruncateLine");
    AppleMenuIvar = class_getInstanceVariable(MenuBarItemViewClass, "_isAppleMenu");
    ImageViewIvar = class_getInstanceVariable(MenuBarItemViewClass, "_imageView");
    TitleTextFieldIvar = class_getInstanceVariable(MenuBarItemViewClass, "_titleTextField");

    const char *lineType = CachedLineIvar ? ivar_getTypeEncoding(CachedLineIvar) : NULL;
    const char *widthType = CachedLineWidthIvar ? ivar_getTypeEncoding(CachedLineWidthIvar) : NULL;
    const char *truncateType = DidTruncateLineIvar ? ivar_getTypeEncoding(DidTruncateLineIvar) : NULL;
    const char *appleType = AppleMenuIvar ? ivar_getTypeEncoding(AppleMenuIvar) : NULL;
    const char *imageType = ImageViewIvar ? ivar_getTypeEncoding(ImageViewIvar) : NULL;
    const char *fieldType = TitleTextFieldIvar ? ivar_getTypeEncoding(TitleTextFieldIvar) : NULL;

    return SLMethodMatches(TitleHooks.textColor, "@16@0:8") &&
        SLMethodMatches(TitleHooks.draw, "v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16") &&
        SLMethodMatches(TitleHooks.updateAttributes, "v24@0:8B16B20") &&
        SLMethodMatches(TitleHooks.idealWidth, "d16@0:8") &&
        SLMethodMatches(TitleHooks.layoutTitle, "v16@0:8") &&
        SLMethodMatches(TitleHooks.highlighted, "v20@0:8B16") &&
        lineType && strcmp(lineType, "^{__CTLine=}") == 0 &&
        widthType && strcmp(widthType, "d") == 0 &&
        truncateType && strcmp(truncateType, "B") == 0 &&
        appleType && strcmp(appleType, "B") == 0 &&
        imageType && imageType[0] == '@' && fieldType && fieldType[0] == '@';
}

static BOOL InstallTitleHooks(void) {
    if (TitleHooksInstalled) return YES;
    if (!MenuBarItemViewClass || !TitleHooks.draw) return NO;

    OriginalTextColor = (ColorFn)method_getImplementation(TitleHooks.textColor);
    OriginalMenuItemDrawRect = (DrawRectFn)method_getImplementation(TitleHooks.draw);
    OriginalMenuItemIdealWidth = (DoubleFn)method_getImplementation(TitleHooks.idealWidth);
    OriginalMenuItemLayoutTitle = (VoidFn)method_getImplementation(TitleHooks.layoutTitle);
    IMP oldHighlight = method_getImplementation(TitleHooks.highlighted);
    if (!OriginalTextColor || !OriginalMenuItemDrawRect ||
        !OriginalMenuItemIdealWidth || !OriginalMenuItemLayoutTitle ||
        !oldHighlight) return NO;

    if (!SLInstallOverrideHook(MenuBarItemViewClass, @selector(setHighlighted:),
            "v20@0:8B16", (IMP)SnowLeopardMenuItemSetHighlighted,
            &oldHighlight)) return NO;
    OriginalMenuItemSetHighlighted = (SetBoolFn)oldHighlight;

    method_setImplementation(TitleHooks.textColor, (IMP)SnowLeopardTextColor);
    method_setImplementation(TitleHooks.draw, (IMP)SnowLeopardMenuItemDrawRect);
    method_setImplementation(TitleHooks.idealWidth, (IMP)SnowLeopardMenuItemIdealWidth);
    method_setImplementation(TitleHooks.layoutTitle, (IMP)SnowLeopardMenuItemLayoutTitle);

    TitleHooksInstalled = YES;
    SLLog(@"title hooks installed");
    SLLog(
        @"apple-menu installed "
         "snow-leopard-embedded-retina-png "
         "source=44x44 "
         "logical=22x22 "
         "native2x=1 "
         "blackCanvas=24.1290322581x23.1578947368 "
         "whiteCanvas=22x22 "
         "targetGeometry=sequoia-native-untouched "
         "offsetX=0.5pt "
         "offsetY=0pt "
         "normalContrast=metallic-black-v1 "
         "rgbPolynomial=0.30x+0.16x2 "
         "alphaTone=a+1.30a2-1.30a3 "
         "sourceAtop=0 "
         "geometry=sequoia-native-untouched");
    SLLog(@"appleMenuWidth=snow-leopard-35pt referenceFrame=x10-width35");
    return YES;
}

static void RollBackTitleHooks(void) {
    if (!TitleHooksInstalled || !MenuBarItemViewClass) return;

    SLRestoreOwnHook(object_getClass(NSColor.class), @selector(textColor),
        (IMP)SnowLeopardTextColor, (IMP)OriginalTextColor);
    SLRestoreOwnHook(MenuBarItemViewClass, @selector(drawRect:),
        (IMP)SnowLeopardMenuItemDrawRect, (IMP)OriginalMenuItemDrawRect);
    SLRestoreOwnHook(MenuBarItemViewClass, NSSelectorFromString(@"idealWidth"),
        (IMP)SnowLeopardMenuItemIdealWidth, (IMP)OriginalMenuItemIdealWidth);
    SLRestoreOwnHook(MenuBarItemViewClass,
        NSSelectorFromString(@"layoutTitleIfNeeded"),
        (IMP)SnowLeopardMenuItemLayoutTitle, (IMP)OriginalMenuItemLayoutTitle);
    SLRestoreOwnHook(MenuBarItemViewClass, @selector(setHighlighted:),
        (IMP)SnowLeopardMenuItemSetHighlighted,
        (IMP)OriginalMenuItemSetHighlighted);
    TitleHooksInstalled = NO;
    SLLog(@"title hooks rolled back");
}

static BOOL ValidateSelectionABI(void) {
    MenuBarImplClass = NSClassFromString(@"NSMenuBarImpl");
    Class selectionClass = NSClassFromString(@"NSMenuSelectionRect");
    if (!MenuBarImplClass || !selectionClass) return NO;
    SelectionHooks = (SLSelectionHooks) {
        .highlighted = SLOwnInstanceMethod(MenuBarImplClass,
            NSSelectorFromString(@"_setHighlighted:menuItemView:")),
        .selectionLayerChanged = SLOwnInstanceMethod(MenuBarImplClass,
            NSSelectorFromString(@"_selectionLayerDidChange")),
    };
    SelectionBackingViewIvar = class_getInstanceVariable(selectionClass, "_backingView");
    const char *backingType = SelectionBackingViewIvar
        ? ivar_getTypeEncoding(SelectionBackingViewIvar) : NULL;
    return SLMethodMatches(SelectionHooks.highlighted, "v28@0:8B16@20") &&
        SLMethodMatches(SelectionHooks.selectionLayerChanged, "v16@0:8") &&
        backingType && backingType[0] == '@';
}

static BOOL InstallSelectionHooks(void) {
    if (SelectionHooksInstalled) return YES;
    if (!SelectionHooks.highlighted || !SelectionHooks.selectionLayerChanged) return NO;
    OriginalMenuBarHighlight =
        (MenuHighlightFn)method_getImplementation(SelectionHooks.highlighted);
    OriginalSelectionLayerDidChange =
        (VoidFn)method_getImplementation(SelectionHooks.selectionLayerChanged);
    if (!OriginalMenuBarHighlight || !OriginalSelectionLayerDidChange) return NO;

    method_setImplementation(SelectionHooks.highlighted,
        (IMP)SnowLeopardMenuBarHighlight);
    method_setImplementation(SelectionHooks.selectionLayerChanged,
        (IMP)SnowLeopardSelectionLayerDidChange);
    SelectionHooksInstalled = YES;
    SLLog(@"selection hooks installed");
    return YES;
}

static void RollBackSelectionHooks(void) {
    if (!SelectionHooksInstalled || !MenuBarImplClass) return;
    SLRestoreOwnHook(MenuBarImplClass,
        NSSelectorFromString(@"_setHighlighted:menuItemView:"),
        (IMP)SnowLeopardMenuBarHighlight, (IMP)OriginalMenuBarHighlight);
    SLRestoreOwnHook(MenuBarImplClass,
        NSSelectorFromString(@"_selectionLayerDidChange"),
        (IMP)SnowLeopardSelectionLayerDidChange,
        (IMP)OriginalSelectionLayerDidChange);
    SelectionHooksInstalled = NO;
    SLLog(@"selection hooks rolled back");
}

static void RefreshViewTree(NSView *view) {
    if (!view) return;
    if (IsMenuBarItem(view)) RefreshTitle(view);
    for (NSView *subview in view.subviews.copy) {
        RefreshViewTree(subview);
    }
}

static void RefreshRepresentationWidths(id representation) {
    SEL countSEL = NSSelectorFromString(@"numberOfVisibleItems");
    SEL updateSEL = NSSelectorFromString(@"updateSizeForItemAtVisibleIndex:");
    SEL beginSEL = NSSelectorFromString(@"beginUpdates");
    SEL endSEL = NSSelectorFromString(@"endUpdates");
    SEL layoutSEL = NSSelectorFromString(@"layoutMenuBarImmediately");
    Class cls = [representation class];
    if (!SLMethodMatches(class_getInstanceMethod(cls, countSEL), "q16@0:8") ||
        !SLMethodMatches(class_getInstanceMethod(cls, updateSEL), "v24@0:8q16") ||
        !SLMethodMatches(class_getInstanceMethod(cls, beginSEL), "v16@0:8") ||
        !SLMethodMatches(class_getInstanceMethod(cls, endSEL), "v16@0:8") ||
        !SLMethodMatches(class_getInstanceMethod(cls, layoutSEL), "v16@0:8")) return;

    // Invalidating each CTLine alone leaves _itemWidthsExcludingExtras and
    // _itemOffsets stale. Ask the representation to measure the already
    // styled items before laying out all its replicas in one transaction.
    NSInteger count = ((NSInteger (*)(id, SEL))objc_msgSend)(representation, countSEL);
    if (count < 0 || count > 1024) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    ((VoidFn)objc_msgSend)(representation, beginSEL);
    for (NSInteger index = 0; index < count; index++) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(representation, updateSEL, index);
    }
    ((VoidFn)objc_msgSend)(representation, endSEL);
    ((VoidFn)objc_msgSend)(representation, layoutSEL);
    [CATransaction commit];
}

static void RefreshRepresentation(id representation) {
    if (!representation) return;
    SEL visibleSelector = NSSelectorFromString(@"forEachVisibleSubview:");
    if ([representation respondsToSelector:visibleSelector]) {
        ((ForEachObjectFn)objc_msgSend)(
            representation, visibleSelector, ^(id view) {
                if ([view isKindOfClass:NSView.class]) {
                    RefreshViewTree(view);
                }
            });
    }

    SEL backingSelector = NSSelectorFromString(@"backingViews");
    if ([representation respondsToSelector:backingSelector]) {
        id backingViews =
            ((id (*)(id, SEL))objc_msgSend)(representation, backingSelector);
        if ([backingViews isKindOfClass:NSArray.class]) {
            for (id view in (NSArray *)backingViews) {
                if (![view isKindOfClass:NSView.class]) continue;
                RefreshViewTree(view);
                EnsureFilmView(view);
                StyleReplicantWindow(((NSView *)view).window);
            }
        }
    }
    RefreshRepresentationWidths(representation);
}

static void RefreshExistingMenuBars(void) {
    static BOOL refreshing = NO;
    if (refreshing) return;
    refreshing = YES;
    NSMenu *mainMenu = NSApp.mainMenu;
    SEL implSelector = NSSelectorFromString(@"_menuBarImpl");
    if (mainMenu && [mainMenu respondsToSelector:implSelector]) {
        id implementation =
            ((id (*)(id, SEL))objc_msgSend)(mainMenu, implSelector);
        SEL eachSelector =
            NSSelectorFromString(@"forEachRepresentationViewDo:");
        if ([implementation respondsToSelector:eachSelector]) {
            ((ForEachObjectFn)objc_msgSend)(
                implementation, eachSelector, ^(id representation) {
                    RefreshRepresentation(representation);
                });
        }
        HideNativeSelection(implementation);
    }

    for (NSWindow *window in NSApp.windows.copy) {
        if ([window isKindOfClass:ReplicantWindowClass]) {
            StyleReplicantWindow(window);
        }
    }
    ConfigureMenuBarBackdropWindows();
    refreshing = NO;
}

static void SLSetWallpaperPollingActive(BOOL active) {
    if (!active) {
        [WallpaperRefreshTimer invalidate];
        WallpaperRefreshTimer = nil;
        return;
    }
    if (WallpaperRefreshTimer) return;
    WallpaperRefreshTimer = [NSTimer timerWithTimeInterval:0.5 repeats:YES
        block:^(__unused NSTimer *timer) {
            @autoreleasepool { RefreshDesktopWallpaperIfNeeded(); }
        }];
    WallpaperRefreshTimer.tolerance = 0.05;
    [NSRunLoop.mainRunLoop addTimer:WallpaperRefreshTimer forMode:NSRunLoopCommonModes];
}

static void ArmLifecycleObservers(void) {
    if (ActivationObserver || !NSApp) return;
    ArmMenuBarLowerShadowObservers();
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    ActivationObserver = [center
        addObserverForName:NSApplicationDidBecomeActiveNotification
                    object:NSApp
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
                    RefreshExistingMenuBars();
                    SLSetWallpaperPollingActive(YES);
                }];
    static id deactivationObserver;
    deactivationObserver = [center addObserverForName:NSApplicationDidResignActiveNotification
        object:NSApp queue:NSOperationQueue.mainQueue
        usingBlock:^(__unused NSNotification *notification) {
            SLSetWallpaperPollingActive(NO);
        }];
    (void)deactivationObserver;
    MainMenuObserver = [center
                addObserverForName:NSMenuDidAddItemNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *notification) {
                    if (notification.object != NSApp.mainMenu) return;
                    RefreshExistingMenuBars();
                }];
    // AppKit can replace/change the application title after activation. Its
    // cached widths must be refreshed on those events, not just item additions.
    static NSMutableArray *menuMutationObservers;
    menuMutationObservers = [NSMutableArray array];
    for (NSNotificationName name in @[NSMenuDidChangeItemNotification, NSMenuDidRemoveItemNotification]) {
        [menuMutationObservers addObject:[center addObserverForName:name object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
                if (notification.object == NSApp.mainMenu) RefreshExistingMenuBars();
            }]];
    }
    RefreshDesktopWallpaperIfNeeded();
    SLSetWallpaperPollingActive(NSApp.isActive);
}

static BOOL ValidateCoreABI(void) {
    if (!ValidateBackgroundABI()) return NO;

    MenuBarItemViewClass = NSClassFromString(@"NSMenuBarItemView");
    if (!MenuBarItemViewClass || !ValidateTitleABI()) return NO;

    return ValidateSelectionABI();
}

static void InstallCore(void);

static void RetryCoreInstall(void) {
    CoreInstallState = SLCoreInstallStateIdle;
    if (InstallAttempt++ < 40) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{ InstallCore(); });
    }
}

static void InstallCore(void) {
    if (!SLIsEligibleRegularApplicationProcess()) return;
    if (CoreInstallState != SLCoreInstallStateIdle) return;
    if (!NSApp) {
        RetryCoreInstall();
        return;
    }

    // No runtime method is changed until all three private AppKit surfaces
    // exist and their exact ABI has been validated.
    CoreInstallState = SLCoreInstallStatePreparing;
    if (!ValidateCoreABI()) {
        if (InstallAttempt >= 40) {
            SLLog([NSString stringWithFormat:
                @"core preflight aborted process=%@ pid=%d",
                NSProcessInfo.processInfo.processName, getpid()]);
        }
        RetryCoreInstall();
        return;
    }

    // Commit in dependency order. Selection has no fallible operation after
    // validation; title materializes its inherited override before swapping
    // anything else; background is last and has its own local rollback.
    BOOL selectionReady = InstallSelectionHooks();
    BOOL titleReady = selectionReady && InstallTitleHooks();
    BOOL backgroundReady = titleReady && InstallBackgroundHooks();
    if (!backgroundReady || !titleReady || !selectionReady) {
        RollBackTitleHooks();
        RollBackSelectionHooks();
        if (InstallAttempt >= 40) {
            SLLog([NSString stringWithFormat:
                @"core install aborted process=%@ pid=%d "
                 "background=%d title=%d selection=%d",
                NSProcessInfo.processInfo.processName, getpid(),
                backgroundReady, titleReady, selectionReady]);
        }
        RetryCoreInstall();
        return;
    }

    CoreInstallState = SLCoreInstallStateInstalled;
    SLLog([NSString stringWithFormat:
        @"core install process=%@ pid=%d background=%d title=%d selection=%d",
        NSProcessInfo.processInfo.processName, getpid(),
        backgroundReady, titleReady, selectionReady]);
    SLLog(
        @"menu bar selection coordinator active owner=unified "
         "blueSelectionState=separate-dylib renderer=shared");
    ArmLifecycleObservers();
    RefreshExistingMenuBars();
    dispatch_async(dispatch_get_main_queue(), ^{
        RefreshExistingMenuBars();
    });
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
            RefreshExistingMenuBars();
        });
}

__attribute__((constructor))
static void SnowLeopardMenuBarCoreLoad(void) {
    if (!SLRuntimeIsMacOSSequoia()) return;
    if (!SLIsEligibleRegularApplicationProcess()) return;
    // Run after constructors on the main queue, without intentionally exposing
    // 300ms of unstyled menu geometry. The existing bounded ABI retry remains.
    dispatch_async(dispatch_get_main_queue(), ^{ InstallCore(); });
}
