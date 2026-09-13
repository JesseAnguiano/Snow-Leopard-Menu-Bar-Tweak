#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <string.h>
#import <unistd.h>
#import <math.h>

#import "Runtime.h"
#import "Protocol.h"
#import "SelectionRenderer.h"

const char SLSnowLeopardPopupCapabilities[] =
    "snowLeopardPopup=modular-v2 background=owned selection=blueSelection";

// Popup-background/geometry module for the Unified dylib.
//
// This module does not read CoreUI/CAAR assets and does not load Glow. It
// owns popup background, mask, radius and placement. Selection hooks/state
// are owned exclusively by libSnowLeopardBlueSelection; both dylibs reuse the
// shared exact renderer instead of installing competing selection pipelines.

typedef id (*InitFrameFn)(id, SEL, NSRect);
typedef void (*VoidFn)(id, SEL);
typedef void (*RadiusFn)(id, SEL, CGFloat);

static InitFrameFn OriginalRootInit = NULL;
static VoidFn OriginalRootLayout = NULL;
static RadiusFn OriginalMaterialRadius = NULL;
static RadiusFn OriginalViewRadius = NULL;
static RadiusFn OriginalPopupRadius = NULL;
static RadiusFn OriginalManagerRadius = NULL;

static Class RootBackgroundClass = Nil;
static Class PopupWindowClass = Nil;
static Class ManagerWindowClass = Nil;

static BOOL Installed = NO;
static NSUInteger InstallAttempts = 0;
static char BackgroundFilmKey;
static char SLPopupRootMaskKey;

static CGFloat SLPendingMenuBarAnchorX = NAN;
static CFTimeInterval SLPendingMenuBarAnchorTime = 0.0;
static NSHashTable<NSWindow *> *
    SLAnchoredTopLevelPopupWindows = nil;
static id SLPopupAnchorObserverToken = nil;


static CGColorRef PopupBackgroundColour = NULL;

/*
 * Snow Leopard: parte superior cuadrada y un radio pequeño
 * únicamente en las dos esquinas inferiores.
 */
static const CGFloat SLPopupBottomRadius = 3.0;

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
 * Los submenús de Snow Leopard tenían radio pequeño en las
 * cuatro esquinas.
 */
static CGPathRef SLCreateSubmenuAttachedPath(
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

static NSBezierPath *SLSubmenuAttachedBorderPath(
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
     * Superior izquierda cuadrada.
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

static CGPathRef SLCreateBottomRoundedPath(
    CGRect bounds,
    CGFloat radius,
    BOOL flipped
) CF_RETURNS_RETAINED {
    CGFloat minX = CGRectGetMinX(bounds);
    CGFloat maxX = CGRectGetMaxX(bounds);
    CGFloat minY = CGRectGetMinY(bounds);
    CGFloat maxY = CGRectGetMaxY(bounds);

    CGFloat maximum =
        MIN(
            CGRectGetWidth(bounds),
            CGRectGetHeight(bounds)
        ) * 0.5;

    CGFloat resolved =
        MAX(0.0, MIN(radius, maximum));

    CGMutablePathRef path =
        CGPathCreateMutable();

    if (flipped) {
        /*
         * minY es la parte superior visible.
         */
        CGPathMoveToPoint(
            path, NULL,
            minX, minY);

        CGPathAddLineToPoint(
            path, NULL,
            maxX, minY);

        CGPathAddLineToPoint(
            path, NULL,
            maxX, maxY - resolved);

        CGPathAddArcToPoint(
            path, NULL,
            maxX, maxY,
            maxX - resolved, maxY,
            resolved);

        CGPathAddLineToPoint(
            path, NULL,
            minX + resolved, maxY);

        CGPathAddArcToPoint(
            path, NULL,
            minX, maxY,
            minX, maxY - resolved,
            resolved);
    } else {
        /*
         * maxY es la parte superior visible.
         */
        CGPathMoveToPoint(
            path, NULL,
            minX, maxY);

        CGPathAddLineToPoint(
            path, NULL,
            maxX, maxY);

        CGPathAddLineToPoint(
            path, NULL,
            maxX, minY + resolved);

        CGPathAddArcToPoint(
            path, NULL,
            maxX, minY,
            maxX - resolved, minY,
            resolved);

        CGPathAddLineToPoint(
            path, NULL,
            minX + resolved, minY);

        CGPathAddArcToPoint(
            path, NULL,
            minX, minY,
            minX, minY + resolved,
            resolved);
    }

    CGPathCloseSubpath(path);

    return path;
}

static NSBezierPath *SLBottomRoundedBorderPath(
    NSRect bounds,
    CGFloat radius
) {
    /*
     * drawRect usa una vista volteada. La parte inferior
     * visible se encuentra en NSMaxY(bounds).
     */
    CGFloat minX = NSMinX(bounds);
    CGFloat maxX = NSMaxX(bounds);
    CGFloat minY = NSMinY(bounds);
    CGFloat maxY = NSMaxY(bounds);

    CGFloat maximum =
        MIN(
            NSWidth(bounds),
            NSHeight(bounds)
        ) * 0.5;

    CGFloat resolved =
        MAX(0.0, MIN(radius, maximum));

    const CGFloat kappa = 0.55228475;

    NSBezierPath *path =
        [NSBezierPath bezierPath];

    [path moveToPoint:
        NSMakePoint(minX, minY)];

    [path lineToPoint:
        NSMakePoint(maxX, minY)];

    [path lineToPoint:
        NSMakePoint(
            maxX,
            maxY - resolved)];

    [path curveToPoint:
        NSMakePoint(
            maxX - resolved,
            maxY)
         controlPoint1:
        NSMakePoint(
            maxX,
            maxY - resolved +
                resolved * kappa)
         controlPoint2:
        NSMakePoint(
            maxX - resolved +
                resolved * kappa,
            maxY)];

    [path lineToPoint:
        NSMakePoint(
            minX + resolved,
            maxY)];

    [path curveToPoint:
        NSMakePoint(
            minX,
            maxY - resolved)
         controlPoint1:
        NSMakePoint(
            minX + resolved -
                resolved * kappa,
            maxY)
         controlPoint2:
        NSMakePoint(
            minX,
            maxY - resolved +
                resolved * kappa)];

    [path closePath];

    return path;
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

    BOOL attachedToMenuBar =
        SLWindowIsAttachedToMenuBar(
            root.window);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    mask.frame =
        layer.bounds;

    CGPathRef path = NULL;

    if (attachedToMenuBar) {
        /*
         * Menú principal:
         * parte superior completamente recta.
         */
        path =
            SLCreateBottomRoundedPath(
                layer.bounds,
                SLPopupBottomRadius,
                layer.geometryFlipped);
    } else {
        /*
         * Submenú:
         * radio en las cuatro esquinas.
         */
        path =
            SLCreateSubmenuAttachedPath(
                layer.bounds,
                SLPopupBottomRadius,
                layer.geometryFlipped);
    }

    mask.path = path;

    if (path) {
        CGPathRelease(path);
    }

    layer.mask = mask;
    layer.masksToBounds = YES;

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
     * El root aplica el único recorte. La película simplemente
     * rellena el menú; no crea una segunda curva.
     */
    CGContextSetFillColorWithColor(
        context,
        PopupBackgroundColour);

    CGContextFillRect(
        context,
        NSRectToCGRect(bounds));

    /*
     * Un solo borde, medio punto hacia dentro para que el
     * antialiasing no quede cortado.
     */
    NSRect borderBounds =
        NSInsetRect(
            bounds,
            0.5,
            0.5);

    BOOL attachedToMenuBar =
        SLWindowIsAttachedToMenuBar(
            self.window);

    CGFloat borderRadius =
        MAX(
            0.0,
            SLPopupBottomRadius - 0.5);

    NSBezierPath *border =
        attachedToMenuBar
            ? SLBottomRoundedBorderPath(
                borderBounds,
                borderRadius)
            : SLSubmenuAttachedBorderPath(
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
    SLApplySinglePopupMask(root);

    /*
     * SLPopupFilmOwnMaskFix
     *
     * El contorno curvo y el relleno deben compartir exactamente
     * la misma geometría. La película sola no basta porque detrás
     * permanece el material rectangular de NSVisualEffectView.
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
     * Aplicar la misma ruta asimétrica a ambos niveles:
     *
     * menú principal:
     *   esquinas superiores rectas;
     *
     * submenú:
     *   superior izquierda recta y las otras tres redondeadas.
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
static const CGFloat SLSubmenuHorizontalOverlap = 0.0;

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
         * SLSubmenuHorizontalOverlap vale 0.0: no hay hueco ni
         * superposición.
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
 * AppKit ordena las ventanas de menú con
 * orderWindow:relativeTo:. La corrección se aplica antes de
 * presentar la ventana y otra vez inmediatamente después, en el
 * mismo ciclo de ejecución.
 */
@interface NSWindow (SLSnowLeopardSubmenuPreOrder)

- (void)sl_snowLeopard_orderWindow:
    (NSWindowOrderingMode)place
    relativeTo:(NSInteger)otherWindowNumber;

@end

@implementation NSWindow (SLSnowLeopardSubmenuPreOrder)

- (void)sl_snowLeopard_orderWindow:
    (NSWindowOrderingMode)place
    relativeTo:(NSInteger)otherWindowNumber
{
    BOOL shouldAlign =
        place != NSWindowOut &&
        IsPopupWindow(self) &&
        !SLPopupTouchesMenuBar(self);

    if (shouldAlign) {
        self.animationBehavior =
            NSWindowAnimationBehaviorNone;

        /*
         * Corregir el frame antes de que la ventana aparezca.
         */
        SLAlignSubmenuHorizontally(self);
    }

    /*
     * Tras el swizzle, esta llamada ejecuta la implementación
     * original de NSWindow.
     */
    [self
        sl_snowLeopard_orderWindow:place
        relativeTo:otherWindowNumber];

    if (shouldAlign) {
        /*
         * AppKit puede alterar el frame durante orderWindow:.
         * Esta segunda corrección sigue siendo síncrona.
         */
        SLAlignSubmenuHorizontally(self);
    }
}

@end

static void SLInstallSubmenuPreOrderHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
            Class windowClass =
                NSWindow.class;

            Method originalMethod =
                class_getInstanceMethod(
                    windowClass,
                    @selector(orderWindow:relativeTo:));

            Method replacementMethod =
                class_getInstanceMethod(
                    windowClass,
                    @selector(
                        sl_snowLeopard_orderWindow:
                        relativeTo:));

            if (!originalMethod ||
                !replacementMethod) {
                SLLog(
                    @"submenu pre-order hook failed");

                return;
            }

            method_exchangeImplementations(
                originalMethod,
                replacementMethod);

            SLLog(
                @"submenu pre-order hook installed");
    });
}

static void StylePopupWindow(NSWindow *window) {
    if (!IsPopupWindow(window)) return;

    /*
     * La sombra nativa dibuja un contorno redondeado en las
     * cuatro esquinas. Eso producía un segundo radio detrás de
     * la esquina superior izquierda cuadrada.
     */
    window.hasShadow = NO;
    [window invalidateShadow];

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
     * La sombra de NSWindow conserva una silueta rectangular y
     * era la segunda esquina que aparecía detrás de la curva.
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
     * SquareVisualEffectView elimina layer.mask. Esta llamada
     * debe ser la última operación geométrica de la función.
     */
    NSView *finalRoot =
        SLFindPopupVisibleRoot(
            window.contentView);

    if (finalRoot) {
        EnsureBackgroundFilm(finalRoot);
    }

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
        SLInstallSubmenuPreOrderHook();
        SLInstallPopupAnchorObserver();
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{ InstallPopupHooks(); });
    }
}
