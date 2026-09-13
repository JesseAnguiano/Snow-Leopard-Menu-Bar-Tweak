#import <Cocoa/Cocoa.h>

// Spotlight's status glyph is known monochrome. Rendering it offscreen to
// rediscover that fact invokes other injected image hooks unnecessarily.
static inline BOOL SLStatusSnapshotAllowed(BOOL attached, BOOL capturing,
                                           NSString *bundleID) {
    return attached && !capturing && ![bundleID isEqualToString:@"com.apple.Spotlight"];
}

static inline NSTimeInterval SLSpotlightWatchInterval(BOOL visible, BOOL active) {
    return visible || active ? 0.05 : 0.5;
}
