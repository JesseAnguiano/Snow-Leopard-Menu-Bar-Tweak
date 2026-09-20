#define SLSnowLeopardRightSelectionView SLPerformanceSelectionView
#import "../src/status/SystemStatusItems.m"
#include <assert.h>

void SLStatusIconReplacementSetHighlighted(NSView *view, BOOL selected) {
    (void)view; (void)selected;
}
@interface SLCountingImageView : NSImageView
@property NSUInteger tintWrites;
@end
@implementation SLCountingImageView
- (void)setContentTintColor:(NSColor *)value {
    self.tintWrites++;
    [super setContentTintColor:value];
}
@end

static CGImageRef TestImage(CGFloat red, CGFloat green, CGFloat blue) CF_RETURNS_RETAINED {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL,16,16,8,64,space,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetRGBFillColor(ctx, red, green, blue, 1);
    CGContextFillRect(ctx, CGRectMake(0,0,16,16));
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx); CGColorSpaceRelease(space);
    return image;
}
int main(void) { @autoreleasepool {
    NSView *anchorRoot = [[NSView alloc] initWithFrame:NSMakeRect(0,0,36,24)];
    NSButton *anchorButton = [[NSButton alloc] initWithFrame:anchorRoot.bounds];
    anchorButton.identifier = SL_SPOTLIGHT_RIGHT_MARGIN_ANCHOR_IDENTIFIER;
    [anchorRoot addSubview:anchorButton];
    assert(SLViewTreeContainsSpotlightRightMarginAnchor(anchorRoot));
    assert(!SLViewTreeContainsSpotlightRightMarginAnchor(
        [[NSView alloc] initWithFrame:NSZeroRect]));

    NSView *foreground = [[NSView alloc] initWithFrame:NSMakeRect(0,0,80,24)];
    foreground.wantsLayer = YES;
    assert(SetMonochromeFilterEnabled(foreground, YES, NO) == 1);
    CIFilter *blackMono = objc_getAssociatedObject(foreground, BlackFilterKey);
    assert(((CIColor *)[blackMono valueForKey:@"inputColor0"]).red == 0);
    assert(SetMonochromeFilterEnabled(foreground, YES, YES) == 1);
    CIFilter *whiteMono = objc_getAssociatedObject(foreground, WhiteFilterKey);
    assert(whiteMono != blackMono);
    assert(((CIColor *)[whiteMono valueForKey:@"inputColor0"]).red == 1);
    assert(![foreground.layer.filters containsObject:blackMono]);
    assert([foreground.layer.filters containsObject:whiteMono]);
    assert(SetMonochromeFilterEnabled(foreground, YES, YES) == 1);
    assert(SetBlackFilterEnabled(foreground, NO) == 0);
    assert(!SLStatusSnapshotAllowed(YES, NO, @"com.apple.Spotlight"));
    assert(SLStatusSnapshotAllowed(YES, NO, @"com.apple.controlcenter"));
    assert(!SLStatusSnapshotAllowed(YES, YES, @"com.apple.controlcenter"));
    assert(!SLStatusSnapshotAllowed(NO, NO, @"com.apple.controlcenter"));
    assert(SLSpotlightWatchInterval(NO, NO) == 0.5);
    assert(SLSpotlightWatchInterval(YES, NO) == 0.05);
    assert(SLSpotlightWatchInterval(NO, YES) == 0.05);
    CALayer *layer = [CALayer layer];
    CGImageRef red = TestImage(1,0,0), gray = TestImage(.5,.5,.5);
    layer.contents = (__bridge id)red;
    assert(LayerTreeContainsChromaticContent(layer));
    NSArray *cached = objc_getAssociatedObject(layer, LayerChromaticCacheKey);
    assert(cached.count == 2 && cached[0] == (__bridge id)red);
    CFTimeInterval start = CACurrentMediaTime();
    for (NSUInteger i=0;i<10000;i++) {
        @autoreleasepool {
            assert(LayerTreeContainsChromaticContent(layer));
            assert(objc_getAssociatedObject(layer, LayerChromaticCacheKey) == cached);
        }
    }
    printf("10,000 unchanged-layer scans, cached: %.6f seconds\n", CACurrentMediaTime()-start);
    layer.contents = (__bridge id)gray;
    assert(!LayerTreeContainsChromaticContent(layer));
    assert(objc_getAssociatedObject(layer, LayerChromaticCacheKey) != cached);
    layer.contents = nil;
    assert(!LayerTreeContainsChromaticContent(layer));
    assert(!objc_getAssociatedObject(layer, LayerChromaticCacheKey));
    CALayer *child = [CALayer layer]; child.contents = (__bridge id)red;
    [layer addSublayer:child];
    assert(LayerTreeContainsChromaticContent(layer));
    child.hidden = YES; assert(!LayerTreeContainsChromaticContent(layer));
    child.hidden = NO; assert(LayerTreeContainsChromaticContent(layer));

    SLCountingImageView *view = [[SLCountingImageView alloc] initWithFrame:NSMakeRect(0,0,16,16)];
    NSImage *image = [[NSImage alloc] initWithCGImage:red size:NSMakeSize(16,16)];
    image.template = YES; view.image = image; view.contentTintColor = nil; view.tintWrites = 0;
    for (NSUInteger i=0;i<1000;i++) ApplySelectiveTint(view,NSColor.blackColor);
    assert(view.tintWrites == 1);
    ApplySelectiveTint(view,NSColor.whiteColor); assert(view.tintWrites == 2);
    image.template = NO;
    ApplySelectiveTint(view,NSColor.blackColor);
    assert(view.contentTintColor == nil); // original colour policy restored
    CGImageRelease(red); CGImageRelease(gray);
    puts("PASS: inert Spotlight anchor marker, Spotlight snapshot exclusion, reentry guard, adaptive cadence, one-entry layer cache/replacement/release, unchanged tint writes=1/1000, selected tint and original restoration.");
} return 0; }
