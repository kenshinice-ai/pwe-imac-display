/* pboard_tool.m — PWE test hook: read or write a named test pasteboard, as
 * "another app on the iMac" for the receiver smoke's clipboard phase.
 *
 *   pboard_tool <name> get          prints its text
 *   pboard_tool <name> set <text>
 *   pboard_tool <name> release
 *
 * Only names under com.pwegroup.pweimacdisplay.test. are accepted, so it can
 * never touch the system clipboard. */

#import <AppKit/AppKit.h>

#include <stdio.h>
#include <string.h>

static const char kPrefix[] = "com.pwegroup.pweimacdisplay.test.";

int main(int argc, char **argv) {
    if (argc < 3 || strncmp(argv[1], kPrefix, sizeof(kPrefix) - 1) != 0) {
        fprintf(stderr, "usage: pboard_tool %s<name> get | set <text> | release\n", kPrefix);
        return 2;
    }
    @autoreleasepool {
        NSPasteboard *pb = [NSPasteboard pasteboardWithName:@(argv[1])];
        if (!strcmp(argv[2], "get")) {
            NSString *s = [pb stringForType:NSPasteboardTypeString];
            fputs(s ? s.UTF8String : "", stdout);
            return 0;
        }
        if (!strcmp(argv[2], "set") && argc > 3) {
            [pb clearContents];
            return [pb setString:@(argv[3]) forType:NSPasteboardTypeString] ? 0 : 1;
        }
        if (!strcmp(argv[2], "release")) {
            [pb releaseGlobally];
            return 0;
        }
    }
    fprintf(stderr, "pboard_tool: unknown command %s\n", argv[2]);
    return 2;
}
