#define SLSnowLeopardMenuBarBackdropView SLColorTestBackdrop
#define SLSnowLeopardMenuBarFilmView SLColorTestFilm
#define SLSnowLeopardMenuBarLowerShadowView SLColorTestShadowView
#define SLSnowLeopardMenuBarLowerShadowPanel SLColorTestShadowPanel
#import "../src/menubar/MenuBar.m"
#include <assert.h>
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 3) return 2;
    NSURL *url = [NSURL fileURLWithPath:@(argv[1])];
    CGImageSourceRef input = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    assert(input);
    CGImageRef original = CGImageSourceCreateImageAtIndex(input, 0, NULL);
    assert(original);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmap = CGBitmapContextCreate(NULL, 1920, 1200, 8, 0, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextSetInterpolationQuality(bitmap, kCGInterpolationHigh);
    CGContextDrawImage(bitmap, CGRectMake(0,0,1920,1200), original);
    CGImageRef resized = CGBitmapContextCreateImage(bitmap);
    CGImageRef strip = CGImageCreateWithImageInRect(resized, CGRectMake(0,59,1920,21));
    // Production fallback scale is 2.0; render exactly 1920x21 pixels.
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0,0,960,10.5)];
    CGImageRef result = SLComposeDirectWallpaper(strip, view);
    assert(result && CGImageGetWidth(result) == 1920 && CGImageGetHeight(result) == 21);
    NSURL *out = [NSURL fileURLWithPath:@(argv[2])];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)out, CFSTR("public.png"), 1, NULL);
    assert(destination);
    CGImageDestinationAddImage(destination, result, NULL);
    assert(CGImageDestinationFinalize(destination));
    CFRelease(destination); CGImageRelease(result); CGImageRelease(strip);
    CGImageRelease(resized); CGContextRelease(bitmap); CGColorSpaceRelease(space);
    CGImageRelease(original); CFRelease(input);
    puts("PASS: generated PNG through the production renderer, not a Python approximation.");
} return 0; }
