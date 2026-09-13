#import "WallpaperWire.h"

@interface SLWallpaperSource : NSObject <NSApplicationDelegate>
@property NSTimer *timer;
@property NSString *fingerprint;
@property NSDictionary *payload;
@property NSTimeInterval lastPublish;
@property NSTimeInterval retryAfter;
@property id activity;
@property NSWindow *diagnostics;
@property NSTextField *label;
@end

static NSDictionary *SLWallpaperMakeStrip(NSScreen *screen, NSURL *url, NSDictionary *options) {
    if (!url.isFileURL) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return nil;
    // Bound decoding, including large user-supplied images. No screen capture.
    NSDictionary *decode = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @8192,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES};
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)decode);
    CFRelease(source);
    if (!image) return nil;
    double width = NSWidth(screen.frame), height = NSHeight(screen.frame), scale = screen.backingScaleFactor;
    size_t pixelsWide = (size_t)llround(width * scale);
    size_t pixelsHigh = (size_t)llround(SLWallpaperStripHeight * scale);
    if (!pixelsWide || pixelsWide > 32768 || !pixelsHigh || pixelsHigh > 256) { CGImageRelease(image); return nil; }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, pixelsWide, pixelsHigh, 8, 0, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) { CGImageRelease(image); return nil; }
    NSColor *background = options[NSWorkspaceDesktopImageFillColorKey];
    if (![background isKindOfClass:NSColor.class]) background = NSColor.blackColor;
    CGContextSetFillColorWithColor(ctx, background.CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, pixelsWide, pixelsHigh));
    double iw = CGImageGetWidth(image), ih = CGImageGetHeight(image);
    BOOL clipping = options[NSWorkspaceDesktopImageAllowClippingKey]
        ? [options[NSWorkspaceDesktopImageAllowClippingKey] boolValue] : YES;
    NSInteger mode = options[NSWorkspaceDesktopImageScalingKey]
        ? [options[NSWorkspaceDesktopImageScalingKey] integerValue] : NSImageScaleProportionallyUpOrDown;
    double factor = clipping ? MAX(width / iw, height / ih) : MIN(width / iw, height / ih);
    if (mode == NSImageScaleNone) factor = 1.0;
    if (mode == NSImageScaleProportionallyDown) factor = MIN(factor, 1.0);
    CGRect destination = mode == NSImageScaleAxesIndependently
        ? CGRectMake(0, 0, width, height)
        : CGRectMake((width - iw * factor) / 2, (height - ih * factor) / 2, iw * factor, ih * factor);
    CGContextScaleCTM(ctx, scale, scale);
    CGContextTranslateCTM(ctx, 0, SLWallpaperStripHeight - height);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, destination, image);
    CGImageRelease(image);
    CGImageRef strip = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!strip) return nil;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:strip];
    CGImageRelease(strip);
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png || png.length > 4 * 1024 * 1024) return nil;
    return @{@"displayID": screen.deviceDescription[@"NSScreenNumber"], @"width": @(width),
        @"screenHeight": @(height), @"scale": @(scale), @"png": png};
}

@implementation SLWallpaperSource
- (void)updateSource {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    NSMutableArray *states = [NSMutableArray array];
    for (NSScreen *screen in NSScreen.screens) {
        NSURL *url = [NSWorkspace.sharedWorkspace desktopImageURLForScreen:screen];
        NSDictionary *options = [NSWorkspace.sharedWorkspace desktopImageOptionsForScreen:screen] ?: @{};
        NSDictionary *attributes = url ? [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:NULL] : nil;
        [states addObject:@{@"screen":screen, @"url":url ?: NSNull.null, @"options":options,
            @"signature": [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%g",
                screen.deviceDescription[@"NSScreenNumber"], NSStringFromRect(screen.frame),
                url.absoluteString, attributes[NSFileModificationDate], options, screen.backingScaleFactor]}];
    }
    NSString *fingerprint = [[states valueForKey:@"signature"] componentsJoinedByString:@"\n"];
    if (![self.fingerprint isEqual:fingerprint] || (self.retryAfter > 0 && now >= self.retryAfter)) {
        NSMutableArray *displays = [NSMutableArray array];
        for (NSDictionary *state in states) {
            NSDictionary *strip = SLWallpaperMakeStrip(state[@"screen"],
                state[@"url"] == NSNull.null ? nil : state[@"url"], state[@"options"]);
            if (strip) [displays addObject:strip];
        }
        self.fingerprint = fingerprint;
        // Retry a transient decode/read failure without repeatedly decoding
        // healthy images. Missing displays are removed from the published feed.
        self.retryAfter = displays.count < states.count ? now + 5 : 0;
        self.payload = @{@"version":@1, @"generation":NSUUID.UUID.UUIDString, @"displays":displays};
        self.lastPublish = 0;
    }
    if (self.payload && now - self.lastPublish >= 10) {
        NSMutableDictionary *wire = self.payload.mutableCopy;
        wire[@"publishedAt"] = @(NSDate.date.timeIntervalSince1970);
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:wire
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        if (data && data.length <= SLWallpaperMaxPayload) {
            NSPasteboard *board = [NSPasteboard pasteboardWithName:SLWallpaperBoardName];
            [board clearContents];
            BOOL published = [board setData:data forType:SLWallpaperWireType];
            self.lastPublish = now;
            self.label.stringValue = [NSString stringWithFormat:@"Fuente compartida: %@\nPantallas publicadas: %lu\nSólo se comparte la franja del wallpaper; no se capturan ventanas.",
                published ? @"correcta" : @"falló", (unsigned long)[wire[@"displays"] count]];
        }
    }
}
- (void)invalidate:(NSNotification *)note { (void)note; self.fingerprint = nil; [self updateSource]; }
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    self.activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
        reason:@"Actualizar el fondo compartido de la barra de menú"];
    if ([NSBundle.mainBundle.infoDictionary[@"SLShowDiagnostics"] boolValue]) {
        self.diagnostics = [[NSWindow alloc] initWithContentRect:NSMakeRect(180, 240, 680, 160)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.diagnostics.title = @"Fuente de wallpaper — prueba sin instalar";
        self.label = [NSTextField wrappingLabelWithString:@"Preparando…"];
        self.label.frame = NSMakeRect(20, 20, 640, 120);
        [self.diagnostics.contentView addSubview:self.label];
        [self.diagnostics makeKeyAndOrderFront:nil];
    }
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(invalidate:)
        name:NSApplicationDidChangeScreenParametersNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(invalidate:)
        name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(invalidate:)
        name:NSWorkspaceDidWakeNotification object:nil];
    [self updateSource];
    self.timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(__unused NSTimer *timer) { [self updateSource]; }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender; return [NSBundle.mainBundle.infoDictionary[@"SLShowDiagnostics"] boolValue];
}
@end
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        SLWallpaperSource *source = [SLWallpaperSource new];
        NSApp.delegate = source;
        [NSApp run];
    }
    return 0;
}
