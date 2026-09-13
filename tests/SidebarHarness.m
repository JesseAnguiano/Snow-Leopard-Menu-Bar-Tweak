#import <Cocoa/Cocoa.h>
#import <dlfcn.h>
#import <objc/runtime.h>

@interface SidebarHarnessData : NSObject
    <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation SidebarHarnessData

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return 3;
}

- (NSView *)tableView:(NSTableView *)tableView
    viewForTableColumn:(NSTableColumn *)tableColumn
                   row:(NSInteger)row {
    (void)tableView;
    (void)tableColumn;
    NSTableCellView *cell = [[NSTableCellView alloc]
        initWithFrame:NSMakeRect(0.0, 0.0, 240.0, 28.0)];
    NSTextField *label = [NSTextField labelWithString:
        [NSString stringWithFormat:@"Sidebar %ld", (long)row]];
    label.frame = NSMakeRect(28.0, 5.0, 180.0, 18.0);
    cell.textField = label;
    [cell addSubview:label];
    return cell;
}

@end

static NSView *FindBlueFilm(NSView *view) {
    if ([NSStringFromClass(view.class)
            isEqualToString:@"SLBlueSelectionFilmView"]) {
        return view;
    }
    for (NSView *subview in view.subviews) {
        NSView *found = FindBlueFilm(subview);
        if (found) return found;
    }
    return nil;
}

static int FinishHarness(NSString *message, int status) {
    NSString *result = [NSString stringWithFormat:
        @"status=%d %@\n", status, message ?: @"unknown"];
    [result writeToFile:
        @"/private/tmp/BlueSelection-sidebar-harness-result.txt"
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
    return status;
}

int main(void) {
    @autoreleasepool {
        void *swiftUI = dlopen(
            "/System/Library/Frameworks/SwiftUI.framework/SwiftUI",
            RTLD_NOW | RTLD_GLOBAL);
        if (!swiftUI) {
            return FinishHarness(
                [NSString stringWithFormat:@"SwiftUI=%s", dlerror()], 2);
        }
        NSString *dylibPath = [NSBundle.mainBundle
            pathForResource:@"libSnowLeopardBlueSelection"
                     ofType:@"dylib"];
        void *tweak = dlopen(dylibPath.fileSystemRepresentation,
                             RTLD_NOW | RTLD_LOCAL);
        if (!tweak) {
            return FinishHarness(
                [NSString stringWithFormat:@"dlopen=%s", dlerror()], 3);
        }
        [[NSRunLoop mainRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.55]];

        NSTableView *table = [[NSTableView alloc]
            initWithFrame:NSMakeRect(0.0, 0.0, 240.0, 200.0)];
        table.style = NSTableViewStyleSourceList;
        NSTableRowView *row = [[NSTableRowView alloc]
            initWithFrame:NSMakeRect(0.0, 28.0, 240.0, 28.0)];
        NSTextField *label = [[NSTextField alloc]
            initWithFrame:NSMakeRect(28.0, 5.0, 180.0, 18.0)];
        label.stringValue = @"Sidebar 1";
        label.editable = NO;
        label.selectable = NO;
        label.bezeled = NO;
        label.drawsBackground = NO;
        label.textColor = NSColor.blackColor;
        [row addSubview:label];
        NSVisualEffectView *nativeEffect = [[NSVisualEffectView alloc]
            initWithFrame:row.bounds];
        nativeEffect.autoresizingMask =
            NSViewWidthSizable | NSViewHeightSizable;
        [row addSubview:nativeEffect
             positioned:NSWindowBelow
             relativeTo:label];
        [table addSubview:row];
        table.frame = NSMakeRect(0.0, 0.0, 240.0, 200.0);
        table.bounds = NSMakeRect(0.0, 0.0, 240.0, 200.0);
        row.selected = YES;
        [[NSRunLoop mainRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.20]];

        NSView *film = FindBlueFilm(table);
        BOOL nativeEffectPreserved = nativeEffect.superview == row &&
            !nativeEffect.hidden &&
            NSEqualRects(nativeEffect.frame, row.bounds);
        BOOL textIsWhite = label &&
            [label.textColor isEqual:NSColor.whiteColor];

        row.selected = NO;
        [[NSRunLoop mainRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        BOOL deselectionRestored = FindBlueFilm(table) == nil &&
            [label.textColor isEqual:NSColor.blackColor];

        NSTableView *plainTable = [[NSTableView alloc]
            initWithFrame:NSMakeRect(0.0, 0.0, 180.0, 100.0)];
        plainTable.style = NSTableViewStylePlain;
        NSTableRowView *plainRow = [[NSTableRowView alloc]
            initWithFrame:NSMakeRect(0.0, 0.0, 180.0, 24.0)];
        [plainTable addSubview:plainRow];
        plainTable.frame = NSMakeRect(0.0, 0.0, 180.0, 100.0);
        plainTable.bounds = NSMakeRect(0.0, 0.0, 180.0, 100.0);
        plainRow.selected = YES;
        BOOL plainTableUnaffected = FindBlueFilm(plainTable) == nil;
        Class swiftUIRow = NSClassFromString(@"SwiftUI.ListTableRowView");
        Method swiftUIAlias = class_getInstanceMethod(
            swiftUIRow,
            NSSelectorFromString(
                @"_slBlueSelectionOriginalSetSelected:"));
        BOOL swiftUISubclassHooked = swiftUIRow && swiftUIAlias;
        NSString *message = [NSString stringWithFormat:
                @"SIDEBAR_HARNESS_OK selected=%d replacementFilm=%d "
                 "nativeEffectPreserved=%d textWhite=%d "
                 "deselectionRestored=%d plainTableUnaffected=%d "
                 "swiftUISubclassHooked=%d",
                YES,
                film != nil,
                nativeEffectPreserved,
                textIsWhite,
                deselectionRestored,
                plainTableUnaffected,
                swiftUISubclassHooked];
        if (film || !nativeEffectPreserved || !textIsWhite ||
            !deselectionRestored || !plainTableUnaffected ||
            !swiftUISubclassHooked) {
            return FinishHarness(message, 4);
        }
        return FinishHarness(message, 0);
    }
}
