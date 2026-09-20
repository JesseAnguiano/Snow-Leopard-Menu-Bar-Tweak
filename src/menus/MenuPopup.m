#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <string.h>
#import <unistd.h>
#import <math.h>
#import <dlfcn.h>

#import "Runtime.h"
#import "Protocol.h"
#import "SelectionRenderer.h"

const char SLSnowLeopardPopupCapabilities[] SL_CAPABILITY_EXPORT =
    "snowLeopardPopup=modular-v2 popupArchitecture=single-window-v19 background=owned-shaped-v12 mask=window-corner-mask-v16 shadow=windowserver-stable-v19 selection=blueSelection";

// Popup-background/geometry module for the Unified dylib.
//
// This module does not read CoreUI/CAAR assets and does not load Glow. It
// owns popup background, mask, radius and placement. Selection hooks/state
// are owned exclusively by libSnowLeopardBlueSelection; both dylibs reuse the
// shared exact renderer instead of installing competing selection pipelines.

typedef id (*InitFrameFn)(id, SEL, NSRect);
typedef void (*VoidFn)(id, SEL);
typedef void (*RadiusFn)(id, SEL, CGFloat);
typedef id (*ObjectFn)(id, SEL);
typedef BOOL (*BoolFn)(id, SEL);
typedef void (*OrderWindowFn)(id, SEL, NSWindowOrderingMode, NSInteger);
typedef void (*InvalidateShadowFn)(id, SEL);

static InitFrameFn OriginalRootInit = NULL;
static VoidFn OriginalRootLayout = NULL;
static RadiusFn OriginalMaterialRadius = NULL;
static RadiusFn OriginalViewRadius = NULL;
static RadiusFn OriginalPopupRadius = NULL;
static RadiusFn OriginalManagerRadius = NULL;
static ObjectFn OriginalPopupCornerMask = NULL;
static BoolFn OriginalPopupCornerMaskShouldDefineShadow = NULL;
static OrderWindowFn OriginalPopupOrderWindow = NULL;
static InvalidateShadowFn OriginalPopupInvalidateShadow = NULL;

static Class RootBackgroundClass = Nil;
static Class PopupWindowClass = Nil;
static Class ManagerWindowClass = Nil;

static BOOL IsPopupWindow(id object);

static BOOL Installed = NO;
static NSUInteger InstallAttempts = 0;
static char BackgroundFilmKey;
static char SLPopupRootMaskKey;
static char SLPopupIsSubmenuKey;
static BOOL SLPopupCornerMaskHookInstalled = NO;
static BOOL SLPopupCornerMaskShadowHookInstalled = NO;
static BOOL SLPopupPresentationHookInstalled = NO;
static BOOL SLPopupInvalidateShadowHookInstalled = NO;
static NSImage *SLRoundedPopupCornerMaskImage = nil;
static NSImage *SLSquareTopLeftPopupCornerMaskImage = nil;

/*
 * WindowServer shadow controls.
 *
 * SLSWindowSetShadowProperties is a private SkyLight SPI used by current
 * low-level macOS projects. Resolve it dynamically so the tweak does not
 * acquire a hard link-time dependency on a private framework symbol.
 */
typedef CGError (*SLWindowSetShadowPropertiesFn)(
    uint32_t windowID,
    CFDictionaryRef properties);

static SLWindowSetShadowPropertiesFn
    SLWindowSetShadowProperties = NULL;
static BOOL SLWindowShadowSPIResolved = NO;
static BOOL SLWindowShadowSPIAvailable = NO;

/*
 * Tuned against the compact, soft Snow Leopard menu shadow. Keep these
 * constants centralized so visual calibration does not touch lifecycle or
 * compositor-shape code.
 */
static const CGFloat SLPopupShadowDensity = 0.42;
static const CGFloat SLPopupShadowRadius = 5.5;
static const CGFloat SLPopupShadowVerticalOffset = 2.0;
static const CGFloat SLPopupShadowRimDensity = 0.06;

static CGFloat SLPendingMenuBarAnchorX = NAN;
static CFTimeInterval SLPendingMenuBarAnchorTime = 0.0;
static NSHashTable<NSWindow *> *
    SLAnchoredTopLevelPopupWindows = nil;
static id SLPopupAnchorObserverToken = nil;


static CGColorRef PopupBackgroundColour = NULL;

/*
 * Snow Leopard used a compact five-point popup radius. Menus opened from
 * the menu bar and nested submenus keep the upper-left corner square;
 * free-standing contextual menus and pop-up controls remain rounded on all
 * four corners.
 */
static const CGFloat SLPopupCornerRadius = 5.0;

/*
 * Un menú principal toca la zona inferior de la barra de menú.
 * Los submenús flotan junto a otra ventana de menú.
 */
static BOOL SLWindowIsAttachedToMenuBar(
    NSWindow *window
) {
    if (!window) {
        return NO;
    }

    NSScreen *screen =
        window.screen ?: NSScreen.mainScreen;

    if (!screen) {
        return NO;
    }

    CGFloat difference =
        NSMaxY(window.frame) -
        NSMaxY(screen.visibleFrame);

    if (difference < 0.0) {
        difference = -difference;
    }

    return difference <= 10.0;
}

/*
 * Los submenús se marcan en cuanto encontramos su popup padre. Esto evita
 * confundir un menú contextual independiente con un submenú simplemente
 * porque ambos usan NSPopupMenuWindow.
 */
static BOOL SLPopupUsesSquareTopLeftCorner(
    NSWindow *window
) {
    if (!window) {
        return NO;
    }

    if (SLWindowIsAttachedToMenuBar(window)) {
        return YES;
    }

    NSNumber *isSubmenu =
        objc_getAssociatedObject(
            window,
            &SLPopupIsSubmenuKey);

    return isSubmenu.boolValue;
}

/*
 * Los menús desplegados desde la barra y los submenús conservan la esquina
 * superior izquierda recta, como en Snow Leopard, mientras las otras tres
 * esquinas mantienen el radio pequeño clásico.
 */
static CGPathRef SLCreateTopLeftSquareRoundedPath(
    CGRect bounds,
    CGFloat radius,
    BOOL geometryFlipped
) CF_RETURNS_RETAINED {
    CGFloat minX =
        CGRectGetMinX(bounds);

    CGFloat maxX =
        CGRectGetMaxX(bounds);

    CGFloat minY =
        CGRectGetMinY(bounds);

    CGFloat maxY =
        CGRectGetMaxY(bounds);

    CGFloat maximumRadius =
        MIN(
            CGRectGetWidth(bounds),
            CGRectGetHeight(bounds)
        ) * 0.5;

    CGFloat resolvedRadius =
        MAX(
            0.0,
            MIN(radius, maximumRadius)
        );

    CGMutablePathRef path =
        CGPathCreateMutable();

    if (geometryFlipped) {
        /*
         * Coordenadas visuales:
         *
         * minY = parte superior
         * maxY = parte inferior
         *
         * La esquina superior izquierda se deja recta.
         */
        CGPathMoveToPoint(
            path,
            NULL,
            minX,
            minY);

        CGPathAddLineToPoint(
            path,
            NULL,
            maxX - resolvedRadius,
            minY);

        /*
         * Esquina superior derecha.
         */
        CGPathAddArcToPoint(
            path,
            NULL,
            maxX,
            minY,
            maxX,
            minY + resolvedRadius,
            resolvedRadius);

        CGPathAddLineToPoint(
            path,
            NULL,
            maxX,
            maxY - resolvedRadius);

        /*
         * Esquina inferior derecha.
         */
        CGPathAddArcToPoint(
            path,
            NULL,
            maxX,
            maxY,
            maxX - resolvedRadius,
            maxY,
            resolvedRadius);

        CGPathAddLineToPoint(
            path,
            NULL,
            minX + resolvedRadius,
            maxY);

        /*
         * Esquina inferior izquierda.
         */
        CGPathAddArcToPoint(
            path,
            NULL,
            minX,
            maxY,
            minX,
            maxY - resolvedRadius,
            resolvedRadius);

        /*
         * Regreso vertical directo:
         * esquina superior izquierda completamente cuadrada.
         */
        CGPathAddLineToPoint(
            path,
            NULL,
            minX,
            minY);
    } else {
        /*
         * En una capa no volteada:
         *
         * maxY = parte superior
         * minY = parte inferior
         */
        CGPathMoveToPoint(
            path,
            NULL,
            minX,
            maxY);

        CGPathAddLineToPoint(
            path,
            NULL,
            maxX - resolvedRadius,
            maxY);

        /*
         * Esquina superior derecha.
         */
        CGPathAddArcToPoint(
            path,
            NULL,
            maxX,
            maxY,
            maxX,
            maxY - resolvedRadius,
            resolvedRadius);

        CGPathAddLineToPoint(
            path,
            NULL,
            maxX,
            minY + resolvedRadius);

        /*
         * Esquina inferior derecha.
         */
        CGPathAddArcToPoint(
            path,
            NULL,
            maxX,
            minY,
            maxX - resolvedRadius,
            minY,
            resolvedRadius);

        CGPathAddLineToPoint(
            path,
            NULL,
            minX + resolvedRadius,
            minY);

        /*
         * Esquina inferior izquierda.
         */
        CGPathAddArcToPoint(
            path,
            NULL,
            minX,
            minY,
            minX,
            minY + resolvedRadius,
            resolvedRadius);

        /*
         * Superior izquierda recta.
         */
        CGPathAddLineToPoint(
            path,
            NULL,
            minX,
            maxY);
    }

    CGPathCloseSubpath(path);

    return path;
}

static NSBezierPath *SLTopLeftSquareRoundedBorderPath(
    NSRect bounds,
    CGFloat radius
) {
    CGFloat minX =
        NSMinX(bounds);

    CGFloat maxX =
        NSMaxX(bounds);

    CGFloat minY =
        NSMinY(bounds);

    CGFloat maxY =
        NSMaxY(bounds);

    CGFloat maximumRadius =
        MIN(
            NSWidth(bounds),
            NSHeight(bounds)
        ) * 0.5;

    CGFloat resolvedRadius =
        MAX(
            0.0,
            MIN(radius, maximumRadius)
        );

    const CGFloat kappa =
        0.55228475;

    NSBezierPath *path =
        [NSBezierPath bezierPath];

    /*
     * Superior izquierda cuadrada para la unión con la barra.
     */
    [path moveToPoint:
        NSMakePoint(
            minX,
            minY)];

    [path lineToPoint:
        NSMakePoint(
            maxX - resolvedRadius,
            minY)];

    /*
     * Superior derecha.
     */
    [path curveToPoint:
        NSMakePoint(
            maxX,
            minY + resolvedRadius)
         controlPoint1:
        NSMakePoint(
            maxX - resolvedRadius +
                resolvedRadius * kappa,
            minY)
         controlPoint2:
        NSMakePoint(
            maxX,
            minY + resolvedRadius -
                resolvedRadius * kappa)];

    [path lineToPoint:
        NSMakePoint(
            maxX,
            maxY - resolvedRadius)];

    /*
     * Inferior derecha.
     */
    [path curveToPoint:
        NSMakePoint(
            maxX - resolvedRadius,
            maxY)
         controlPoint1:
        NSMakePoint(
            maxX,
            maxY - resolvedRadius +
                resolvedRadius * kappa)
         controlPoint2:
        NSMakePoint(
            maxX - resolvedRadius +
                resolvedRadius * kappa,
            maxY)];

    [path lineToPoint:
        NSMakePoint(
            minX + resolvedRadius,
            maxY)];

    /*
     * Inferior izquierda.
     */
    [path curveToPoint:
        NSMakePoint(
            minX,
            maxY - resolvedRadius)
         controlPoint1:
        NSMakePoint(
            minX + resolvedRadius -
                resolvedRadius * kappa,
            maxY)
         controlPoint2:
        NSMakePoint(
            minX,
            maxY - resolvedRadius +
                resolvedRadius * kappa)];

    /*
     * Línea vertical hasta la esquina superior izquierda.
     * No se dibuja ninguna curva ahí.
     */
    [path lineToPoint:
        NSMakePoint(
            minX,
            minY)];

    [path closePath];

    return path;
}

static CGPathRef SLCreateFullyRoundedPath(
    CGRect bounds,
    CGFloat radius
) CF_RETURNS_RETAINED {
    CGFloat maximumRadius =
        MIN(
            CGRectGetWidth(bounds),
            CGRectGetHeight(bounds)
        ) * 0.5;

    CGFloat resolvedRadius =
        MAX(
            0.0,
            MIN(radius, maximumRadius)
        );

    return CGPathCreateWithRoundedRect(
        bounds,
        resolvedRadius,
        resolvedRadius,
        NULL);
}


/*
 * WindowServer corner-mask bridge (v16)
 *
 * AppKit has a private -[NSWindow _cornerMask] path that is forwarded to the
 * window compositor. Unlike a CALayer mask, this describes the real window
 * silhouette to the compositor, so the native shadow can follow the same
 * rounded outline instead of casting from a rectangular backing surface.
 *
 * This is installed only on NSPopupMenuWindow; ordinary application windows
 * are left untouched.
 */
static NSImage *SLBuildPopupCornerMaskImage(
    BOOL squareTopLeft
) {
    CGFloat radius = SLPopupCornerRadius;
    CGFloat dimension = (radius * 2.0) + 1.0;
    NSSize size = NSMakeSize(dimension, dimension);

    NSImage *image = [NSImage
        imageWithSize:size
        flipped:NO
        drawingHandler:^BOOL(NSRect destinationRect) {
            CGContextRef context =
                NSGraphicsContext.currentContext.CGContext;

            if (!context) {
                return NO;
            }

            CGPathRef path =
                squareTopLeft
                    ? SLCreateTopLeftSquareRoundedPath(
                        NSRectToCGRect(destinationRect),
                        radius,
                        NO)
                    : SLCreateFullyRoundedPath(
                        NSRectToCGRect(destinationRect),
                        radius);

            if (!path) {
                return NO;
            }

            CGContextSaveGState(context);
            CGContextSetShouldAntialias(context, true);
            CGContextSetAllowsAntialiasing(context, true);
            CGContextSetFillColorWithColor(
                context,
                NSColor.blackColor.CGColor);
            CGContextAddPath(context, path);
            CGContextFillPath(context);
            CGContextRestoreGState(context);

            CGPathRelease(path);
            return YES;
        }];

    if (!image) {
        return nil;
    }

    image.capInsets =
        NSEdgeInsetsMake(
            radius,
            radius,
            radius,
            radius);
    image.resizingMode = NSImageResizingModeStretch;

    /* Static cache owns these masks for the process lifetime. */
    return image;
}

static NSImage *SLPopupCornerMaskImage(
    BOOL squareTopLeft
) {
    if (squareTopLeft) {
        if (!SLSquareTopLeftPopupCornerMaskImage) {
            SLSquareTopLeftPopupCornerMaskImage =
                SLBuildPopupCornerMaskImage(YES);
        }
        return SLSquareTopLeftPopupCornerMaskImage;
    }

    if (!SLRoundedPopupCornerMaskImage) {
        SLRoundedPopupCornerMaskImage =
            SLBuildPopupCornerMaskImage(NO);
    }
    return SLRoundedPopupCornerMaskImage;
}

static id SnowLeopardPopupCornerMask(
    id object,
    SEL selector
) {
    if (!object ||
        !PopupWindowClass ||
        ![object isKindOfClass:PopupWindowClass]) {
        return OriginalPopupCornerMask
            ? OriginalPopupCornerMask(object, selector)
            : nil;
    }

    NSWindow *window = (NSWindow *)object;
    NSImage *mask =
        SLPopupCornerMaskImage(
            SLPopupUsesSquareTopLeftCorner(window));

    if (mask) {
        return mask;
    }

    return OriginalPopupCornerMask
        ? OriginalPopupCornerMask(object, selector)
        : nil;
}

static BOOL SnowLeopardPopupCornerMaskShouldDefineShadow(
    id object,
    SEL selector
) {
    if (object &&
        PopupWindowClass &&
        [object isKindOfClass:PopupWindowClass]) {
        return YES;
    }

    return OriginalPopupCornerMaskShouldDefineShadow
        ? OriginalPopupCornerMaskShouldDefineShadow(object, selector)
        : NO;
}

static BOOL SLPopupCanUseNativeShapedShadow(
    NSWindow *window
) {
    return window &&
        PopupWindowClass &&
        [window isKindOfClass:PopupWindowClass] &&
        SLPopupCornerMaskHookInstalled;
}

static void SLResolveWindowShadowSPI(void) {
    if (SLWindowShadowSPIResolved) {
        return;
    }

    SLWindowShadowSPIResolved = YES;

    /*
     * SkyLight currently exports the SLS-prefixed symbol. Older reverse-
     * engineered interfaces document the same ABI under the CGS prefix.
     * Resolve both names for compatibility without linking either directly.
     */
    void *symbol =
        dlsym(RTLD_DEFAULT, "SLSWindowSetShadowProperties");

    if (!symbol) {
        symbol =
            dlsym(RTLD_DEFAULT, "CGSWindowSetShadowProperties");
    }

    if (symbol) {
        SLWindowSetShadowProperties =
            (SLWindowSetShadowPropertiesFn)symbol;
        SLWindowShadowSPIAvailable = YES;
        SLLog(@"WindowServer shadow-properties SPI available");
    } else {
        SLLog(@"WindowServer shadow-properties SPI unavailable; using AppKit defaults");
    }
}

static void SLTuneSnowLeopardWindowShadow(NSWindow *window) {
    if (!SLPopupCanUseNativeShapedShadow(window) ||
        window.windowNumber <= 0) {
        return;
    }

    SLResolveWindowShadowSPI();

    /*
     * Only calibrate WindowServer's existing shadow. This deliberately
     * does not invalidate the shadow here: this routine is also called from
     * our -invalidateShadow hook, so doing so would recurse.
     */
    if (SLWindowShadowSPIAvailable &&
        SLWindowSetShadowProperties) {
        NSDictionary *properties = @{
            @"com.apple.WindowShadowDensity":
                @(SLPopupShadowDensity),
            @"com.apple.WindowShadowRadius":
                @(SLPopupShadowRadius),
            @"com.apple.WindowShadowVerticalOffset":
                @(SLPopupShadowVerticalOffset),
            @"com.apple.WindowShadowRimDensity":
                @(SLPopupShadowRimDensity)
        };

        CGError error =
            SLWindowSetShadowProperties(
                (uint32_t)window.windowNumber,
                (__bridge CFDictionaryRef)properties);

        if (error != kCGErrorSuccess) {
            SLLog([NSString stringWithFormat:
                @"WindowServer shadow-properties error=%d window=%ld",
                (int)error,
                (long)window.windowNumber]);
        }
    }
}

static void SLCommitSnowLeopardWindowShadow(NSWindow *window) {
    if (!SLPopupCanUseNativeShapedShadow(window)) {
        if (window && IsPopupWindow(window)) {
            window.hasShadow = NO;
        }
        return;
    }

    /*
     * Make AppKit create/rebuild the real shadow only after the popup has
     * actually been ordered and therefore has a valid WindowServer window ID.
     * The popup -invalidateShadow hook reapplies our exact parameters after
     * AppKit performs every rebuild, so hover/layout updates cannot switch the
     * shadow back to a different appearance.
     */
    if (!window.hasShadow) {
        window.hasShadow = YES;
    }

    [window invalidateShadow];

    /* Defensive fallback if the private popup class cannot be hooked. */
    if (!SLPopupInvalidateShadowHookInstalled) {
        SLTuneSnowLeopardWindowShadow(window);
    }
}

static void SLRefreshPopupCompositorShape(
    NSWindow *window
) {
    if (!SLPopupCanUseNativeShapedShadow(window)) {
        if (window && IsPopupWindow(window)) {
            window.hasShadow = NO;
        }
        return;
    }

    /*
     * _cornerMaskChanged forwards the current _cornerMask to AppKit's
     * WindowServer bridge. Run it after submenu classification so a submenu
     * receives the three-rounded-corners mask with a square upper-left corner.
     * Shadow calibration is intentionally separate: layout/hover may
     * refresh this mask, but they no longer become the trigger that changes
     * the visible shadow style.
     */
    SEL changedSEL =
        NSSelectorFromString(@"_cornerMaskChanged");

    if ([window respondsToSelector:changedSEL]) {
        void (*changedFn)(id, SEL) =
            (void (*)(id, SEL))[window
                methodForSelector:changedSEL];

        if (changedFn) {
            changedFn(window, changedSEL);
        }
    }
}

static NSBezierPath *SLFullyRoundedBorderPath(
    NSRect bounds,
    CGFloat radius
) {
    CGFloat maximumRadius =
        MIN(
            NSWidth(bounds),
            NSHeight(bounds)
        ) * 0.5;

    CGFloat resolvedRadius =
        MAX(
            0.0,
            MIN(radius, maximumRadius)
        );

    return [NSBezierPath
        bezierPathWithRoundedRect:bounds
                     xRadius:resolvedRadius
                     yRadius:resolvedRadius];
}

static void SLApplySinglePopupMask(
    NSView *root
) {
    if (!root ||
        NSIsEmptyRect(root.bounds)) {
        return;
    }

    root.wantsLayer = YES;

    CALayer *layer =
        root.layer;

    if (!layer) {
        return;
    }

    CAShapeLayer *mask =
        objc_getAssociatedObject(
            root,
            &SLPopupRootMaskKey);

    if (!mask) {
        mask =
            [CAShapeLayer layer];

        mask.fillColor =
            NSColor.blackColor.CGColor;

        mask.actions = @{
            @"bounds": NSNull.null,
            @"position": NSNull.null,
            @"path": NSNull.null
        };

        objc_setAssociatedObject(
            root,
            &SLPopupRootMaskKey,
            mask,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    BOOL squareTopLeft =
        SLPopupUsesSquareTopLeftCorner(
            root.window);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    mask.frame =
        layer.bounds;

    CGPathRef path = NULL;

    if (squareTopLeft) {
        /*
         * Menú principal o submenú: esquina superior izquierda recta.
         */
        path =
            SLCreateTopLeftSquareRoundedPath(
                layer.bounds,
                SLPopupCornerRadius,
                layer.geometryFlipped);
    } else {
        /*
         * Menú contextual o popup de control independiente:
         * radio Snow Leopard en las cuatro esquinas.
         */
        path =
            SLCreateFullyRoundedPath(
                layer.bounds,
                SLPopupCornerRadius);
    }

    mask.path = path;

    if (path) {
        CGPathRelease(path);
    }

    layer.mask = mask;
    layer.masksToBounds = YES;

    [CATransaction commit];
}

/*
 * Single-window popup compositor
 *
 * AppKit can compute a rectangular native shadow even when the visible popup
 * is rounded. This fixes the compositor silhouette itself through NSWindow's
 * private corner-mask path.
 * The system shadow can therefore be used again without auxiliary windows,
 * overlay layers, timers, observers, or delayed cleanup.
 */
static NSView *SLPopupOutermostContainer(
    NSWindow *window
) {
    if (!window || !IsPopupWindow(window)) {
        return nil;
    }

    NSView *view = window.contentView;

    if (!view) {
        return nil;
    }

    while (view.superview &&
           view.superview.window == window) {
        view = view.superview;
    }

    return view;
}

static void SLPreparePopupOuterContainer(
    NSWindow *window
) {
    if (!window || !IsPopupWindow(window)) {
        return;
    }

    NSView *container =
        SLPopupOutermostContainer(window);

    if (!container ||
        NSIsEmptyRect(container.bounds)) {
        return;
    }

    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;

    container.wantsLayer = YES;

    CALayer *layer = container.layer;

    if (!layer) {
        return;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    layer.opaque = NO;
    layer.backgroundColor =
        NSColor.clearColor.CGColor;
    layer.borderWidth = 0.0;
    layer.borderColor = NULL;

    /*
     * Do not mask the outer container. The visible menu surface is clipped by
     * the root/film masks, while -_cornerMask supplies the real compositor
     * silhouette. AppKit can therefore draw its external shadow outside this
     * transparent container without exposing rectangular corner artifacts.
     */
    layer.mask = nil;
    layer.masksToBounds = NO;

    [CATransaction commit];
}

@interface SLSnowLeopardPopupBackgroundFilmView : NSView
@end

static void PreparePopupPalette(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        PopupBackgroundColour = SLCreateSRGBColor(
            243.0 / 255.0, 243.0 / 255.0, 245.0 / 255.0, 1.0);
    });
}

@implementation SLSnowLeopardPopupBackgroundFilmView

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)isOpaque {
    /*
     * La película sólo es opaca dentro de su máscara.
     * Declararla completamente opaca hacía visible el rectángulo
     * de respaldo en las esquinas.
     */
    return NO;
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

    PreparePopupPalette();

    CGContextRef context =
        NSGraphicsContext.currentContext.CGContext;

    NSRect bounds =
        self.bounds;

    if (!context ||
        NSIsEmptyRect(bounds)) {
        return;
    }

    /*
     * Dibujar la propia superficie del menú con la silueta final.
     *
     * Las revisiones anteriores rellenaban un rectángulo y confiaban en una
     * máscara exterior para borrar las esquinas. En algunas configuraciones
     * de AppKit el backing/material se compone fuera de ese recorte y deja
     * visibles pequeños cuadrados claros. Aquí el fondo que nosotros
     * poseemos nunca pinta esos píxeles: las esquinas nacen transparentes.
     */
    BOOL squareTopLeft =
        SLPopupUsesSquareTopLeftCorner(
            self.window);

    NSBezierPath *surface =
        squareTopLeft
            ? SLTopLeftSquareRoundedBorderPath(
                bounds,
                SLPopupCornerRadius)
            : SLFullyRoundedBorderPath(
                bounds,
                SLPopupCornerRadius);

    [NSGraphicsContext saveGraphicsState];
    [surface addClip];

    CGContextSetFillColorWithColor(
        context,
        PopupBackgroundColour);

    CGContextFillRect(
        context,
        NSRectToCGRect(bounds));

    [NSGraphicsContext restoreGraphicsState];

    /*
     * El borde usa exactamente la misma geometría, medio punto hacia dentro
     * para que el antialiasing quede contenido dentro de la superficie.
     */
    NSRect borderBounds =
        NSInsetRect(
            bounds,
            0.5,
            0.5);

    CGFloat borderRadius =
        MAX(
            0.0,
            SLPopupCornerRadius - 0.5);

    NSBezierPath *border =
        squareTopLeft
            ? SLTopLeftSquareRoundedBorderPath(
                borderBounds,
                borderRadius)
            : SLFullyRoundedBorderPath(
                borderBounds,
                borderRadius);

    [[NSColor colorWithSRGBRed:
        145.0 / 255.0
                             green:
        145.0 / 255.0
                              blue:
        145.0 / 255.0
                             alpha:
        0.90] setStroke];

    border.lineWidth = 1.0;
    [border stroke];
}

@end

static CALayer *LayerIvar(id object, const char *name) {
    id value = SLObjectIvar(object, name);
    return [value isKindOfClass:CALayer.class] ? value : nil;
}

static void SetNumericIvarToZero(id object, const char *name) {
    if (!object) return;
    for (Class cls = object_getClass(object); cls;
         cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        uint8_t *address =
            (uint8_t *)(__bridge void *)object + ivar_getOffset(ivar);
        if (type && type[0] == 'd') {
            *((double *)address) = 0.0;
        } else if (type && type[0] == 'f') {
            *((float *)address) = 0.0f;
        }
        return;
    }
}

static NSDictionary *NoPopupAnimations(void) {
    static NSDictionary *actions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        actions = @{
            @"bounds": NSNull.null,
            @"position": NSNull.null,
            @"cornerRadius": NSNull.null,
            @"contents": NSNull.null,
            @"opacity": NSNull.null,
            @"transform": NSNull.null,
            @"sublayerTransform": NSNull.null
        };
    });
    return actions;
}

static void SquareLayer(CALayer *layer, BOOL recurse) {
    if (!layer) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.cornerRadius = 0.0;
    layer.mask = nil;
    layer.masksToBounds = NO;
    layer.actions = NoPopupAnimations();
    [layer removeAnimationForKey:@"bounds"];
    [layer removeAnimationForKey:@"position"];
    [layer removeAnimationForKey:@"cornerRadius"];
    [layer removeAnimationForKey:@"contents"];
    [layer removeAnimationForKey:@"opacity"];
    [layer removeAnimationForKey:@"transform"];
    [layer removeAnimationForKey:@"sublayerTransform"];
    if (recurse) {
        for (CALayer *child in layer.sublayers.copy) {
            SquareLayer(child, YES);
        }
    }
    [CATransaction commit];
}

static void SquareVisualEffectView(NSView *view, BOOL recurseLayers) {
    if (!view) return;
    SetNumericIvarToZero(view, "_materialCornerRadius");
    SetNumericIvarToZero(view, "_cornerRadius");
    SquareLayer(view.layer, recurseLayers);
    SquareLayer(LayerIvar(view, "_materialLayerActive"), NO);
    SquareLayer(LayerIvar(view, "_materialLayerInactive"), NO);
}

static BOOL IsPopupWindow(id object) {
    return object &&
        ((PopupWindowClass && [object isKindOfClass:PopupWindowClass]) ||
         (ManagerWindowClass && [object isKindOfClass:ManagerWindowClass]));
}

static BOOL IsRootBackground(id object) {
    return object && RootBackgroundClass &&
        [object isKindOfClass:RootBackgroundClass];
}

static void EnsureBackgroundFilm(NSView *root) {
    if (!root) return;
    SquareVisualEffectView(root, NO);

    SLSnowLeopardPopupBackgroundFilmView *film =
        objc_getAssociatedObject(root, &BackgroundFilmKey);
    if (!film) {
        film = [[SLSnowLeopardPopupBackgroundFilmView alloc]
            initWithFrame:root.bounds];
        film.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        objc_setAssociatedObject(root, &BackgroundFilmKey, film,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    film.frame = root.bounds;
    if (film.superview != root) {
        [root addSubview:film positioned:NSWindowBelow relativeTo:nil];
    } else if (root.subviews.firstObject != film) {
        [film removeFromSuperviewWithoutNeedingDisplay];
        [root addSubview:film positioned:NSWindowBelow relativeTo:nil];
    }
    [film setNeedsDisplay:YES];

    /*
     * Keep the legacy material layers transparent. The film supplies the
     * classic Snow Leopard fill; the single outer window mask clips both the
     * film and any remaining AppKit backing in one place.
     */
    root.wantsLayer = YES;
    film.wantsLayer = YES;

    CALayer *rootLayer =
        root.layer;

    CALayer *filmLayer =
        film.layer;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if (rootLayer) {
        rootLayer.opaque = NO;
        rootLayer.backgroundColor =
            NSColor.clearColor.CGColor;
        rootLayer.borderWidth = 0.0;
        rootLayer.borderColor = NULL;
    }

    if (filmLayer) {
        filmLayer.opaque = NO;
        filmLayer.backgroundColor =
            NSColor.clearColor.CGColor;
        filmLayer.borderWidth = 0.0;
        filmLayer.borderColor = NULL;
    }

    /*
     * Estas capas pertenecen al material moderno de AppKit.
     * Si permanecen visibles, forman una esquina cuadrada detrás
     * del contorno personalizado.
     */
    CALayer *activeMaterial =
        LayerIvar(
            root,
            "_materialLayerActive");

    CALayer *inactiveMaterial =
        LayerIvar(
            root,
            "_materialLayerInactive");

    if (activeMaterial) {
        activeMaterial.opacity = 0.0;
        activeMaterial.backgroundColor =
            NSColor.clearColor.CGColor;
        activeMaterial.borderWidth = 0.0;
        activeMaterial.borderColor = NULL;
    }

    if (inactiveMaterial) {
        inactiveMaterial.opacity = 0.0;
        inactiveMaterial.backgroundColor =
            NSColor.clearColor.CGColor;
        inactiveMaterial.borderWidth = 0.0;
        inactiveMaterial.borderColor = NULL;
    }

    [CATransaction commit];

    /*
     * El recorte principal vive en la superficie real que dibuja el fondo.
     * Así CABackdropLayer/materiales privados que cuelguen del root no pueden
     * sobresalir en las esquinas. El contorno equivalente también se entrega
     * al compositor mediante -_cornerMask para que la sombra siga esa forma.
     */
    SLApplySinglePopupMask(root);
    SLApplySinglePopupMask(film);

}

static const CGFloat SLTopLevelPopupOverlap = 1.0;

static void AlignTopLevelPopupWithMenuBar(
    NSWindow *window
) {
    if (!IsPopupWindow(window)) {
        return;
    }

    NSScreen *screen = window.screen;

    if (!screen) {
        screen = NSScreen.mainScreen;
    }

    if (!screen) {
        return;
    }

    NSRect frame = window.frame;

    CGFloat visibleTop =
        NSMaxY(screen.visibleFrame);

    CGFloat popupTop =
        NSMaxY(frame);

    CGFloat separation =
        popupTop - visibleTop;

    /*
     * Solamente se ajustan ventanas cuya parte superior está
     * pegada a la zona inferior de la barra de menú.
     *
     * Así no se desplazan menús contextuales abiertos en otras
     * partes de la pantalla.
     */
    if (separation < -3.0 ||
        separation > 3.0) {
        return;
    }

    CGFloat targetTop =
        visibleTop + SLTopLevelPopupOverlap;

    CGFloat correction =
        targetTop - popupTop;

    if (correction > -0.01 &&
        correction < 0.01) {
        return;
    }

    frame.origin.y += correction;

    [window setFrameOrigin:frame.origin];
}

static void SLInstallPopupAnchorObserver(void) {
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        SLAnchoredTopLevelPopupWindows =
            [NSHashTable weakObjectsHashTable];

        SLPopupAnchorObserverToken =
            [[NSNotificationCenter defaultCenter]
                addObserverForName:
                    SL_TOP_LEVEL_POPUP_ANCHOR_NOTIFICATION
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *notification) {
            NSNumber *minX =
                notification.userInfo[@"minX"];

            if (![minX isKindOfClass:NSNumber.class]) {
                return;
            }

            CGFloat anchorX =
                minX.doubleValue;

            if (!isfinite(anchorX)) {
                return;
            }

            SLPendingMenuBarAnchorX =
                anchorX;

            SLPendingMenuBarAnchorTime =
                CACurrentMediaTime();

            /*
             * Una nueva selección de la barra corresponde a un
             * nuevo popup superior. Se elimina la referencia débil
             * al popup anterior.
             */
            [SLAnchoredTopLevelPopupWindows
                removeAllObjects];
        }];
    });
}

static BOOL SLIsMenuBarAttachedPopup(
    NSWindow *window
) {
    if (!window || !IsPopupWindow(window)) {
        return NO;
    }

    NSScreen *screen =
        window.screen ?: NSScreen.mainScreen;

    if (!screen) {
        return NO;
    }

    CGFloat popupTop =
        NSMaxY(window.frame);

    CGFloat menuAreaBottom =
        NSMaxY(screen.visibleFrame);

    /*
     * Incluye el punto de solapamiento vertical conservado.
     * Un menú contextual lejos de la barra no cumple esto.
     */
    return fabs(
        popupTop - menuAreaBottom
    ) <= 10.0;
}

static void SLAlignPopupToMenuBarAnchor(
    NSWindow *window
) {
    if (!SLIsMenuBarAttachedPopup(window) ||
        !isfinite(SLPendingMenuBarAnchorX)) {
        return;
    }

    CFTimeInterval age =
        CACurrentMediaTime() -
        SLPendingMenuBarAnchorTime;

    if (age < 0.0 || age > 2.0) {
        return;
    }

    NSWindow *activeWindow =
        SLAnchoredTopLevelPopupWindows
            .allObjects.firstObject;

    /*
     * Sólo la primera ventana superior relacionada con el clic
     * consume el ancla. Los submenús quedan intactos.
     */
    if (activeWindow && activeWindow != window) {
        return;
    }

    NSRect frame =
        window.frame;

    CGFloat correction =
        SLPendingMenuBarAnchorX -
        NSMinX(frame);

    /*
     * En la captura la diferencia real es pequeña. Si AppKit
     * movió el popup mucho para mantenerlo dentro de la pantalla,
     * no forzamos una alineación que lo saque de ella.
     */
    if (!isfinite(correction) ||
        fabs(correction) > 16.0) {
        return;
    }

    if (!activeWindow) {
        [SLAnchoredTopLevelPopupWindows
            addObject:window];
    }

    if (fabs(correction) < 0.05) {
        return;
    }

    NSPoint origin =
        frame.origin;

    /*
     * Posición absoluta, no acumulativa:
     * el comienzo de la ventana queda en la misma X que el
     * comienzo del botón azul superior.
     */
    origin.x =
        SLPendingMenuBarAnchorX;

    [window setFrameOrigin:origin];

    SLLog([NSString stringWithFormat:
        @"popup absolute-anchor process=%@ "
         "anchor=%.3f oldX=%.3f correction=%.3f",
        NSProcessInfo.processInfo.processName,
        SLPendingMenuBarAnchorX,
        NSMinX(frame),
        correction]);
}

/*
 * En Snow Leopard los submenús no empezaban después del borde
 * exterior del menú padre. Se superponían ligeramente sobre él,
 * evitando una separación o una línea vertical doble.
 *
 * Este valor afecta solamente el eje X de los submenús.
 */
static const CGFloat SLSubmenuHorizontalOverlap = 1.0;

/*
 * El borde del menú padre mide un punto. El submenú
 * debe comenzar después de ese borde, no encima de él.
 */
static const CGFloat SLSubmenuBorderJoinAllowance = 0.0;

static CGFloat SLAbsoluteCGFloat(
    CGFloat value
) {
    return value < 0.0
        ? -value
        : value;
}

static BOOL SLPopupTouchesMenuBar(
    NSWindow *window
) {
    if (!window ||
        !IsPopupWindow(window)) {
        return NO;
    }

    NSScreen *screen =
        window.screen ?: NSScreen.mainScreen;

    if (!screen) {
        return NO;
    }

    CGFloat popupTop =
        NSMaxY(window.frame);

    CGFloat menuBarBottom =
        NSMaxY(screen.visibleFrame);

    /*
     * Incluye el solapamiento vertical que ya se había
     * configurado para los menús principales.
     */
    return SLAbsoluteCGFloat(
        popupTop - menuBarBottom
    ) <= 10.0;
}

static NSWindow *SLFindParentPopupForSubmenu(
    NSWindow *submenu,
    BOOL *opensToRight
) {
    if (opensToRight) {
        *opensToRight = YES;
    }

    if (!submenu) {
        return nil;
    }

    NSApplication *application =
        NSApplication.sharedApplication;

    if (!application) {
        return nil;
    }

    NSMutableOrderedSet *windows =
        [NSMutableOrderedSet orderedSet];

    if (application.orderedWindows.count > 0) {
        [windows addObjectsFromArray:
            application.orderedWindows];
    }

    if (application.windows.count > 0) {
        [windows addObjectsFromArray:
            application.windows];
    }

    NSRect submenuFrame =
        submenu.frame;

    NSWindow *bestParent =
        nil;

    BOOL bestOpensToRight =
        YES;

    CGFloat bestScore =
        CGFLOAT_MAX;

    NSUInteger popupCount =
        0;

    for (id object in windows) {
        if (![object
                isKindOfClass:NSWindow.class]) {
            continue;
        }

        NSWindow *candidate =
            (NSWindow *)object;

        if (candidate == submenu ||
            !candidate.isVisible ||
            !IsPopupWindow(candidate)) {
            continue;
        }

        popupCount++;

        NSRect parentFrame =
            candidate.frame;

        /*
         * Comparar únicamente los intervalos verticales.
         * Los dos menús no necesitan intersectarse en X.
         */
        CGFloat overlapTop =
            MIN(
                NSMaxY(submenuFrame),
                NSMaxY(parentFrame));

        CGFloat overlapBottom =
            MAX(
                NSMinY(submenuFrame),
                NSMinY(parentFrame));

        CGFloat verticalOverlap =
            MAX(
                0.0,
                overlapTop - overlapBottom);

        if (verticalOverlap < 2.0) {
            continue;
        }

        CGFloat rightDistance =
            SLAbsoluteCGFloat(
                NSMinX(submenuFrame) -
                NSMaxX(parentFrame));

        CGFloat leftDistance =
            SLAbsoluteCGFloat(
                NSMaxX(submenuFrame) -
                NSMinX(parentFrame));

        BOOL candidateOpensToRight =
            rightDistance <= leftDistance;

        CGFloat horizontalDistance =
            candidateOpensToRight
                ? rightDistance
                : leftDistance;

        /*
         * El padre correcto es el popup lateral más cercano.
         * No existe el antiguo límite de -16 a 24 puntos.
         */
        CGFloat score =
            horizontalDistance;

        score +=
            SLAbsoluteCGFloat(
                NSMaxY(submenuFrame) -
                NSMaxY(parentFrame)
            ) * 0.025;

        if (SLPopupTouchesMenuBar(candidate)) {
            score -= 2.0;
        }

        if (!bestParent ||
            score < bestScore) {
            bestParent =
                candidate;

            bestScore =
                score;

            bestOpensToRight =
                candidateOpensToRight;
        }
    }

    if (!bestParent) {
        SLLog([NSString stringWithFormat:
            @"submenu parent-miss process=%@ "
             "popupCount=%lu submenuFrame=%@",
            NSProcessInfo.processInfo.processName,
            (unsigned long)popupCount,
            NSStringFromRect(submenuFrame)]);

        return nil;
    }

    if (opensToRight) {
        *opensToRight =
            bestOpensToRight;
    }

    SLLog([NSString stringWithFormat:
        @"submenu parent-found process=%@ "
         "direction=%@ score=%.3f "
         "parentFrame=%@ submenuFrame=%@ "
         "parentTouchesMenuBar=%d",
        NSProcessInfo.processInfo.processName,
        bestOpensToRight ? @"right" : @"left",
        bestScore,
        NSStringFromRect(bestParent.frame),
        NSStringFromRect(submenuFrame),
        SLPopupTouchesMenuBar(bestParent)]);

    return bestParent;
}

/*
 * El frame de NSWindow incluye zonas transparentes, sombra e
 * insets. Para unir correctamente dos menús hay que comparar
 * los bordes visibles de NSRootMenuWindowBackgroundView.
 */
static NSView *SLFindPopupVisibleRoot(
    NSView *view
) {
    if (!view) {
        return nil;
    }

    if (IsRootBackground(view)) {
        return view;
    }

    for (NSView *subview
         in view.subviews.copy) {
        NSView *result =
            SLFindPopupVisibleRoot(
                subview);

        if (result) {
            return result;
        }
    }

    return nil;
}

/*
 * There is deliberately no custom shadow layer. AppKit owns the external
 * shadow after receiving the compositor corner mask from -_cornerMask;
 * WindowServer SPI is used only to calibrate radius, density and offset.
 */

static NSRect SLPopupVisibleRectOnScreen(
    NSWindow *window
) {
    if (!window) {
        return NSZeroRect;
    }

    NSView *root =
        SLFindPopupVisibleRoot(
            window.contentView);

    if (!root) {
        return window.frame;
    }

    NSRect rectInWindow =
        [root convertRect:root.bounds
                   toView:nil];

    NSRect rectOnScreen =
        [window convertRectToScreen:
            rectInWindow];

    if (NSIsEmptyRect(rectOnScreen)) {
        return window.frame;
    }

    return rectOnScreen;
}

static void SLAlignSubmenuHorizontally(
    NSWindow *submenu
) {
    if (!submenu ||
        !IsPopupWindow(submenu) ||
        SLPopupTouchesMenuBar(submenu)) {
        return;
    }

    BOOL opensToRight = YES;

    NSWindow *parent =
        SLFindParentPopupForSubmenu(
            submenu,
            &opensToRight);

    if (!parent) {
        return;
    }

    objc_setAssociatedObject(
        submenu,
        &SLPopupIsSubmenuKey,
        @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    /*
     * El root puede haberse creado antes de que AppKit revele la relación
     * padre/submenú. Reaplicar ahora evita un frame con las cuatro esquinas
     * redondeadas antes de que aparezca en pantalla.
     */
    NSView *submenuRoot =
        SLFindPopupVisibleRoot(
            submenu.contentView);

    if (submenuRoot) {
        EnsureBackgroundFilm(submenuRoot);
    }

    NSRect parentVisible =
        SLPopupVisibleRectOnScreen(
            parent);

    NSRect submenuVisible =
        SLPopupVisibleRectOnScreen(
            submenu);

    if (NSIsEmptyRect(parentVisible) ||
        NSIsEmptyRect(submenuVisible)) {
        return;
    }

    CGFloat correction = 0.0;

    if (opensToRight) {
        /*
         * El borde visible izquierdo del submenú debe coincidir
         * exactamente con el borde visible derecho del padre.
         *
         * SLSubmenuHorizontalOverlap vale 1.0: el submenú invade un punto
         * el borde visible del padre, como en Snow Leopard.
         */
        CGFloat targetVisibleLeft =
            NSMaxX(parentVisible) +
            SLSubmenuBorderJoinAllowance -
            SLSubmenuHorizontalOverlap;

        correction =
            targetVisibleLeft -
            NSMinX(submenuVisible);
    } else {
        /*
         * Caso inverso cuando AppKit abre hacia la izquierda.
         */
        CGFloat targetVisibleRight =
            NSMinX(parentVisible) -
            SLSubmenuBorderJoinAllowance +
            SLSubmenuHorizontalOverlap;

        correction =
            targetVisibleRight -
            NSMaxX(submenuVisible);
    }

    CGFloat magnitude =
        correction < 0.0
            ? -correction
            : correction;

    SLLog([NSString stringWithFormat:
        @"submenu alignment-plan process=%@ "
         "direction=%@ parentVisible=%@ "
         "submenuVisible=%@ correction=%.3f",
        NSProcessInfo.processInfo.processName,
        opensToRight ? @"right" : @"left",
        NSStringFromRect(parentVisible),
        NSStringFromRect(submenuVisible),
        correction]);

    if (magnitude < 0.05) {
        SLLog([NSString stringWithFormat:
            @"submenu already-aligned process=%@ "
             "correction=%.3f",
            NSProcessInfo.processInfo.processName,
            correction]);

        return;
    }

    /*
     * Sólo rechazar coordenadas claramente corruptas.
     * Los frames privados de AppKit pueden contener márgenes
     * transparentes mayores de 32 puntos.
     */
    if (magnitude > 1024.0) {
        SLLog([NSString stringWithFormat:
            @"submenu correction-rejected process=%@ "
             "correction=%.3f",
            NSProcessInfo.processInfo.processName,
            correction]);

        return;
    }

    NSPoint origin =
        submenu.frame.origin;

    /*
     * Sólo se modifica X. La geometría vertical calculada por
     * AppKit permanece intacta.
     */
    origin.x += correction;

    [submenu setFrameOrigin:origin];

    SLLog([NSString stringWithFormat:
        @"submenu visible-edge-align process=%@ "
         "direction=%@ parentEdge=%.3f "
         "submenuEdge=%.3f correction=%.3f",
        NSProcessInfo.processInfo.processName,
        opensToRight ? @"right" : @"left",
        opensToRight
            ? NSMaxX(parentVisible)
            : NSMinX(parentVisible),
        opensToRight
            ? NSMinX(submenuVisible)
            : NSMaxX(submenuVisible),
        correction]);
}

/*
 * En esta versión de AppKit, StylePopupWindow suele ejecutarse
 * primero para el menú principal. El submenú puede aparecer
 * después sin volver a recorrer el mismo camino.
 *
 * Por eso no esperamos recibir directamente la ventana del
 * submenú: revisamos todas las ventanas popup visibles.
 */

static void SLScheduleSubmenuHorizontalAlignment(
    NSWindow *window
) {
    if (!window ||
        !IsPopupWindow(window) ||
        SLPopupTouchesMenuBar(window)) {
        return;
    }

    /*
     * Ejecución síncrona: no programar correcciones para
     * fotogramas posteriores.
     */
    SLAlignSubmenuHorizontally(window);
}

/*
 * Popup presentation/shadow lifecycle hooks.
 *
 * Hook the popup class itself rather than NSWindow's inherited ordering path,
 * because popup subclasses can override that selector. The shape is committed
 * after AppKit's own order operation, then one real shadow rebuild is requested.
 * We also
 * hook invalidateShadow on the popup class so every AppKit-triggered rebuild
 * is synchronously retuned to the exact same Snow Leopard parameters.
 */
static void SnowLeopardPopupInvalidateShadow(
    id object,
    SEL selector
) {
    NSWindow *window = (NSWindow *)object;
    BOOL tune =
        SLPopupCanUseNativeShapedShadow(window) &&
        window.hasShadow;

    /*
     * Apply both before and after AppKit's rebuild. The pre-pass guarantees
     * that WindowServer sees our parameters for the shadow being generated
     * right now; the post-pass restores them if AppKit rewrites any property
     * during its private invalidation path. No extra invalidation is issued.
     */
    if (tune) {
        SLTuneSnowLeopardWindowShadow(window);
    }

    if (OriginalPopupInvalidateShadow) {
        OriginalPopupInvalidateShadow(object, selector);
    }

    if (tune) {
        SLTuneSnowLeopardWindowShadow(window);
    }
}

static void SnowLeopardPopupOrderWindow(
    id object,
    SEL selector,
    NSWindowOrderingMode place,
    NSInteger otherWindowNumber
) {
    NSWindow *window = (NSWindow *)object;
    BOOL presenting = place != NSWindowOut;

    if (presenting &&
        !SLPopupTouchesMenuBar(window)) {
        /* Resolve/mark submenus and apply the classic 1 pt overlap. */
        SLAlignSubmenuHorizontally(window);
    }

    if (OriginalPopupOrderWindow) {
        OriginalPopupOrderWindow(
            object,
            selector,
            place,
            otherWindowNumber);
    }

    if (!presenting) {
        return;
    }

    /* AppKit can adjust the frame during ordering; correct it once more. */
    if (!SLPopupTouchesMenuBar(window)) {
        SLAlignSubmenuHorizontally(window);
    }

    SLPreparePopupOuterContainer(window);
    SLRefreshPopupCompositorShape(window);
    SLCommitSnowLeopardWindowShadow(window);
}

static void SLInstallPopupPresentationHooks(void) {
    if (!PopupWindowClass) {
        return;
    }

    IMP originalOrder = NULL;
    SLPopupPresentationHookInstalled =
        SLInstallOverrideHook(
            PopupWindowClass,
            @selector(orderWindow:relativeTo:),
            NULL,
            (IMP)SnowLeopardPopupOrderWindow,
            &originalOrder);

    if (SLPopupPresentationHookInstalled) {
        OriginalPopupOrderWindow =
            (OrderWindowFn)originalOrder;
    }

    IMP originalInvalidate = NULL;
    SLPopupInvalidateShadowHookInstalled =
        SLInstallOverrideHook(
            PopupWindowClass,
            @selector(invalidateShadow),
            "v16@0:8",
            (IMP)SnowLeopardPopupInvalidateShadow,
            &originalInvalidate);

    if (SLPopupInvalidateShadowHookInstalled) {
        OriginalPopupInvalidateShadow =
            (InvalidateShadowFn)originalInvalidate;
    }

    SLLog([NSString stringWithFormat:
        @"popup presentation hook=%d invalidateShadowHook=%d",
        SLPopupPresentationHookInstalled,
        SLPopupInvalidateShadowHookInstalled]);
}

static void StylePopupWindow(NSWindow *window) {
    if (!IsPopupWindow(window)) return;

    /*
     * The window stays non-opaque and transparent around the classic menu
     * surface. AppKit/WindowServer receives the same silhouette through
     * -_cornerMask, allowing the native external shadow to follow the real
     * rounded outline instead of a rectangular backing box.
     */

    CALayer *contentLayer =
        window.contentView.layer;

    if (contentLayer) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];

        contentLayer.shadowOpacity = 0.0;
        contentLayer.shadowRadius = 0.0;
        contentLayer.shadowOffset =
            CGSizeZero;
        contentLayer.shadowPath = nil;

        [CATransaction commit];
    }

    /*
     * Quitamos los radios privados modernos. El contorno visible lo controlan
     * las máscaras del fondo y la silueta de NSWindow la define _cornerMask;
     * de este modo no se añade el radio uniforme moderno de Sequoia.
     */
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    SetNumericIvarToZero(window, "_effectiveCornerRadius");
    SetNumericIvarToZero(window, "_cornerRadius");
    SquareLayer(window.contentView.layer, NO);
    if (window.contentView) {
        SquareVisualEffectView(window.contentView, NO);
    }

    AlignTopLevelPopupWithMenuBar(window);

    SLAlignPopupToMenuBarAnchor(window);

    SLScheduleSubmenuHorizontalAlignment(window);

    /*
     * SquareVisualEffectView limpia las capas de material moderno. El root y
     * nuestra película llevan la silueta visible; el contenedor exterior queda
     * transparente y WindowServer recibe la misma silueta mediante _cornerMask.
     */
    NSView *finalRoot =
        SLFindPopupVisibleRoot(
            window.contentView);

    if (finalRoot) {
        EnsureBackgroundFilm(finalRoot);
    }

    /*
     * Keep AppKit's outer container transparent, then push the same corner
     * geometry into the compositor. Shadow style/lifecycle calibration is
     * owned by the popup presentation + invalidateShadow hooks, not layout.
     */
    SLPreparePopupOuterContainer(window);
    SLRefreshPopupCompositorShape(window);

}

static id SnowLeopardRootInit(id object, SEL selector, NSRect frame) {
    id result = OriginalRootInit(object, selector, frame);
    EnsureBackgroundFilm(result);
    return result;
}

static void SnowLeopardRootLayout(id object, SEL selector) {
    OriginalRootLayout(object, selector);
    EnsureBackgroundFilm(object);
    StylePopupWindow([object window]);
}

static void SnowLeopardMaterialRadius(id object, SEL selector, CGFloat radius) {
    OriginalMaterialRadius(object, selector, IsRootBackground(object) ? 0.0 : radius);
}

static void SnowLeopardViewRadius(id object, SEL selector, CGFloat radius) {
    OriginalViewRadius(object, selector, IsRootBackground(object) ? 0.0 : radius);
}

static void SnowLeopardPopupRadius(id object, SEL selector,
                                   CGFloat radius) {
    OriginalPopupRadius(
        object, selector, IsPopupWindow(object) ? 0.0 : radius);
}

static void SnowLeopardManagerRadius(id object, SEL selector,
                                     CGFloat radius) {
    OriginalManagerRadius(
        object, selector, IsPopupWindow(object) ? 0.0 : radius);
}


static void SLInstallPopupCompositorMaskHooks(void) {
    if (!PopupWindowClass) {
        return;
    }

    IMP originalMask = NULL;
    SLPopupCornerMaskHookInstalled =
        SLInstallOverrideHook(
            PopupWindowClass,
            NSSelectorFromString(@"_cornerMask"),
            "@16@0:8",
            (IMP)SnowLeopardPopupCornerMask,
            &originalMask);

    if (SLPopupCornerMaskHookInstalled) {
        OriginalPopupCornerMask =
            (ObjectFn)originalMask;
    }

    /*
     * Best-effort on Sequoia. AppKit commonly derives this from the mask, but
     * forcing YES for menu popups makes the shadow relationship explicit. If
     * Apple changes this private selector, the core _cornerMask hook still
     * remains usable and the optional hook simply stays off.
     */
    IMP originalDefinesShadow = NULL;
    SLPopupCornerMaskShadowHookInstalled =
        SLInstallOverrideHook(
            PopupWindowClass,
            NSSelectorFromString(@"_cornerMaskShouldDefineShadow"),
            "B16@0:8",
            (IMP)SnowLeopardPopupCornerMaskShouldDefineShadow,
            &originalDefinesShadow);

    if (SLPopupCornerMaskShadowHookInstalled) {
        OriginalPopupCornerMaskShouldDefineShadow =
            (BoolFn)originalDefinesShadow;
    }

    SLLog([NSString stringWithFormat:
        @"popup compositor mask hook=%d shadowMaskHook=%d",
        SLPopupCornerMaskHookInstalled,
        SLPopupCornerMaskShadowHookInstalled]);
}

typedef struct {
    Method rootInit;
    Method rootLayout;
    Method materialRadius;
    Method viewRadius;
    Method popupRadius;
    Method managerRadius;
} SLPopupHookMethods;

static SLPopupHookMethods PopupHooks;

static BOOL PreparePopupHooks(void) {
    RootBackgroundClass = NSClassFromString(@"NSRootMenuWindowBackgroundView");
    PopupWindowClass = NSClassFromString(@"NSPopupMenuWindow");
    ManagerWindowClass = NSClassFromString(@"NSMenuWindowManagerWindow");
    if (!RootBackgroundClass || !PopupWindowClass || !ManagerWindowClass ||
        ![RootBackgroundClass isSubclassOfClass:NSVisualEffectView.class] ||
        ![PopupWindowClass isSubclassOfClass:NSWindow.class] ||
        ![ManagerWindowClass isSubclassOfClass:NSWindow.class]) return NO;

    SEL radiusSEL = NSSelectorFromString(@"_setCornerRadius:");
    PopupHooks.rootInit = SLOwnInstanceMethod(RootBackgroundClass, @selector(initWithFrame:));
    PopupHooks.rootLayout = SLMaterializeOwnMethod(
        RootBackgroundClass, @selector(layout), "v16@0:8");
    PopupHooks.materialRadius = SLOwnInstanceMethod(
        NSVisualEffectView.class, NSSelectorFromString(@"_setMaterialCornerRadius:"));
    PopupHooks.viewRadius = SLOwnInstanceMethod(NSVisualEffectView.class, radiusSEL);
    PopupHooks.popupRadius = SLMaterializeOwnMethod(
        PopupWindowClass, radiusSEL, "v24@0:8d16");
    PopupHooks.managerRadius = SLMaterializeOwnMethod(
        ManagerWindowClass, radiusSEL, "v24@0:8d16");

    if (!SLMethodMatches(PopupHooks.rootInit,
            "@48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16") ||
        !PopupHooks.rootLayout ||
        !SLMethodMatches(PopupHooks.materialRadius, "v24@0:8d16") ||
        !SLMethodMatches(PopupHooks.viewRadius, "v24@0:8d16") ||
        !PopupHooks.popupRadius || !PopupHooks.managerRadius) return NO;

    OriginalRootInit = (InitFrameFn)method_getImplementation(PopupHooks.rootInit);
    OriginalRootLayout = (VoidFn)method_getImplementation(PopupHooks.rootLayout);
    OriginalMaterialRadius = (RadiusFn)method_getImplementation(PopupHooks.materialRadius);
    OriginalViewRadius = (RadiusFn)method_getImplementation(PopupHooks.viewRadius);
    OriginalPopupRadius = (RadiusFn)method_getImplementation(PopupHooks.popupRadius);
    OriginalManagerRadius = (RadiusFn)method_getImplementation(PopupHooks.managerRadius);
    return OriginalRootInit && OriginalRootLayout && OriginalMaterialRadius &&
        OriginalViewRadius && OriginalPopupRadius && OriginalManagerRadius;
}

static void CommitPopupHooks(void) {
    method_setImplementation(PopupHooks.rootInit, (IMP)SnowLeopardRootInit);
    method_setImplementation(PopupHooks.rootLayout, (IMP)SnowLeopardRootLayout);
    method_setImplementation(PopupHooks.materialRadius, (IMP)SnowLeopardMaterialRadius);
    method_setImplementation(PopupHooks.viewRadius, (IMP)SnowLeopardViewRadius);
    method_setImplementation(PopupHooks.popupRadius, (IMP)SnowLeopardPopupRadius);
    method_setImplementation(PopupHooks.managerRadius, (IMP)SnowLeopardManagerRadius);
}

static void InstallPopupHooks(void) {
    if (Installed || !SLIsEligibleRegularApplicationProcess()) return;
    if (!PreparePopupHooks()) {
        if (InstallAttempts++ < 40) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{ InstallPopupHooks(); });
        } else {
            SLLog([NSString stringWithFormat:
                @"popup preflight aborted process=%@ pid=%d",
                NSProcessInfo.processInfo.processName, getpid()]);
        }
        return;
    }

    PreparePopupPalette();
    SLInstallPopupCompositorMaskHooks();
    SLInstallPopupPresentationHooks();
    CommitPopupHooks();
    Installed = YES;
    SLLog([NSString stringWithFormat:
        @"popup install process=%@ pid=%d installed=1 selectionOwner=BlueSelection",
        NSProcessInfo.processInfo.processName, getpid()]);
}

__attribute__((constructor))
static void SnowLeopardMenuPopupLoad(void) {
    @autoreleasepool {
        if (!SLRuntimeIsMacOSSequoia() ||
            !SLIsEligibleRegularApplicationProcess()) return;
        SLInstallPopupAnchorObserver();
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{ InstallPopupHooks(); });
    }
}
