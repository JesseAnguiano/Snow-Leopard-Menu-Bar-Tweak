#import "Runtime.h"

#import <mach-o/dyld.h>
#import <limits.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <strings.h>


NSString * const SLBundleIDControlCenter = @"com.apple.controlcenter";
NSString * const SLBundleIDSystemUIServer = @"com.apple.systemuiserver";
NSString * const SLBundleIDSpotlight = @"com.apple.Spotlight";

static const char * const SLControlCenterExecutable =
    "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter";
static const char * const SLSystemUIServerExecutable =
    "/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer";
static const char * const SLSpotlightExecutable =
    "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight";

BOOL SLRuntimeIsMacOSSequoia(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15;
}

Method SLOwnInstanceMethod(Class cls, SEL selector) {
    if (!cls || !selector) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method result = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            result = methods[index];
            break;
        }
    }
    free(methods);
    return result;
}

Ivar SLOwnInstanceVariable(Class cls, const char *name) {
    if (!cls || !name) return NULL;
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    Ivar result = NULL;
    for (unsigned int index = 0; index < count; index++) {
        const char *candidate = ivar_getName(ivars[index]);
        if (candidate && strcmp(candidate, name) == 0) {
            result = ivars[index];
            break;
        }
    }
    free(ivars);
    return result;
}

id SLObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
        if (type && type[0] == '@') return object_getIvar(object, ivar);
    }
    return nil;
}

BOOL SLMethodMatches(Method method, const char *encoding) {
    const char *actual = method ? method_getTypeEncoding(method) : NULL;
    return actual && encoding && strcmp(actual, encoding) == 0;
}

IMP SLResolvedImplementation(Class cls, SEL selector) {
    Method method = cls && selector ? class_getInstanceMethod(cls, selector) : NULL;
    return method ? method_getImplementation(method) : NULL;
}

Method SLMaterializeOwnMethod(Class cls, SEL selector, const char *encoding) {
    if (!cls || !selector) return NULL;
    Method own = SLOwnInstanceMethod(cls, selector);
    if (own) return (!encoding || SLMethodMatches(own, encoding)) ? own : NULL;

    Method inherited = class_getInstanceMethod(cls, selector);
    if (!inherited || (encoding && !SLMethodMatches(inherited, encoding))) return NULL;
    class_addMethod(cls, selector, method_getImplementation(inherited),
                    method_getTypeEncoding(inherited));
    own = SLOwnInstanceMethod(cls, selector);
    return own && (!encoding || SLMethodMatches(own, encoding)) ? own : NULL;
}

BOOL SLInstallOverrideHook(Class cls, SEL selector, const char *encoding,
                           IMP replacement, IMP *original) {
    if (!cls || !selector || !replacement) return NO;
    Method resolved = class_getInstanceMethod(cls, selector);
    if (!resolved || (encoding && !SLMethodMatches(resolved, encoding))) return NO;
    if (original) *original = method_getImplementation(resolved);

    Method own = SLOwnInstanceMethod(cls, selector);
    if (own) {
        method_setImplementation(own, replacement);
        return YES;
    }
    if (class_addMethod(cls, selector, replacement, method_getTypeEncoding(resolved))) {
        return YES;
    }
    own = SLOwnInstanceMethod(cls, selector);
    if (!own || (encoding && !SLMethodMatches(own, encoding))) return NO;
    method_setImplementation(own, replacement);
    return YES;
}

void SLRestoreOwnHook(Class cls, SEL selector, IMP replacement, IMP original) {
    Method method = SLOwnInstanceMethod(cls, selector);
    if (method && method_getImplementation(method) == replacement && original) {
        method_setImplementation(method, original);
    }
}

static BOOL SLHasExactProcessIdentity(const char *processName,
                               const char *executablePath,
                               NSString *bundleIdentifier) {
    const char *actualName = getprogname();
    if (!actualName || !processName || !executablePath || !bundleIdentifier.length ||
        strcmp(actualName, processName) != 0 ||
        ![NSBundle.mainBundle.bundleIdentifier isEqualToString:bundleIdentifier]) {
        return NO;
    }
    char actualPath[PATH_MAX];
    uint32_t pathSize = sizeof(actualPath);
    return _NSGetExecutablePath(actualPath, &pathSize) == 0 &&
           strcmp(actualPath, executablePath) == 0;
}

BOOL SLIsExactControlCenterProcess(void) {
    return SLHasExactProcessIdentity("ControlCenter", SLControlCenterExecutable, SLBundleIDControlCenter);
}

BOOL SLIsExactSystemUIServerProcess(void) {
    return SLHasExactProcessIdentity("SystemUIServer", SLSystemUIServerExecutable, SLBundleIDSystemUIServer);
}

BOOL SLIsExactSpotlightProcess(void) {
    return SLHasExactProcessIdentity("Spotlight", SLSpotlightExecutable, SLBundleIDSpotlight);
}

BOOL SLIsEligibleApplicationProcess(BOOL allowUIElement) {
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *processName = NSProcessInfo.processInfo.processName;
    NSString *bundleIdentifier = bundle.bundleIdentifier;
    if ([processName isEqualToString:@"ControlCenter"] ||
        [processName isEqualToString:@"SystemUIServer"] ||
        [bundleIdentifier isEqualToString:@"com.apple.controlcenter"] ||
        [bundleIdentifier isEqualToString:@"com.apple.systemuiserver"]) return NO;

    NSString *bundlePath = bundle.bundlePath;
    NSString *executablePath = bundle.executablePath;
    if (!bundlePath.length || ![bundlePath.pathExtension isEqualToString:@"app"] ||
        !executablePath.length || [executablePath containsString:@"/XPCServices/"] ||
        [executablePath containsString:@"/PlugIns/"] ||
        [executablePath containsString:@"/Contents/Frameworks/"] ||
        [executablePath containsString:@"/Helpers/"]) return NO;

    NSDictionary *info = bundle.infoDictionary;
    return ![info[@"LSBackgroundOnly"] boolValue] &&
           (allowUIElement || ![info[@"LSUIElement"] boolValue]);
}

BOOL SLIsEligibleRegularApplicationProcess(void) {
    return SLIsEligibleApplicationProcess(NO);
}

static BOOL SLIsDockProcess(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    return [NSProcessInfo.processInfo.processName isEqualToString:@"Dock"] ||
        [bundle.bundleIdentifier isEqualToString:@"com.apple.dock"] ||
        [bundle.bundleIdentifier isEqualToString:@"com.apple.dock.helper"] ||
        [bundle.executablePath containsString:@"/DockHelper.xpc/Contents/MacOS/DockHelper"];
}

BOOL SLIsDockOrRegularApplicationProcess(void) {
    return SLIsDockProcess() || SLIsEligibleRegularApplicationProcess();
}

BOOL SLIsTopMenuBarWindow(NSWindow *window) {
    return window && [NSStringFromClass(window.class)
        isEqualToString:@"NSMenuBarReplicantWindow"];
}

BOOL SLDebugLoggingEnabled(void) {
    static BOOL enabled = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *value = getenv("SNOW_LEOPARD_MENU_BAR_DEBUG");
        enabled = value && (strcmp(value, "1") == 0 ||
            strcasecmp(value, "true") == 0 || strcasecmp(value, "yes") == 0);
    });
    return enabled;
}

void SLAppendLog(NSString *line) {
    if (!line) return;
    FILE *file = fopen("/private/tmp/SnowLeopardMenuBar.log", "a");
    if (!file) {
        NSString *path = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"SnowLeopardMenuBar.log"];
        file = fopen(path.fileSystemRepresentation, "a");
    }
    if (!file) return;
    fprintf(file, "%s\n", line.UTF8String);
    fclose(file);
}
