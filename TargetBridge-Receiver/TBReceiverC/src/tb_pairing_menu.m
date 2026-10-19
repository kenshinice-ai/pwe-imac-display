/* tb_pairing_menu.m — see tb_pairing_menu.h. */

#import <AppKit/AppKit.h>

#include "tb_pairing_menu.h"

@interface TBPairingMenuTarget : NSObject
@property (nonatomic) tb_pairing_menu_cb onToggle;
@property (nonatomic) tb_pairing_menu_cb onForget;
@property (nonatomic) void *context;
@end

@implementation TBPairingMenuTarget
- (void)toggleUnencrypted:(id)sender {
    (void)sender;
    if (self.onToggle) self.onToggle(self.context);
}
- (void)forgetAll:(id)sender {
    (void)sender;
    if (self.onForget) self.onForget(self.context);
}
@end

static TBPairingMenuTarget *g_target;
static NSMenuItem *g_allow_item;
static NSMenuItem *g_forget_item;

void tb_pairing_menu_install(tb_pairing_menu_cb on_toggle_unencrypted,
                             tb_pairing_menu_cb on_forget_all,
                             void *ctx) {
    @autoreleasepool {
        NSMenu *app_menu = [[[NSApp mainMenu] itemAtIndex:0] submenu];
        if (!app_menu || g_target) return;
        g_target = [TBPairingMenuTarget new];
        g_target.onToggle = on_toggle_unencrypted;
        g_target.onForget = on_forget_all;
        g_target.context = ctx;

        /* After "About" and its separator, before the rest. */
        NSInteger at = app_menu.numberOfItems > 1 ? 1 : app_menu.numberOfItems;
        g_allow_item = [[NSMenuItem alloc] initWithTitle:@"Allow Unencrypted Connections"
                                                  action:@selector(toggleUnencrypted:)
                                           keyEquivalent:@""];
        g_allow_item.target = g_target;
        g_forget_item = [[NSMenuItem alloc] initWithTitle:@"Forget All Paired Macs…"
                                                   action:@selector(forgetAll:)
                                            keyEquivalent:@""];
        g_forget_item.target = g_target;
        [app_menu insertItem:[NSMenuItem separatorItem] atIndex:at];
        [app_menu insertItem:g_allow_item atIndex:at + 1];
        [app_menu insertItem:g_forget_item atIndex:at + 2];
    }
}

void tb_pairing_menu_update(const char *allow_title, int allow_on, const char *forget_title) {
    @autoreleasepool {
        if (!g_allow_item) return;
        if (allow_title) g_allow_item.title = [NSString stringWithUTF8String:allow_title] ?: g_allow_item.title;
        g_allow_item.state = allow_on ? NSControlStateValueOn : NSControlStateValueOff;
        if (forget_title) g_forget_item.title = [NSString stringWithUTF8String:forget_title] ?: g_forget_item.title;
    }
}

int tb_pairing_menu_confirm(const char *message, const char *confirm, const char *cancel) {
    @autoreleasepool {
        NSAlert *alert = [NSAlert new];
        alert.messageText = [NSString stringWithUTF8String:message ? message : ""] ?: @"";
        [alert addButtonWithTitle:[NSString stringWithUTF8String:confirm ? confirm : "OK"] ?: @"OK"];
        [alert addButtonWithTitle:[NSString stringWithUTF8String:cancel ? cancel : "Cancel"] ?: @"Cancel"];
        alert.alertStyle = NSAlertStyleWarning;
        [NSApp activateIgnoringOtherApps:YES];
        return [alert runModal] == NSAlertFirstButtonReturn ? 1 : 0;
    }
}
