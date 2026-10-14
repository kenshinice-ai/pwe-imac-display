/* tb_login_item.m — see tb_login_item.h. */

#include "tb_login_item.h"
#include "tb_i18n.h"

#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>

static NSString *const kOfferedKey = @"LaunchAtLoginOffered";

static BOOL tb_login_item_in_bundle(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    return bundle.bundleIdentifier.length > 0 && [bundle.bundlePath hasSuffix:@".app"];
}

/* macOS 11 and 12: a per-user LaunchAgent that opens this executable. */
static NSString *tb_login_item_agent_path(void) {
    NSString *label = [NSBundle mainBundle].bundleIdentifier;
    return [NSHomeDirectory() stringByAppendingFormat:@"/Library/LaunchAgents/%@.plist", label];
}

int tb_login_item_is_enabled(void) {
    if (!tb_login_item_in_bundle()) return 0;
    if (@available(macOS 13.0, *)) {
        return SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? 1 : 0;
    }
    return [[NSFileManager defaultManager] fileExistsAtPath:tb_login_item_agent_path()] ? 1 : 0;
}

int tb_login_item_set_enabled(int enabled) {
    if (!tb_login_item_in_bundle()) return 0;
    if (@available(macOS 13.0, *)) {
        NSError *error = nil;
        BOOL ok = enabled ? [SMAppService.mainAppService registerAndReturnError:&error]
                          : [SMAppService.mainAppService unregisterAndReturnError:&error];
        if (!ok) fprintf(stderr, "[login] %s\n", error.localizedDescription.UTF8String);
        return ok ? 1 : 0;
    }
    NSString *path = tb_login_item_agent_path();
    if (!enabled) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return 1;
    }
    NSString *executable = [NSBundle mainBundle].executablePath;
    NSDictionary *agent = @{
        @"Label": [NSBundle mainBundle].bundleIdentifier,
        @"ProgramArguments": @[ executable ],
        @"RunAtLoad": @YES,
        @"LimitLoadToSessionType": @"Aqua",
        @"ProcessType": @"Interactive",
    };
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [agent writeToFile:path atomically:YES] ? 1 : 0;
}

void tb_login_item_offer_once(void) {
    if (!tb_login_item_in_bundle()) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:kOfferedKey] || tb_login_item_is_enabled()) return;
    [defaults setBool:YES forKey:kOfferedKey];

    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [NSString stringWithUTF8String:tb_i18n_get("receiver.login.title")];
        alert.informativeText = [NSString stringWithUTF8String:tb_i18n_get("receiver.login.body")];
        [alert addButtonWithTitle:[NSString stringWithUTF8String:tb_i18n_get("receiver.login.yes")]];
        [alert addButtonWithTitle:[NSString stringWithUTF8String:tb_i18n_get("receiver.login.no")]];
        [NSApp activateIgnoringOtherApps:YES];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            tb_login_item_set_enabled(1);
        }
    }
}
