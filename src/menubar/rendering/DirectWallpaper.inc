// Included by Core after its film renderer and AppKit view declarations.
#include "ColorTransfer.h"
static NSDictionary *SLSharedWallpaperPayload;
static NSInteger SLSharedWallpaperChange = NSIntegerMin;
static NSMutableDictionary<NSString *, id> *SLSharedMaterialCache;
static char SLDirectImageLayerKey;
static char SLDirectMaterialTokenKey;

static BOOL SLPollWallpaperFeed(void) {
    NSPasteboard *board = [NSPasteboard pasteboardWithName:SLWallpaperBoardName];
    NSInteger change = board.changeCount;
    NSString *oldGeneration = SLSharedWallpaperPayload[@"generation"];
    if (change != SLSharedWallpaperChange) {
        SLSharedWallpaperChange = change;
        SLSharedWallpaperPayload = SLWallpaperDecodePayload([board dataForType:SLWallpaperWireType]);
    }
    NSTimeInterval age = NSDate.date.timeIntervalSince1970 -
        [SLSharedWallpaperPayload[@"publishedAt"] doubleValue];
    if (age > 45 || age < -5) SLSharedWallpaperPayload = nil;
    NSString *generation = SLSharedWallpaperPayload[@"generation"];
    BOOL changed = oldGeneration != generation && ![oldGeneration isEqualToString:generation];
    if (changed) {
        [SLSharedMaterialCache removeAllObjects];
        SLLog([NSString stringWithFormat:@"wallpaper-feed process=%@ generation=%@ displays=%lu",
            NSProcessInfo.processInfo.processName, generation ?: @"unavailable",
            (unsigned long)[SLSharedWallpaperPayload[@"displays"] count]]);
    }
    return changed;
}

static CGImageRef SLComposeDirectWallpaper(CGImageRef source, NSView *view) CF_RETURNS_RETAINED {
    CGFloat scale = view.window.backingScaleFactor ?: 2.0;
    NSRect bounds = view.bounds;
    size_t width = (size_t)ceil(NSWidth(bounds) * scale);
    size_t height = (size_t)ceil(NSHeight(bounds) * scale);
    if (!source || !width || !height || width > 32768 || height > 512) return NULL;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, 0, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!bitmap) return NULL;
    CGContextScaleCTM(bitmap, scale, scale);
    CGContextDrawImage(bitmap, NSRectToCGRect(bounds), source);
    SLMenuBarApplyColorTransfer(CGBitmapContextGetData(bitmap), width, height,
                               CGBitmapContextGetBytesPerRow(bitmap));
    CGImageRef material = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    return material;
}

static BOOL SLApplyDirectWallpaper(SLSnowLeopardMenuBarBackdropView *view) {
    SLPollWallpaperFeed();
    NSScreen *screen = view.window.screen ?: NSScreen.mainScreen;
    NSNumber *displayID = screen.deviceDescription[@"NSScreenNumber"];
    NSDictionary *entry = nil;
    for (NSDictionary *candidate in SLSharedWallpaperPayload[@"displays"]) {
        if ([candidate[@"displayID"] isEqual:displayID]) { entry = candidate; break; }
    }
    CALayer *imageLayer = objc_getAssociatedObject(view, &SLDirectImageLayerKey);
    NSString *oldToken = objc_getAssociatedObject(view, &SLDirectMaterialTokenKey);
    BOOL geometryValid = entry && NSWidth(view.bounds) > 0 && NSHeight(view.bounds) > 0 &&
        NSHeight(view.bounds) <= SLWallpaperStripHeight &&
        fabs([entry[@"width"] doubleValue] - NSWidth(screen.frame)) < 0.5 &&
        fabs([entry[@"screenHeight"] doubleValue] - NSHeight(screen.frame)) < 0.5;
    NSString *token = geometryValid ? [NSString stringWithFormat:@"%@/%@/%@/%@/%g",
        SLSharedWallpaperPayload[@"generation"], displayID, NSStringFromRect(view.window.frame),
        NSStringFromRect(view.bounds), view.window.backingScaleFactor] : nil;
    if (token && [token isEqualToString:oldToken] && imageLayer.contents && imageLayer.superlayer == view.layer) {
        imageLayer.hidden = NO;
        return YES;
    }
    id materialObject = token ? SLSharedMaterialCache[token] : nil;
    if (token && !materialObject) {
        CGImageRef strip = SLWallpaperDecodeImage(entry);
        CGFloat scale = [entry[@"scale"] doubleValue];
        CGRect crop = CGRectMake((NSMinX(view.window.frame) - NSMinX(screen.frame)) * scale,
            (NSMaxY(screen.frame) - NSMaxY(view.window.frame)) * scale,
            NSWidth(view.bounds) * scale, NSHeight(view.bounds) * scale);
        if (strip && CGRectContainsRect(CGRectMake(0, 0, CGImageGetWidth(strip), CGImageGetHeight(strip)), crop)) {
            CGImageRef source = CGImageCreateWithImageInRect(strip, crop);
            CGImageRef material = SLComposeDirectWallpaper(source, view);
            if (material) {
                materialObject = CFBridgingRelease(material);
                if (!SLSharedMaterialCache) SLSharedMaterialCache = [NSMutableDictionary dictionary];
                if (SLSharedMaterialCache.count >= 32) [SLSharedMaterialCache removeAllObjects];
                SLSharedMaterialCache[token] = materialObject;
            }
            if (source) CGImageRelease(source);
        }
        if (strip) CGImageRelease(strip);
    }
    if (!materialObject) {
        imageLayer.hidden = YES;
        imageLayer.contents = nil;
        if (oldToken) objc_setAssociatedObject(view.layer, &LiveBackdropConfiguredKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, &SLDirectMaterialTokenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return NO;
    }
    if (!imageLayer) {
        imageLayer = [CALayer layer];
        imageLayer.name = @"SLMenuBarDirectWallpaperMaterial";
        objc_setAssociatedObject(view, &SLDirectImageLayerKey, imageLayer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (imageLayer.superlayer != view.layer) [view.layer addSublayer:imageLayer];
    view.layer.filters = nil;
    view.layer.backgroundFilters = nil;
    view.layer.compositingFilter = nil;
    view.layer.masksToBounds = YES;
    imageLayer.contentsScale = view.window.backingScaleFactor ?: 2.0;
    imageLayer.frame = NSRectToCGRect(view.bounds);
    imageLayer.contentsGravity = kCAGravityResize;
    imageLayer.contents = materialObject;
    imageLayer.hidden = NO;
    [CATransaction commit];
    objc_setAssociatedObject(view, &SLDirectMaterialTokenKey, token, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SLLog([NSString stringWithFormat:@"direct-wallpaper material process=%@ window=%ld generation=%@",
        NSProcessInfo.processInfo.processName, (long)view.window.windowNumber, SLSharedWallpaperPayload[@"generation"]]);
    return YES;
}
