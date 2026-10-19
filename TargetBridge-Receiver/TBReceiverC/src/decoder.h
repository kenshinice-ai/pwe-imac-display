/* decoder.h — HEVC hardware decoder via FFmpeg + VideoToolbox (macOS).
 * On Linux: VAAPI. On Windows: D3D11VA. Selected at runtime.
 */

#ifndef TB_DECODER_H
#define TB_DECODER_H

#include <stdint.h>
#include <stddef.h>

/* Frame callback: NV12 planes.
 *   Y plane  : (width * height) bytes,            stride = y_stride
 *   UV plane : (width * height / 2) bytes,        stride = uv_stride
 */
/* trace_id: the id passed to tb_dec_feed_frame for the packet that produced
 * this frame (tb_trace.h), carried through FFmpeg as the packet's pts. */
typedef void (*tb_frame_cb)(const uint8_t *y, int y_stride,
                            const uint8_t *uv, int uv_stride,
                            int width, int height, uint32_t trace_id, void *ud);

struct tb_decoder;

struct tb_decoder *tb_dec_create(tb_frame_cb cb, void *ud);
void               tb_dec_destroy(struct tb_decoder *d);
int                tb_dec_supports_hevc_hwdecode(void);

/* Reset decoder state on client disconnect.
 * Forces re-open on next param sets so a stale FFmpeg context doesn't
 * carry over to a new stream session. */
void               tb_dec_reset  (struct tb_decoder *d);

/* Set codec parameter sets. payload format:
 *   [1 byte codec: 1 = H264, 2 = HEVC]
 *   [1 byte count] then for each: [4 bytes BE size][size bytes]
 * Builds Annex B extradata and re-opens decoder. */
int  tb_dec_set_param_sets(struct tb_decoder *d, const uint8_t *payload, size_t len);

/* Feed one AVCC-formatted frame (4-byte length prefixed NAL units).
 * Converts to Annex B and dispatches to FFmpeg. trace_id may be 0. */
int  tb_dec_feed_frame(struct tb_decoder *d, const uint8_t *avcc, size_t len, uint32_t trace_id);

#endif
