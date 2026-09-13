#ifndef SNOW_LEOPARD_RUNTIME_H
#define SNOW_LEOPARD_RUNTIME_H

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__GNUC__)
#define SL_INTERNAL __attribute__((visibility("hidden")))
#else
#define SL_INTERNAL
#endif

SL_INTERNAL BOOL SLRuntimeIsMacOSSequoia(void);
SL_INTERNAL Method SLOwnInstanceMethod(Class cls, SEL selector);
SL_INTERNAL Ivar SLOwnInstanceVariable(Class cls, const char *name);
SL_INTERNAL id SLObjectIvar(id object, const char *name);
SL_INTERNAL BOOL SLMethodMatches(Method method, const char *encoding);
SL_INTERNAL IMP SLResolvedImplementation(Class cls, SEL selector);
SL_INTERNAL Method SLMaterializeOwnMethod(Class cls, SEL selector,
                                          const char *encoding);
SL_INTERNAL BOOL SLInstallOverrideHook(Class cls, SEL selector, const char *encoding,
                                       IMP replacement, IMP *original);
SL_INTERNAL void SLRestoreOwnHook(Class cls, SEL selector, IMP replacement,
                                  IMP original);
SL_INTERNAL extern NSString * const SLBundleIDControlCenter;
SL_INTERNAL extern NSString * const SLBundleIDSystemUIServer;
SL_INTERNAL extern NSString * const SLBundleIDSpotlight;
SL_INTERNAL BOOL SLIsExactControlCenterProcess(void);
SL_INTERNAL BOOL SLIsExactSystemUIServerProcess(void);
SL_INTERNAL BOOL SLIsExactSpotlightProcess(void);
SL_INTERNAL BOOL SLIsEligibleApplicationProcess(BOOL allowUIElement);
SL_INTERNAL BOOL SLIsEligibleRegularApplicationProcess(void);
SL_INTERNAL BOOL SLIsDockOrRegularApplicationProcess(void);
SL_INTERNAL BOOL SLIsTopMenuBarWindow(NSWindow *window);
SL_INTERNAL BOOL SLDebugLoggingEnabled(void);
SL_INTERNAL void SLAppendLog(NSString *line);

#define SLLog(...) \
    do { \
        if (SLDebugLoggingEnabled()) SLAppendLog((__VA_ARGS__)); \
    } while (0)

#undef SL_INTERNAL

#ifdef __cplusplus
}
#endif

#endif
