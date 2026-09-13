#define SLSnowLeopardMenuBarBackdropView SLShadowRegressionBackdrop
#define SLSnowLeopardMenuBarFilmView SLShadowRegressionFilm
#define SLSnowLeopardMenuBarLowerShadowView SLShadowRegressionView
#define SLSnowLeopardMenuBarLowerShadowPanel SLShadowRegressionPanel
#import "../src/menubar/MenuBar.m"
#include <assert.h>
int main(void) { @autoreleasepool {
    assert(SLLowerShadowWindowLevel() > CGWindowLevelForKey(kCGDesktopWindowLevelKey));
    assert(SLLowerShadowWindowLevel() < CGWindowLevelForKey(kCGDesktopIconWindowLevelKey));
    assert(SLLowerShadowWindowLevel() < NSNormalWindowLevel);
    NSRect screen = NSMakeRect(0,0,1440,900), menu = NSMakeRect(0,876,1440,24);
    NSRect shadow = SLLowerShadowFrame(screen, menu);
    assert(NSEqualRects(shadow,NSMakeRect(0,862,1440,14)));
    assert(NSMaxY(shadow) == NSMinY(menu)); // strictly outside the bar
    assert(NSEqualRects(SLLowerShadowFrame(NSMakeRect(1440,-200,1440,900),
        NSMakeRect(1440,676,1440,24)),NSMakeRect(1440,662,1440,14)));
    assert(NSIsEmptyRect(SLLowerShadowFrame(screen,NSMakeRect(0,876,100,24))));
    assert(NSIsEmptyRect(SLLowerShadowFrame(screen,NSMakeRect(0,875,1440,22))));
    NSRect visible = NSMakeRect(0,0,1440,876);
    assert(SLLowerShadowAllowed(YES,0,screen,visible));
    assert(!SLLowerShadowAllowed(NO,0,screen,visible));
    assert(!SLLowerShadowAllowed(YES,NSApplicationPresentationHideMenuBar,screen,visible));
    assert(!SLLowerShadowAllowed(YES,NSApplicationPresentationAutoHideMenuBar,screen,visible));
    assert(!SLLowerShadowAllowed(YES,0,screen,screen));
    uint8_t rgba[8*28*4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(rgba,8,28,8,8*4,space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    assert(ctx);
    CGContextScaleCTM(ctx,2,2);
    SLDrawLowerShadow(ctx,NSMakeRect(0,0,4,14));
    unsigned char previous=255;
    for (NSUInteger y=0;y<28;y++) {
        unsigned char *pixel=rgba+y*8*4;
        assert(pixel[0]==0 && pixel[1]==0 && pixel[2]==0);
        assert(pixel[3] <= previous && pixel[3] < 110);
        previous=pixel[3];
    }
    assert(rgba[3] >= 95 && previous <= 2);
    SLShadowRegressionView *view = [[SLShadowRegressionView alloc] initWithFrame:shadow];
    assert(!view.isOpaque && [view hitTest:NSMakePoint(1,1)] == nil);
    CGContextRelease(ctx); CGColorSpaceRelease(space);
    puts("PASS: shadow outside menu, Retina 2x falloff, no opaque rule, secondary-screen coordinates, inactive/fullscreen/auto-hide guards, view hit-test passthrough. GUI lifecycle requires live validation.");
} return 0; }
