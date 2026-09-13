#ifndef SNOW_LEOPARD_SELECTION_RENDERER_H
#define SNOW_LEOPARD_SELECTION_RENDERER_H

#import <Cocoa/Cocoa.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__GNUC__)
#define SL_INTERNAL __attribute__((visibility("hidden")))
#else
#define SL_INTERNAL
#endif

SL_INTERNAL CGColorRef SLCreateSRGBColor(CGFloat red, CGFloat green, CGFloat blue,
                                         CGFloat alpha) CF_RETURNS_RETAINED;
SL_INTERNAL CGGradientRef SLSnowLeopardSelectionGradient(void);
SL_INTERNAL void SLDrawSharedSnowLeopardSelection(NSView *view);

#undef SL_INTERNAL

#ifdef __cplusplus
}
#endif

#endif
