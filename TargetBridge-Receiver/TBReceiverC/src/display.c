/* display.c — SDL2 window, status screens and the video renderer.
 *
 * Two ways to put video on screen:
 *   - SDL's renderer (OpenGL): SDL_UpdateNVTexture copies the planes into an
 *     NV12 texture and the frame is presented on arrival. The default, and
 *     the fallback when anything on the Metal path fails.
 *   - Metal zero-copy (PWE 1.1, tb_metal_video.m): VideoToolbox's IOSurface
 *     becomes a texture with no copy, and frames are paced to the display
 *     refresh, newest frame first. Less CPU (iMac18,3: 25-40 % less).
 * The person chooses on the Mac (PWE Settings › Advanced); the sender's hello
 * carries it as "receiverRenderer" and tb_disp_use_renderer applies it when
 * the session starts. Upstream senders say nothing: OpenGL.
 * A local setting wins over the sender, for testing:
 * TB_RECEIVER_RENDER_DRIVER = metal | opengl | metal-sdl (SDL's own Metal
 * renderer with the copying upload, for comparison) | any SDL driver name.
 * TB_RECEIVER_PACING = vsync | immediate applies to the Metal path.
 * Without the environment variable, the app's defaults keys
 * TBReceiverRenderDriver and TBReceiverPacing are read (tb_disp_setting).
 */

#include "display.h"

#include <ImageIO/ImageIO.h>

#ifndef TB_RECEIVER_COMPACT_IDLE
#define TB_RECEIVER_COMPACT_IDLE 0
#endif
#include "tb_i18n.h"
#include "tb_gesture_bridge.h"
#include "tb_loopwatch.h"
#include "tb_trace.h"
#include "tb_metal_video.h"
#include "tb_vsync.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <SDL.h>
#include <dlfcn.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef TB_RECEIVER_VERSION
#define TB_RECEIVER_VERSION "3.6.0"
#endif

#ifndef TB_RECEIVER_BUILD
#define TB_RECEIVER_BUILD "dev"
#endif

struct tb_display {
    SDL_Window   *win;
    SDL_Renderer *ren;
    SDL_Texture  *tex;
    SDL_Texture  *status_tex;
    int           tex_w, tex_h;
    int           quit;
    int           preferred_fullscreen;
    int           is_connected;
    int           is_connecting;
    int           input_capture_active;
    int           input_intercept_active;
    struct tb_input_queue input_queue;
    uint32_t      last_target_switch_tick;
    uint32_t      last_space_switch_tick;
    uint32_t      last_space_gesture_tick;
    int           space_gesture_accum_x;
    int           cursor_x, cursor_y;
    int           cursor_source_w, cursor_source_h;
    int           cursor_visible;
    int           cursor_type;
    int           cursor_large;
    uint32_t      last_video_frame_time;
    int           system_cursor_hidden;

    char          last_ip[64];
    char          last_status[128];
    char          last_sender[128];
    char          last_panel[128];
    char          last_mode[128];
    char          last_language[96];
    char          last_permissions[160];
    int           show_details;       /* idle screen: full diagnostics instead of the calm view */
    int           last_show_details;
    enum tb_display_login_item login_item_state;
    enum tb_display_login_item last_login_item_state;
    int           last_drawable_w;
    int           last_drawable_h;
    int           status_is_connecting;
    /* PWE (1.1.1): when the idle or connecting screen was last presented. The
     * main loop asks for it every pass; it is presented when its picture
     * changed, else at TB_DISP_IDLE_PRESENT_MS / TB_DISP_CONNECTING_PRESENT_MS. */
    uint64_t      last_status_present_ms;

    /* PWE pairing: a notice drawn in place of the calm idle screen's two lines
     * (and, for a warning, on the connecting screen). See tb_disp_set_notice. */
    int           pwe_notice_kind;
    char          pwe_notice[3][192];
    int           pwe_notice_dirty;

    /* PWE (COMPACT_IDLE): Esc quits only when pressed twice; the first press
     * arms quitting until this tick and the screen says so (T36). 0 = not armed. */
    uint64_t      quit_armed_until;
    int           last_quit_hint;

    /* Receiver rendering (PWE 1.1): the Metal zero-copy path and its pacing. */
    struct tb_mtl   *mtl;            /* non-NULL = Metal draws the video */
    int              metal_unusable; /* Metal failed once: OpenGL for the rest of this run */
    struct tb_vsync *vsync;          /* refresh ticks, when paced */
    int              paced;          /* at most one submit per refresh, newest frame wins */
    int              copy_frames;    /* decoder buffers cannot be textured: copy them */
    int              frame_checked;  /* this session's first frame was test-wrapped */
    int              logged_first_metal_frame;
    CVPixelBufferRef pending;        /* decoded, waiting for the next refresh */
    uint32_t         pending_trace_id;
    CVPixelBufferRef current;        /* on screen; redrawn when the pointer moves */
    uint64_t         last_submit_tick;
    uint64_t         last_submit_ns;
    uint64_t         video_submit_tick;
    uint64_t         last_seen_tick;
    int              new_frame_since_tick;
    int              redraw_needed;
    int              cursor_dirty;
    uint32_t         last_cursor_render_time;
    uint64_t         metal_cursor_key;  /* which picture the Metal path has uploaded */

    /* Receiver-drawn pointer: the sender's picture (0x39), premultiplied BGRA. */
    uint8_t         *cursor_pixels;
    int              cursor_img_w, cursor_img_h;
    int              cursor_hot_x, cursor_hot_y;
    int              cursor_frame_w, cursor_frame_h;
    uint32_t         cursor_img_id;
    SDL_Texture     *cursor_tex;       /* the picture on the SDL renderer */
};

#define TB_DISP_QUIT_CONFIRM_MS 2000u

/* PWE (1.1.1): how often an unchanged idle or connecting screen is presented
 * again (a covered window gets its picture back; the spinner turns every 83 ms). */
#define TB_DISP_IDLE_PRESENT_MS       100u
#define TB_DISP_CONNECTING_PRESENT_MS  33u

/* Whether to present the idle or connecting screen now: when its texture was
 * rebuilt, or when `interval_ms` passed since the last present. Updates the
 * stamp when it says yes. */
static int tb_disp_status_present_due(struct tb_display *d, int rebuilt, uint64_t interval_ms) {
    const uint64_t now = SDL_GetTicks64();
    if (!rebuilt && d->last_status_present_ms && now - d->last_status_present_ms < interval_ms) return 0;
    d->last_status_present_ms = now;
    return 1;
}

/* Whether the screen should say "Press Esc again to quit" now (PWE build). */
static int tb_disp_quit_hint(const struct tb_display *d) {
    return TB_RECEIVER_COMPACT_IDLE &&
           d->quit_armed_until != 0 && SDL_GetTicks64() < d->quit_armed_until;
}

static uint16_t tb_disp_mac_keycode_for_sdl_scancode(SDL_Scancode scancode) {
    switch (scancode) {
    case SDL_SCANCODE_A: return 0x00;
    case SDL_SCANCODE_S: return 0x01;
    case SDL_SCANCODE_D: return 0x02;
    case SDL_SCANCODE_F: return 0x03;
    case SDL_SCANCODE_H: return 0x04;
    case SDL_SCANCODE_G: return 0x05;
    case SDL_SCANCODE_Z: return 0x06;
    case SDL_SCANCODE_X: return 0x07;
    case SDL_SCANCODE_C: return 0x08;
    case SDL_SCANCODE_V: return 0x09;
    case SDL_SCANCODE_B: return 0x0B;
    case SDL_SCANCODE_Q: return 0x0C;
    case SDL_SCANCODE_W: return 0x0D;
    case SDL_SCANCODE_E: return 0x0E;
    case SDL_SCANCODE_R: return 0x0F;
    case SDL_SCANCODE_Y: return 0x10;
    case SDL_SCANCODE_T: return 0x11;
    case SDL_SCANCODE_1: return 0x12;
    case SDL_SCANCODE_2: return 0x13;
    case SDL_SCANCODE_3: return 0x14;
    case SDL_SCANCODE_4: return 0x15;
    case SDL_SCANCODE_6: return 0x16;
    case SDL_SCANCODE_5: return 0x17;
    case SDL_SCANCODE_EQUALS: return 0x18;
    case SDL_SCANCODE_9: return 0x19;
    case SDL_SCANCODE_7: return 0x1A;
    case SDL_SCANCODE_MINUS: return 0x1B;
    case SDL_SCANCODE_8: return 0x1C;
    case SDL_SCANCODE_0: return 0x1D;
    case SDL_SCANCODE_RIGHTBRACKET: return 0x1E;
    case SDL_SCANCODE_O: return 0x1F;
    case SDL_SCANCODE_U: return 0x20;
    case SDL_SCANCODE_LEFTBRACKET: return 0x21;
    case SDL_SCANCODE_I: return 0x22;
    case SDL_SCANCODE_P: return 0x23;
    case SDL_SCANCODE_RETURN: return 0x24;
    case SDL_SCANCODE_L: return 0x25;
    case SDL_SCANCODE_J: return 0x26;
    case SDL_SCANCODE_APOSTROPHE: return 0x27;
    case SDL_SCANCODE_K: return 0x28;
    case SDL_SCANCODE_SEMICOLON: return 0x29;
    case SDL_SCANCODE_BACKSLASH: return 0x2A;
    case SDL_SCANCODE_COMMA: return 0x2B;
    case SDL_SCANCODE_SLASH: return 0x2C;
    case SDL_SCANCODE_N: return 0x2D;
    case SDL_SCANCODE_M: return 0x2E;
    case SDL_SCANCODE_PERIOD: return 0x2F;
    case SDL_SCANCODE_TAB: return 0x30;
    case SDL_SCANCODE_SPACE: return 0x31;
    case SDL_SCANCODE_GRAVE: return 0x32;
    case SDL_SCANCODE_BACKSPACE: return 0x33;
    case SDL_SCANCODE_ESCAPE: return 0x35;
    case SDL_SCANCODE_LGUI: return 0x37;
    case SDL_SCANCODE_LSHIFT: return 0x38;
    case SDL_SCANCODE_CAPSLOCK: return 0x39;
    case SDL_SCANCODE_LALT: return 0x3A;
    case SDL_SCANCODE_LCTRL: return 0x3B;
    case SDL_SCANCODE_RSHIFT: return 0x3C;
    case SDL_SCANCODE_RALT: return 0x3D;
    case SDL_SCANCODE_RCTRL: return 0x3E;
    case SDL_SCANCODE_RGUI: return 0x36;
    case SDL_SCANCODE_F17: return 0x40;
    case SDL_SCANCODE_KP_DECIMAL: return 0x41;
    case SDL_SCANCODE_KP_MULTIPLY: return 0x43;
    case SDL_SCANCODE_KP_PLUS: return 0x45;
    case SDL_SCANCODE_NUMLOCKCLEAR: return 0x47;
    case SDL_SCANCODE_KP_DIVIDE: return 0x4B;
    case SDL_SCANCODE_KP_ENTER: return 0x4C;
    case SDL_SCANCODE_KP_MINUS: return 0x4E;
    case SDL_SCANCODE_KP_EQUALS: return 0x51;
    case SDL_SCANCODE_KP_0: return 0x52;
    case SDL_SCANCODE_KP_1: return 0x53;
    case SDL_SCANCODE_KP_2: return 0x54;
    case SDL_SCANCODE_KP_3: return 0x55;
    case SDL_SCANCODE_KP_4: return 0x56;
    case SDL_SCANCODE_KP_5: return 0x57;
    case SDL_SCANCODE_KP_6: return 0x58;
    case SDL_SCANCODE_KP_7: return 0x59;
    case SDL_SCANCODE_F18: return 0x4F;
    case SDL_SCANCODE_F19: return 0x50;
    case SDL_SCANCODE_KP_8: return 0x5B;
    case SDL_SCANCODE_KP_9: return 0x5C;
    case SDL_SCANCODE_F5: return 0x60;
    case SDL_SCANCODE_F6: return 0x61;
    case SDL_SCANCODE_F7: return 0x62;
    case SDL_SCANCODE_F3: return 0x63;
    case SDL_SCANCODE_F8: return 0x64;
    case SDL_SCANCODE_F9: return 0x65;
    case SDL_SCANCODE_F11: return 0x67;
    case SDL_SCANCODE_F13: return 0x69;
    case SDL_SCANCODE_F16: return 0x6A;
    case SDL_SCANCODE_F14: return 0x6B;
    case SDL_SCANCODE_F10: return 0x6D;
    case SDL_SCANCODE_F12: return 0x6F;
    case SDL_SCANCODE_F15: return 0x71;
    case SDL_SCANCODE_INSERT: return 0x72;
    case SDL_SCANCODE_HOME: return 0x73;
    case SDL_SCANCODE_PAGEUP: return 0x74;
    case SDL_SCANCODE_DELETE: return 0x75;
    case SDL_SCANCODE_F4: return 0x76;
    case SDL_SCANCODE_END: return 0x77;
    case SDL_SCANCODE_F2: return 0x78;
    case SDL_SCANCODE_PAGEDOWN: return 0x79;
    case SDL_SCANCODE_F1: return 0x7A;
    case SDL_SCANCODE_LEFT: return 0x7B;
    case SDL_SCANCODE_RIGHT: return 0x7C;
    case SDL_SCANCODE_DOWN: return 0x7D;
    case SDL_SCANCODE_UP: return 0x7E;
    default: return 0xFFFF;
    }
}

static void tb_disp_metal_release_frames(struct tb_display *d);

static void tb_disp_queue_input_event(struct tb_display *d, const struct tb_input_event *event) {
    if (!d || !event) return;
    (void)tb_input_queue_push(&d->input_queue, event);
}

static void tb_disp_destroy_status_texture(struct tb_display *d) {
    if (d->status_tex) {
        SDL_DestroyTexture(d->status_tex);
        d->status_tex = NULL;
    }
}

/* A font by name. Upstream's screens name PostScript fonts (Helvetica, Menlo,
 * PingFang). PWE's screens use the system font through three tokens:
 *   ".system"           the system UI font, regular
 *   ".system-semibold"  the same, semibold
 *   "...-digits"        either of them with monospaced figures (codes, addresses,
 *                       version numbers), e.g. ".system-semibold-digits"
 * Chinese falls back to PingFang through the system font's cascade list. The
 * receiver's own language is passed so Han text takes the Simplified Chinese
 * face even when the iMac's system language is not Chinese (L switches it).
 * CTFontCreateUIFontForLanguage and the weight trait both exist on macOS 11. */
static CTFontRef tb_disp_create_font(const char *font_name, CGFloat font_size) {
    if (!font_name) return NULL;
    if (strncmp(font_name, ".system", 7) != 0) {
        CFStringRef cf_font_name = CFStringCreateWithCString(NULL, font_name, kCFStringEncodingUTF8);
        if (!cf_font_name) return NULL;
        CTFontRef font = CTFontCreateWithName(cf_font_name, font_size, NULL);
        CFRelease(cf_font_name);
        return font;
    }

    const char *language = tb_i18n_current_language();
    CTFontRef base = CTFontCreateUIFontForLanguage(
        kCTFontUIFontSystem, font_size,
        language && strncmp(language, "zh", 2) == 0 ? CFSTR("zh-Hans") : NULL);
    if (!base) return NULL;
    const int semibold = strstr(font_name, "-semibold") != NULL;
    const int digits = strstr(font_name, "-digits") != NULL;
    if (!semibold && !digits) return base;

    CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                             &kCFTypeDictionaryValueCallBacks);
    if (!attrs) return base;
    if (semibold) {
        const CGFloat weight = 0.3;   /* NSFontWeightSemibold */
        CFNumberRef weight_ref = CFNumberCreate(NULL, kCFNumberCGFloatType, &weight);
        const void *keys[] = { kCTFontWeightTrait };
        const void *values[] = { weight_ref };
        CFDictionaryRef traits = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                                    &kCFTypeDictionaryValueCallBacks);
        if (traits) {
            CFDictionarySetValue(attrs, kCTFontTraitsAttribute, traits);
            CFRelease(traits);
        }
        if (weight_ref) CFRelease(weight_ref);
    }
    if (digits) {
        const int type = kNumberSpacingType, selector = kMonospacedNumbersSelector;
        CFNumberRef type_ref = CFNumberCreate(NULL, kCFNumberIntType, &type);
        CFNumberRef selector_ref = CFNumberCreate(NULL, kCFNumberIntType, &selector);
        const void *keys[] = { kCTFontFeatureTypeIdentifierKey, kCTFontFeatureSelectorIdentifierKey };
        const void *values[] = { type_ref, selector_ref };
        CFDictionaryRef setting = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
                                                     &kCFTypeDictionaryValueCallBacks);
        CFArrayRef settings = setting ? CFArrayCreate(NULL, (const void **)&setting, 1, &kCFTypeArrayCallBacks) : NULL;
        if (settings) {
            CFDictionarySetValue(attrs, kCTFontFeatureSettingsAttribute, settings);
            CFRelease(settings);
        }
        if (setting) CFRelease(setting);
        if (selector_ref) CFRelease(selector_ref);
        if (type_ref) CFRelease(type_ref);
    }
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attrs);
    CFRelease(attrs);
    CTFontRef font = descriptor ? CTFontCreateCopyWithAttributes(base, font_size, NULL, descriptor) : NULL;
    if (descriptor) CFRelease(descriptor);
    if (!font) return base;
    CFRelease(base);
    return font;
}

/* Typographic width of `text` in the given font, for centring. */
static CGFloat tb_disp_text_width(const char *text, const char *font_name, CGFloat font_size) {
    if (!text || !*text) return 0;
    CFStringRef cf_text = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    CTFontRef font = tb_disp_create_font(font_name, font_size);
    CGFloat width = 0;
    if (cf_text && font) {
        const void *keys[] = { kCTFontAttributeName };
        const void *values[] = { font };
        CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, values, 1,
                                                   &kCFTypeDictionaryKeyCallBacks,
                                                   &kCFTypeDictionaryValueCallBacks);
        CFAttributedStringRef attr = attrs ? CFAttributedStringCreate(NULL, cf_text, attrs) : NULL;
        CTLineRef line = attr ? CTLineCreateWithAttributedString(attr) : NULL;
        if (line) width = (CGFloat)CTLineGetTypographicBounds(line, NULL, NULL, NULL);
        if (line) CFRelease(line);
        if (attr) CFRelease(attr);
        if (attrs) CFRelease(attrs);
    }
    if (font) CFRelease(font);
    if (cf_text) CFRelease(cf_text);
    return width;
}

static void tb_disp_draw_text_rgba(CGContextRef ctx,
                                   const char *text,
                                   const char *font_name,
                                   CGFloat font_size,
                                   CGFloat x,
                                   CGFloat y,
                                   CGFloat r,
                                   CGFloat g,
                                   CGFloat b,
                                   CGFloat a) {
    if (!text || !*text) return;

    CFStringRef cf_text = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    if (!cf_text) return;

    CTFontRef font = tb_disp_create_font(font_name, font_size);
    if (!font) {
        CFRelease(cf_text);
        return;
    }

    CGFloat components[4] = { r, g, b, a };
    CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    CGColorRef color = CGColorCreate(color_space, components);
    CGColorSpaceRelease(color_space);
    if (!color) {
        CFRelease(font);
        CFRelease(cf_text);
        return;
    }

    const void *keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
    const void *values[] = { font, color };
    CFDictionaryRef attrs = CFDictionaryCreate(
        NULL,
        keys,
        values,
        2,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    CFAttributedStringRef attributed = CFAttributedStringCreate(NULL, cf_text, attrs);
    CTLineRef line = attributed ? CTLineCreateWithAttributedString(attributed) : NULL;

    if (line) {
        CGContextSaveGState(ctx);
        /* The whole status canvas is flipped to get a top-left origin.
         * CoreText glyph rasterization does not follow that transform the
         * way the filled rects do, so we locally flip again just for text. */
        CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
        CGContextTranslateCTM(ctx, 0.0, 2.0 * y);
        CGContextScaleCTM(ctx, 1.0, -1.0);
        CGContextSetTextPosition(ctx, x, y);
        CTLineDraw(line, ctx);
        CGContextRestoreGState(ctx);
        CFRelease(line);
    }

    if (attributed) CFRelease(attributed);
    if (attrs) CFRelease(attrs);
    CGColorRelease(color);
    CFRelease(font);
    CFRelease(cf_text);
}

static void tb_disp_draw_text(CGContextRef ctx, const char *text, const char *font_name, CGFloat font_size,
                              CGFloat x, CGFloat y, CGFloat r, CGFloat g, CGFloat b) {
    tb_disp_draw_text_rgba(ctx, text, font_name, font_size, x, y, r, g, b, 1.0);
}

/* Draw `text` centred on `center_x`, so any language and any product name fit. */
static void tb_disp_draw_text_centered(CGContextRef ctx, const char *text, const char *font_name,
                                       CGFloat font_size, CGFloat center_x, CGFloat y,
                                       CGFloat r, CGFloat g, CGFloat b) {
    CGFloat width = tb_disp_text_width(text, font_name, font_size);
    tb_disp_draw_text(ctx, text, font_name, font_size, center_x - width / 2.0, y, r, g, b);
}

static void tb_disp_fill_rect(CGContextRef ctx,
                              CGFloat x,
                              CGFloat y,
                              CGFloat w,
                              CGFloat h,
                              CGFloat r,
                              CGFloat g,
                              CGFloat b,
                              CGFloat a) {
    CGContextSetRGBFillColor(ctx, r, g, b, a);
    CGContextFillRect(ctx, CGRectMake(x, y, w, h));
}

static void tb_disp_fill_rounded_rect(CGContextRef ctx,
                                      CGFloat x,
                                      CGFloat y,
                                      CGFloat w,
                                      CGFloat h,
                                      CGFloat radius,
                                      CGFloat r,
                                      CGFloat g,
                                      CGFloat b,
                                      CGFloat a) {
    CGPathRef path = CGPathCreateWithRoundedRect(CGRectMake(x, y, w, h), radius, radius, NULL);
    if (!path) return;
    CGContextSetRGBFillColor(ctx, r, g, b, a);
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);
    CGPathRelease(path);
}

static void tb_disp_draw_brand_icon(CGContextRef ctx, CGFloat x, CGFloat y, CGFloat size) {
    const CGFloat inset = size * 0.22;
    const CGFloat monitor_w = size * 0.56;
    const CGFloat monitor_h = size * 0.34;
    const CGFloat monitor_x = x + (size - monitor_w) / 2.0;
    const CGFloat monitor_y = y + size * 0.25;

    tb_disp_fill_rounded_rect(ctx, x, y, size, size, size * 0.22, 0.13, 0.34, 0.24, 1.0);
    CGContextSetRGBStrokeColor(ctx, 0.94, 0.98, 0.96, 1.0);
    CGContextSetLineWidth(ctx, size * 0.045);
    CGContextStrokeRect(ctx, CGRectMake(monitor_x, monitor_y, monitor_w, monitor_h));
    CGContextMoveToPoint(ctx, monitor_x + monitor_w * 0.5, monitor_y + monitor_h);
    CGContextAddLineToPoint(ctx, monitor_x + monitor_w * 0.5, monitor_y + monitor_h + size * 0.13);
    CGContextMoveToPoint(ctx, monitor_x + inset, monitor_y + monitor_h + size * 0.13);
    CGContextAddLineToPoint(ctx, monitor_x + monitor_w - inset, monitor_y + monitor_h + size * 0.13);
    CGContextStrokePath(ctx);
}

/* The app's own icon from its bundle (CFBundleIconFile), so a renamed build shows
 * its own mark. Falls back to the drawn icon when there is no bundle icon, for
 * example when the bare binary runs from the build directory. */
static void tb_disp_draw_app_icon(CGContextRef ctx, CGFloat x, CGFloat y, CGFloat size) {
    CGImageRef image = NULL;
    CFBundleRef bundle = CFBundleGetMainBundle();
    CFTypeRef icon_name = bundle ? CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("CFBundleIconFile")) : NULL;
    if (icon_name && CFGetTypeID(icon_name) == CFStringGetTypeID()) {
        CFURLRef url = CFBundleCopyResourceURL(bundle, (CFStringRef)icon_name, CFSTR("icns"), NULL);
        if (!url) url = CFBundleCopyResourceURL(bundle, (CFStringRef)icon_name, NULL, NULL);
        if (url) {
            CGImageSourceRef source = CGImageSourceCreateWithURL(url, NULL);
            if (source) {
                /* The largest representation, so it stays sharp on a 5K panel. */
                size_t best = 0, best_width = 0, count = CGImageSourceGetCount(source);
                for (size_t i = 0; i < count; i++) {
                    CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(source, i, NULL);
                    if (!props) continue;
                    CFNumberRef width_ref = CFDictionaryGetValue(props, kCGImagePropertyPixelWidth);
                    long width = 0;
                    if (width_ref) CFNumberGetValue(width_ref, kCFNumberLongType, &width);
                    if ((size_t)width > best_width) { best_width = (size_t)width; best = i; }
                    CFRelease(props);
                }
                if (count > 0) image = CGImageSourceCreateImageAtIndex(source, best, NULL);
                CFRelease(source);
            }
            CFRelease(url);
        }
    }
    if (!image) {
        tb_disp_draw_brand_icon(ctx, x, y, size);
        return;
    }
    /* The canvas is flipped to a top-left origin; flip back locally so the
     * bitmap is not drawn upside down. */
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, x, y + size);
    CGContextScaleCTM(ctx, 1.0, -1.0);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, size, size), image);
    CGContextRestoreGState(ctx);
    CGImageRelease(image);
}

static void tb_disp_draw_connecting_spinner(struct tb_display *d, int drawable_w, int drawable_h) {
    if (!d || !d->ren) return;
#if TB_RECEIVER_COMPACT_IDLE
    /* PWE (BRAND §2.6): twelve paper spokes at up to 40 % (label-3), centred
     * C + 100 u, outer radius 14 u. Each spoke is a quad, not a 1-pixel line, so
     * it keeps its weight on a 5K panel. */
    {
        const float u = (float)(drawable_w < drawable_h ? drawable_w : drawable_h) / 720.0f;
        const float cx = (float)drawable_w / 2.0f;
        const float cy = (float)drawable_h / 2.0f + 100.0f * u;
        const float r_out = 14.0f * u, r_in = 7.0f * u, half_w = 1.1f * u;
        const int phase = (int)((SDL_GetTicks() / 83u) % 12u);
        SDL_Vertex verts[48];
        int indices[72];
        for (int i = 0; i < 12; i++) {
            const float angle = (float)i * 0.5235988f;   /* 30 degrees */
            const float dx = sinf(angle), dy = -cosf(angle);   /* spoke 0 points up */
            const float px = -dy * half_w, py = dx * half_w;
            const int age = (i - phase + 12) % 12;
            const Uint8 alpha = (Uint8)(102.0f * (0.25f + 0.75f * (float)(11 - age) / 11.0f));
            const float ends[2][2] = { { cx + dx * r_in, cy + dy * r_in }, { cx + dx * r_out, cy + dy * r_out } };
            for (int k = 0; k < 4; k++) {
                SDL_Vertex *v = &verts[i * 4 + k];
                const float sign = (k & 1) ? -1.0f : 1.0f;
                v->position.x = ends[k >> 1][0] + px * sign;
                v->position.y = ends[k >> 1][1] + py * sign;
                v->color = (SDL_Color){ 247, 245, 242, alpha };
                v->tex_coord.x = 0.0f;
                v->tex_coord.y = 0.0f;
            }
            const int base = i * 4;
            const int quad[6] = { base, base + 1, base + 2, base + 2, base + 1, base + 3 };
            memcpy(&indices[i * 6], quad, sizeof(quad));
        }
        SDL_BlendMode old_blend = SDL_BLENDMODE_NONE;
        SDL_GetRenderDrawBlendMode(d->ren, &old_blend);
        SDL_SetRenderDrawBlendMode(d->ren, SDL_BLENDMODE_BLEND);
        SDL_RenderGeometry(d->ren, NULL, verts, 48, indices, 72);
        SDL_SetRenderDrawBlendMode(d->ren, old_blend);
        return;
    }
#endif

    static const int vectors[12][2] = {
        { 0, -100 }, { 50, -87 }, { 87, -50 }, { 100, 0 },
        { 87, 50 }, { 50, 87 }, { 0, 100 }, { -50, 87 },
        { -87, 50 }, { -100, 0 }, { -87, -50 }, { -50, -87 }
    };
    const int min_side = drawable_w < drawable_h ? drawable_w : drawable_h;
    const int radius = min_side / 13;
    const int segment = min_side / 42;
    const int center_x = drawable_w / 2;
    const int center_y = drawable_h / 2 + min_side / 5;
    const int phase = (int)((SDL_GetTicks() / 90u) % 12u);

    SDL_BlendMode old_blend = SDL_BLENDMODE_NONE;
    SDL_GetRenderDrawBlendMode(d->ren, &old_blend);
    SDL_SetRenderDrawBlendMode(d->ren, SDL_BLENDMODE_BLEND);
    for (int i = 0; i < 12; i++) {
        const int age = (i - phase + 12) % 12;
        const Uint8 alpha = (Uint8)(54 + (11 - age) * 18);
        const int x1 = center_x + vectors[i][0] * radius / 100;
        const int y1 = center_y + vectors[i][1] * radius / 100;
        const int x2 = center_x + vectors[i][0] * (radius + segment) / 100;
        const int y2 = center_y + vectors[i][1] * (radius + segment) / 100;
        SDL_SetRenderDrawColor(d->ren, 84, 225, 137, alpha);
        SDL_RenderDrawLine(d->ren, x1, y1, x2, y2);
    }
    SDL_SetRenderDrawBlendMode(d->ren, old_blend);
}

/* ---- PWE's screens (COMPACT_IDLE / OFFER_LOGIN_ITEM builds) ---------------
 * docs/pwe/BRAND-iMac-Display-2026-10-20.md §2.2, §2.3, §2.6. Colours are the
 * dark-appearance tokens of 01 BRAND ASSETS/tokens/armature.json; there is no
 * green, no card behind the waiting screens and no capitals for emphasis.
 * Lengths are in u = short side / 720 (2560x1440 points: 1 u = 2 pt). The
 * canvas has a top-left origin: y grows down. */
struct tb_pwe_colour { CGFloat r, g, b, a; };
static const struct tb_pwe_colour TB_PWE_NIGHT   = { 14 / 255.0, 23 / 255.0, 41 / 255.0, 1.0 };    /* night   #0E1729 */
static const struct tb_pwe_colour TB_PWE_NIGHT_2 = { 22 / 255.0, 35 / 255.0, 61 / 255.0, 1.0 };    /* night-2 #16233D */
static const struct tb_pwe_colour TB_PWE_LABEL   = { 247 / 255.0, 245 / 255.0, 242 / 255.0, 1.0 }; /* label   #F7F5F2 */
static const struct tb_pwe_colour TB_PWE_LABEL_2 = { 247 / 255.0, 245 / 255.0, 242 / 255.0, 0.66 };
static const struct tb_pwe_colour TB_PWE_LINE    = { 247 / 255.0, 245 / 255.0, 242 / 255.0, 0.12 };
static const struct tb_pwe_colour TB_PWE_SIGNAL  = { 245 / 255.0, 179 / 255.0, 53 / 255.0, 1.0 };  /* signal  #F5B335 */
static const struct tb_pwe_colour TB_PWE_ALERT   = { 232 / 255.0, 101 / 255.0, 78 / 255.0, 1.0 };  /* alert   #E8654E */

static void tb_pwe_text(CGContextRef ctx, const char *text, const char *font, CGFloat size,
                        CGFloat x, CGFloat y, struct tb_pwe_colour c) {
    tb_disp_draw_text_rgba(ctx, text, font, size, x, y, c.r, c.g, c.b, c.a);
}

static void tb_pwe_text_centered(CGContextRef ctx, const char *text, const char *font, CGFloat size,
                                 CGFloat center_x, CGFloat y, struct tb_pwe_colour c) {
    tb_pwe_text(ctx, text, font, size, center_x - tb_disp_text_width(text, font, size) / 2.0, y, c);
}

static void tb_pwe_text_right(CGContextRef ctx, const char *text, const char *font, CGFloat size,
                              CGFloat right_x, CGFloat y, struct tb_pwe_colour c) {
    tb_pwe_text(ctx, text, font, size, right_x - tb_disp_text_width(text, font, size), y, c);
}

static void tb_pwe_fill(CGContextRef ctx, CGFloat x, CGFloat y, CGFloat w, CGFloat h, CGFloat radius,
                        struct tb_pwe_colour c) {
    if (radius > 0) tb_disp_fill_rounded_rect(ctx, x, y, w, h, radius, c.r, c.g, c.b, c.a);
    else tb_disp_fill_rect(ctx, x, y, w, h, c.r, c.g, c.b, c.a);
}

/* The paper wing (pwe/brand/receiver/receiver-wing.pdf: pwe/brand/make.py draws
 * it from the brand's wing geometry; pwe/package.sh puts it in Resources), its
 * first page `width` wide, top edge at `top`, centred on `center_x`. Returns 0
 * when there is no wing to draw: a bare binary has no bundle, unless it was
 * built with TB_RECEIVER_WING_DEV_PATH (offscreen renders). */
static int tb_disp_draw_wing(CGContextRef ctx, CGFloat center_x, CGFloat top, CGFloat width) {
    CFURLRef url = NULL;
    CFBundleRef bundle = CFBundleGetMainBundle();
    if (bundle) url = CFBundleCopyResourceURL(bundle, CFSTR("receiver-wing"), CFSTR("pdf"), NULL);
#ifdef TB_RECEIVER_WING_DEV_PATH
    if (!url) {
        url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)TB_RECEIVER_WING_DEV_PATH,
                                                      (CFIndex)strlen(TB_RECEIVER_WING_DEV_PATH), false);
    }
#endif
    if (!url) return 0;
    CGPDFDocumentRef pdf = CGPDFDocumentCreateWithURL(url);
    CFRelease(url);
    if (!pdf) return 0;
    int drawn = 0;
    CGPDFPageRef page = CGPDFDocumentGetPage(pdf, 1);
    const CGRect box = page ? CGPDFPageGetBoxRect(page, kCGPDFMediaBox) : CGRectZero;
    if (box.size.width > 0 && box.size.height > 0) {
        const CGFloat scale = width / box.size.width;
        CGContextSaveGState(ctx);
        /* PDF pages are bottom-up; the canvas is top-down. */
        CGContextTranslateCTM(ctx, center_x - width / 2.0, top + box.size.height * scale);
        CGContextScaleCTM(ctx, scale, -scale);
        CGContextTranslateCTM(ctx, -box.origin.x, -box.origin.y);
        CGContextDrawPDFPage(ctx, page);
        CGContextRestoreGState(ctx);
        drawn = 1;
    }
    CGPDFDocumentRelease(pdf);
    return drawn;
}

/* The waiting screens, idle, pairing code and connecting, are one layout: the
 * wing and the name never move and only the lines under them change, so a new
 * state does not make the screen jump. C is the vertical centre. The connecting
 * spinner (C + 100 u) is drawn on top by tb_disp_draw_connecting_spinner. */
static void tb_disp_draw_waiting_screen(CGContextRef ctx, const struct tb_display *d,
                                        int drawable_w, int drawable_h, int connecting) {
    const CGFloat W = (CGFloat)drawable_w;
    const CGFloat H = (CGFloat)drawable_h;
    const CGFloat u = (W < H ? W : H) / 720.0;
    const CGFloat cx = W / 2.0;
    const CGFloat C = H / 2.0;
    const int kind = d->pwe_notice_kind;

    tb_pwe_fill(ctx, 0, 0, W, H, 0, TB_PWE_NIGHT);
    if (!tb_disp_draw_wing(ctx, cx, C - 190.0 * u, 144.0 * u)) {
        tb_disp_draw_app_icon(ctx, cx - 44.5 * u, C - 190.0 * u, 89.0 * u);
    }
    tb_pwe_text_centered(ctx, tb_i18n_get("common.app_name"), ".system-semibold", 28.0 * u, cx, C - 24.0 * u,
                         TB_PWE_LABEL);

    if (connecting) {
        tb_pwe_text_centered(ctx, tb_i18n_get("receiver.splash.connecting"), ".system", 22.0 * u,
                             cx, C + 26.0 * u, TB_PWE_LABEL);
        tb_pwe_text_centered(ctx, tb_i18n_get("receiver.splash.waiting_first_frame"), ".system", 15.0 * u,
                             cx, C + 56.0 * u, TB_PWE_LABEL_2);
    } else if (kind == TB_DISP_NOTICE_PAIRING_CODE) {
        tb_pwe_text_centered(ctx, d->pwe_notice[0], ".system-semibold-digits", 34.0 * u,
                             cx, C + 26.0 * u, TB_PWE_LABEL);
        tb_pwe_text_centered(ctx, d->pwe_notice[1], ".system", 17.0 * u, cx, C + 70.0 * u, TB_PWE_LABEL);
        tb_pwe_text_centered(ctx, d->pwe_notice[2], ".system", 15.0 * u, cx, C + 94.0 * u, TB_PWE_LABEL_2);
    } else if (kind == TB_DISP_NOTICE_INFO) {
        tb_pwe_text_centered(ctx, d->pwe_notice[0], ".system", 22.0 * u, cx, C + 26.0 * u, TB_PWE_LABEL);
        tb_pwe_text_centered(ctx, d->pwe_notice[1], ".system", 15.0 * u, cx, C + 56.0 * u, TB_PWE_LABEL_2);
    } else {
        tb_pwe_text_centered(ctx, tb_i18n_get("receiver.ui.compact_waiting"), ".system", 22.0 * u,
                             cx, C + 26.0 * u, TB_PWE_LABEL);
        tb_pwe_text_centered(ctx, tb_i18n_get("receiver.ui.compact_hint"), ".system", 15.0 * u,
                             cx, C + 56.0 * u, TB_PWE_LABEL_2);
    }
    /* What needs the person (amber) or what failed (red), below everything else. */
    if (kind == TB_DISP_NOTICE_WARNING || kind == TB_DISP_NOTICE_ERROR) {
        tb_pwe_text_centered(ctx, d->pwe_notice[0], ".system", 15.0 * u, cx, C + 130.0 * u,
                             kind == TB_DISP_NOTICE_ERROR ? TB_PWE_ALERT : TB_PWE_SIGNAL);
        tb_pwe_text_centered(ctx, d->pwe_notice[1], ".system", 15.0 * u, cx, C + 154.0 * u, TB_PWE_LABEL_2);
    }

    /* The address is on the details screen. I opens it only while idle, so the
     * connecting screen shows the version alone. */
    char footer[160];
    if (connecting) snprintf(footer, sizeof(footer), "%s", TB_RECEIVER_VERSION);
    else snprintf(footer, sizeof(footer), "%s · %s", TB_RECEIVER_VERSION, tb_i18n_get("receiver.ui.compact_details"));
    /* After one Esc the footer says what a second one does, in full white. */
    if (tb_disp_quit_hint(d)) {
        tb_pwe_text_centered(ctx, tb_i18n_get("receiver.ui.quit_confirm"), ".system", 12.0 * u, cx, H - 34.0 * u,
                             TB_PWE_LABEL);
    } else {
        tb_pwe_text_centered(ctx, footer, ".system-digits", 12.0 * u, cx, H - 34.0 * u, TB_PWE_LABEL_2);
    }
}

/* The details screen of the PWE build (COMPACT_IDLE or OFFER_LOGIN_ITEM): the
 * same facts as upstream's details layout (kept in the else branch of
 * tb_disp_rebuild_status_texture, untouched), on PWE's night ground, measured
 * in u so it fits a 980x620 window on a non-Retina iMac and is not half size on
 * a Retina one. Opening at login has its own card. */
static void tb_disp_draw_details_scaled(CGContextRef ctx,
                                        const struct tb_display *d,
                                        const char *ip,
                                        const char *status,
                                        const char *sender,
                                        const char *panel,
                                        const char *mode,
                                        const char *language,
                                        const char *permissions,
                                        int drawable_w,
                                        int drawable_h) {
    const char *title_font = ".system-semibold";
    const char *body_font = ".system";
    const char *label_font = ".system-semibold";
    const char *digits_font = ".system-digits";

    const CGFloat W = (CGFloat)drawable_w;
    const CGFloat H = (CGFloat)drawable_h;
    const CGFloat s = (W < H ? W : H) / 720.0;
    /* One device pixel at least, so the rule survives a 980x620 window. */
    const CGFloat hairline = s < 1.0 ? 1.0 : s;

    tb_pwe_fill(ctx, 0, 0, W, H, 0, TB_PWE_NIGHT);

    const CGFloat outer_x = 72 * s;
    const CGFloat outer_w = W - 144 * s;
    const CGFloat outer_right = outer_x + outer_w;
    const CGFloat gap = 16 * s;
    const CGFloat card_w = (outer_w - gap) / 2.0;
    const CGFloat pad = 20 * s;
    const CGFloat right_x = outer_x + card_w + gap;
    const CGFloat radius = 13 * s;

    tb_pwe_text(ctx, tb_i18n_get("receiver.ui.title"), title_font, 28 * s, outer_x, 84 * s, TB_PWE_LABEL);
    tb_pwe_text(ctx, tb_i18n_get("receiver.ui.subtitle"), body_font, 15 * s, outer_x, 108 * s, TB_PWE_LABEL_2);
    tb_pwe_text_right(ctx, TB_RECEIVER_VERSION, digits_font, 15 * s, outer_right, 82 * s, TB_PWE_LABEL_2);
    tb_pwe_text_right(ctx, TB_RECEIVER_BUILD, digits_font, 12 * s, outer_right, 104 * s, TB_PWE_LABEL_2);
    tb_pwe_fill(ctx, outer_x, 128 * s, outer_w, hairline, 0, TB_PWE_LINE);

    tb_pwe_text(ctx, tb_i18n_get("receiver.ui.ip_thunderbolt_bridge"), label_font, 13 * s, outer_x, 160 * s,
                TB_PWE_LABEL_2);
    tb_pwe_text(ctx, ip, ".system-semibold-digits", 28 * s, outer_x, 194 * s, TB_PWE_LABEL);

    /* Two rows of cards, two label/value pairs in each card. */
    const CGFloat label_1 = 30 * s, value_1 = 58 * s, label_2 = 88 * s, value_2 = 116 * s;
    const CGFloat card_h = 136 * s;
    const CGFloat row_1 = 216 * s;
    const CGFloat row_2 = row_1 + card_h + gap;
    const int login_card = d->login_item_state != TB_DISP_LOGIN_ITEM_HIDDEN;

    tb_pwe_fill(ctx, outer_x, row_1, card_w, card_h, radius, TB_PWE_NIGHT_2);
    tb_pwe_fill(ctx, right_x, row_1, card_w, card_h, radius, TB_PWE_NIGHT_2);
    tb_pwe_fill(ctx, outer_x, row_2, login_card ? card_w : outer_w, card_h, radius, TB_PWE_NIGHT_2);
    if (login_card) tb_pwe_fill(ctx, right_x, row_2, card_w, card_h, radius, TB_PWE_NIGHT_2);

    tb_pwe_text(ctx, tb_i18n_get("receiver.ui.status"), label_font, 13 * s, outer_x + pad, row_1 + label_1, TB_PWE_LABEL_2);
    tb_pwe_text(ctx, status, body_font, 20 * s, outer_x + pad, row_1 + value_1, TB_PWE_LABEL);
    tb_pwe_text(ctx, tb_i18n_get("receiver.ui.sender"), label_font, 13 * s, outer_x + pad, row_1 + label_2, TB_PWE_LABEL_2);
    tb_pwe_text(ctx, sender, body_font, 20 * s, outer_x + pad, row_1 + value_2, TB_PWE_LABEL);

    tb_pwe_text(ctx, tb_i18n_get("receiver.ui.display"), label_font, 13 * s, right_x + pad, row_1 + label_1, TB_PWE_LABEL_2);
    tb_pwe_text(ctx, panel, digits_font, 20 * s, right_x + pad, row_1 + value_1, TB_PWE_LABEL);
    tb_pwe_text(ctx, tb_i18n_get("receiver.ui.stream_profile"), label_font, 13 * s, right_x + pad, row_1 + label_2, TB_PWE_LABEL_2);
    tb_pwe_text(ctx, mode, digits_font, 20 * s, right_x + pad, row_1 + value_2, TB_PWE_LABEL);

    tb_pwe_text(ctx, tb_i18n_get("receiver.ui.language"), label_font, 13 * s, outer_x + pad, row_2 + label_1, TB_PWE_LABEL_2);
    tb_pwe_text(ctx, language, body_font, 20 * s, outer_x + pad, row_2 + value_1, TB_PWE_LABEL);
    tb_pwe_text(ctx, tb_i18n_get("receiver.ui.permissions"), label_font, 13 * s, outer_x + pad, row_2 + label_2, TB_PWE_LABEL_2);
    tb_pwe_text(ctx, permissions, body_font, 20 * s, outer_x + pad, row_2 + value_2, TB_PWE_LABEL);

    if (login_card) {
        tb_pwe_text(ctx, tb_i18n_get("receiver.ui.login_item"), label_font, 13 * s, right_x + pad, row_2 + label_1,
                    TB_PWE_LABEL_2);
        if (d->login_item_state == TB_DISP_LOGIN_ITEM_UNAVAILABLE) {
            tb_pwe_text(ctx, tb_i18n_get("receiver.login.unavailable"), body_font, 20 * s,
                        right_x + pad, row_2 + value_1, TB_PWE_LABEL_2);
        } else {
            const char *state = tb_i18n_get(d->login_item_state == TB_DISP_LOGIN_ITEM_ON
                                            ? "receiver.login.state_on" : "receiver.login.state_off");
            char hint[160];
            snprintf(hint, sizeof(hint), " · %s", tb_i18n_get("receiver.login.toggle_hint"));
            tb_pwe_text(ctx, state, body_font, 20 * s, right_x + pad, row_2 + value_1, TB_PWE_LABEL);
            tb_pwe_text(ctx, hint, body_font, 20 * s,
                        right_x + pad + tb_disp_text_width(state, body_font, 20 * s), row_2 + value_1,
                        TB_PWE_LABEL_2);
        }
    }

    /* Two lines: how to connect, then the keys. */
    char keys[256];
    if (TB_RECEIVER_COMPACT_IDLE) {
        snprintf(keys, sizeof(keys), "%s · %s", tb_i18n_get("receiver.ui.help_4"),
                 tb_i18n_get("receiver.ui.details_back"));
    } else {
        snprintf(keys, sizeof(keys), "%s", tb_i18n_get("receiver.ui.help_4"));
    }
    tb_pwe_text(ctx, tb_i18n_get("receiver.ui.help_1"), body_font, 15 * s, outer_x, H - 66 * s, TB_PWE_LABEL_2);
    if (tb_disp_quit_hint(d)) {
        tb_pwe_text(ctx, tb_i18n_get("receiver.ui.quit_confirm"), body_font, 15 * s, outer_x, H - 42 * s,
                    TB_PWE_LABEL);
    } else {
        tb_pwe_text(ctx, keys, body_font, 15 * s, outer_x, H - 42 * s, TB_PWE_LABEL_2);
    }
}

static void tb_disp_rebuild_status_texture(struct tb_display *d,
                                           const char *ip,
                                           const char *status,
                                           const char *sender,
                                           const char *panel,
                                           const char *mode,
                                           const char *language,
                                           const char *permissions,
                                           int drawable_w,
                                           int drawable_h,
                                           int connecting) {
    if (!d || drawable_w <= 0 || drawable_h <= 0) return;

    tb_disp_destroy_status_texture(d);

    const size_t bytes_per_row = (size_t)drawable_w * 4u;
    uint32_t *pixels = (uint32_t *)calloc((size_t)drawable_w * (size_t)drawable_h, sizeof(uint32_t));
    if (!pixels) return;

    CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        pixels,
        (size_t)drawable_w,
        (size_t)drawable_h,
        8,
        bytes_per_row,
        color_space,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little
    );
    CGColorSpaceRelease(color_space);
    if (!ctx) {
        free(pixels);
        return;
    }

    CGContextTranslateCTM(ctx, 0, (CGFloat)drawable_h);
    CGContextScaleCTM(ctx, 1.0, -1.0);

    const char *current_language = tb_i18n_current_language();
    const int zh = current_language && strncmp(current_language, "zh", 2) == 0;
    const char *title_font = zh ? "PingFangSC-Semibold" : "Helvetica-Bold";
    const char *body_font = zh ? "PingFangSC-Regular" : "Helvetica";
    const char *section_font = zh ? "PingFangSC-Semibold" : "Helvetica-Bold";
    const char *mono_font = "Menlo";
    const char *mono_bold_font = "Menlo-Bold";

    if (connecting && TB_RECEIVER_COMPACT_IDLE) {
        tb_disp_draw_waiting_screen(ctx, d, drawable_w, drawable_h, 1);
    } else if (connecting) {
        const CGFloat min_side = (CGFloat)(drawable_w < drawable_h ? drawable_w : drawable_h);
        const CGFloat scale = min_side / 720.0;
        const CGFloat icon_size = 132.0 * scale;
        const CGFloat center_x = (CGFloat)drawable_w / 2.0;
        const CGFloat icon_x = center_x - icon_size / 2.0;
        const CGFloat icon_y = (CGFloat)drawable_h / 2.0 - 206.0 * scale;

        tb_disp_fill_rect(ctx, 0, 0, (CGFloat)drawable_w, (CGFloat)drawable_h, 0.035, 0.045, 0.06, 1.0);
        tb_disp_fill_rounded_rect(ctx,
                                  center_x - 300.0 * scale,
                                  icon_y - 60.0 * scale,
                                  600.0 * scale,
                                  490.0 * scale,
                                  38.0 * scale,
                                  0.075, 0.09, 0.12, 1.0);
        tb_disp_draw_app_icon(ctx, icon_x, icon_y, icon_size);
        tb_disp_draw_text_centered(ctx, tb_i18n_get("common.app_name"), title_font, 42.0 * scale,
                                   center_x, icon_y + icon_size + 74.0 * scale,
                                   0.95, 0.98, 0.97);
        tb_disp_draw_text_centered(ctx, tb_i18n_get("receiver.splash.role"), mono_bold_font, 15.0 * scale,
                                   center_x, icon_y + icon_size + 104.0 * scale,
                                   0.40, 0.90, 0.59);
        tb_disp_draw_text_centered(ctx, tb_i18n_get("receiver.splash.connecting"), body_font, 23.0 * scale,
                                   center_x, icon_y + icon_size + 166.0 * scale,
                                   0.93, 0.95, 0.99);
        tb_disp_draw_text_centered(ctx, tb_i18n_get("receiver.splash.waiting_first_frame"), body_font, 17.0 * scale,
                                   center_x, icon_y + icon_size + 202.0 * scale,
                                   0.62, 0.68, 0.77);
        if (d->pwe_notice_kind == TB_DISP_NOTICE_WARNING ||   /* PWE: e.g. not encrypted */
            d->pwe_notice_kind == TB_DISP_NOTICE_ERROR) {
            tb_disp_draw_text_centered(ctx, d->pwe_notice[0], body_font, 17.0 * scale,
                                       center_x, icon_y + icon_size + 248.0 * scale, 1.0, 0.72, 0.30);
        }
        tb_disp_draw_text_centered(ctx, TB_RECEIVER_VERSION, mono_font, 13.0 * scale,
                                   center_x, icon_y + icon_size + 310.0 * scale,
                                   0.40, 0.45, 0.53);
    } else if (TB_RECEIVER_COMPACT_IDLE && !d->show_details) {
        /* The calm idle screen: what this screen is, what it is waiting for, and
         * the one thing to do. The address and diagnostics are one key away. */
        tb_disp_draw_waiting_screen(ctx, d, drawable_w, drawable_h, 0);
    } else if (TB_RECEIVER_COMPACT_IDLE || d->login_item_state != TB_DISP_LOGIN_ITEM_HIDDEN) {
        tb_disp_draw_details_scaled(ctx, d, ip, status, sender, panel, mode, language, permissions,
                                    drawable_w, drawable_h);
    } else {
    /* The canvas has a top-left origin (y grows down). This layout was written
     * for a bottom-left origin and drew upside down (title at the bottom, each
     * caption under its value). It is the same layout measured from the top:
     * every baseline y became H - y and every rect top became H - y - height. */
    const CGFloat H = (CGFloat)drawable_h;

    tb_disp_fill_rect(ctx, 0, 0, (CGFloat)drawable_w, H, 0.06, 0.07, 0.09, 1.0);
    tb_disp_fill_rect(ctx, 48, 52, (CGFloat)drawable_w - 96, H - 104, 0.11, 0.12, 0.15, 1.0);
    tb_disp_fill_rect(ctx, 48, 150, (CGFloat)drawable_w - 96, 2, 0.22, 0.24, 0.29, 1.0);

    const CGFloat outer_x = 72.0;
    const CGFloat outer_w = (CGFloat)drawable_w - 144.0;
    const CGFloat top_y = 176.0;
    const CGFloat card_gap = 28.0;
    const CGFloat card_w = (outer_w - card_gap) / 2.0;

    tb_disp_draw_text(ctx, tb_i18n_get("receiver.ui.title"), title_font, 28, 72, 84, 0.95, 0.97, 1.0);
    tb_disp_draw_text(ctx, tb_i18n_get("receiver.ui.subtitle"), body_font, 17, 72, 118, 0.72, 0.76, 0.84);
    tb_disp_draw_text(ctx, TB_RECEIVER_VERSION, mono_bold_font, 17, (CGFloat)drawable_w - 220, 82, 0.64, 0.69, 0.78);
    tb_disp_draw_text(ctx, TB_RECEIVER_BUILD, mono_font, 13, (CGFloat)drawable_w - 220, 114, 0.53, 0.57, 0.66);

    tb_disp_draw_text(ctx, tb_i18n_get("receiver.ui.ip_thunderbolt_bridge"), section_font, 15, outer_x, top_y, 0.54, 0.62, 0.76);
    tb_disp_draw_text(ctx, ip, mono_bold_font, 34, outer_x, top_y + 42.0, 0.43, 0.93, 0.60);

    const CGFloat info_top = top_y + 126.0;
    const CGFloat info_h = 194.0;
    tb_disp_fill_rect(ctx, outer_x, info_top, card_w, info_h, 0.14, 0.15, 0.19, 1.0);
    tb_disp_fill_rect(ctx, outer_x + card_w + card_gap, info_top, card_w, info_h, 0.14, 0.15, 0.19, 1.0);

    tb_disp_draw_text(ctx, tb_i18n_get("receiver.ui.status"), section_font, 15, outer_x + 20.0, info_top + 34.0, 0.54, 0.62, 0.76);
    tb_disp_draw_text(ctx, status, body_font, 22, outer_x + 20.0, info_top + 68.0, 0.94, 0.96, 0.99);
    tb_disp_draw_text(ctx, tb_i18n_get("receiver.ui.sender"), section_font, 14, outer_x + 20.0, info_top + 118.0, 0.54, 0.62, 0.76);
    tb_disp_draw_text(ctx, sender, body_font, 20, outer_x + 20.0, info_top + 148.0, 0.94, 0.96, 0.99);

    const CGFloat display_x = outer_x + card_w + card_gap + 20.0;
    tb_disp_draw_text(ctx, tb_i18n_get("receiver.ui.display"), section_font, 15, display_x, info_top + 34.0, 0.54, 0.62, 0.76);
    tb_disp_draw_text(ctx, panel, zh ? body_font : mono_font, 20, display_x, info_top + 68.0, 0.94, 0.96, 0.99);
    tb_disp_draw_text(ctx, tb_i18n_get("receiver.ui.stream_profile"), section_font, 14, display_x, info_top + 118.0, 0.54, 0.62, 0.76);
    tb_disp_draw_text(ctx, mode, zh ? body_font : mono_font, 20, display_x, info_top + 148.0, 0.94, 0.96, 0.99);

    const CGFloat footer_top = info_top + info_h + 28.0;
    const CGFloat footer_h = 150.0;
    tb_disp_fill_rect(ctx, outer_x, footer_top, outer_w, footer_h, 0.14, 0.15, 0.19, 1.0);

    tb_disp_draw_text(ctx, tb_i18n_get("receiver.ui.language"), section_font, 15, outer_x + 20.0, footer_top + 32.0, 0.54, 0.62, 0.76);
    tb_disp_draw_text(ctx, language, body_font, 20, outer_x + 20.0, footer_top + 64.0, 0.94, 0.96, 0.99);

    tb_disp_draw_text(ctx, tb_i18n_get("receiver.ui.permissions"), section_font, 15, outer_x + 20.0, footer_top + 102.0, 0.54, 0.62, 0.76);
    tb_disp_draw_text(ctx, permissions, body_font, 20, outer_x + 20.0, footer_top + 134.0, 0.94, 0.96, 0.99);

    tb_disp_draw_text(ctx, tb_i18n_get("receiver.ui.help_1"), body_font, 17, 72, H - 138, 0.76, 0.80, 0.88);
    tb_disp_draw_text(ctx, tb_i18n_get("receiver.ui.help_2"), body_font, 17, 72, H - 108, 0.76, 0.80, 0.88);
    tb_disp_draw_text(ctx, tb_i18n_get("receiver.ui.help_4"), body_font, 17, 72, H - 78, 0.76, 0.80, 0.88);
    }

    /* Developer aid: TB_RECEIVER_SNAPSHOT=<file.png> writes each rebuilt status
     * screen to that file, so layouts can be checked without capturing the screen. */
    const char *snapshot_path = getenv("TB_RECEIVER_SNAPSHOT");
    if (snapshot_path && *snapshot_path) {
        CGImageRef snapshot = CGBitmapContextCreateImage(ctx);
        CFStringRef path = CFStringCreateWithCString(NULL, snapshot_path, kCFStringEncodingUTF8);
        CFURLRef url = path ? CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, false) : NULL;
        CGImageDestinationRef dest = url ? CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL) : NULL;
        if (dest && snapshot) {
            CGImageDestinationAddImage(dest, snapshot, NULL);
            CGImageDestinationFinalize(dest);
        }
        if (dest) CFRelease(dest);
        if (url) CFRelease(url);
        if (path) CFRelease(path);
        if (snapshot) CGImageRelease(snapshot);
    }

    CGContextRelease(ctx);

    d->status_tex = SDL_CreateTexture(
        d->ren,
        SDL_PIXELFORMAT_ARGB8888,
        SDL_TEXTUREACCESS_STATIC,
        drawable_w,
        drawable_h
    );
    if (d->status_tex) {
        SDL_UpdateTexture(d->status_tex, NULL, pixels, (int)bytes_per_row);
        SDL_SetTextureBlendMode(d->status_tex, SDL_BLENDMODE_NONE);
    }
    free(pixels);
}

static void tb_disp_refresh_window_mode(struct tb_display *d) {
    if (!d || !d->win) return;
    const char *outer = TB_LOOP_ENTER("window: fullscreen, size, shield, pointer");

    const int monitor_shield_active =
        (d->is_connected || d->is_connecting) && d->preferred_fullscreen;

    if (monitor_shield_active) {
        SDL_SetWindowFullscreen(d->win, SDL_WINDOW_FULLSCREEN_DESKTOP);
    } else {
        SDL_SetWindowFullscreen(d->win, 0);
        SDL_SetWindowSize(d->win, 980, 620);
        SDL_SetWindowPosition(d->win, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED);
    }
    tb_receiver_set_monitor_shield(monitor_shield_active);

    const int should_hide_cursor =
        ((d->is_connected || d->is_connecting) && d->preferred_fullscreen) ||
        d->input_capture_active ||
        d->input_intercept_active;

    SDL_ShowCursor(should_hide_cursor ? SDL_DISABLE : SDL_ENABLE);
    if (should_hide_cursor && !d->system_cursor_hidden) {
        CGDisplayHideCursor(CGMainDisplayID());
        d->system_cursor_hidden = 1;
    } else if (!should_hide_cursor && d->system_cursor_hidden) {
        CGDisplayShowCursor(CGMainDisplayID());
        d->system_cursor_hidden = 0;
    }
    TB_LOOP_LEAVE(outer);
}

static SDL_Renderer *tb_disp_try_renderer(SDL_Window *win, const char *driver) {
    if (driver && driver[0] != '\0') {
        SDL_SetHint(SDL_HINT_RENDER_DRIVER, driver);
    } else {
        SDL_SetHint(SDL_HINT_RENDER_DRIVER, "");
    }

    SDL_Renderer *ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    if (!ren) {
        fprintf(stderr, "[disp] CreateRenderer(%s): %s\n",
                driver && driver[0] != '\0' ? driver : "default",
                SDL_GetError());
    }
    return ren;
}

static SDL_Renderer *tb_disp_create_accelerated_renderer(SDL_Window *win, const char *forced_driver) {
    if (forced_driver && forced_driver[0] != '\0') {
        fprintf(stderr, "[disp] renderer override = %s\n", forced_driver);
        return tb_disp_try_renderer(win, forced_driver);
    }

#if defined(__APPLE__)
    const char *macos_drivers[] = { "opengl", "metal", NULL };
    for (int i = 0; macos_drivers[i] != NULL; i++) {
        SDL_Renderer *ren = tb_disp_try_renderer(win, macos_drivers[i]);
        if (ren) return ren;
    }
#endif

    return tb_disp_try_renderer(win, NULL);
}

int tb_disp_setting(const char *env_name, const char *defaults_key, char *out, size_t size) {
    if (!out || size == 0) return 0;
    out[0] = '\0';
    const char *env = env_name ? getenv(env_name) : NULL;
    if (env) {
        snprintf(out, size, "%s", env);
        return 1;
    }
    if (!defaults_key) return 0;
    CFStringRef key = CFStringCreateWithCString(NULL, defaults_key, kCFStringEncodingUTF8);
    CFPropertyListRef value = key ? CFPreferencesCopyAppValue(key, kCFPreferencesCurrentApplication) : NULL;
    int found = 0;
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        found = CFStringGetCString((CFStringRef)value, out, (CFIndex)size, kCFStringEncodingUTF8) ? 1 : 0;
    } else if (value && CFGetTypeID(value) == CFBooleanGetTypeID()) {
        snprintf(out, size, "%s", CFBooleanGetValue((CFBooleanRef)value) ? "1" : "0");
        found = 1;
    }
    if (value) CFRelease(value);
    if (key) CFRelease(key);
    return found;
}

/* After every renderer (re)creation: colour conversion, logging, trace labels. */
static void tb_disp_setup_renderer(struct tb_display *d) {
    SDL_SetYUVConversionMode(SDL_YUV_CONVERSION_BT709);
    SDL_RenderSetLogicalSize(d->ren, 0, 0);

    /* report which backend SDL picked */
    SDL_RendererInfo info;
    memset(&info, 0, sizeof(info));
    if (SDL_GetRendererInfo(d->ren, &info) == 0) {
        fprintf(stderr, "[disp] renderer = %s%s\n", info.name,
                d->mtl ? (d->paced ? " (zero-copy video, paced to the refresh)" : " (zero-copy video)") : "");
    }
    SDL_DisplayMode mode;
    uint64_t refresh_ns = 0;
    if (d->vsync) {
        refresh_ns = tb_vsync_period_ns(d->vsync);
    } else if (SDL_GetCurrentDisplayMode(0, &mode) == 0 && mode.refresh_rate > 0) {
        refresh_ns = 1000000000ull / (uint64_t)mode.refresh_rate;
    }
    tb_trace_configure(d->mtl ? "metal-zero-copy" : info.name, d->paced ? "vsync" : "immediate", refresh_ns);
}

/* Choose and build the renderer: a local setting if there is one, else what
 * the sender asked for (`wish`: "metal" or "opengl"; NULL = OpenGL). Any
 * failure on the Metal path ends on OpenGL. */
static int tb_disp_create_renderer(struct tb_display *d, const char *wish) {
    char driver_buf[32];
    const char *driver = driver_buf;
    const int from_setting =
        tb_disp_setting("TB_RECEIVER_RENDER_DRIVER", "TBReceiverRenderDriver", driver_buf, sizeof(driver_buf));
    if (from_setting) {
        fprintf(stderr, "[disp] renderer setting = %s\n", driver);
    } else {
        snprintf(driver_buf, sizeof(driver_buf), "%s", wish && strcmp(wish, "metal") == 0 ? "metal" : "opengl");
    }
    if (strcmp(driver, "metal") == 0 && d->metal_unusable) driver = "opengl";

    if (strcmp(driver, "metal") == 0) {
        char pacing[32];
        tb_disp_setting("TB_RECEIVER_PACING", "TBReceiverPacing", pacing, sizeof(pacing));
        const int paced = strcmp(pacing, "immediate") != 0;
        if (tb_mtl_os_defaults_to_opengl()) {
            fprintf(stderr, "[disp] macOS 26 or later: upstream saw Metal flicker here (03299cb)\n");
        }
        d->ren = tb_disp_try_renderer(d->win, "metal");
        char why[256] = "SDL could not create its Metal renderer";
        if (d->ren) d->mtl = tb_mtl_create(SDL_RenderGetMetalLayer(d->ren), paced, why, sizeof(why));
        if (d->mtl && paced) {
            d->vsync = tb_vsync_create(CGMainDisplayID());
            if (!d->vsync) fprintf(stderr, "[disp] no display link: frames are drawn on arrival\n");
        }
        if (d->mtl) {
            d->paced = d->vsync != NULL;
            d->last_submit_tick = UINT64_MAX;
            d->video_submit_tick = UINT64_MAX;
            d->metal_cursor_key = 0;
            return 0;
        }
        fprintf(stderr, "[disp] Metal zero-copy unavailable (%s); falling back to OpenGL\n", why);
        d->metal_unusable = 1;
        if (d->ren) SDL_DestroyRenderer(d->ren);
        d->ren = tb_disp_create_accelerated_renderer(d->win, "opengl");
        if (!d->ren) d->ren = tb_disp_create_accelerated_renderer(d->win, NULL);
        return d->ren ? 0 : -1;
    }

    /* "metal-sdl": SDL's own Metal renderer with its copying NV12 upload. */
    if (strcmp(driver, "metal-sdl") == 0) driver = "metal";
    /* OpenGL that nobody set locally goes SDL's usual way (OpenGL first, then
     * Metal), as upstream does, rather than as an override. */
    if (strcmp(driver, "opengl") == 0 && (!from_setting || d->metal_unusable)) driver = NULL;
    d->ren = tb_disp_create_accelerated_renderer(d->win, driver);
    return d->ren ? 0 : -1;
}

struct tb_display *tb_disp_create(int fullscreen) {
    /* Best-quality scaling (linear filter; Metal backend uses bilinear
     * regardless but this sets the hint correctly). "best" enables
     * anisotropic where supported. Must be set BEFORE renderer creation. */
    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "best");

    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) < 0) {
        fprintf(stderr, "[disp] SDL_Init: %s\n", SDL_GetError());
        return NULL;
    }

    struct tb_display *d = (struct tb_display *)calloc(1, sizeof(*d));
    if (!d) return NULL;

    Uint32 flags = SDL_WINDOW_HIDDEN | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_RESIZABLE;

    d->win = SDL_CreateWindow("TargetBridge Receiver",
                              SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                              980, 620, flags);
    if (!d->win) {
        fprintf(stderr, "[disp] CreateWindow: %s\n", SDL_GetError());
        free(d); return NULL;
    }

    /* SDL starts text input with the video subsystem, so every key also went to
     * the input method: with Pinyin on, I opened a candidate bar (T36). Nothing
     * here reads text: the shortcuts and the keys relayed to the Mac are key
     * events. Off for the whole run; SDL turns it back on only when asked. */
    SDL_StopTextInput();
    fprintf(stderr, "[disp] text input %s\n", SDL_IsTextInputActive() ? "still on" : "off: keys only");

    /* The SDL renderer path has no VSYNC: it presents as fast as decode
     * produces frames. On Intel iMac with Radeon Pro 570 + 5K display, VSYNC
     * at 60Hz combined with GPU→CPU NV12 transfer was stalling the pipeline
     * to ~4 fps. The Metal path has no transfer and paces to the refresh. */
    if (tb_disp_create_renderer(d, NULL) < 0) {
        fprintf(stderr, "[disp] CreateRenderer: %s\n", SDL_GetError());
        SDL_DestroyWindow(d->win); free(d); return NULL;
    }
    tb_disp_setup_renderer(d);

    int win_w = 0, win_h = 0, out_w = 0, out_h = 0;
    SDL_GetWindowSize(d->win, &win_w, &win_h);
    if (SDL_GetRendererOutputSize(d->ren, &out_w, &out_h) == 0) {
        fprintf(stderr, "[disp] window %dx%d -> drawable %dx%d\n",
                win_w, win_h, out_w, out_h);
    }

    d->preferred_fullscreen = fullscreen;
    d->is_connected = 0;
    d->last_ip[0] = '\0';
    d->last_status[0] = '\0';
    d->last_sender[0] = '\0';
    d->last_panel[0] = '\0';
    d->last_mode[0] = '\0';
    d->last_language[0] = '\0';
    d->last_drawable_w = 0;
    d->last_drawable_h = 0;
    d->cursor_x = 0;
    d->cursor_y = 0;
    d->cursor_source_w = 1;
    d->cursor_source_h = 1;
    d->cursor_visible = 0;
    d->cursor_type = 0;
    d->system_cursor_hidden = 0;
    d->last_video_frame_time = 0;

    tb_disp_refresh_window_mode(d);
    SDL_ShowWindow(d->win);
    return d;
}

void tb_disp_destroy(struct tb_display *d) {
    if (!d) return;
    if (d->system_cursor_hidden) {
        CGDisplayShowCursor(CGMainDisplayID());
        d->system_cursor_hidden = 0;
    }
    tb_disp_destroy_status_texture(d);
    tb_disp_metal_release_frames(d);
    tb_vsync_destroy(d->vsync);
    tb_mtl_destroy(d->mtl);
    if (d->cursor_tex) SDL_DestroyTexture(d->cursor_tex);
    free(d->cursor_pixels);
    if (d->tex) SDL_DestroyTexture(d->tex);
    if (d->ren) SDL_DestroyRenderer(d->ren);
    if (d->win) SDL_DestroyWindow(d->win);
    SDL_EnableScreenSaver();
    SDL_Quit();
    free(d);
}

int tb_disp_ensure_texture(struct tb_display *d, int w, int h) {
    if (d->tex && d->tex_w == w && d->tex_h == h) return 0;
    if (d->tex) { SDL_DestroyTexture(d->tex); d->tex = NULL; }

    d->tex = SDL_CreateTexture(d->ren, SDL_PIXELFORMAT_NV12,
                               SDL_TEXTUREACCESS_STREAMING, w, h);
    if (!d->tex) {
        fprintf(stderr, "[disp] CreateTexture(NV12): %s\n", SDL_GetError());
        return -1;
    }
    d->tex_w = w;
    d->tex_h = h;
    fprintf(stderr, "[disp] texture %dx%d NV12\n", w, h);
    return 0;
}

static void tb_disp_draw_poly_outline(SDL_Renderer *ren, const SDL_Point *pts, int count) {
    if (!ren || !pts || count < 2) return;
    for (int i = 0; i < count; ++i) {
        const SDL_Point a = pts[i];
        const SDL_Point b = pts[(i + 1) % count];
        SDL_RenderDrawLine(ren, a.x, a.y, b.x, b.y);
    }
}

static void tb_disp_fill_poly(SDL_Renderer *ren, const SDL_Point *pts, int count) {
    if (!ren || !pts || count < 3) return;

    int min_y = pts[0].y;
    int max_y = pts[0].y;
    for (int i = 1; i < count; ++i) {
        if (pts[i].y < min_y) min_y = pts[i].y;
        if (pts[i].y > max_y) max_y = pts[i].y;
    }

    for (int y = min_y; y <= max_y; ++y) {
        int nodes[16];
        int node_count = 0;

        for (int i = 0, j = count - 1; i < count; j = i++) {
            const int yi = pts[i].y;
            const int yj = pts[j].y;
            if ((yi < y && yj >= y) || (yj < y && yi >= y)) {
                const int xi = pts[i].x;
                const int xj = pts[j].x;
                if (node_count < (int)(sizeof(nodes) / sizeof(nodes[0]))) {
                    nodes[node_count++] = xi + ((y - yi) * (xj - xi)) / (yj - yi);
                }
            }
        }

        for (int i = 1; i < node_count; ++i) {
            int v = nodes[i];
            int k = i - 1;
            while (k >= 0 && nodes[k] > v) {
                nodes[k + 1] = nodes[k];
                --k;
            }
            nodes[k + 1] = v;
        }

        for (int i = 0; i + 1 < node_count; i += 2) {
            SDL_RenderDrawLine(ren, nodes[i], y, nodes[i + 1], y);
        }
    }
}

static int tb_disp_cursor_scale(int size, int value) {
    return (size * value + 16) / 32;
}

static SDL_Point tb_disp_cursor_point(int x, int y, int size, int px, int py) {
    SDL_Point p = {
        x + tb_disp_cursor_scale(size, px),
        y + tb_disp_cursor_scale(size, py)
    };
    return p;
}

static void draw_scaled_rect(SDL_Renderer *ren, int cx, int cy, int size, int rx1, int ry1, int rx2, int ry2) {
    SDL_Rect r;
    int x1 = cx + tb_disp_cursor_scale(size, rx1);
    int y1 = cy + tb_disp_cursor_scale(size, ry1);
    int x2 = cx + tb_disp_cursor_scale(size, rx2);
    int y2 = cy + tb_disp_cursor_scale(size, ry2);
    r.x = x1 < x2 ? x1 : x2;
    r.y = y1 < y2 ? y1 : y2;
    r.w = x2 > x1 ? (x2 - x1) : (x1 - x2);
    r.h = y2 > y1 ? (y2 - y1) : (y1 - y2);
    if (r.w == 0) r.w = 1;
    if (r.h == 0) r.h = 1;
    SDL_RenderFillRect(ren, &r);
}

/* The pointer size the vector shapes are drawn at, in drawable pixels. */
static int tb_disp_vector_cursor_size(int out_w, int large) {
    return large ? (out_w >= 5000 ? 58 : 44) : (out_w >= 5000 ? 32 : 24);
}

/* One of the vector pointer shapes with its hot spot at (x, y), on any renderer:
 * the window's (OpenGL path) or a software one that bakes a bitmap (Metal path). */
static void tb_disp_draw_vector_cursor(SDL_Renderer *ren, int x, int y, int type, int size) {
    SDL_BlendMode old_blend = SDL_BLENDMODE_NONE;
    (void)SDL_GetRenderDrawBlendMode(ren, &old_blend);

    SDL_SetRenderDrawBlendMode(ren, SDL_BLENDMODE_BLEND);

    if (type == 1) {
        /* I-Beam (Text Cursor) */
        /* Draw Shadow */
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 70);
        int sx_off = 1, sy_off = 2;
        draw_scaled_rect(ren, x + sx_off, y + sy_off, size, -8, -14, 8, -10);
        draw_scaled_rect(ren, x + sx_off, y + sy_off, size, -8, 10, 8, 14);
        draw_scaled_rect(ren, x + sx_off, y + sy_off, size, -2, -12, 2, 12);
        
        /* Draw Outline (White) */
        SDL_SetRenderDrawColor(ren, 255, 255, 255, 255);
        draw_scaled_rect(ren, x, y, size, -8, -14, 8, -10);
        draw_scaled_rect(ren, x, y, size, -8, 10, 8, 14);
        draw_scaled_rect(ren, x, y, size, -2, -12, 2, 12);
        
        /* Draw Body (Black) */
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);
        draw_scaled_rect(ren, x, y, size, -7, -13, 7, -11);
        draw_scaled_rect(ren, x, y, size, -7, 11, 7, 13);
        draw_scaled_rect(ren, x, y, size, -1, -11, 1, 11);
    }
    else if (type == 2) {
        /* Pointing Hand */
        const int cx = x - tb_disp_cursor_scale(size, 10);
        const int cy = y;
        SDL_Point shadow[] = {
            tb_disp_cursor_point(cx + 2, cy + 3, size, 10, 0),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 13, 2),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 13, 11),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 17, 11),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 17, 15),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 16, 17),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 16, 20),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 14, 22),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 14, 24),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 11, 27),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 5, 27),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 1, 20),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 0, 16),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 3, 13),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 7, 11),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 7, 2)
        };
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 70);
        tb_disp_fill_poly(ren, shadow, (int)(sizeof(shadow) / sizeof(shadow[0])));

        SDL_Point outline[] = {
            tb_disp_cursor_point(cx, cy, size, 10, 0),
            tb_disp_cursor_point(cx, cy, size, 13, 2),
            tb_disp_cursor_point(cx, cy, size, 13, 11),
            tb_disp_cursor_point(cx, cy, size, 17, 11),
            tb_disp_cursor_point(cx, cy, size, 17, 15),
            tb_disp_cursor_point(cx, cy, size, 16, 17),
            tb_disp_cursor_point(cx, cy, size, 16, 20),
            tb_disp_cursor_point(cx, cy, size, 14, 22),
            tb_disp_cursor_point(cx, cy, size, 14, 24),
            tb_disp_cursor_point(cx, cy, size, 11, 27),
            tb_disp_cursor_point(cx, cy, size, 5, 27),
            tb_disp_cursor_point(cx, cy, size, 1, 20),
            tb_disp_cursor_point(cx, cy, size, 0, 16),
            tb_disp_cursor_point(cx, cy, size, 3, 13),
            tb_disp_cursor_point(cx, cy, size, 7, 11),
            tb_disp_cursor_point(cx, cy, size, 7, 2)
        };
        SDL_SetRenderDrawColor(ren, 255, 255, 255, 255);
        tb_disp_fill_poly(ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));
        tb_disp_draw_poly_outline(ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));

        SDL_Point body[] = {
            tb_disp_cursor_point(cx, cy, size, 10, 2),
            tb_disp_cursor_point(cx, cy, size, 12, 3),
            tb_disp_cursor_point(cx, cy, size, 12, 11),
            tb_disp_cursor_point(cx, cy, size, 15, 12),
            tb_disp_cursor_point(cx, cy, size, 15, 14),
            tb_disp_cursor_point(cx, cy, size, 14, 17),
            tb_disp_cursor_point(cx, cy, size, 14, 19),
            tb_disp_cursor_point(cx, cy, size, 12, 21),
            tb_disp_cursor_point(cx, cy, size, 12, 23),
            tb_disp_cursor_point(cx, cy, size, 10, 25),
            tb_disp_cursor_point(cx, cy, size, 6, 25),
            tb_disp_cursor_point(cx, cy, size, 3, 19),
            tb_disp_cursor_point(cx, cy, size, 2, 16),
            tb_disp_cursor_point(cx, cy, size, 4, 14),
            tb_disp_cursor_point(cx, cy, size, 8, 12),
            tb_disp_cursor_point(cx, cy, size, 8, 3)
        };
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);
        tb_disp_fill_poly(ren, body, (int)(sizeof(body) / sizeof(body[0])));
        tb_disp_draw_poly_outline(ren, body, (int)(sizeof(body) / sizeof(body[0])));
    }
    else if (type == 3) {
        /* Resize Horizontal */
        const int cx = x - tb_disp_cursor_scale(size, 16);
        const int cy = y - tb_disp_cursor_scale(size, 16);
        SDL_Point shadow[] = {
            tb_disp_cursor_point(cx + 2, cy + 3, size, 2, 16),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 8, 10),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 8, 13),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 24, 13),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 24, 10),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 30, 16),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 24, 22),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 24, 19),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 8, 19),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 8, 22)
        };
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 70);
        tb_disp_fill_poly(ren, shadow, (int)(sizeof(shadow) / sizeof(shadow[0])));

        SDL_Point outline[] = {
            tb_disp_cursor_point(cx, cy, size, 2, 16),
            tb_disp_cursor_point(cx, cy, size, 8, 10),
            tb_disp_cursor_point(cx, cy, size, 8, 13),
            tb_disp_cursor_point(cx, cy, size, 24, 13),
            tb_disp_cursor_point(cx, cy, size, 24, 10),
            tb_disp_cursor_point(cx, cy, size, 30, 16),
            tb_disp_cursor_point(cx, cy, size, 24, 22),
            tb_disp_cursor_point(cx, cy, size, 24, 19),
            tb_disp_cursor_point(cx, cy, size, 8, 19),
            tb_disp_cursor_point(cx, cy, size, 8, 22)
        };
        SDL_SetRenderDrawColor(ren, 255, 255, 255, 255);
        tb_disp_fill_poly(ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));
        tb_disp_draw_poly_outline(ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));

        SDL_Point body[] = {
            tb_disp_cursor_point(cx, cy, size, 5, 16),
            tb_disp_cursor_point(cx, cy, size, 8, 12),
            tb_disp_cursor_point(cx, cy, size, 8, 15),
            tb_disp_cursor_point(cx, cy, size, 24, 15),
            tb_disp_cursor_point(cx, cy, size, 24, 12),
            tb_disp_cursor_point(cx, cy, size, 27, 16),
            tb_disp_cursor_point(cx, cy, size, 24, 20),
            tb_disp_cursor_point(cx, cy, size, 24, 17),
            tb_disp_cursor_point(cx, cy, size, 8, 17),
            tb_disp_cursor_point(cx, cy, size, 8, 20)
        };
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);
        tb_disp_fill_poly(ren, body, (int)(sizeof(body) / sizeof(body[0])));
        tb_disp_draw_poly_outline(ren, body, (int)(sizeof(body) / sizeof(body[0])));
    }
    else if (type == 4) {
        /* Resize Vertical */
        const int cx = x - tb_disp_cursor_scale(size, 16);
        const int cy = y - tb_disp_cursor_scale(size, 16);
        SDL_Point shadow[] = {
            tb_disp_cursor_point(cx + 2, cy + 3, size, 16, 2),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 22, 8),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 19, 8),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 19, 24),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 22, 24),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 16, 30),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 10, 24),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 13, 24),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 13, 8),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 10, 8)
        };
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 70);
        tb_disp_fill_poly(ren, shadow, (int)(sizeof(shadow) / sizeof(shadow[0])));

        SDL_Point outline[] = {
            tb_disp_cursor_point(cx, cy, size, 16, 2),
            tb_disp_cursor_point(cx, cy, size, 22, 8),
            tb_disp_cursor_point(cx, cy, size, 19, 8),
            tb_disp_cursor_point(cx, cy, size, 19, 24),
            tb_disp_cursor_point(cx, cy, size, 22, 24),
            tb_disp_cursor_point(cx, cy, size, 16, 30),
            tb_disp_cursor_point(cx, cy, size, 10, 24),
            tb_disp_cursor_point(cx, cy, size, 13, 24),
            tb_disp_cursor_point(cx, cy, size, 13, 8),
            tb_disp_cursor_point(cx, cy, size, 10, 8)
        };
        SDL_SetRenderDrawColor(ren, 255, 255, 255, 255);
        tb_disp_fill_poly(ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));
        tb_disp_draw_poly_outline(ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));

        SDL_Point body[] = {
            tb_disp_cursor_point(cx, cy, size, 16, 5),
            tb_disp_cursor_point(cx, cy, size, 20, 8),
            tb_disp_cursor_point(cx, cy, size, 17, 8),
            tb_disp_cursor_point(cx, cy, size, 17, 24),
            tb_disp_cursor_point(cx, cy, size, 20, 24),
            tb_disp_cursor_point(cx, cy, size, 16, 27),
            tb_disp_cursor_point(cx, cy, size, 12, 24),
            tb_disp_cursor_point(cx, cy, size, 15, 24),
            tb_disp_cursor_point(cx, cy, size, 15, 8),
            tb_disp_cursor_point(cx, cy, size, 12, 8)
        };
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);
        tb_disp_fill_poly(ren, body, (int)(sizeof(body) / sizeof(body[0])));
        tb_disp_draw_poly_outline(ren, body, (int)(sizeof(body) / sizeof(body[0])));
    }
    else if (type == 6) {
        /* Crosshair */
        /* Draw Shadow */
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 70);
        int sx_off = 1, sy_off = 2;
        draw_scaled_rect(ren, x + sx_off, y + sy_off, size, -15, -2, -2, 2);
        draw_scaled_rect(ren, x + sx_off, y + sy_off, size, 2, -2, 15, 2);
        draw_scaled_rect(ren, x + sx_off, y + sy_off, size, -2, -15, 2, -2);
        draw_scaled_rect(ren, x + sx_off, y + sy_off, size, -2, 2, 2, 15);
        
        /* Draw Outline (White) */
        SDL_SetRenderDrawColor(ren, 255, 255, 255, 255);
        draw_scaled_rect(ren, x, y, size, -15, -2, -2, 2);
        draw_scaled_rect(ren, x, y, size, 2, -2, 15, 2);
        draw_scaled_rect(ren, x, y, size, -2, -15, 2, -2);
        draw_scaled_rect(ren, x, y, size, -2, 2, 2, 15);
        
        /* Draw Body (Black) */
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);
        draw_scaled_rect(ren, x, y, size, -14, -1, -3, 1);
        draw_scaled_rect(ren, x, y, size, 3, -1, 14, 1);
        draw_scaled_rect(ren, x, y, size, -1, -14, 1, -3);
        draw_scaled_rect(ren, x, y, size, -1, 3, 1, 14);
    }
    else if (type == 7) {
        /* Northwest-Southeast diagonal resize cursor (NWSE) */
        const int cx = x - tb_disp_cursor_scale(size, 16);
        const int cy = y - tb_disp_cursor_scale(size, 16);
        SDL_Point shadow[] = {
            tb_disp_cursor_point(cx + 2, cy + 3, size, 4, 4),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 12, 4),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 10, 7),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 22, 19),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 28, 20),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 28, 28),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 20, 28),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 22, 25),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 10, 13),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 4, 12)
        };
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 70);
        tb_disp_fill_poly(ren, shadow, (int)(sizeof(shadow) / sizeof(shadow[0])));

        SDL_Point outline[] = {
            tb_disp_cursor_point(cx, cy, size, 4, 4),
            tb_disp_cursor_point(cx, cy, size, 12, 4),
            tb_disp_cursor_point(cx, cy, size, 10, 7),
            tb_disp_cursor_point(cx, cy, size, 22, 19),
            tb_disp_cursor_point(cx, cy, size, 28, 20),
            tb_disp_cursor_point(cx, cy, size, 28, 28),
            tb_disp_cursor_point(cx, cy, size, 20, 28),
            tb_disp_cursor_point(cx, cy, size, 22, 25),
            tb_disp_cursor_point(cx, cy, size, 10, 13),
            tb_disp_cursor_point(cx, cy, size, 4, 12)
        };
        SDL_SetRenderDrawColor(ren, 255, 255, 255, 255);
        tb_disp_fill_poly(ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));
        tb_disp_draw_poly_outline(ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));

        SDL_Point body[] = {
            tb_disp_cursor_point(cx, cy, size, 7, 7),
            tb_disp_cursor_point(cx, cy, size, 12, 7),
            tb_disp_cursor_point(cx, cy, size, 10, 9),
            tb_disp_cursor_point(cx, cy, size, 21, 20),
            tb_disp_cursor_point(cx, cy, size, 25, 20),
            tb_disp_cursor_point(cx, cy, size, 25, 25),
            tb_disp_cursor_point(cx, cy, size, 20, 25),
            tb_disp_cursor_point(cx, cy, size, 22, 23),
            tb_disp_cursor_point(cx, cy, size, 11, 12),
            tb_disp_cursor_point(cx, cy, size, 7, 12)
        };
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);
        tb_disp_fill_poly(ren, body, (int)(sizeof(body) / sizeof(body[0])));
        tb_disp_draw_poly_outline(ren, body, (int)(sizeof(body) / sizeof(body[0])));
    }
    else if (type == 8) {
        /* Northeast-Southwest diagonal resize cursor (NESW) */
        const int cx = x - tb_disp_cursor_scale(size, 16);
        const int cy = y - tb_disp_cursor_scale(size, 16);
        SDL_Point shadow[] = {
            tb_disp_cursor_point(cx + 2, cy + 3, size, 28, 4),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 20, 4),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 22, 7),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 10, 19),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 4, 20),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 4, 28),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 12, 28),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 10, 25),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 22, 13),
            tb_disp_cursor_point(cx + 2, cy + 3, size, 28, 12)
        };
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 70);
        tb_disp_fill_poly(ren, shadow, (int)(sizeof(shadow) / sizeof(shadow[0])));

        SDL_Point outline[] = {
            tb_disp_cursor_point(cx, cy, size, 28, 4),
            tb_disp_cursor_point(cx, cy, size, 20, 4),
            tb_disp_cursor_point(cx, cy, size, 22, 7),
            tb_disp_cursor_point(cx, cy, size, 10, 19),
            tb_disp_cursor_point(cx, cy, size, 4, 20),
            tb_disp_cursor_point(cx, cy, size, 4, 28),
            tb_disp_cursor_point(cx, cy, size, 12, 28),
            tb_disp_cursor_point(cx, cy, size, 10, 25),
            tb_disp_cursor_point(cx, cy, size, 22, 13),
            tb_disp_cursor_point(cx, cy, size, 28, 12)
        };
        SDL_SetRenderDrawColor(ren, 255, 255, 255, 255);
        tb_disp_fill_poly(ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));
        tb_disp_draw_poly_outline(ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));

        SDL_Point body[] = {
            tb_disp_cursor_point(cx, cy, size, 25, 7),
            tb_disp_cursor_point(cx, cy, size, 20, 7),
            tb_disp_cursor_point(cx, cy, size, 22, 9),
            tb_disp_cursor_point(cx, cy, size, 11, 20),
            tb_disp_cursor_point(cx, cy, size, 7, 20),
            tb_disp_cursor_point(cx, cy, size, 7, 25),
            tb_disp_cursor_point(cx, cy, size, 12, 25),
            tb_disp_cursor_point(cx, cy, size, 10, 23),
            tb_disp_cursor_point(cx, cy, size, 21, 12),
            tb_disp_cursor_point(cx, cy, size, 25, 12)
        };
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);
        tb_disp_fill_poly(ren, body, (int)(sizeof(body) / sizeof(body[0])));
        tb_disp_draw_poly_outline(ren, body, (int)(sizeof(body) / sizeof(body[0])));
    }
    else {
        /* Default: Arrow (Type 0, 5, or fallback) */
        SDL_Point shadow[] = {
            tb_disp_cursor_point(x + 2, y + 3, size, 0, 0),
            tb_disp_cursor_point(x + 2, y + 3, size, 0, 33),
            tb_disp_cursor_point(x + 2, y + 3, size, 7, 25),
            tb_disp_cursor_point(x + 2, y + 3, size, 13, 38),
            tb_disp_cursor_point(x + 2, y + 3, size, 20, 35),
            tb_disp_cursor_point(x + 2, y + 3, size, 14, 22),
            tb_disp_cursor_point(x + 2, y + 3, size, 24, 22)
        };
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 70);
        tb_disp_fill_poly(ren, shadow, (int)(sizeof(shadow) / sizeof(shadow[0])));

        SDL_Point outline[] = {
            tb_disp_cursor_point(x, y, size, 0, 0),
            tb_disp_cursor_point(x, y, size, 0, 33),
            tb_disp_cursor_point(x, y, size, 7, 25),
            tb_disp_cursor_point(x, y, size, 13, 38),
            tb_disp_cursor_point(x, y, size, 20, 35),
            tb_disp_cursor_point(x, y, size, 14, 22),
            tb_disp_cursor_point(x, y, size, 24, 22)
        };
        SDL_SetRenderDrawColor(ren, 255, 255, 255, 255);
        tb_disp_fill_poly(ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));
        tb_disp_draw_poly_outline(ren, outline, (int)(sizeof(outline) / sizeof(outline[0])));

        SDL_Point body[] = {
            tb_disp_cursor_point(x, y, size, 3, 5),
            tb_disp_cursor_point(x, y, size, 3, 27),
            tb_disp_cursor_point(x, y, size, 8, 21),
            tb_disp_cursor_point(x, y, size, 14, 34),
            tb_disp_cursor_point(x, y, size, 16, 33),
            tb_disp_cursor_point(x, y, size, 11, 20),
            tb_disp_cursor_point(x, y, size, 19, 20)
        };
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);
        tb_disp_fill_poly(ren, body, (int)(sizeof(body) / sizeof(body[0])));
        tb_disp_draw_poly_outline(ren, body, (int)(sizeof(body) / sizeof(body[0])));
    }

    SDL_SetRenderDrawBlendMode(ren, old_blend);
}

/* Where the sender's pointer picture goes on an out_w x out_h drawable: its
 * hot spot on the pointer position, its size as on the video frame, twice that
 * with "Large cursor". 0 when there is no picture. */
static int tb_disp_cursor_image_rect(const struct tb_display *d, int out_w, int out_h,
                                     float *x, float *y, float *w, float *h) {
    if (!d->cursor_pixels || d->cursor_img_w <= 0 || d->cursor_img_h <= 0) return 0;
    const double sx = (double)out_w / (double)d->cursor_source_w;
    const double sy = (double)out_h / (double)d->cursor_source_h;
    const double scale = d->cursor_large ? 2.0 : 1.0;
    const double dw = (double)d->cursor_frame_w * sx * scale;
    const double dh = (double)d->cursor_frame_h * sy * scale;
    *w = (float)dw;
    *h = (float)dh;
    *x = (float)((double)d->cursor_x * sx - (double)d->cursor_hot_x * dw / (double)d->cursor_img_w);
    *y = (float)((double)d->cursor_y * sy - (double)d->cursor_hot_y * dh / (double)d->cursor_img_h);
    return 1;
}

/* The picture on the SDL renderer, as a premultiplied-alpha texture. */
static void tb_disp_draw_cursor_image(struct tb_display *d, int out_w, int out_h) {
    if (!d->cursor_tex) {
        d->cursor_tex = SDL_CreateTexture(d->ren, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STATIC,
                                          d->cursor_img_w, d->cursor_img_h);
        if (!d->cursor_tex) return;
        SDL_UpdateTexture(d->cursor_tex, NULL, d->cursor_pixels, d->cursor_img_w * 4);
        SDL_BlendMode premultiplied = SDL_ComposeCustomBlendMode(
            SDL_BLENDFACTOR_ONE, SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, SDL_BLENDOPERATION_ADD,
            SDL_BLENDFACTOR_ONE, SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, SDL_BLENDOPERATION_ADD);
        if (SDL_SetTextureBlendMode(d->cursor_tex, premultiplied) < 0) {
            SDL_SetTextureBlendMode(d->cursor_tex, SDL_BLENDMODE_BLEND);
        }
        SDL_SetTextureScaleMode(d->cursor_tex, SDL_ScaleModeLinear);
    }
    SDL_FRect dst;
    if (tb_disp_cursor_image_rect(d, out_w, out_h, &dst.x, &dst.y, &dst.w, &dst.h)) {
        SDL_RenderCopyF(d->ren, d->cursor_tex, NULL, &dst);
    }
}

static void tb_disp_draw_cursor(struct tb_display *d) {
    if (!d || !d->cursor_visible || d->cursor_source_w <= 0 || d->cursor_source_h <= 0) return;

    int out_w = 0, out_h = 0;
    if (SDL_GetRendererOutputSize(d->ren, &out_w, &out_h) < 0 || out_w <= 0 || out_h <= 0) {
        return;
    }
    if (d->cursor_pixels) {
        tb_disp_draw_cursor_image(d, out_w, out_h);
        return;
    }

    const double sx = (double)out_w / (double)d->cursor_source_w;
    const double sy = (double)out_h / (double)d->cursor_source_h;
    const int x = (int)((double)d->cursor_x * sx);
    const int y = (int)((double)d->cursor_y * sy);
    tb_disp_draw_vector_cursor(d->ren, x, y, d->cursor_type, tb_disp_vector_cursor_size(out_w, d->cursor_large));
}

static void tb_disp_render_current(struct tb_display *d, uint32_t trace_id) {
    if (!d || !d->tex) return;
    SDL_RenderClear(d->ren);
    SDL_RenderCopy(d->ren, d->tex, NULL, NULL);
    tb_disp_draw_cursor(d);
    tb_trace_mark_now(trace_id, TB_TRACE_SUBMITTED);
    const char *outer = TB_LOOP_ENTER("draw: SDL_RenderPresent (video)");
    SDL_RenderPresent(d->ren);
    TB_LOOP_LEAVE(outer);
    /* No vsync on this path: this is the hand-off to the window server. */
    tb_trace_mark_now(trace_id, TB_TRACE_PRESENTED);
    d->last_cursor_render_time = SDL_GetTicks();
    d->cursor_dirty = 0;
}

/* SDL renderer path (OpenGL by default; also metal-sdl for comparison): the
 * planes go through the CPU into an SDL NV12 texture and the frame is
 * presented as soon as it arrives, as upstream does. */
static void tb_disp_sdl_show_frame(struct tb_display *d, const struct tb_frame *f) {
    if (tb_disp_ensure_texture(d, f->width, f->height) < 0) return;

    const uint8_t *y = f->y, *uv = f->uv;
    int y_stride = f->y_stride, uv_stride = f->uv_stride;
    CVPixelBufferRef pb = (CVPixelBufferRef)f->pixel_buffer;
    if (pb) {
        /* Locking the IOSurface lets the CPU read the planes in place; SDL
         * then copies them into its texture. */
        if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;
        y = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
        y_stride = (int)CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
        uv = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
        uv_stride = (int)CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    }
    int updated = y && uv && SDL_UpdateNVTexture(d->tex, NULL, y, y_stride, uv, uv_stride) == 0;
    if (pb) CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (!updated) {
        fprintf(stderr, "[disp] UpdateNVTexture: %s\n", SDL_GetError());
        return;
    }
    tb_trace_mark_now(f->trace_id, TB_TRACE_TEX_READY);
    d->last_video_frame_time = SDL_GetTicks();
    tb_disp_render_current(d, f->trace_id);
}

/* ---- Metal zero-copy path (PWE 1.1) ------------------------------------
 *
 * Pacing: at most one submit per display refresh, and the newest frame wins.
 * A frame that arrives while this refresh is still free is drawn at once (it
 * shows at the next refresh); one that arrives after waits in `pending` and is
 * drawn at the next refresh tick, replaced if a newer one comes first. The
 * pointer rides on video frames while video flows; when it does not, the
 * pointer is redrawn on its own, once per refresh. */

static uint64_t tb_disp_now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

/* PWE (1.1.1): start the refresh ticks on the display the window is on. If
 * CoreVideo will not start the link, pacing would wait on ticks that never
 * come: draw on arrival instead (as with no display link at all), and pace
 * again when a later start succeeds. */
static void tb_disp_start_vsync(struct tb_display *d) {
    if (!d->vsync) return;
    tb_vsync_set_display(d->vsync, d->mtl ? tb_mtl_display_id(d->mtl) : 0);
    const int err = tb_vsync_start(d->vsync);
    if (err && d->paced) {
        fprintf(stderr, "[disp] display link did not start (CVReturn %d): frames are drawn on arrival\n", err);
    } else if (!err && !d->paced) {
        fprintf(stderr, "[disp] display link running again: frames paced to the refresh\n");
    }
    d->paced = err == 0;
}

static uint64_t tb_disp_tick_count(const struct tb_display *d) {
    return d->vsync ? tb_vsync_count(d->vsync) : 0;
}

static int tb_disp_metal_slot_free(const struct tb_display *d) {
    if (!d->paced) return 1;
    if (tb_disp_tick_count(d) != d->last_submit_tick) return 1;
    /* No refresh ticks (display link stopped, display asleep): do not stall.
     * PWE (1.1.1): wait one and a half refresh periods, not a fixed 50 ms
     * (three refreshes at 60 Hz). */
    return tb_disp_now_ns() - d->last_submit_ns > tb_vsync_period_ns(d->vsync) * 3 / 2;
}

/* Whether a moved pointer should wait for the next video frame instead of
 * being drawn on its own. Paced: while frames came in this refresh or the
 * last one. Unpaced: as the OpenGL path, within 40 ms of a frame, and at most
 * one pointer-only draw per 16 ms. */
static int tb_disp_metal_defer_pointer(const struct tb_display *d) {
    if (!d->paced) {
        const uint32_t now = SDL_GetTicks();
        return now - d->last_video_frame_time <= 40 || now - d->last_cursor_render_time < 16;
    }
    return d->video_submit_tick != UINT64_MAX && d->video_submit_tick + 1 >= tb_disp_tick_count(d);
}

static void tb_disp_metal_release_frames(struct tb_display *d) {
    if (d->pending) {
        tb_trace_frame_replaced(d->pending_trace_id);
        CVPixelBufferRelease(d->pending);
        d->pending = NULL;
    }
    d->pending_trace_id = 0;
    if (d->current) CVPixelBufferRelease(d->current);
    d->current = NULL;
}

static void tb_disp_sdl_show_frame(struct tb_display *d, const struct tb_frame *f);

/* Tear the renderer down and build it again for `wish` (see
 * tb_disp_create_renderer). SDL recreates the window for the other kind of
 * context; nothing here caches it. The newest picture is kept: with a still
 * desktop no new frame may come. 0, or -1 when no renderer could be made. */
static int tb_disp_rebuild_renderer(struct tb_display *d, const char *wish) {
    const char *outer = TB_LOOP_ENTER("renderer: tear down and rebuild");
    CVPixelBufferRef keep = d->pending ? d->pending : d->current;
    if (keep) CVPixelBufferRetain(keep);
    tb_disp_metal_release_frames(d);
    tb_mtl_destroy(d->mtl);
    d->mtl = NULL;
    tb_vsync_destroy(d->vsync);
    d->vsync = NULL;
    d->paced = 0;
    d->copy_frames = 0;
    d->frame_checked = 0;
    d->logged_first_metal_frame = 0;
    tb_disp_destroy_status_texture(d);
    if (d->cursor_tex) SDL_DestroyTexture(d->cursor_tex);
    d->cursor_tex = NULL;
    if (d->tex) SDL_DestroyTexture(d->tex);
    d->tex = NULL;
    d->tex_w = d->tex_h = 0;
    d->last_drawable_w = d->last_drawable_h = 0;
    SDL_DestroyRenderer(d->ren);
    d->ren = NULL;
    if (tb_disp_create_renderer(d, wish) < 0 || !d->ren) {
        fprintf(stderr, "[disp] no renderer after the change; quitting\n");
        if (keep) CVPixelBufferRelease(keep);
        d->quit = 1;
        TB_LOOP_LEAVE(outer);
        return -1;
    }
    tb_disp_setup_renderer(d);
    tb_disp_refresh_window_mode(d);
    if (d->mtl && d->is_connected) tb_disp_start_vsync(d);
    if (keep) {
        struct tb_frame f = {
            .width = (int)CVPixelBufferGetWidth(keep),
            .height = (int)CVPixelBufferGetHeight(keep),
            .pixel_buffer = keep,
        };
        if (d->is_connected) tb_disp_show_frame(d, &f);
        CVPixelBufferRelease(keep);
    }
    TB_LOOP_LEAVE(outer);
    return 0;
}

/* Drop the Metal path for the rest of this run and draw with OpenGL. */
static void tb_disp_fall_back_to_opengl(struct tb_display *d, const char *why) {
    fprintf(stderr, "[disp] Metal zero-copy failed (%s); falling back to OpenGL\n", why);
    d->metal_unusable = 1;
    (void)tb_disp_rebuild_renderer(d, "opengl");
}

void tb_disp_use_renderer(struct tb_display *d, const char *wish) {
    if (!d) return;
    const int want_metal = wish && strcmp(wish, "metal") == 0;
    char setting[32];
    if (tb_disp_setting("TB_RECEIVER_RENDER_DRIVER", "TBReceiverRenderDriver", setting, sizeof(setting))) {
        fprintf(stderr, "[disp] the Mac asks for %s; the local renderer setting (%s) stays\n",
                want_metal ? "Metal" : "OpenGL", setting);
        return;
    }
    if (want_metal && d->metal_unusable) {
        fprintf(stderr, "[disp] the Mac asks for Metal; it failed earlier in this run, so OpenGL stays\n");
        return;
    }
    if (want_metal == (d->mtl != NULL)) return;
    fprintf(stderr, "[disp] the Mac asks for %s: switching the renderer\n", want_metal ? "Metal" : "OpenGL");
    (void)tb_disp_rebuild_renderer(d, want_metal ? "metal" : "opengl");
}

/* The vector pointer, rasterised once per shape and size with SDL's software
 * renderer into a premultiplied bitmap for the Metal path. */
static int tb_disp_metal_vector_cursor(struct tb_display *d, int type, int size, int *hot) {
    const int canvas = size * 2 + 16;
    *hot = size * 5 / 8 + 8;
    const uint64_t key = (2ull << 40) | ((uint64_t)(uint32_t)type << 16) | (uint64_t)(uint32_t)size;
    if (d->metal_cursor_key == key) return canvas;

    SDL_Surface *surface = SDL_CreateRGBSurfaceWithFormat(0, canvas, canvas, 32, SDL_PIXELFORMAT_ARGB8888);
    SDL_Renderer *soft = surface ? SDL_CreateSoftwareRenderer(surface) : NULL;
    if (!soft) {
        if (surface) SDL_FreeSurface(surface);
        return 0;
    }
    SDL_SetRenderDrawBlendMode(soft, SDL_BLENDMODE_NONE);
    SDL_SetRenderDrawColor(soft, 0, 0, 0, 0);
    SDL_RenderClear(soft);
    tb_disp_draw_vector_cursor(soft, *hot, *hot, type, size);
    SDL_RenderPresent(soft);
    SDL_DestroyRenderer(soft);

    /* ARGB8888 is B, G, R, A in memory; premultiply for the blend. */
    uint8_t *px = (uint8_t *)surface->pixels;
    for (int row = 0; row < canvas; row++) {
        uint8_t *p = px + (size_t)row * (size_t)surface->pitch;
        for (int col = 0; col < canvas; col++, p += 4) {
            const unsigned a = p[3];
            p[0] = (uint8_t)((p[0] * a + 127) / 255);
            p[1] = (uint8_t)((p[1] * a + 127) / 255);
            p[2] = (uint8_t)((p[2] * a + 127) / 255);
        }
    }
    tb_mtl_set_cursor_bitmap(d->mtl, px, canvas, canvas, surface->pitch);
    SDL_FreeSurface(surface);
    d->metal_cursor_key = key;
    return canvas;
}

/* Where the pointer goes on the drawable; 0 when it is not shown. */
static int tb_disp_metal_cursor_rect(struct tb_display *d, struct tb_mtl_rect *rect) {
    if (!d->cursor_visible || d->cursor_source_w <= 0 || d->cursor_source_h <= 0) return 0;
    int out_w = 0, out_h = 0;
    tb_mtl_drawable_size(d->mtl, &out_w, &out_h);
    if (out_w <= 0 || out_h <= 0) return 0;
    if (d->cursor_pixels) {
        const uint64_t key = (1ull << 40) | d->cursor_img_id;
        if (d->metal_cursor_key != key) {
            tb_mtl_set_cursor_bitmap(d->mtl, d->cursor_pixels, d->cursor_img_w, d->cursor_img_h, d->cursor_img_w * 4);
            d->metal_cursor_key = key;
        }
        return tb_disp_cursor_image_rect(d, out_w, out_h, &rect->x, &rect->y, &rect->w, &rect->h);
    }
    const double sx = (double)out_w / (double)d->cursor_source_w;
    const double sy = (double)out_h / (double)d->cursor_source_h;
    const int x = (int)((double)d->cursor_x * sx);
    const int y = (int)((double)d->cursor_y * sy);
    int hot = 0;
    const int canvas = tb_disp_metal_vector_cursor(d, d->cursor_type,
                                                   tb_disp_vector_cursor_size(out_w, d->cursor_large), &hot);
    if (canvas <= 0) return 0;
    rect->x = (float)(x - hot);
    rect->y = (float)(y - hot);
    rect->w = (float)canvas;
    rect->h = (float)canvas;
    return 1;
}

static void tb_disp_metal_render(struct tb_display *d) {
    if (!tb_mtl_ready(d->mtl)) {
        /* Covered window, or enough frames queued: try again next refresh.
         * A waiting frame stays waiting (and may still be replaced). */
        d->redraw_needed = 1;
        d->last_submit_tick = tb_disp_tick_count(d);
        d->last_submit_ns = tb_disp_now_ns();
        return;
    }
    uint32_t trace_id = 0;
    const int new_frame = d->pending != NULL;
    if (new_frame) {
        if (d->current) CVPixelBufferRelease(d->current);
        d->current = d->pending;
        trace_id = d->pending_trace_id;
        d->pending = NULL;
        d->pending_trace_id = 0;
    }
    if (!d->current) return;

    struct tb_mtl_rect cursor;
    const int has_cursor = tb_disp_metal_cursor_rect(d, &cursor);
    enum tb_mtl_draw_result r = tb_mtl_draw(d->mtl, d->current, has_cursor ? &cursor : NULL, trace_id);
    if (r == TB_MTL_TEXTURE_FAILED && !d->copy_frames) {
        /* This Mac's decoder buffers cannot be textured: copy each one into a
         * Metal-compatible buffer instead (one memcpy, like the OpenGL path). */
        CVPixelBufferRef copy = tb_mtl_copy_buffer(d->mtl, d->current);
        if (copy) {
            fprintf(stderr, "[disp] decoder buffers are not Metal textures here; copying each frame\n");
            d->copy_frames = 1;
            CVPixelBufferRelease(d->current);
            d->current = copy;
            r = tb_mtl_draw(d->mtl, d->current, has_cursor ? &cursor : NULL, trace_id);
        }
    }
    if (r == TB_MTL_TEXTURE_FAILED) {
        tb_disp_fall_back_to_opengl(d, "a decoded frame did not become a Metal texture");
        return;
    }
    if (r == TB_MTL_NO_DRAWABLE) {
        tb_trace_frame_replaced(trace_id);   /* never reached the screen */
        d->redraw_needed = 1;
        return;
    }
    d->last_submit_tick = tb_disp_tick_count(d);
    d->last_submit_ns = tb_disp_now_ns();
    d->last_cursor_render_time = SDL_GetTicks();
    if (new_frame) {
        d->video_submit_tick = d->last_submit_tick;
        d->new_frame_since_tick = 1;
    }
    d->cursor_dirty = 0;
    d->redraw_needed = 0;
}

/* Take a decoded frame for the Metal path. On return d->mtl is NULL if the
 * path fell back to OpenGL and the caller must show `f` there. */
static void tb_disp_metal_take_frame(struct tb_display *d, const struct tb_frame *f) {
    CVPixelBufferRef pb = NULL;
    if (f->pixel_buffer && !d->copy_frames) {
        pb = CVPixelBufferRetain((CVPixelBufferRef)f->pixel_buffer);
    } else if (f->pixel_buffer) {
        pb = tb_mtl_copy_buffer(d->mtl, (CVPixelBufferRef)f->pixel_buffer);
    } else {
        pb = tb_mtl_copy_planes(d->mtl, f->y, f->y_stride, f->uv, f->uv_stride, f->width, f->height);
    }
    if (pb && !d->frame_checked) {
        /* The first frame of a session must become a texture, visible window
         * or not: if the decoder's buffers cannot, copy them; if not even a
         * copy can, give up on Metal now rather than at the first draw. */
        d->frame_checked = 1;
        if (!tb_mtl_can_texture(d->mtl, pb) && !d->copy_frames) {
            CVPixelBufferRef copy = tb_mtl_copy_buffer(d->mtl, pb);
            CVPixelBufferRelease(pb);
            pb = copy;
            if (pb) {
                fprintf(stderr, "[disp] decoder buffers are not Metal textures here; copying each frame\n");
                d->copy_frames = 1;
            }
        }
        if (pb && !tb_mtl_can_texture(d->mtl, pb)) {
            CVPixelBufferRelease(pb);
            tb_disp_fall_back_to_opengl(d, "a decoded frame did not become a Metal texture");
            return;
        }
    }
    if (!pb) {
        tb_disp_fall_back_to_opengl(d, "a frame could not be put into an IOSurface buffer");
        return;
    }
    if (d->pending) {
        tb_trace_frame_replaced(d->pending_trace_id);
        CVPixelBufferRelease(d->pending);
    }
    d->pending = pb;
    d->pending_trace_id = f->trace_id;
    d->last_video_frame_time = SDL_GetTicks();
    if (!d->logged_first_metal_frame) {
        d->logged_first_metal_frame = 1;
        fprintf(stderr, "[disp] Metal zero-copy: first frame %dx%d %s\n", f->width, f->height,
                f->pixel_buffer && !d->copy_frames ? "(IOSurface, no copy)" : "(copied into an IOSurface)");
    }
    if (tb_disp_metal_slot_free(d)) tb_disp_metal_render(d);
}

void tb_disp_show_frame(struct tb_display *d, const struct tb_frame *f) {
    if (!d || !f || f->width <= 0 || f->height <= 0) return;
    tb_disp_set_connection_state(d, 1);
    if (d->mtl) {
        tb_disp_metal_take_frame(d, f);
        if (d->mtl) return;
    }
    tb_disp_sdl_show_frame(d, f);
}

void tb_disp_tick(struct tb_display *d) {
    if (!d || !d->is_connected) return;
    if (d->mtl) {
        const uint64_t n = tb_disp_tick_count(d);
        if (d->vsync && n != d->last_seen_tick) {
            /* Refreshes during a stream that brought no new frame. */
            if (d->last_seen_tick != 0 && n > d->last_seen_tick &&
                SDL_GetTicks() - d->last_video_frame_time < 250) {
                uint64_t missed = n - d->last_seen_tick - (d->new_frame_since_tick ? 1 : 0);
                tb_trace_repeat((unsigned)missed);
            }
            d->last_seen_tick = n;
            d->new_frame_since_tick = 0;
        }
        if (!tb_disp_metal_slot_free(d)) return;
        if (d->pending ||
            d->redraw_needed ||
            (d->cursor_dirty && !tb_disp_metal_defer_pointer(d))) {
            tb_disp_metal_render(d);
        }
        return;
    }
    /* SDL path: a pointer that moved while no video arrived, at most once a refresh. */
    if (d->cursor_dirty && d->tex) {
        const uint32_t now = SDL_GetTicks();
        if (now - d->last_video_frame_time > 40 && now - d->last_cursor_render_time >= 16) {
            tb_disp_render_current(d, 0);
        }
    }
}

void tb_disp_set_cursor(struct tb_display *d,
                        int x, int y,
                        int source_w, int source_h,
                        int visible,
                        int type,
                        int large) {
    if (!d) return;
    d->cursor_x = x;
    d->cursor_y = y;
    d->cursor_source_w = source_w > 0 ? source_w : 1;
    d->cursor_source_h = source_h > 0 ? source_h : 1;
    d->cursor_visible = visible;
    d->cursor_type = type;
    d->cursor_large = large;
    d->cursor_dirty = 1;

    if (d->mtl) {
        if (d->is_connected && !tb_disp_metal_defer_pointer(d) && tb_disp_metal_slot_free(d)) {
            tb_disp_metal_render(d);
        }
        return;
    }

    uint32_t now = SDL_GetTicks();
    if (now - d->last_video_frame_time > 40 && now - d->last_cursor_render_time >= 16) {
        if (d->is_connected && d->tex) {
            tb_disp_render_current(d, 0);
        }
    }
}

void tb_disp_set_cursor_image(struct tb_display *d, const struct tb_cursor_image *image) {
    if (!d) return;
    if (image && !d->cursor_pixels) {
        fprintf(stderr, "[disp] the sender's pointer picture arrived (%dx%d): this receiver draws the pointer\n",
                image->width, image->height);
    }
    if (d->cursor_tex) SDL_DestroyTexture(d->cursor_tex);
    d->cursor_tex = NULL;
    d->metal_cursor_key = 0;
    free(d->cursor_pixels);
    d->cursor_pixels = NULL;
    d->cursor_img_w = d->cursor_img_h = 0;
    if (image) {
        const size_t bytes = (size_t)image->width * (size_t)image->height * 4u;
        d->cursor_pixels = (uint8_t *)malloc(bytes);
        if (d->cursor_pixels) {
            memcpy(d->cursor_pixels, image->bgra, bytes);
            d->cursor_img_w = image->width;
            d->cursor_img_h = image->height;
            d->cursor_hot_x = image->hot_x;
            d->cursor_hot_y = image->hot_y;
            d->cursor_frame_w = image->frame_width;
            d->cursor_frame_h = image->frame_height;
            d->cursor_img_id = image->id;
        }
    }
    d->cursor_dirty = 1;
}

/* A fresh press of a shortcut key with no Command, Control or Option: holding
 * a key must not repeat a toggle, and Cmd-A or Ctrl-L are not these commands.
 * Key events only, never text input, which an input method takes first (T36).
 * The key is the one the layout labels with the letter (`sym`), so an AZERTY A
 * is A; on a layout whose key types no Latin letter (Cyrillic, Greek) the key
 * in the letter's physical place (`scancode`) counts instead. */
static int tb_disp_is_shortcut(const SDL_Event *ev, SDL_Keycode sym, SDL_Scancode scancode) {
    if (ev->type != SDL_KEYDOWN || ev->key.repeat) return 0;
    if (ev->key.keysym.mod & (KMOD_GUI | KMOD_CTRL | KMOD_ALT)) return 0;
    const SDL_Keycode got = ev->key.keysym.sym;
    if (got == sym) return 1;
    return !(got >= SDLK_a && got <= SDLK_z) && ev->key.keysym.scancode == scancode;
}

/* Esc on the receiver's own screens. Upstream quits at once; the PWE build
 * quits on a second press within 2 s, and the first press puts the hint on
 * screen. While the Mac's picture is up there is nowhere to show the hint, so
 * Esc does nothing there (T36); Command-Q and the window's close button quit. */
static void tb_disp_escape(struct tb_display *d) {
#if TB_RECEIVER_COMPACT_IDLE
    if (d->is_connected) return;
    if (tb_disp_quit_hint(d)) {
        fprintf(stderr, "[disp] quit: Esc pressed twice\n");
        d->quit = 1;
        return;
    }
    d->quit_armed_until = SDL_GetTicks64() + TB_DISP_QUIT_CONFIRM_MS;
    fprintf(stderr, "[disp] Esc: press again within 2 s to quit\n");
#else
    fprintf(stderr, "[disp] quit: Esc\n");
    d->quit = 1;
#endif
}

unsigned int tb_disp_poll_actions(struct tb_display *d) {
    unsigned int actions = TB_DISP_ACTION_NONE;
    SDL_Event ev;
    while (SDL_PollEvent(&ev)) {
        const int idle = !d->is_connected && !d->is_connecting;
        const int own_keys = !d->input_capture_active && !d->input_intercept_active;
        if (ev.type == SDL_QUIT) {
            fprintf(stderr, "[disp] quit: Command-Q, the close button or a signal\n");
            d->quit = 1;
        }
        /* PWE (1.1.1): the window moved to another display: tick with that one. */
        else if (ev.type == SDL_WINDOWEVENT && ev.window.event == SDL_WINDOWEVENT_DISPLAY_CHANGED) {
            if (d->vsync && d->mtl) tb_vsync_set_display(d->vsync, tb_mtl_display_id(d->mtl));
        }
        else if (own_keys &&
                 tb_disp_is_shortcut(&ev, SDLK_ESCAPE, SDL_SCANCODE_ESCAPE)) tb_disp_escape(d);
        else if (own_keys &&
                 tb_disp_is_shortcut(&ev, SDLK_l, SDL_SCANCODE_L)) actions |= TB_DISP_ACTION_CYCLE_LANGUAGE;
        else if (own_keys &&
                 idle &&
                 tb_disp_is_shortcut(&ev, SDLK_i, SDL_SCANCODE_I)) d->show_details = !d->show_details;
        /* A changes a setting, so only where its state is on screen. */
        else if (own_keys &&
                 (!TB_RECEIVER_COMPACT_IDLE || d->show_details) &&
                 tb_disp_is_shortcut(&ev, SDLK_a, SDL_SCANCODE_A)) actions |= TB_DISP_ACTION_TOGGLE_LOGIN_ITEM;
        else if (d->input_capture_active) {
            struct tb_input_event input_event;
            memset(&input_event, 0, sizeof(input_event));
            switch (ev.type) {
            case SDL_MOUSEMOTION:
                if (ev.motion.x <= 2 && ev.motion.xrel < 0 && SDL_GetTicks() - d->last_target_switch_tick > 450) {
                    input_event.kind = TB_INPUT_EVENT_SWITCH_PREV_TARGET;
                    tb_disp_queue_input_event(d, &input_event);
                    d->last_target_switch_tick = SDL_GetTicks();
                    break;
                }
                if (ev.motion.x >= d->last_drawable_w - 2 && ev.motion.xrel > 0 && SDL_GetTicks() - d->last_target_switch_tick > 450) {
                    input_event.kind = TB_INPUT_EVENT_SWITCH_NEXT_TARGET;
                    tb_disp_queue_input_event(d, &input_event);
                    d->last_target_switch_tick = SDL_GetTicks();
                    break;
                }
                if (ev.motion.state & SDL_BUTTON_LMASK) input_event.kind = TB_INPUT_EVENT_LEFT_DRAG;
                else if (ev.motion.state & SDL_BUTTON_RMASK) input_event.kind = TB_INPUT_EVENT_RIGHT_DRAG;
                else if (ev.motion.state & SDL_BUTTON_MMASK) input_event.kind = TB_INPUT_EVENT_OTHER_DRAG;
                else input_event.kind = TB_INPUT_EVENT_MOVE;
                input_event.dx = ev.motion.xrel;
                input_event.dy = ev.motion.yrel;
                tb_disp_queue_input_event(d, &input_event);
                break;
            case SDL_MOUSEWHEEL:
            {
                uint32_t now = SDL_GetTicks();
                SDL_Keymod mods = SDL_GetModState();
                if ((mods & KMOD_ALT) &&
                    abs(ev.wheel.x) > abs(ev.wheel.y) &&
                    ev.wheel.x != 0 &&
                    now - d->last_space_switch_tick > 300) {
                    input_event.kind = ev.wheel.x > 0 ? TB_INPUT_EVENT_SWITCH_NEXT_SPACE : TB_INPUT_EVENT_SWITCH_PREV_SPACE;
                    tb_disp_queue_input_event(d, &input_event);
                    d->last_space_switch_tick = now;
                    d->space_gesture_accum_x = 0;
                    break;
                }
                if (abs(ev.wheel.x) > abs(ev.wheel.y) * 2 && ev.wheel.x != 0) {
                    if (now - d->last_space_gesture_tick > 250) {
                        d->space_gesture_accum_x = 0;
                    }
                    d->last_space_gesture_tick = now;
                    d->space_gesture_accum_x += ev.wheel.x;
                    if (abs(d->space_gesture_accum_x) >= 6 &&
                        now - d->last_space_switch_tick > 450) {
                        input_event.kind = d->space_gesture_accum_x > 0 ? TB_INPUT_EVENT_SWITCH_NEXT_SPACE : TB_INPUT_EVENT_SWITCH_PREV_SPACE;
                        tb_disp_queue_input_event(d, &input_event);
                        d->last_space_switch_tick = now;
                        d->space_gesture_accum_x = 0;
                    }
                    break;
                }
                if (now - d->last_space_gesture_tick > 250) {
                    d->space_gesture_accum_x = 0;
                }
                input_event.kind = TB_INPUT_EVENT_SCROLL;
                input_event.scroll_x = ev.wheel.x;
                input_event.scroll_y = ev.wheel.y;
                tb_disp_queue_input_event(d, &input_event);
                break;
            }
            case SDL_MOUSEBUTTONDOWN:
                if (ev.button.button == SDL_BUTTON_LEFT) input_event.kind = TB_INPUT_EVENT_LEFT_DOWN;
                else if (ev.button.button == SDL_BUTTON_RIGHT) input_event.kind = TB_INPUT_EVENT_RIGHT_DOWN;
                else input_event.kind = TB_INPUT_EVENT_OTHER_DOWN;
                input_event.click_count = ev.button.clicks;
                tb_disp_queue_input_event(d, &input_event);
                break;
            case SDL_MOUSEBUTTONUP:
                if (ev.button.button == SDL_BUTTON_LEFT) input_event.kind = TB_INPUT_EVENT_LEFT_UP;
                else if (ev.button.button == SDL_BUTTON_RIGHT) input_event.kind = TB_INPUT_EVENT_RIGHT_UP;
                else input_event.kind = TB_INPUT_EVENT_OTHER_UP;
                input_event.click_count = ev.button.clicks;
                tb_disp_queue_input_event(d, &input_event);
                break;
            case SDL_KEYDOWN:
                if (!ev.key.repeat) {
                    if ((ev.key.keysym.mod & KMOD_CTRL) &&
                        (ev.key.keysym.mod & KMOD_ALT) &&
                        (ev.key.keysym.mod & KMOD_GUI) &&
                        ev.key.keysym.sym == SDLK_k) {
                        input_event.kind = TB_INPUT_EVENT_DEACTIVATE_CONTROL;
                        tb_disp_queue_input_event(d, &input_event);
                        break;
                    }
                    if ((ev.key.keysym.mod & KMOD_CTRL) && (ev.key.keysym.mod & KMOD_GUI)) {
                        if (ev.key.keysym.sym == SDLK_LEFT) {
                            input_event.kind = TB_INPUT_EVENT_SWITCH_PREV_TARGET;
                            tb_disp_queue_input_event(d, &input_event);
                            break;
                        }
                        if (ev.key.keysym.sym == SDLK_RIGHT) {
                            input_event.kind = TB_INPUT_EVENT_SWITCH_NEXT_TARGET;
                            tb_disp_queue_input_event(d, &input_event);
                            break;
                        }
                    }
                    uint16_t mac_key_code = tb_disp_mac_keycode_for_sdl_scancode(ev.key.keysym.scancode);
                    if (mac_key_code == 0xFFFF) break;
                    input_event.kind = TB_INPUT_EVENT_KEY_DOWN;
                    input_event.key_code = mac_key_code;
                    tb_disp_queue_input_event(d, &input_event);
                }
                break;
            case SDL_KEYUP:
                {
                if ((ev.key.keysym.mod & KMOD_CTRL) &&
                    (ev.key.keysym.mod & KMOD_ALT) &&
                    (ev.key.keysym.mod & KMOD_GUI) &&
                    ev.key.keysym.sym == SDLK_k) {
                    break;
                }
                if ((ev.key.keysym.mod & KMOD_CTRL) && (ev.key.keysym.mod & KMOD_GUI) &&
                    (ev.key.keysym.sym == SDLK_LEFT || ev.key.keysym.sym == SDLK_RIGHT)) {
                    break;
                }
                uint16_t mac_key_code = tb_disp_mac_keycode_for_sdl_scancode(ev.key.keysym.scancode);
                if (mac_key_code == 0xFFFF) break;
                input_event.kind = TB_INPUT_EVENT_KEY_UP;
                input_event.key_code = mac_key_code;
                tb_disp_queue_input_event(d, &input_event);
                }
                break;
            default:
                break;
            }
        }
    }
    if (d->quit) actions |= TB_DISP_ACTION_QUIT;
    return actions;
}

int tb_disp_pop_input_event(struct tb_display *d, struct tb_input_event *out) {
    if (!d || !out) return 0;
    return tb_input_queue_pop(&d->input_queue, out);
}

int tb_disp_get_info(struct tb_display *d, struct tb_display_info *info) {
    if (!d || !info || !d->win || !d->ren) return -1;

    memset(info, 0, sizeof(*info));

    int display_index = SDL_GetWindowDisplayIndex(d->win);
    if (display_index < 0) display_index = 0;

    SDL_DisplayMode mode;
    if (SDL_GetCurrentDisplayMode(display_index, &mode) == 0) {
        info->logical_w = (uint32_t)mode.w;
        info->logical_h = (uint32_t)mode.h;
        info->active_w = info->logical_w;
        info->active_h = info->logical_h;
    }

    int window_w = 0, window_h = 0;
    int drawable_w = 0, drawable_h = 0;
    SDL_GetWindowSize(d->win, &window_w, &window_h);
    if (SDL_GetRendererOutputSize(d->ren, &drawable_w, &drawable_h) == 0) {
        info->drawable_w = (uint32_t)drawable_w;
        info->drawable_h = (uint32_t)drawable_h;
    }

    /* SDL reports a logical desktop mode on Retina displays. Query the
     * receiver window's NSScreen for native pixels instead of using its
     * transient drawable, which is only window-sized before fullscreen. */
    uint32_t native_w = 0, native_h = 0;
    if (tb_receiver_content_display_pixels(&native_w, &native_h) == 0) {
        info->active_w = native_w;
        info->active_h = native_h;
    } else {
        if (info->drawable_w > info->active_w) info->active_w = info->drawable_w;
        if (info->drawable_h > info->active_h) info->active_h = info->drawable_h;
    }

    info->window_w = (uint32_t)window_w;
    info->window_h = (uint32_t)window_h;

    const char *name = SDL_GetDisplayName(display_index);
    if (!name) name = "Receiver Display";
    snprintf(info->name, sizeof(info->name), "%s", name);
    return 0;
}

static void tb_disp_set_stream_state(struct tb_display *d, int connected, int connecting) {
    if (!d) return;
    if (d->is_connected == connected && d->is_connecting == connecting) return;
    d->is_connected = connected;
    d->is_connecting = connecting;
    const char *outer = TB_LOOP_ENTER("display link: start or stop (CVDisplayLink)");
    if (connected) {
        tb_disp_start_vsync(d);
    } else {
        tb_vsync_stop(d->vsync);
        tb_disp_metal_release_frames(d);
        d->cursor_dirty = 0;
        d->redraw_needed = 0;
        d->last_seen_tick = 0;
        d->frame_checked = 0;
    }
    TB_LOOP_LEAVE(outer);
    /* A session starts: the next idle screen opens on the calm view again. */
    if (connected || connecting) d->show_details = 0;
    tb_disp_refresh_window_mode(d);
}

void tb_disp_set_connection_state(struct tb_display *d, int connected) {
    tb_disp_set_stream_state(d, connected ? 1 : 0, 0);
}

static void tb_disp_set_connecting_state(struct tb_display *d, int connecting) {
    tb_disp_set_stream_state(d, 0, connecting ? 1 : 0);
}

void tb_disp_set_input_capture_active(struct tb_display *d, int active) {
    if (!d) return;
    d->input_capture_active = active ? 1 : 0;
    tb_disp_refresh_window_mode(d);
}

void tb_disp_set_input_intercept_active(struct tb_display *d, int active) {
    if (!d) return;
    d->input_intercept_active = active ? 1 : 0;
    tb_disp_refresh_window_mode(d);
}

int tb_disp_window_on_active_space(struct tb_display *d) {
    /* Whether the receiver's display window is on the Space the user is
     * currently viewing. The receiverMaster global event tap fires for events
     * on every Space, but the user only intends to drive the sender while
     * looking at this (fullscreen) window. When they switch to another Space on
     * the receiver, this window is no longer on the active Space and the caller
     * stops forwarding so local work doesn't leak to the sender's cursor.
     *
     * Keyboard focus is not a reliable signal here: a fullscreen window can stay
     * key across a Space switch when the receiver app remains active on the new
     * (empty) Space. -[NSWindow isOnActiveSpace] is a direct, purely spatial
     * query to the window server, so it stays correct in that case. */
    if (!d || !d->win) return 1;
    return tb_window_on_active_space(d->win);
}

/* The title bar, set only when it changes: this runs on every loop. */
static void tb_disp_set_title(struct tb_display *d, const char *title) {
    const char *now = SDL_GetWindowTitle(d->win);
    if (!now || strcmp(now, title) != 0) SDL_SetWindowTitle(d->win, title);
}

void tb_disp_render_status(struct tb_display *d,
                           const char *ip,
                           const char *status,
                           const char *sender,
                           const char *panel,
                           const char *mode,
                           const char *language,
                           const char *permissions) {
    if (!d || !d->ren || !d->win) return;

    tb_disp_set_connection_state(d, 0);

    if (!ip) ip = tb_i18n_get("receiver.network.not_detected");
    if (!status) status = tb_i18n_get("receiver.status.waiting_for_sender");
    if (!sender) sender = tb_i18n_get("receiver.status.waiting");
    if (!panel) panel = tb_i18n_get("receiver.panel.unknown");
    if (!mode) mode = tb_i18n_get("receiver.mode.default");
    if (!language) language = tb_i18n_get("receiver.language.auto");
    if (!permissions) permissions = "";

    int drawable_w = 0, drawable_h = 0;
    if (SDL_GetRendererOutputSize(d->ren, &drawable_w, &drawable_h) < 0 ||
        drawable_w <= 0 || drawable_h <= 0) {
        drawable_w = 980;
        drawable_h = 620;
    }

    const int quit_hint = tb_disp_quit_hint(d);
    int rebuilt = 0;
    if (strcmp(d->last_ip, ip) != 0 ||
        strcmp(d->last_status, status) != 0 ||
        strcmp(d->last_sender, sender) != 0 ||
        strcmp(d->last_panel, panel) != 0 ||
        strcmp(d->last_mode, mode) != 0 ||
        strcmp(d->last_language, language) != 0 ||
        strcmp(d->last_permissions, permissions) != 0 ||
        d->last_drawable_w != drawable_w ||
        d->last_drawable_h != drawable_h ||
        d->last_show_details != d->show_details ||
        d->last_login_item_state != d->login_item_state ||
        d->last_quit_hint != quit_hint ||
        d->status_tex == NULL ||
        d->pwe_notice_dirty ||
        d->status_is_connecting) {
        rebuilt = 1;
        d->pwe_notice_dirty = 0;
        snprintf(d->last_ip, sizeof(d->last_ip), "%s", ip);
        snprintf(d->last_status, sizeof(d->last_status), "%s", status);
        snprintf(d->last_sender, sizeof(d->last_sender), "%s", sender);
        snprintf(d->last_panel, sizeof(d->last_panel), "%s", panel);
        snprintf(d->last_mode, sizeof(d->last_mode), "%s", mode);
        snprintf(d->last_language, sizeof(d->last_language), "%s", language);
        snprintf(d->last_permissions, sizeof(d->last_permissions), "%s", permissions);
        d->last_drawable_w = drawable_w;
        d->last_drawable_h = drawable_h;
        d->last_show_details = d->show_details;
        d->last_login_item_state = d->login_item_state;
        d->last_quit_hint = quit_hint;
        d->status_is_connecting = 0;
        tb_disp_rebuild_status_texture(d, ip, status, sender, panel, mode, language, permissions,
                                       drawable_w, drawable_h, 0);
    }

#if TB_RECEIVER_COMPACT_IDLE
    /* PWE: the product's name alone. The host name and address are on the
     * details screen only, not in the title bar (T35). */
    tb_disp_set_title(d, tb_i18n_get("common.app_name"));
#else
    char title[256];
    snprintf(title, sizeof(title), "%s %s — %s — %s", tb_i18n_get("common.app_name"), TB_RECEIVER_VERSION, ip, status);
    tb_disp_set_title(d, title);
#endif

    /* On the Metal layer a covered window may wait a second for a drawable. */
    if (d->mtl && !tb_mtl_window_visible(d->mtl)) return;
    if (!tb_disp_status_present_due(d, rebuilt, TB_DISP_IDLE_PRESENT_MS)) return;
    SDL_RenderClear(d->ren);
    if (d->status_tex) SDL_RenderCopy(d->ren, d->status_tex, NULL, NULL);
    const char *outer = TB_LOOP_ENTER("draw: SDL_RenderPresent (idle screen)");
    SDL_RenderPresent(d->ren);
    TB_LOOP_LEAVE(outer);
}

void tb_disp_render_connecting(struct tb_display *d) {
    if (!d || !d->ren || !d->win) return;

    tb_disp_set_connecting_state(d, 1);

    int drawable_w = 0;
    int drawable_h = 0;
    if (SDL_GetRendererOutputSize(d->ren, &drawable_w, &drawable_h) < 0 ||
        drawable_w <= 0 || drawable_h <= 0) {
        drawable_w = 980;
        drawable_h = 620;
    }

    const int quit_hint = tb_disp_quit_hint(d);
    int rebuilt = 0;
    if (d->status_tex == NULL ||
        !d->status_is_connecting ||
        d->pwe_notice_dirty ||
        d->last_quit_hint != quit_hint ||
        d->last_drawable_w != drawable_w ||
        d->last_drawable_h != drawable_h) {
        rebuilt = 1;
        d->pwe_notice_dirty = 0;
        d->last_drawable_w = drawable_w;
        d->last_drawable_h = drawable_h;
        d->status_is_connecting = 1;
        d->last_quit_hint = quit_hint;
        tb_disp_rebuild_status_texture(d, "", "", "", "", "", "", "",
                                       drawable_w, drawable_h, 1);
    }

#if TB_RECEIVER_COMPACT_IDLE
    tb_disp_set_title(d, tb_i18n_get("common.app_name"));
#else
    tb_disp_set_title(d, "TargetBridge Receiver — Connecting");
#endif
    if (d->mtl && !tb_mtl_window_visible(d->mtl)) return;
    if (!tb_disp_status_present_due(d, rebuilt, TB_DISP_CONNECTING_PRESENT_MS)) return;
    SDL_RenderClear(d->ren);
    if (d->status_tex) SDL_RenderCopy(d->ren, d->status_tex, NULL, NULL);
    tb_disp_draw_connecting_spinner(d, drawable_w, drawable_h);
    const char *outer = TB_LOOP_ENTER("draw: SDL_RenderPresent (connecting screen)");
    SDL_RenderPresent(d->ren);
    TB_LOOP_LEAVE(outer);
}

void tb_disp_set_notice(struct tb_display *d, enum tb_display_notice kind,
                        const char *line1, const char *line2, const char *line3) {
    if (!d) return;
    const char *lines[3] = { line1 ? line1 : "", line2 ? line2 : "", line3 ? line3 : "" };
    int changed = d->pwe_notice_kind != (int)kind;
    for (int i = 0; i < 3; i++) {
        if (strcmp(d->pwe_notice[i], lines[i]) != 0) changed = 1;
        snprintf(d->pwe_notice[i], sizeof(d->pwe_notice[i]), "%s", lines[i]);
    }
    d->pwe_notice_kind = (int)kind;
    if (changed) d->pwe_notice_dirty = 1;
}

void tb_disp_set_login_item_state(struct tb_display *d, enum tb_display_login_item state) {
    if (!d) return;
    d->login_item_state = state;
}

void tb_disp_set_brightness(struct tb_display *d, double level) {
    (void)d;
    if (level < 0.0) level = 0.0;
    if (level > 1.0) level = 1.0;

    void *lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices", RTLD_LAZY);
    if (!lib) {
        fprintf(stderr, "[disp] failed to dlopen DisplayServices\n");
        return;
    }

    typedef int (*SetBrightnessFunc)(CGDirectDisplayID display, float brightness);
    SetBrightnessFunc set_brightness = (SetBrightnessFunc)dlsym(lib, "DisplayServicesSetBrightness");
    if (!set_brightness) {
        fprintf(stderr, "[disp] failed to find DisplayServicesSetBrightness symbol\n");
        dlclose(lib);
        return;
    }

    CGDirectDisplayID displays[16];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(16, displays, &count) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < count; i++) {
            set_brightness(displays[i], (float)level);
        }
    } else {
        set_brightness(CGMainDisplayID(), (float)level);
    }

    dlclose(lib);
}
