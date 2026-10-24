/* tb_brightness.c — brightness on the receiver's own display. See tb_brightness.h. */

#include "tb_brightness.h"

#include <dlfcn.h>
#include <stdio.h>

typedef int (*tb_set_brightness_fn)(CGDirectDisplayID display, float brightness);

/* Looked up once; NULL when unavailable. Main thread. */
static tb_set_brightness_fn tb_brightness_symbol(const char **why) {
    static int looked;
    static tb_set_brightness_fn fn;
    static const char *reason = "";
    if (!looked) {
        looked = 1;
        void *lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices",
                           RTLD_LAZY);
        if (!lib) {
            reason = "the DisplayServices framework did not load";
        } else {
            fn = (tb_set_brightness_fn)dlsym(lib, "DisplayServicesSetBrightness");
            if (!fn) reason = "DisplayServicesSetBrightness is missing";
            /* The library stays loaded: fn points into it. */
        }
    }
    *why = reason;
    return fn;
}

int tb_brightness_set(CGDirectDisplayID display, double level) {
    static int failure_logged;
    if (level < 0.0) level = 0.0;
    if (level > 1.0) level = 1.0;
    const char *why = "";
    tb_set_brightness_fn fn = tb_brightness_symbol(&why);
    int err = 0;
    if (fn) {
        err = fn(display, (float)level);
        if (err == 0) return 0;
    }
    if (!failure_logged) {
        failure_logged = 1;
        if (fn) {
            fprintf(stderr, "[disp] brightness could not be set on display %u (error %d); "
                            "the Mac's brightness control does nothing here\n", (unsigned)display, err);
        } else {
            fprintf(stderr, "[disp] brightness unavailable: %s; the Mac's brightness control does nothing here\n", why);
        }
    }
    return -1;
}

static double overlap_area(CGRect a, CGRect b) {
    const CGRect i = CGRectIntersection(a, b);
    return CGRectIsNull(i) ? 0.0 : (double)i.size.width * (double)i.size.height;
}

CGDirectDisplayID tb_brightness_pick_display(CGRect window, const CGDirectDisplayID *ids, const CGRect *bounds,
                                             uint32_t count, CGDirectDisplayID fallback) {
    if (!ids || !bounds || count == 0) return fallback;
    const CGPoint centre = CGPointMake(CGRectGetMidX(window), CGRectGetMidY(window));
    for (uint32_t i = 0; i < count; i++) {
        if (CGRectContainsPoint(bounds[i], centre)) return ids[i];
    }
    CGDirectDisplayID best = fallback;
    double best_area = 0.0;
    for (uint32_t i = 0; i < count; i++) {
        const double area = overlap_area(window, bounds[i]);
        if (area > best_area) {
            best_area = area;
            best = ids[i];
        }
    }
    return best;
}

uint32_t tb_brightness_mirror_set(CGDirectDisplayID target, CGDirectDisplayID target_primary,
                                  const CGDirectDisplayID *ids, const CGDirectDisplayID *primaries,
                                  uint32_t count, CGDirectDisplayID *out, uint32_t max) {
    if (!out || max == 0) return 0;
    uint32_t n = 0;
    out[n++] = target;
    if (!ids || !primaries) return n;
    for (uint32_t i = 0; i < count && n < max; i++) {
        if (ids[i] == target) continue;
        if (primaries[i] == target_primary) out[n++] = ids[i];
    }
    return n;
}
