#import "SelectionRenderer.h"

static const CGFloat SLSelectionLocations[35] = {
    0.000000000, 0.029411765, 0.058823529, 0.088235294, 0.117647059,
    0.147058824, 0.176470588, 0.205882353, 0.235294118, 0.264705882,
    0.294117647, 0.323529412, 0.352941176, 0.382352941, 0.411764706,
    0.441176471, 0.470588235, 0.500000000, 0.529411765, 0.558823529,
    0.588235294, 0.617647059, 0.647058824, 0.676470588, 0.705882353,
    0.735294118, 0.764705882, 0.794117647, 0.823529412, 0.852941176,
    0.882352941, 0.911764706, 0.941176471, 0.970588235, 1.000000000
};

static const uint8_t SLSelectionRGB[35][3] = {
    {86,119,247}, {86,119,247}, {82,116,247}, {77,113,246}, {77,113,246},
    {73,109,246}, {73,109,246}, {70,106,246}, {70,106,246}, {65,103,246},
    {62, 99,246}, {62, 99,246}, {57, 96,246}, {57, 96,246}, {52, 93,246},
    {52, 93,246}, {48, 91,245}, {42, 87,245}, {42, 87,245}, {38, 84,245},
    {38, 84,245}, {34, 81,245}, {34, 81,245}, {30, 78,244}, {28, 76,244},
    {28, 76,244}, {24, 73,244}, {24, 73,244}, {21, 71,244}, {21, 71,244},
    {18, 70,244}, {20, 70,243}, {20, 70,243}, {17, 69,242}, {17, 69,242}
};

static CGGradientRef SLSelectionGradient = NULL;
static CGColorRef SLSelectionTopRule = NULL;
static CGColorRef SLSelectionBottomRule = NULL;

CGColorRef SLCreateSRGBColor(CGFloat red, CGFloat green, CGFloat blue,
                             CGFloat alpha) {
    return CGColorCreateSRGB(red, green, blue, alpha);
}

static void SLPrepareSelectionPalette(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGFloat components[35 * 4];
        for (NSUInteger index = 0; index < 35; index++) {
            NSUInteger base = index * 4;
            components[base + 0] = SLSelectionRGB[index][0] / 255.0;
            components[base + 1] = SLSelectionRGB[index][1] / 255.0;
            components[base + 2] = SLSelectionRGB[index][2] / 255.0;
            components[base + 3] = 1.0;
        }
        SLSelectionGradient = CGGradientCreateWithColorComponents(
            space, components, SLSelectionLocations, 35);
        CGColorSpaceRelease(space);
        SLSelectionTopRule = SLCreateSRGBColor(
            105.0/255.0, 134.0/255.0, 247.0/255.0, 1.0);
        SLSelectionBottomRule = SLCreateSRGBColor(
            5.0/255.0, 47.0/255.0, 209.0/255.0, 1.0);
    });
}

CGGradientRef SLSnowLeopardSelectionGradient(void) {
    SLPrepareSelectionPalette();
    return SLSelectionGradient;
}

static void SLDrawSnowLeopardSelection(NSView *view, NSRect bounds, CGFloat rule) {
    if (!view || NSIsEmptyRect(bounds) || rule <= 0.0) return;
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    if (!context) return;
    NSRect gradientBounds = NSInsetRect(bounds, 0.0, rule);
    if (NSIsEmptyRect(gradientBounds)) return;

    SLPrepareSelectionPalette();
    [NSGraphicsContext saveGraphicsState];
    [NSBezierPath clipRect:bounds];
    CGFloat middleX = NSMidX(gradientBounds);
    CGPoint start = CGPointMake(middleX,
        view.isFlipped ? NSMinY(gradientBounds) : NSMaxY(gradientBounds));
    CGPoint end = CGPointMake(middleX,
        view.isFlipped ? NSMaxY(gradientBounds) : NSMinY(gradientBounds));
    CGContextDrawLinearGradient(context, SLSelectionGradient, start, end, 0);

    CGFloat topY = view.isFlipped ? NSMinY(bounds) : NSMaxY(bounds) - rule;
    CGFloat bottomY = view.isFlipped ? NSMaxY(bounds) - rule : NSMinY(bounds);
    CGContextSetFillColorWithColor(context, SLSelectionTopRule);
    CGContextFillRect(context, CGRectMake(NSMinX(bounds), topY, NSWidth(bounds), rule));
    CGContextSetFillColorWithColor(context, SLSelectionBottomRule);
    CGContextFillRect(context, CGRectMake(NSMinX(bounds), bottomY, NSWidth(bounds), rule));
    [NSGraphicsContext restoreGraphicsState];
}

void SLDrawSharedSnowLeopardSelection(NSView *view) {
    if (!view) return;
    CGFloat scale = view.window.backingScaleFactor;
    if (scale <= 0.0) scale = NSScreen.mainScreen.backingScaleFactor;
    if (scale <= 0.0) scale = 2.0;
    SLDrawSnowLeopardSelection(view, view.bounds, 1.0 / scale);
}
