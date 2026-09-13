#define SLEmbeddedStatusIconOverlayView SLTestEmbeddedStatusIconOverlayView
#import "../src/status/StatusIcons.m"
#include <assert.h>

int main(void) { @autoreleasepool {
    assert(SLStatusAssetBatch == nil);
    SLStatusAssetBatch = [NSMutableDictionary dictionaryWithCapacity:4];
    // Even an empty result must be cached rather than queried repeatedly.
    assert([SLCurrentAssetForKind(SLStatusIconKindNone) isEqualToString:@""]);
    assert(SLStatusAssetBatch.count == 1);
    for (SLStatusIconKind kind = SLStatusIconKindWiFi;
         kind <= SLStatusIconKindBattery; kind++) {
        NSString *sentinel = [NSString stringWithFormat:@"batch-%ld", (long)kind];
        SLStatusAssetBatch[@(kind)] = sentinel;
        for (NSUInteger i = 0; i < 1000; i++) {
            assert(SLCurrentAssetForKind(kind) == sentinel);
        }
    }
    assert(SLStatusAssetBatch.count == 5);
    SLStatusAssetBatch = nil;
    assert([SLCurrentAssetForKind(SLStatusIconKindNone) isEqualToString:@""]);
    assert(SLStatusAssetBatch == nil);
    puts("PASS: per-kind synchronous asset batch, empty-result cache, batch release, no persistent TTL.");
} return 0; }
