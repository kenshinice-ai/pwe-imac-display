/* tb_cursor_image.h — packet 0x39, the pointer's picture (receiver-drawn pointer).
 *
 * A receiver that says "cursorImage": true in its display profile gets the
 * sender's real pointer picture whenever it changes, and positions in 0x32 at
 * up to 240 Hz; the video then carries no pointer and the receiver draws it on
 * every refresh. Payload, big-endian:
 *   [id u32][width u16][height u16][hotX u16][hotY u16][frameWidth u16][frameHeight u16]
 *   [width * height * 4 bytes: premultiplied BGRA, top row first]
 * Pure C, no SDL, so it is unit-tested on its own.
 */

#ifndef TB_CURSOR_IMAGE_H
#define TB_CURSOR_IMAGE_H

#include <stddef.h>
#include <stdint.h>

#define TB_CURSOR_IMAGE_HEADER    16
#define TB_CURSOR_IMAGE_MAX_SIDE  256
#define TB_CURSOR_IMAGE_MAX_FRAME (4 * TB_CURSOR_IMAGE_MAX_SIDE)

struct tb_cursor_image {
    uint32_t       id;
    int            width, height;              /* pixels, 1..256 */
    int            hot_x, hot_y;               /* pixels from the top-left, inside the picture */
    int            frame_width, frame_height;  /* size on the video frame, frame pixels, 1..1024 */
    const uint8_t *bgra;                       /* points into the payload */
};

/* 0 and *out filled, or -1 when the payload is malformed. */
int tb_cursor_image_parse(const uint8_t *payload, size_t len, struct tb_cursor_image *out);

#endif
