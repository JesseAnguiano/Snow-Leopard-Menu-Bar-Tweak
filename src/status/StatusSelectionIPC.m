#import "StatusSelectionIPC.h"

#import <unistd.h>

NSString * const SLExternalStatusSelectionNotificationName =
    @"com.snowleopardmenubar.ExternalStatusSelection";

void SLPostExternalStatusSelection(NSView *view, BOOL selected) {
    if (!view) return;
    NSDictionary *userInfo = @{
        @"selected": @(selected),
        @"windowTitle": view.window.title ?: @"",
        @"sourcePID": @(getpid()),
        @"sourceBundle": NSBundle.mainBundle.bundleIdentifier ?: @""
    };
    [NSDistributedNotificationCenter.defaultCenter
        postNotificationName:SLExternalStatusSelectionNotificationName
        object:nil
        userInfo:userInfo
        deliverImmediately:YES];
}
