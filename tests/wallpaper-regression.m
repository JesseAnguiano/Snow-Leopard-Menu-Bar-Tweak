#define SLSnowLeopardMenuBarBackdropView SLWallpaperRegressionBackdrop
#define SLSnowLeopardMenuBarFilmView SLWallpaperRegressionFilm
#define SLSnowLeopardMenuBarLowerShadowView SLWallpaperTestShadowView
#define SLSnowLeopardMenuBarLowerShadowPanel SLWallpaperTestShadowPanel
#import "../src/menubar/MenuBar.m"
#include <assert.h>

static NSData *Wire(id object) {
    return [NSPropertyListSerialization dataWithPropertyList:object
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
}
int main(void) {
    @autoreleasepool {
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate(NULL, 200, 128, 8, 0, space,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        assert(ctx);
        CGContextSetRGBFillColor(ctx, 0, 1, 0, 1);
        CGContextFillRect(ctx, CGRectMake(0, 0, 100, 128));
        CGContextSetRGBFillColor(ctx, 1, 0, 0, 1);
        CGContextFillRect(ctx, CGRectMake(100, 0, 100, 128));
        CGImageRef raw = CGBitmapContextCreateImage(ctx);
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:raw];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSDictionary *entry = @{@"displayID":@1, @"width":@100, @"screenHeight":@900, @"scale":@2, @"png":png};
        NSMutableDictionary *payload = [@{@"version":@1, @"generation":@"test", @"publishedAt":@1,
            @"displays":@[entry]} mutableCopy];
        assert(SLWallpaperDecodePayload(Wire(payload)));
        assert(!SLWallpaperDecodePayload(Wire(@[])));
        assert(!SLWallpaperDecodePayload([NSData dataWithBytes:"bad" length:3]));
        payload[@"version"] = @2;
        assert(!SLWallpaperDecodePayload(Wire(payload)));
        payload[@"version"] = @1;
        payload[@"displays"] = @[@{@"displayID":@1}];
        assert(!SLWallpaperDecodePayload(Wire(payload)));
        CGImageRef decoded = SLWallpaperDecodeImage(entry);
        assert(decoded && CGImageGetHeight(decoded) == 128);
        NSMutableDictionary *bad = entry.mutableCopy;
        bad[@"width"] = @101;
        assert(!SLWallpaperDecodeImage(bad));
        bad[@"png"] = [NSData data];
        assert(!SLWallpaperDecodeImage(bad));
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, 24)];
        CGImageRef material = SLComposeDirectWallpaper(decoded, view);
        assert(material && CGImageGetWidth(material) == 200 && CGImageGetHeight(material) == 48);
        CGContextRef result = CGBitmapContextCreate(NULL, 200, 48, 8, 0, space,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGContextDrawImage(result, CGRectMake(0, 0, 200, 48), material);
        unsigned char *pixels = CGBitmapContextGetData(result);
        size_t stride = CGBitmapContextGetBytesPerRow(result);
        unsigned char *green = pixels + stride * 24 + 30 * 4;
        unsigned char *red = pixels + stride * 24 + 170 * 4;
        assert(green[3] == 255 && red[3] == 255);
        assert(green[1] > green[0] + 30 && red[0] > red[1] + 30);
        // The v14 reference model adds illumination independently of source
        // transmission (~165 here). There must be no white overlay afterward.
        assert(green[0] >= 160 && green[0] <= 170);
        assert(red[1] >= 160 && red[1] <= 170);
        assert(pixels[30 * 4] > green[0]); // top brighter than the body
        assert(green[0] > pixels[stride * 47 + 30 * 4]);
        // Check pitch padding and alpha using the production pixel operation.
        uint8_t padded[24] = {0};
        padded[4] = padded[5] = padded[6] = padded[7] = 77;
        SLMenuBarApplyColorTransfer(padded, 1, 3, 8);
        assert(padded[4] == 77 && padded[7] == 77);
        assert(padded[3] == 255 && padded[11] == 255 && padded[19] == 255);
        assert(padded[0] > padded[8] && padded[8] > padded[16]);
        CGImageRelease(material); CGImageRelease(decoded); CGImageRelease(raw);
        CGContextRelease(result); CGContextRelease(ctx); CGColorSpaceRelease(space);
        puts("PASS: wire validation, malformed payloads, PNG dimensions, Retina color transfer, gradient orientation, stride, opaque alpha and no double film. No global visual claim.");
    }
    return 0;
}
