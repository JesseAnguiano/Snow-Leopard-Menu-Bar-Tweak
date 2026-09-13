// Override with -DSL_SYSTEM_STATUS_SOURCE='"/absolute/SystemStatusItems.m"' when benchmarking another checkout.
#define SLSnowLeopardRightSelectionView SLBenchmarkSelectionView
#ifndef SL_SYSTEM_STATUS_SOURCE
#define SL_SYSTEM_STATUS_SOURCE "../src/status/SystemStatusItems.m"
#endif
#import SL_SYSTEM_STATUS_SOURCE
#include <assert.h>
void SLStatusIconReplacementSetHighlighted(NSView *view, BOOL selected) { (void)view; (void)selected; }
@interface SLBenchmarkImageView : NSImageView
@property NSUInteger writes;
@end
@implementation SLBenchmarkImageView
- (void)setContentTintColor:(NSColor *)colour { self.writes++; [super setContentTintColor:colour]; }
@end
int main(void) { @autoreleasepool {
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx=CGBitmapContextCreate(NULL,16,16,8,64,space,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextSetRGBFillColor(ctx,1,0,0,1); CGContextFillRect(ctx,CGRectMake(0,0,16,16));
    CGImageRef image=CGBitmapContextCreateImage(ctx);
    CALayer *layer=[CALayer layer]; layer.contents=(__bridge id)image;
    CFTimeInterval start=CACurrentMediaTime();
    for (NSUInteger i=0;i<10000;i++) { @autoreleasepool { assert(LayerTreeContainsChromaticContent(layer)); } }
    printf("layer scans=10000 elapsed=%.6f s\n", CACurrentMediaTime()-start);
    SLBenchmarkImageView *view=[[SLBenchmarkImageView alloc] initWithFrame:NSMakeRect(0,0,16,16)];
    NSImage *icon=[[NSImage alloc] initWithCGImage:image size:NSMakeSize(16,16)];
    icon.template=YES; view.image=icon; view.contentTintColor=nil; view.writes=0;
    for (NSUInteger i=0;i<1000;i++) ApplySelectiveTint(view,NSColor.blackColor);
    printf("unchanged tint calls=1000 setter writes=%lu\n", (unsigned long)view.writes);
    CGImageRelease(image); CGContextRelease(ctx); CGColorSpaceRelease(space);
} return 0; }
