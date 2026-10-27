/* tb_login_item.m — see tb_login_item.h. */

#include "tb_login_item.h"
#include "tb_i18n.h"

#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>

static NSString *const kOfferedKey = @"LaunchAtLoginOffered";
static NSString *const kOpenTool = @"/usr/bin/open";

static BOOL tb_login_item_in_bundle(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    return bundle.bundleIdentifier.length > 0 && [bundle.bundlePath hasSuffix:@".app"];
}

/* A copy that will not be there at the next login: run from App Translocation's
 * randomised read-only mount, from a disk image, or from an ejectable volume.
 * Registering it would point login at nothing. */
static BOOL tb_login_item_location_is_transient(void) {
    NSString *path = [NSBundle mainBundle].bundlePath;
    if ([path rangeOfString:@"/AppTranslocation/"].location != NSNotFound) return YES;

    NSURL *url = [NSURL fileURLWithPath:path];
    NSNumber *read_only = nil;
    if ([url getResourceValue:&read_only forKey:NSURLVolumeIsReadOnlyKey error:nil] && read_only.boolValue) {
        return YES;
    }
    if ([path hasPrefix:@"/Volumes/"]) {
        NSNumber *ejectable = nil;
        NSNumber *removable = nil;
        [url getResourceValue:&ejectable forKey:NSURLVolumeIsEjectableKey error:nil];
        [url getResourceValue:&removable forKey:NSURLVolumeIsRemovableKey error:nil];
        if (ejectable.boolValue || removable.boolValue) return YES;
    }
    return NO;
}

/* macOS 11 and 12: a per-user LaunchAgent that opens this app. Also read on 13+
 * to find one left behind by an OS upgrade. */
static NSString *tb_login_item_agent_path(void) {
    NSString *label = [NSBundle mainBundle].bundleIdentifier;
    return [NSHomeDirectory() stringByAppendingFormat:@"/Library/LaunchAgents/%@.plist", label];
}

static BOOL tb_login_item_agent_exists(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:tb_login_item_agent_path()];
}

static void tb_login_item_remove_agent(void) {
    [[NSFileManager defaultManager] removeItemAtPath:tb_login_item_agent_path() error:nil];
}

/* `open -b` lets Launch Services find the app wherever it now lives, as the
 * upstream install_tbreceiverc_launch_agent.sh does with `open -a`. */
static BOOL tb_login_item_write_agent(void) {
    NSString *path = tb_login_item_agent_path();
    NSString *bundle_id = [NSBundle mainBundle].bundleIdentifier;
    NSDictionary *agent = @{
        @"Label": bundle_id,
        @"ProgramArguments": @[ kOpenTool, @"-b", bundle_id ],
        @"RunAtLoad": @YES,
        @"LimitLoadToSessionType": @"Aqua",
    };
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [agent writeToFile:path atomically:YES];
}

int tb_login_item_available(void) {
    @autoreleasepool {
        return tb_login_item_in_bundle() && !tb_login_item_location_is_transient() ? 1 : 0;
    }
}

int tb_login_item_is_enabled(void) {
    @autoreleasepool {
        if (!tb_login_item_in_bundle()) return 0;
        /* On 13+ an agent left from 11/12 still opens the app at login. */
        if (tb_login_item_agent_exists()) return 1;
        if (@available(macOS 13.0, *)) {
            return SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? 1 : 0;
        }
        return 0;
    }
}

int tb_login_item_set_enabled(int enabled) {
    @autoreleasepool {
        if (!tb_login_item_in_bundle()) return 0;
        if (enabled && tb_login_item_location_is_transient()) {
            fprintf(stderr, "[login] not registering a copy that runs from a disk image or translocated path\n");
            return 0;
        }
        if (@available(macOS 13.0, *)) {
            /* Never leave both an agent and SMAppService: that opens two receivers. */
            tb_login_item_remove_agent();
            SMAppService *service = SMAppService.mainAppService;
            if (!enabled && service.status == SMAppServiceStatusNotRegistered) return 1;
            NSError *error = nil;
            BOOL ok = enabled ? [service registerAndReturnError:&error]
                              : [service unregisterAndReturnError:&error];
            if (!ok) fprintf(stderr, "[login] %s\n", error.localizedDescription.UTF8String);
            return ok ? 1 : 0;
        }
        if (!enabled) {
            tb_login_item_remove_agent();
            return 1;
        }
        return tb_login_item_write_agent() ? 1 : 0;
    }
}

void tb_login_item_migrate(void) {
    @autoreleasepool {
        if (!tb_login_item_in_bundle() || !tb_login_item_agent_exists()) return;
        if (@available(macOS 13.0, *)) {
            /* Upgraded from 11/12 with the agent on: move it to SMAppService. */
            tb_login_item_remove_agent();
            if (tb_login_item_location_is_transient()) return;
            NSError *error = nil;
            if ([SMAppService.mainAppService registerAndReturnError:&error]) {
                fprintf(stderr, "[login] moved the login agent to SMAppService\n");
            } else {
                fprintf(stderr, "[login] %s\n", error.localizedDescription.UTF8String);
            }
            return;
        }
        /* 1.1 wrote the executable path, which breaks when the app moves. */
        NSDictionary *agent = [NSDictionary dictionaryWithContentsOfFile:tb_login_item_agent_path()];
        NSArray *arguments = agent[@"ProgramArguments"];
        BOOL current = [arguments isKindOfClass:[NSArray class]] && arguments.count > 0 &&
                       [arguments[0] isEqual:kOpenTool];
        if (!current && !tb_login_item_location_is_transient() && tb_login_item_write_agent()) {
            fprintf(stderr, "[login] rewrote the login agent to open the app by bundle id\n");
        }
    }
}

void tb_login_item_offer_once(void) {
    @autoreleasepool {
        if (!tb_login_item_available()) return;   /* not marked: ask again from Applications */
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if ([defaults boolForKey:kOfferedKey] || tb_login_item_is_enabled()) return;
        [defaults setBool:YES forKey:kOfferedKey];

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
