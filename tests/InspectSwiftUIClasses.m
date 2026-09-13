#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

static BOOL OwnsSelector(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL owns = NO;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            owns = YES;
            break;
        }
    }
    free(methods);
    return owns;
}

int main(void) {
    @autoreleasepool {
        void *swiftUI = dlopen(
            "/System/Library/Frameworks/SwiftUI.framework/SwiftUI",
            RTLD_NOW | RTLD_GLOBAL);
        if (!swiftUI) return 2;
        int count = objc_getClassList(NULL, 0);
        Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
        count = objc_getClassList(classes, count);
        for (int index = 0; index < count; index++) {
            NSString *name = NSStringFromClass(classes[index]);
            NSString *lower = name.lowercaseString;
            if ([lower containsString:@"list"] ||
                [lower containsString:@"table"] ||
                [lower containsString:@"outline"] ||
                [lower containsString:@"sidebar"] ||
                [lower containsString:@"rowview"]) {
                if ([name hasPrefix:@"SwiftUI."] &&
                    ([lower containsString:@"rowview"] ||
                     [lower containsString:@"tableview"] ||
                     [lower containsString:@"outlineview"])) {
                    Class cls = classes[index];
                    printf("%s super=%s drawOwn=%d selectedOwn=%d "
                           "emphasizedOwn=%d\n",
                           name.UTF8String,
                           class_getName(class_getSuperclass(cls)),
                           OwnsSelector(cls, @selector(drawSelectionInRect:)),
                           OwnsSelector(cls, @selector(setSelected:)),
                           OwnsSelector(cls, @selector(setEmphasized:)));
                }
            }
        }
        free(classes);
    }
    return 0;
}
