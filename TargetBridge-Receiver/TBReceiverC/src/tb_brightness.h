/* tb_brightness.h — the Mac's brightness slider on the iMac's panel (PWE 1.1.1, A6).
 *
 * Brightness goes through DisplayServicesSetBrightness in the private
 * DisplayServices framework. Upstream opened the framework and looked the
 * symbol up on every packet, said nothing when it was missing (machines with
 * patched graphics drivers: the slider just did nothing), and dimmed every
 * active display, a second monitor on the iMac included. Now the symbol is
 * looked up once, the first failure is logged once, and only the display the
 * receiver's window is on changes.
 */

#ifndef TB_BRIGHTNESS_H
#define TB_BRIGHTNESS_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>

/* Set `display` to `level` (0..1, clamped). 0 on success, -1 when the
 * framework, the symbol or the call failed (logged once per run). */
int tb_brightness_set(CGDirectDisplayID display, double level);

/* The display a window is on: the one holding the window's centre, else the
 * one it overlaps most, else `fallback`. `window` and `bounds` are in global
 * display coordinates (CGDisplayBounds, top-left origin). Pure, for the tests. */
CGDirectDisplayID tb_brightness_pick_display(CGRect window, const CGDirectDisplayID *ids, const CGRect *bounds,
                                             uint32_t count, CGDirectDisplayID fallback);

/* The displays that show the same picture as `target` (a mirror set: the
 * ones whose primary display, CGDisplayPrimaryDisplay, is target's), target
 * first. `primaries[i]` is ids[i]'s primary. Writes at most `max` ids into
 * `out` and returns how many; a display outside any mirror set is alone.
 * 1.1.0 dimmed every display; mirrors still follow the target, nothing else
 * does. Pure, for the tests. */
uint32_t tb_brightness_mirror_set(CGDirectDisplayID target, CGDirectDisplayID target_primary,
                                  const CGDirectDisplayID *ids, const CGDirectDisplayID *primaries,
                                  uint32_t count, CGDirectDisplayID *out, uint32_t max);

#endif
