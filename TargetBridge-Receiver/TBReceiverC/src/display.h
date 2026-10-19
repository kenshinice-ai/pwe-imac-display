/* display.h — SDL2 fullscreen window + video renderer (Metal zero-copy or OpenGL). */

#ifndef TB_DISPLAY_H
#define TB_DISPLAY_H

#include <stdint.h>
#include <stddef.h>

#include "decoder.h"
#include "input_queue.h"
#include "tb_cursor_image.h"

struct tb_display;

struct tb_display_info {
    uint32_t logical_w;
    uint32_t logical_h;
    uint32_t active_w;
    uint32_t active_h;
    uint32_t window_w;
    uint32_t window_h;
    uint32_t drawable_w;
    uint32_t drawable_h;
    char     name[128];
};

enum tb_display_action {
    TB_DISP_ACTION_NONE = 0,
    TB_DISP_ACTION_QUIT = 1 << 0,
    TB_DISP_ACTION_CYCLE_LANGUAGE = 1 << 1,
    TB_DISP_ACTION_TOGGLE_LOGIN_ITEM = 1 << 2
};

/* What the details screen says about opening at login. HIDDEN keeps the
 * upstream details screen. */
enum tb_display_login_item {
    TB_DISP_LOGIN_ITEM_HIDDEN = 0,
    TB_DISP_LOGIN_ITEM_OFF,
    TB_DISP_LOGIN_ITEM_ON,
    TB_DISP_LOGIN_ITEM_UNAVAILABLE   /* this copy runs from a disk image or translocated path */
};

struct tb_display *tb_disp_create(int fullscreen);
void               tb_disp_destroy(struct tb_display *d);
void               tb_disp_set_connection_state(struct tb_display *d, int connected);
void               tb_disp_set_input_capture_active(struct tb_display *d, int active);
void               tb_disp_set_input_intercept_active(struct tb_display *d, int active);

/* Whether the receiver display window is on the active macOS Space. Used to
 * gate receiverMaster global-tap forwarding so input on other receiver Spaces
 * does not leak to the sender. */
int                tb_disp_window_on_active_space(struct tb_display *d);

/* Resize/recreate texture when frame dimensions change. */
int  tb_disp_ensure_texture(struct tb_display *d, int w, int h);

/* Show one decoded frame (CPU planes or a VideoToolbox pixel buffer). Called
 * once per decoded frame. On the paced Metal path the frame may wait for the
 * next display refresh; tb_disp_tick draws it then. */
void tb_disp_show_frame(struct tb_display *d, const struct tb_frame *frame);

/* Call every main-loop iteration: draws a waiting frame or a moved pointer
 * when the next refresh has begun. Cheap when there is nothing to do. */
void tb_disp_tick(struct tb_display *d);

/* Update low-latency local cursor overlay in source-frame coordinates. */
void tb_disp_set_cursor(struct tb_display *d,
                        int x, int y,
                        int source_w, int source_h,
                        int visible,
                        int type,
                        int large);

/* The sender's pointer picture (0x39); NULL goes back to the drawn shapes.
 * The pixels are copied. */
void tb_disp_set_cursor_image(struct tb_display *d, const struct tb_cursor_image *image);

void tb_disp_set_brightness(struct tb_display *d, double level);

/* Poll input actions while idle/connected. */
unsigned int tb_disp_poll_actions(struct tb_display *d);
int          tb_disp_pop_input_event(struct tb_display *d, struct tb_input_event *out);

/* Query active display/window/drawable information for UI/debug metadata. */
int  tb_disp_get_info(struct tb_display *d, struct tb_display_info *info);

/* Render a simple launcher/status UI before the video stream starts. */
void tb_disp_render_status(struct tb_display *d,
                           const char *ip,
                           const char *status,
                           const char *sender,
                           const char *panel,
                           const char *mode,
                           const char *language,
                           const char *permissions);
void tb_disp_render_connecting(struct tb_display *d);
void tb_disp_set_login_item_state(struct tb_display *d, enum tb_display_login_item state);

#endif
