/* tb_vsync.h — refresh ticks of the receiver's display (CVDisplayLink).
 *
 * The display link runs on its own thread and only counts refreshes; the main
 * loop reads the counter to submit at most one frame per refresh. Plain C:
 * CoreVideo's display link has no Objective-C in it.
 */

#ifndef TB_VSYNC_H
#define TB_VSYNC_H

#include <stdint.h>

struct tb_vsync;

/* NULL when no display link can be made for `display_id` (a CGDirectDisplayID). */
struct tb_vsync *tb_vsync_create(uint32_t display_id);
void             tb_vsync_destroy(struct tb_vsync *v);

/* Follow the display the window is on; cheap when it did not change. */
void             tb_vsync_set_display(struct tb_vsync *v, uint32_t display_id);
void             tb_vsync_start(struct tb_vsync *v);
void             tb_vsync_stop(struct tb_vsync *v);

/* Refreshes counted since start. Safe from any thread. */
uint64_t         tb_vsync_count(const struct tb_vsync *v);
/* Refresh period in nanoseconds (16.7 ms when unknown). */
uint64_t         tb_vsync_period_ns(const struct tb_vsync *v);

#endif
