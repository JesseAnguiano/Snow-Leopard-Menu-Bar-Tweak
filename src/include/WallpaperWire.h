#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#include <float.h>
#include <math.h>
#include <stdint.h>

// Dedicated local named pasteboard, never generalPasteboard / Universal Clipboard.
static NSString *const SLWallpaperBoardName = @"com.snowleopardmenubar.wallpaper.v1";
static NSString *const SLWallpaperWireType = @"com.snowleopardmenubar.wallpaper-payload";
static const NSUInteger SLWallpaperMaxPayload = 8 * 1024 * 1024;
static const CGFloat SLWallpaperStripHeight = 64.0;

static inline BOOL SLWallpaperValidNumber(id value, double minimum, double maximum) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) &&
        [value doubleValue] >= minimum && [value doubleValue] <= maximum;
}

static inline NSDictionary *SLWallpaperDecodePayload(NSData *data) {
    if (![data isKindOfClass:NSData.class] || data.length > SLWallpaperMaxPayload) return nil;
    id result = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
        format:NULL error:NULL];
    if (![result isKindOfClass:NSDictionary.class] ||
        ![result[@"version"] isEqual:@1] ||
        ![result[@"generation"] isKindOfClass:NSString.class] ||
        [result[@"generation"] length] > 80 ||
        !SLWallpaperValidNumber(result[@"publishedAt"], 0, DBL_MAX) ||
        ![result[@"displays"] isKindOfClass:NSArray.class] ||
        [result[@"displays"] count] > 16) return nil;
    for (id item in result[@"displays"]) {
        if (![item isKindOfClass:NSDictionary.class] ||
            !SLWallpaperValidNumber(item[@"displayID"], 1, UINT32_MAX) ||
            !SLWallpaperValidNumber(item[@"width"], 1, 16384) ||
            !SLWallpaperValidNumber(item[@"screenHeight"], 64, 16384) ||
            !SLWallpaperValidNumber(item[@"scale"], 1, 4) ||
            ![item[@"png"] isKindOfClass:NSData.class] ||
            [item[@"png"] length] > 4 * 1024 * 1024) return nil;
    }
    return result;
}

static inline CGImageRef SLWallpaperDecodeImage(NSDictionary *entry) CF_RETURNS_RETAINED {
    NSData *data = entry[@"png"];
    if (![data isKindOfClass:NSData.class] || data.length > 4 * 1024 * 1024) return NULL;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return NULL;
    CFStringRef type = CGImageSourceGetType(source);
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    double width = [properties[(id)kCGImagePropertyPixelWidth] doubleValue];
    double height = [properties[(id)kCGImagePropertyPixelHeight] doubleValue];
    CGImageRef image = NULL;
    if (type && CFEqual(type, CFSTR("public.png")) &&
        width > 0 && width <= 32768 && height > 0 && height <= 256 &&
        width * height <= 8388608 &&
        fabs(width - [entry[@"width"] doubleValue] * [entry[@"scale"] doubleValue]) < 1 &&
        fabs(height - SLWallpaperStripHeight * [entry[@"scale"] doubleValue]) < 1) {
        image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    }
    CFRelease(source);
    return image;
}
