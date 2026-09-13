// Exercise production helpers without injecting into or opening another app.
// Ammonia may also load the installed dylib in this test executable.
#define SLSnowLeopardMenuBarBackdropView SLRegressionBackdropView
#define SLSnowLeopardMenuBarFilmView SLRegressionFilmView
#define SLSnowLeopardMenuBarLowerShadowView SLLayoutTestShadowView
#define SLSnowLeopardMenuBarLowerShadowPanel SLLayoutTestShadowPanel
#import "../src/menubar/MenuBar.m"
#include <assert.h>

@interface SLTestRepresentation : NSObject
@property NSInteger count;
@property NSInteger updates;
@property NSInteger layouts;
@property BOOL batching;
@property NSMutableArray<NSNumber *> *widths;
@property NSMutableArray<NSNumber *> *offsets;
@end
@implementation SLTestRepresentation
- (NSInteger)numberOfVisibleItems { return self.count; }
- (void)beginUpdates { assert(!self.batching); self.batching = YES; }
- (void)endUpdates { assert(self.batching); self.batching = NO; }
- (void)updateSizeForItemAtVisibleIndex:(NSInteger)index {
    assert(self.batching);
    self.widths[index] = index == 0 ? @35 : @60;
    self.updates++;
}
- (void)layoutMenuBarImmediately {
    assert(!self.batching);
    NSInteger offset = 10;
    for (NSInteger index = 0; index < self.count; index++) {
        self.offsets[index] = @(offset);
        offset += self.widths[index].integerValue;
    }
    self.layouts++;
}
@end

@interface SLTestReplica : NSObject
@property NSInteger windowNumber;
@property NSRect frame;
@end
@implementation SLTestReplica
@end

int main(void) {
    @autoreleasepool {
        SLSetWallpaperPollingActive(NO);
        assert(WallpaperRefreshTimer == nil);
        SLSetWallpaperPollingActive(YES);
        NSTimer *polling = WallpaperRefreshTimer;
        assert(polling.isValid && polling.timeInterval == 0.5);
        SLSetWallpaperPollingActive(YES);
        assert(WallpaperRefreshTimer == polling);
        SLSetWallpaperPollingActive(NO);
        assert(!polling.isValid && WallpaperRefreshTimer == nil);
        CIFilter *controls = [CIFilter filterWithName:@"CIColorControls"];
        assert(controls != nil);
        CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
        assert(blur != nil);
        SLRegressionBackdropView *backdrop = [[SLRegressionBackdropView alloc]
            initWithFrame:NSMakeRect(0, 0, 1440, 24)];
        CALayer *liveLayer = [backdrop makeBackingLayer];
        assert(SnowLeopardUsesWindowServerBackdrop(liveLayer));
        assert(ConfigureLiveBackdrop(liveLayer));
        assert(ConfigureLiveBackdrop(liveLayer));
        assert(liveLayer.filters.count == 1);
        assert([[liveLayer valueForKey:@"windowServerAware"] boolValue]);
        assert(!ConfigureLiveBackdrop([CALayer layer]));
        assert(backdrop.subviews.count == 0); // No second NSVisualEffect tint.
        // A 6016x3760 16:10 wallpaper must map exactly to the 1440x900
        // Retina desktop. The menu bar is its uppermost 24 points.
        CGRect crop = SnowLeopardWallpaperSourceRect(
            CGSizeMake(6016, 3760), NSMakeRect(0, 0, 1440, 900),
            NSMakeRect(0, 876, 1440, 24));
        assert(fabs(crop.origin.x) < 0.001);
        assert(fabs(CGRectGetMaxY(crop) - 3760) < 0.001);
        assert(fabs(crop.size.width - 6016) < 0.001);
        assert(fabs(crop.size.height - 100.2666667) < 0.01);
        CGRect wideCrop = SnowLeopardWallpaperSourceRect(
            CGSizeMake(3840, 2160), NSMakeRect(0, 0, 1440, 900),
            NSMakeRect(0, 876, 1440, 24));
        assert(fabs(wideCrop.origin.x - 192) < 0.001);
        assert(fabs(CGRectGetMaxY(wideCrop) - 2160) < 0.001);
        CGRect portraitCrop = SnowLeopardWallpaperSourceRect(
            CGSizeMake(1200, 1800), NSMakeRect(1440, -200, 1440, 900),
            NSMakeRect(1440, 676, 1440, 24));
        assert(CGRectContainsRect(CGRectMake(0, 0, 1200, 1800), portraitCrop));
        // Test the actual rendered alpha, not the availability of a filter.
        PreparePalette();
        unsigned char rgba[24 * 8 * 4] = {0};
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef bitmap = CGBitmapContextCreate(rgba, 8, 24, 8, 8 * 4,
            space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        assert(bitmap != NULL);
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 8, 24)];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:bitmap flipped:NO];
        DrawMenuBarFilm(view, view.bounds);
        [NSGraphicsContext restoreGraphicsState];
        unsigned char minAlpha = 255, maxAlpha = 0;
        for (NSUInteger row = 0; row < 24; row++) {
            unsigned char alpha = rgba[row * 8 * 4 + 3];
            assert(alpha > 120 && alpha < 245);
            minAlpha = MIN(minAlpha, alpha);
            maxAlpha = MAX(maxAlpha, alpha);
        }
        assert(maxAlpha - minAlpha >= 70);
        CGContextRelease(bitmap);
        CGColorSpaceRelease(space);
        SLTestRepresentation *rep = [SLTestRepresentation new];
        rep.count = 3;
        rep.widths = [@[@55, @90, @70] mutableCopy];
        rep.offsets = [@[@10, @65, @155] mutableCopy];
        RefreshRepresentationWidths(rep);
        assert(rep.updates == 3 && rep.layouts == 1);
        assert(([rep.offsets isEqualToArray:@[@10, @45, @105]]));
        RefreshRepresentationWidths(rep);
        assert(rep.updates == 6 && rep.layouts == 2);
        assert(([rep.offsets isEqualToArray:@[@10, @45, @105]]));
        // Reject an unexpected runtime object or invalid item count safely.
        RefreshRepresentationWidths([NSObject new]);
        rep.count = -1;
        RefreshRepresentationWidths(rep);
        assert(rep.updates == 6 && rep.layouts == 2);

        // Discovery must work even with no public NSApp.windows list, must
        // deduplicate, and must not retain dead replicas.
        ReplicantWindowClass = SLTestReplica.class;
        KnownMenuBarWindows = nil;
        __weak SLTestReplica *weakReplica;
        @autoreleasepool {
            SLTestReplica *replica = [SLTestReplica new];
            replica.windowNumber = 123;
            replica.frame = NSMakeRect(0, 876, 1440, 24);
            weakReplica = replica;
            RegisterMenuBarWindow((NSWindow *)replica);
            RegisterMenuBarWindow((NSWindow *)replica);
            assert(KnownMenuBarWindows.allObjects.count == 1);
        }
        assert(weakReplica == nil);
        assert(KnownMenuBarWindows.allObjects.count == 0);
        puts("PASS: real AppKit backing factory, live blur ABI/configuration, no material tint, fill geometry, film alpha, cached offsets, repeated activation, ABI guard, private discovery, weak lifetime. Live desktop pixels not covered by this test.");
    }
    return 0;
}
