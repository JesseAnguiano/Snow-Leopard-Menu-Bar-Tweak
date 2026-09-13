#ifndef SNOW_LEOPARD_STATUS_SELECTION_IPC_H
#define SNOW_LEOPARD_STATUS_SELECTION_IPC_H

#import <Cocoa/Cocoa.h>

#ifdef __cplusplus
extern "C" {
#endif

extern NSString * const SLExternalStatusSelectionNotificationName;
void SLPostExternalStatusSelection(NSView *view, BOOL selected);

#ifdef __cplusplus
}
#endif

#endif
