/* tb_metal_video.h — zero-copy video on SDL's Metal layer.
 *
 * VideoToolbox decodes into IOSurface-backed CVPixelBuffers. This module turns
 * a buffer's two NV12 planes into Metal textures through CVMetalTextureCache
 * (no copy), converts BT.709 to RGB in its own shader, draws the pointer on
 * top, and presents on the CAMetalLayer that SDL's Metal renderer created.
 * SDL keeps drawing the status screens on the same layer; the two never hold
 * a drawable at the same time because SDL only takes one inside its own
 * render/present calls.
 *
 * Frames that live in CPU memory (software decode, RAW passthrough) are copied
 * once into a pooled IOSurface buffer and then take the same path.
 *
 * Main thread only, except where noted.
 */

#ifndef TB_METAL_VIDEO_H
#define TB_METAL_VIDEO_H

#include <stddef.h>
#include <stdint.h>

#include <CoreVideo/CoreVideo.h>

struct tb_mtl;

/* Builds the path on `metal_layer`, the CAMetalLayer of SDL's Metal renderer
 * (SDL_RenderGetMetalLayer), and checks it end to end: shader compile, a
 * texture from a VideoToolbox-style IOSurface buffer, and one offscreen draw.
 * NULL on any failure, with the reason in `why`. `vsync` turns on
 * CAMetalLayer.displaySyncEnabled (present at the refresh). */
struct tb_mtl *tb_mtl_create(void *metal_layer, int vsync, char *why, size_t why_size);
void           tb_mtl_destroy(struct tb_mtl *m);

/* Copy CPU NV12 planes into a pooled IOSurface buffer. +1 reference, or NULL. */
CVPixelBufferRef tb_mtl_copy_planes(struct tb_mtl *m,
                                    const uint8_t *y, int y_stride,
                                    const uint8_t *uv, int uv_stride,
                                    int w, int h);

/* Copy any lockable NV12 buffer into a pooled one (when its own planes cannot
 * become textures). +1 reference, or NULL. */
CVPixelBufferRef tb_mtl_copy_buffer(struct tb_mtl *m, CVPixelBufferRef pb);

/* The pointer image: premultiplied BGRA, `stride` bytes per row. NULL clears it. */
void tb_mtl_set_cursor_bitmap(struct tb_mtl *m, const uint8_t *bgra, int w, int h, int stride);

struct tb_mtl_rect { float x, y, w, h; };   /* drawable pixels, top-left origin */

enum tb_mtl_draw_result {
    TB_MTL_DRAWN = 0,
    TB_MTL_NO_DRAWABLE = 1,      /* window not visible or no drawable: try again later */
    TB_MTL_TEXTURE_FAILED = -1   /* this buffer cannot become a texture */
};

/* Draw `frame` (NULL = black) stretched over the drawable, then the pointer
 * bitmap at `cursor` when it is non-NULL, and present it. trace_id stamps
 * TEX_READY, SUBMITTED and PRESENTED (tb_trace.h); 0 for a redraw. The buffer
 * is retained until the GPU is done with it. */
enum tb_mtl_draw_result tb_mtl_draw(struct tb_mtl *m, CVPixelBufferRef frame,
                                    const struct tb_mtl_rect *cursor, uint32_t trace_id);

/* 1 when `pb`'s planes become Metal textures (checked on a session's first frame). */
int      tb_mtl_can_texture(struct tb_mtl *m, CVPixelBufferRef pb);
/* 1 when a draw now would neither wait for a drawable nor be wasted: the
 * window is visible and fewer than maximumDrawableCount - 1 frames are in flight. */
int      tb_mtl_ready(struct tb_mtl *m);
/* 0 when the window is fully covered or hidden (no drawable will come soon). */
int      tb_mtl_window_visible(struct tb_mtl *m);
/* Drawable size in pixels (0 x 0 when unknown). */
void     tb_mtl_drawable_size(struct tb_mtl *m, int *w, int *h);
/* The CGDirectDisplayID of the screen the window is on, or 0. */
uint32_t tb_mtl_display_id(struct tb_mtl *m);

/* For the unit test: the same pipeline without a window, on the default device
 * and BGRA8, and a synchronous draw read back as BGRA (w * 4 bytes per row). */
struct tb_mtl *tb_mtl_create_offscreen(char *why, size_t why_size);
int            tb_mtl_render_offscreen(struct tb_mtl *m, CVPixelBufferRef frame, const struct tb_mtl_rect *cursor,
                                       int w, int h, uint8_t *bgra_out);

/* 1 on macOS 26 and later, where upstream saw the Metal renderer flicker
 * (03299cb) and the default stays OpenGL until that is retested. */
int      tb_mtl_os_defaults_to_opengl(void);

#endif
