#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>
#import <string.h>
#import <unistd.h>

#import "SnowLeopardEmbeddedAssets.h"
#import "Runtime.h"
#import "SelectionRenderer.h"

const char SLSnowLeopardStatusIconCapabilities[] =
    "snowLeopardStatusIcons=embedded-v2 owner=unified";

// Embedded Snow Leopard status icons for the Apple-owned right side of the
// menu bar. No image file is read at runtime: all PDF bytes are linked into
// libSnowLeopardMenuBarUnified.dylib.

typedef NS_ENUM(NSInteger, SLStatusIconKind) {
    SLStatusIconKindNone = 0,
    SLStatusIconKindWiFi,
    SLStatusIconKindSound,
    SLStatusIconKindBluetooth,
    SLStatusIconKindBattery,
};

typedef id (*SLObjCIdSend)(id, SEL);
typedef BOOL (*SLObjCBoolSend)(id, SEL);
typedef NSInteger (*SLObjCIntegerSend)(id, SEL);

static Class SLStatusBarWindowClass = Nil;
static Ivar SLStatusViewIvar = NULL;
static dispatch_source_t SLStatusIconTimer = NULL;
static NSMutableDictionary<NSString *, NSImage *> *SLNormalImageCache = nil;
static NSMutableDictionary<NSString *, NSImage *> *SLSelectedImageCache = nil;
static NSMutableDictionary<NSString *, NSImage *> *SLBatteryImageCache = nil;
static void *SLCoreWLANHandle = NULL;
static void *SLIOBluetoothHandle = NULL;
static NSUInteger SLStatusIconAttachLogCount = 0;
static NSUInteger SLStatusIconStateLogCount = 0;
static char SLStatusIconOverlayKey;
static char SLStatusIconOriginalLayerOpacityKey;

static BOOL SLStatusIconHasExactControlCenterIdentity(void) {
    return SLIsExactControlCenterProcess();
}

static NSImage *SLStatusIconImageNamed(
    NSString *name,
    BOOL selected
) {
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        SLNormalImageCache = [NSMutableDictionary dictionary];
        SLSelectedImageCache = [NSMutableDictionary dictionary];
    });

    NSMutableDictionary<NSString *, NSImage *> *cache =
        selected ? SLSelectedImageCache : SLNormalImageCache;

    NSImage *cached = cache[name];
    if (cached) return cached;

    const SLEmbeddedAsset *asset =
        SLEmbeddedAssetNamed(name.UTF8String);

    if (!asset) return nil;

    NSData *data =
        [NSData dataWithBytes:asset->bytes length:asset->length];

    NSImage *image = [[NSImage alloc] initWithData:data];
    if (!image) return nil;

    image.template = selected;
    cache[name] = image;
    return image;
}

static SLStatusIconKind SLStatusIconKindForWindowTitle(
    NSString *title
) {
    if ([title isEqualToString:@"WiFi"]) {
        return SLStatusIconKindWiFi;
    }

    if ([title isEqualToString:@"Sound"]) {
        return SLStatusIconKindSound;
    }

    if ([title isEqualToString:@"Bluetooth"]) {
        return SLStatusIconKindBluetooth;
    }

    if ([title isEqualToString:@"Battery"]) {
        return SLStatusIconKindBattery;
    }

    return SLStatusIconKindNone;
}

static NSString *SLStatusIconDefaultAssetForKind(
    SLStatusIconKind kind
) {
    switch (kind) {
        case SLStatusIconKindWiFi:
            return @"AirportInMenu4";

        case SLStatusIconKindSound:
            return @"Volume4";

        case SLStatusIconKindBluetooth:
            return @"BlueTooth_Idle";

        case SLStatusIconKindBattery:
            return @"BatteryEmpty";

        case SLStatusIconKindNone:
        default:
            return @"";
    }
}

/* Preserve the embedded artwork at 1:1 inside Sequoia's native bounds. */
static const CGFloat SLStatusIconVisualScale = 1.15;
static const CGFloat SLStatusIconMinimumInset = 2.0;

static BOOL SLObjectResponds(id object, SEL selector) {
    return object && selector && [object respondsToSelector:selector];
}

static id SLObjectResult(id object, SEL selector) {
    if (!SLObjectResponds(object, selector)) return nil;
    return ((SLObjCIdSend)objc_msgSend)(object, selector);
}

static BOOL SLBoolResult(id object, SEL selector, BOOL fallback) {
    if (!SLObjectResponds(object, selector)) return fallback;
    return ((SLObjCBoolSend)objc_msgSend)(object, selector);
}

static NSInteger SLIntegerResult(
    id object,
    SEL selector,
    NSInteger fallback
) {
    if (!SLObjectResponds(object, selector)) return fallback;
    return ((SLObjCIntegerSend)objc_msgSend)(object, selector);
}

static NSString *SLCurrentWiFiAssetName(void) {
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        SLCoreWLANHandle = dlopen(
            "/System/Library/Frameworks/CoreWLAN.framework/CoreWLAN",
            RTLD_LAZY | RTLD_LOCAL);
    });

    (void)SLCoreWLANHandle;

    Class clientClass = NSClassFromString(@"CWWiFiClient");
    id client = SLObjectResult(
        (id)clientClass,
        NSSelectorFromString(@"sharedWiFiClient"));
    id interface = SLObjectResult(
        client,
        NSSelectorFromString(@"interface"));

    if (!interface) return @"AirPortOff";

    BOOL powerOn = SLBoolResult(
        interface,
        NSSelectorFromString(@"powerOn"),
        NO);

    if (!powerOn) return @"AirPortOff";

    BOOL serviceActive = SLBoolResult(
        interface,
        NSSelectorFromString(@"serviceActive"),
        YES);

    NSInteger rssi = SLIntegerResult(
        interface,
        NSSelectorFromString(@"rssiValue"),
        0);

    if (!serviceActive || rssi >= 0) {
        return @"AirportInMenu0";
    }

    if (rssi <= -82) return @"AirportInMenu1";
    if (rssi <= -72) return @"AirportInMenu2";
    if (rssi <= -62) return @"AirportInMenu3";
    return @"AirportInMenu4";
}

static BOOL SLReadAudioProperty(
    AudioObjectID objectID,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    AudioObjectPropertyElement element,
    void *value,
    UInt32 expectedSize
) {
    AudioObjectPropertyAddress address = {
        selector,
        scope,
        element
    };

    if (!AudioObjectHasProperty(objectID, &address)) return NO;

    UInt32 size = expectedSize;
    OSStatus status = AudioObjectGetPropertyData(
        objectID,
        &address,
        0,
        NULL,
        &size,
        value);

    return status == noErr && size == expectedSize;
}

static AudioDeviceID SLDefaultOutputDevice(void) {
    AudioDeviceID device = kAudioObjectUnknown;

    BOOL success = SLReadAudioProperty(
        kAudioObjectSystemObject,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
        &device,
        (UInt32)sizeof(device));

    return success ? device : kAudioObjectUnknown;
}

static BOOL SLOutputDeviceMuted(AudioDeviceID device) {
    UInt32 muted = 0;

    if (SLReadAudioProperty(
            device,
            kAudioDevicePropertyMute,
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyElementMain,
            &muted,
            (UInt32)sizeof(muted))) {
        return muted != 0;
    }

    for (AudioObjectPropertyElement channel = 1;
         channel <= 2;
         channel++) {
        muted = 0;

        if (SLReadAudioProperty(
                device,
                kAudioDevicePropertyMute,
                kAudioDevicePropertyScopeOutput,
                channel,
                &muted,
                (UInt32)sizeof(muted)) &&
            muted != 0) {
            return YES;
        }
    }

    return NO;
}

static Float32 SLOutputDeviceVolume(AudioDeviceID device) {
    Float32 volume = 1.0f;

    if (SLReadAudioProperty(
            device,
            kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyElementMain,
            &volume,
            (UInt32)sizeof(volume))) {
        return fmaxf(0.0f, fminf(1.0f, volume));
    }

    Float32 total = 0.0f;
    NSUInteger count = 0;

    for (AudioObjectPropertyElement channel = 1;
         channel <= 2;
         channel++) {
        Float32 channelVolume = 0.0f;

        if (SLReadAudioProperty(
                device,
                kAudioDevicePropertyVolumeScalar,
                kAudioDevicePropertyScopeOutput,
                channel,
                &channelVolume,
                (UInt32)sizeof(channelVolume))) {
            total += channelVolume;
            count++;
        }
    }

    if (count == 0) return 1.0f;
    return fmaxf(0.0f, fminf(1.0f, total / (Float32)count));
}

static NSString *SLCurrentSoundAssetName(void) {
    AudioDeviceID device = SLDefaultOutputDevice();
    if (device == kAudioObjectUnknown) return @"Volume4";

    BOOL muted = SLOutputDeviceMuted(device);
    Float32 volume = SLOutputDeviceVolume(device);

    if (muted || volume <= 0.005f) return @"Volume1";
    if (volume <= 0.34f) return @"Volume2";
    if (volume <= 0.67f) return @"Volume3";
    return @"Volume4";
}

static NSString *SLCurrentBluetoothAssetName(void) {
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        SLIOBluetoothHandle = dlopen(
            "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth",
            RTLD_LAZY | RTLD_LOCAL);
    });

    (void)SLIOBluetoothHandle;

    Class controllerClass =
        NSClassFromString(@"IOBluetoothHostController");

    id controller = SLObjectResult(
        (id)controllerClass,
        NSSelectorFromString(@"defaultController"));

    if (!controller) return @"BlueTooth_Off";

    NSInteger powerState = SLIntegerResult(
        controller,
        NSSelectorFromString(@"powerState"),
        0);

    if (powerState == 0) return @"BlueTooth_Off";
    if (powerState != 1) return @"BlueTooth_Error";

    Class deviceClass = NSClassFromString(@"IOBluetoothDevice");
    id pairedResult = SLObjectResult(
        (id)deviceClass,
        NSSelectorFromString(@"pairedDevices"));

    NSArray *pairedDevices =
        [pairedResult isKindOfClass:NSArray.class]
        ? (NSArray *)pairedResult
        : @[];

    for (id device in pairedDevices) {
        if (SLBoolResult(
                device,
                NSSelectorFromString(@"isConnected"),
                NO)) {
            return @"BlueTooth_Connected";
        }
    }

    return @"BlueTooth_Idle";
}

typedef struct {
    BOOL present;
    BOOL charging;
    BOOL charged;
    BOOL externalPower;
    BOOL permanentFailure;
    NSInteger percentage;
} SLBatteryState;

static BOOL SLCFDictionaryBoolean(
    CFDictionaryRef dictionary,
    CFStringRef key,
    BOOL fallback
) {
    if (!dictionary || !key) return fallback;

    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    if (!value || CFGetTypeID(value) != CFBooleanGetTypeID()) {
        return fallback;
    }

    return CFBooleanGetValue((CFBooleanRef)value);
}

static NSInteger SLCFDictionaryInteger(
    CFDictionaryRef dictionary,
    CFStringRef key,
    NSInteger fallback
) {
    if (!dictionary || !key) return fallback;

    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return fallback;
    }

    NSInteger result = fallback;
    if (!CFNumberGetValue(
            (CFNumberRef)value,
            kCFNumberNSIntegerType,
            &result)) {
        return fallback;
    }

    return result;
}

static BOOL SLCFDictionaryStringEquals(
    CFDictionaryRef dictionary,
    CFStringRef key,
    CFStringRef expected
) {
    if (!dictionary || !key || !expected) return NO;

    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) {
        return NO;
    }

    return CFEqual(value, expected);
}

static SLBatteryState SLCurrentBatteryState(void) {
    SLBatteryState state = {
        .present = NO,
        .charging = NO,
        .charged = NO,
        .externalPower = NO,
        .permanentFailure = NO,
        .percentage = 0,
    };

    CFTypeRef powerInfo = IOPSCopyPowerSourcesInfo();
    if (!powerInfo) return state;

    CFArrayRef sources = IOPSCopyPowerSourcesList(powerInfo);
    if (!sources) {
        CFRelease(powerInfo);
        return state;
    }

    CFIndex count = CFArrayGetCount(sources);

    for (CFIndex index = 0; index < count; index++) {
        CFTypeRef source = CFArrayGetValueAtIndex(sources, index);
        CFDictionaryRef description =
            IOPSGetPowerSourceDescription(powerInfo, source);

        if (!description) continue;

        if (!SLCFDictionaryStringEquals(
                description,
                CFSTR(kIOPSTypeKey),
                CFSTR(kIOPSInternalBatteryType))) {
            continue;
        }

        state.present = SLCFDictionaryBoolean(
            description,
            CFSTR(kIOPSIsPresentKey),
            YES);

        NSInteger currentCapacity = SLCFDictionaryInteger(
            description,
            CFSTR(kIOPSCurrentCapacityKey),
            0);

        NSInteger maximumCapacity = SLCFDictionaryInteger(
            description,
            CFSTR(kIOPSMaxCapacityKey),
            100);

        if (maximumCapacity <= 0) maximumCapacity = 100;

        double ratio =
            (double)currentCapacity /
            (double)maximumCapacity;

        NSInteger percentage =
            (NSInteger)lround(ratio * 100.0);

        state.percentage = MAX(
            0,
            MIN(100, percentage));

        state.charging = SLCFDictionaryBoolean(
            description,
            CFSTR(kIOPSIsChargingKey),
            NO);

        state.charged = SLCFDictionaryBoolean(
            description,
            CFSTR(kIOPSIsChargedKey),
            NO);

        state.externalPower = SLCFDictionaryStringEquals(
            description,
            CFSTR(kIOPSPowerSourceStateKey),
            CFSTR(kIOPSACPowerValue));

        state.permanentFailure = SLCFDictionaryStringEquals(
            description,
            CFSTR(kIOPSBatteryHealthConditionKey),
            CFSTR(kIOPSPermanentFailureValue));

        break;
    }

    CFRelease(sources);
    CFRelease(powerInfo);

    return state;
}

static NSString *SLCurrentBatteryStateToken(void) {
    SLBatteryState state = SLCurrentBatteryState();

    if (!state.present) return @"BatteryNone";
    if (state.permanentFailure) return @"BatteryDeadCropped";
    if (state.charging) return @"BatteryCharging";
    if (state.charged) return @"BatteryCharged";

    BOOL low = state.percentage <= 20;

    return [NSString stringWithFormat:
        @"BatteryLevel:%ld:%@:%d",
        (long)state.percentage,
        low ? @"red" : @"black",
        state.externalPower];
}

static BOOL SLParseBatteryLevelToken(
    NSString *token,
    NSInteger *percentage,
    BOOL *red
) {
    if (![token hasPrefix:@"BatteryLevel:"]) return NO;

    NSArray<NSString *> *parts =
        [token componentsSeparatedByString:@":"];

    if (parts.count < 3) return NO;

    NSInteger parsedPercentage =
        [parts[1] integerValue];

    if (percentage) {
        *percentage = MAX(
            0,
            MIN(100, parsedPercentage));
    }

    if (red) {
        *red = [parts[2] isEqualToString:@"red"];
    }

    return YES;
}

static void SLDrawBatteryPiece(
    NSImage *image,
    NSRect destination
) {
    if (!image || NSIsEmptyRect(destination)) return;

    [image drawInRect:destination
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0
       respectFlipped:YES
                hints:nil];
}

static NSImage *SLBatteryLevelImage(
    NSInteger percentage,
    BOOL red,
    BOOL selected
) {
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        SLBatteryImageCache = [NSMutableDictionary dictionary];
    });

    NSString *cacheKey = [NSString stringWithFormat:
        @"%ld:%d:%d",
        (long)percentage,
        red,
        selected];

    NSImage *cached = SLBatteryImageCache[cacheKey];
    if (cached) return cached;

    NSImage *outline =
        SLStatusIconImageNamed(@"BatteryEmpty", NO);

    NSString *prefix = red
        ? @"BatteryLevelCapR-"
        : @"BatteryLevelCapB-";

    NSImage *left = SLStatusIconImageNamed(
        [prefix stringByAppendingString:@"L"],
        NO);
    NSImage *middle = SLStatusIconImageNamed(
        [prefix stringByAppendingString:@"M"],
        NO);
    NSImage *right = SLStatusIconImageNamed(
        [prefix stringByAppendingString:@"R"],
        NO);

    if (!outline || !left || !middle || !right) {
        return outline;
    }

    NSInteger fillPixels =
        (NSInteger)lround(
            ((double)percentage / 100.0) * 14.0);

    if (percentage > 0 && fillPixels < 1) {
        fillPixels = 1;
    }

    fillPixels = MAX(0, MIN(14, fillPixels));

    NSSize imageSize = NSMakeSize(22.0, 12.0);

    NSImage *result = [NSImage
        imageWithSize:imageSize
        flipped:NO
        drawingHandler:^BOOL(NSRect destinationRect) {
            CGFloat scaleX =
                destinationRect.size.width / imageSize.width;
            CGFloat scaleY =
                destinationRect.size.height / imageSize.height;

            SLDrawBatteryPiece(outline, destinationRect);

            if (fillPixels <= 0) return YES;

            CGFloat originX =
                destinationRect.origin.x + 3.0 * scaleX;
            CGFloat originY =
                destinationRect.origin.y + 3.0 * scaleY;
            CGFloat pieceWidth = 1.0 * scaleX;
            CGFloat pieceHeight = 6.0 * scaleY;

            if (fillPixels == 1) {
                SLDrawBatteryPiece(
                    left,
                    NSMakeRect(
                        originX,
                        originY,
                        pieceWidth,
                        pieceHeight));
                return YES;
            }

            SLDrawBatteryPiece(
                left,
                NSMakeRect(
                    originX,
                    originY,
                    pieceWidth,
                    pieceHeight));

            for (NSInteger pixel = 1;
                 pixel < fillPixels - 1;
                 pixel++) {
                SLDrawBatteryPiece(
                    middle,
                    NSMakeRect(
                        originX + pixel * pieceWidth,
                        originY,
                        pieceWidth,
                        pieceHeight));
            }

            SLDrawBatteryPiece(
                right,
                NSMakeRect(
                    originX +
                        (fillPixels - 1) * pieceWidth,
                    originY,
                    pieceWidth,
                    pieceHeight));

            return YES;
        }];

    result.template = selected;
    SLBatteryImageCache[cacheKey] = result;
    return result;
}

static NSImage *SLStatusIconImageForState(
    SLStatusIconKind kind,
    NSString *stateToken,
    BOOL selected
) {
    if (kind != SLStatusIconKindBattery) {
        return SLStatusIconImageNamed(stateToken, selected);
    }

    NSInteger percentage = 0;
    BOOL red = NO;

    if (SLParseBatteryLevelToken(
            stateToken,
            &percentage,
            &red)) {
        return SLBatteryLevelImage(
            percentage,
            red,
            selected);
    }

    return SLStatusIconImageNamed(stateToken, selected);
}

static NSMutableDictionary<NSNumber *, NSString *> *SLStatusAssetBatch;

static NSString *SLReadAssetForKind(SLStatusIconKind kind) {
    switch (kind) {
        case SLStatusIconKindWiFi:
            return SLCurrentWiFiAssetName();

        case SLStatusIconKindSound:
            return SLCurrentSoundAssetName();

        case SLStatusIconKindBluetooth:
            return SLCurrentBluetoothAssetName();

        case SLStatusIconKindBattery:
            return SLCurrentBatteryStateToken();

        case SLStatusIconKindNone:
        default:
            return @"";
    }
}

// Share live hardware queries across replicas in one synchronous refresh.
// The caller discards this batch afterwards; there is no stale-state TTL.
static NSString *SLCurrentAssetForKind(SLStatusIconKind kind) {
    NSString *cached = SLStatusAssetBatch[@(kind)];
    if (cached) return cached;
    NSString *asset = SLReadAssetForKind(kind);
    if (asset) SLStatusAssetBatch[@(kind)] = asset;
    return asset;
}

@interface SLEmbeddedStatusIconOverlayView : NSView

@property(nonatomic) SLStatusIconKind iconKind;
@property(nonatomic) BOOL selected;
@property(nonatomic, copy) NSString *assetName;
@property(nonatomic, strong) NSImageView *imageView;

- (instancetype)initWithFrame:(NSRect)frame
                     iconKind:(SLStatusIconKind)iconKind;
- (void)applyAssetName:(NSString *)assetName selected:(BOOL)selected;

@end

@implementation SLEmbeddedStatusIconOverlayView

- (instancetype)initWithFrame:(NSRect)frame
                     iconKind:(SLStatusIconKind)iconKind {
    self = [super initWithFrame:frame];

    if (!self) return nil;

    _iconKind = iconKind;
    _selected = NO;
    _assetName = SLStatusIconDefaultAssetForKind(iconKind);

    self.autoresizingMask =
        NSViewWidthSizable |
        NSViewHeightSizable;

    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.clearColor.CGColor;

    _imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _imageView.autoresizingMask = NSViewNotSizable;
    _imageView.imageAlignment = NSImageAlignCenter;
    _imageView.imageScaling = NSImageScaleProportionallyUpOrDown;

    [self addSubview:_imageView];
    [self applyAssetName:_assetName selected:NO];

    return self;
}

- (void)layout {
    [super layout];

    NSImage *image = self.imageView.image;
    NSSize sourceSize = image.size;

    if (!image ||
        sourceSize.width <= 0.0 ||
        sourceSize.height <= 0.0) {
        self.imageView.frame = NSZeroRect;
        return;
    }

    CGFloat targetWidth =
        sourceSize.width * SLStatusIconVisualScale;
    CGFloat targetHeight =
        sourceSize.height * SLStatusIconVisualScale;

    CGFloat maximumWidth = MAX(
        1.0,
        NSWidth(self.bounds) -
            2.0 * SLStatusIconMinimumInset);
    CGFloat maximumHeight = MAX(
        1.0,
        NSHeight(self.bounds) -
            2.0 * SLStatusIconMinimumInset);

    CGFloat fitScale = MIN(
        1.0,
        MIN(
            maximumWidth / targetWidth,
            maximumHeight / targetHeight));

    targetWidth *= fitScale;
    targetHeight *= fitScale;

    CGFloat originX =
        NSMidX(self.bounds) - targetWidth * 0.5;
    CGFloat originY =
        NSMidY(self.bounds) - targetHeight * 0.5;

    self.imageView.frame = NSMakeRect(
        originX,
        originY,
        targetWidth,
        targetHeight);
}

- (BOOL)isOpaque {
    return NO;
}

- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

- (void)applyAssetName:(NSString *)assetName selected:(BOOL)selected {
    if (!assetName.length) {
        assetName = SLStatusIconDefaultAssetForKind(self.iconKind);
    }

    BOOL changed =
        ![self.assetName isEqualToString:assetName] ||
        self.selected != selected ||
        self.imageView.image == nil;

    self.assetName = assetName;
    self.selected = selected;

    if (!changed) return;

    NSImage *image = SLStatusIconImageForState(
        self.iconKind,
        assetName,
        selected);
    if (!image) return;

    self.imageView.image = image;
    self.imageView.contentTintColor =
        selected ? NSColor.whiteColor : nil;
    self.needsLayout = YES;
    [self layoutSubtreeIfNeeded];
    self.imageView.needsDisplay = YES;

    if (SLStatusIconStateLogCount++ < 96) {
        SLLog([NSString stringWithFormat:
            @"embedded status icon state title=%@ asset=%@ "
             "selected=%d size=%@ visualScale=1.0 frame=%@",
            self.window.title ?: @"",
            assetName,
            selected,
            NSStringFromSize(image.size),
            NSStringFromRect(self.imageView.frame)]);
    }
}

@end

static NSView *SLStatusViewForWindow(NSWindow *window) {
    if (!window || !SLStatusViewIvar) return nil;
    return object_getIvar(window, SLStatusViewIvar);
}

static BOOL SLSelectionUnderlayVisible(NSView *contentView) {
    for (NSView *subview in contentView.subviews.copy) {
        if ([NSStringFromClass(subview.class)
                isEqualToString:@"SLSnowLeopardRightSelectionView"] &&
            !subview.hidden &&
            subview.alphaValue > 0.01) {
            return YES;
        }
    }

    return NO;
}

static SLEmbeddedStatusIconOverlayView *
SLEnsureStatusIconOverlayForWindow(NSWindow *window) {
    if (!window || ![window isKindOfClass:SLStatusBarWindowClass]) {
        return nil;
    }

    SLStatusIconKind kind =
        SLStatusIconKindForWindowTitle(window.title);

    if (kind == SLStatusIconKindNone) return nil;

    NSView *contentView = window.contentView;
    NSView *statusView = SLStatusViewForWindow(window);

    if (!contentView || !statusView) return nil;

    id existing = objc_getAssociatedObject(
        contentView,
        &SLStatusIconOverlayKey);

    SLEmbeddedStatusIconOverlayView *overlay =
        [existing isKindOfClass:SLEmbeddedStatusIconOverlayView.class]
        ? existing
        : nil;

    if (!overlay) {
        overlay = [[SLEmbeddedStatusIconOverlayView alloc]
            initWithFrame:contentView.bounds
            iconKind:kind];

        [contentView
            addSubview:overlay
            positioned:NSWindowAbove
            relativeTo:nil];

        objc_setAssociatedObject(
            contentView,
            &SLStatusIconOverlayKey,
            overlay,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if (SLStatusIconAttachLogCount++ < 24) {
            SLLog([NSString stringWithFormat:
                @"embedded status icon attached title=%@ window=%ld "
                 "kind=%ld frame=%@ assets=%zu",
                window.title ?: @"",
                (long)window.windowNumber,
                (long)kind,
                NSStringFromRect(contentView.bounds),
                SLEmbeddedAssetCount]);
        }
    }

    if (!NSEqualRects(overlay.frame, contentView.bounds)) overlay.frame = contentView.bounds;

    if (!statusView.wantsLayer) statusView.wantsLayer = YES;

    CALayer *nativeLayer = statusView.layer;

    if (nativeLayer) {
        if (!objc_getAssociatedObject(
                statusView,
                &SLStatusIconOriginalLayerOpacityKey)) {
            objc_setAssociatedObject(
                statusView,
                &SLStatusIconOriginalLayerOpacityKey,
                @(nativeLayer.opacity),
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        /* Layer opacity hides only the native drawing. The NSView stays
         * visible and keeps its original hit-testing and click handling. */
        if (nativeLayer.opacity != 0.0f) nativeLayer.opacity = 0.0f;
    }

    BOOL selected = SLSelectionUnderlayVisible(contentView);
    NSString *assetName = SLCurrentAssetForKind(kind);
    [overlay applyAssetName:assetName selected:selected];

    return overlay;
}

static void SLRefreshEmbeddedStatusIcons(void) {
    if (!SLStatusBarWindowClass || !SLStatusViewIvar) return;

    NSMutableDictionary *previousBatch = SLStatusAssetBatch;
    SLStatusAssetBatch = [NSMutableDictionary dictionaryWithCapacity:4];
    @try {
    for (NSWindow *window in NSApp.windows.copy) {
        if (![window isKindOfClass:SLStatusBarWindowClass]) continue;

        if (SLStatusIconKindForWindowTitle(window.title) ==
            SLStatusIconKindNone) {
            continue;
        }

        SLEnsureStatusIconOverlayForWindow(window);
    }
    } @finally {
        SLStatusAssetBatch = previousBatch;
    }
}

void SLStatusIconReplacementSetHighlighted(
    NSView *statusItemView,
    BOOL highlighted
) {
    if (!SLStatusIconHasExactControlCenterIdentity()) return;

    NSWindow *window = statusItemView.window;
    if (!window) return;

    SLStatusIconKind kind =
        SLStatusIconKindForWindowTitle(window.title);

    if (kind == SLStatusIconKindNone) return;

    SLEmbeddedStatusIconOverlayView *overlay =
        SLEnsureStatusIconOverlayForWindow(window);

    if (!overlay) return;

    // Ensure above has just refreshed this asset. Selection does not need
    // another hardware query in the same call stack.
    [overlay applyAssetName:overlay.assetName selected:highlighted];
}

static void SLInstallEmbeddedStatusIcons(void) {
    if (!SLStatusIconHasExactControlCenterIdentity() ||
        SLStatusIconTimer) {
        return;
    }

    SLStatusBarWindowClass = NSClassFromString(@"NSStatusBarWindow");
    SLStatusViewIvar = SLStatusBarWindowClass
        ? class_getInstanceVariable(SLStatusBarWindowClass, "_statusView")
        : NULL;

    if (!SLStatusBarWindowClass || !SLStatusViewIvar) {
        SLLog(
            @"embedded status icons aborted: AppKit status ABI unavailable");
        return;
    }

    SLRefreshEmbeddedStatusIcons();

    SLStatusIconTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER,
        0,
        0,
        dispatch_get_main_queue());

    if (!SLStatusIconTimer) {
        SLLog(
            @"embedded status icons aborted: timer unavailable");
        return;
    }

    dispatch_source_set_timer(
        SLStatusIconTimer,
        dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
        500 * NSEC_PER_MSEC,
        50 * NSEC_PER_MSEC);

    dispatch_source_set_event_handler(
        SLStatusIconTimer,
        ^{
            @autoreleasepool { SLRefreshEmbeddedStatusIcons(); }
        });

    dispatch_resume(SLStatusIconTimer);

    SLLog([NSString stringWithFormat:
        @"embedded status icons installed process=%@ bundle=%@ "
         "pid=%d assets=%zu runtimeResources=0 batteryDynamic=1 "
         "visualScale=1.15 compatibility=sequoia15-native-geometry",
        NSProcessInfo.processInfo.processName,
        NSBundle.mainBundle.bundleIdentifier,
        getpid(),
        SLEmbeddedAssetCount]);
}

__attribute__((constructor))
static void SLStartEmbeddedStatusIcons(void) {
    if (!SLRuntimeIsMacOSSequoia()) return;
    if (!SLStatusIconHasExactControlCenterIdentity()) return;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC),
        dispatch_get_main_queue(),
        ^{
            SLInstallEmbeddedStatusIcons();
        });
}
