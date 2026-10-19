/* tb_cursor_image.c — packet 0x39 parser. See tb_cursor_image.h. */

#include "tb_cursor_image.h"

#include <string.h>

static unsigned be16(const uint8_t *p) { return ((unsigned)p[0] << 8) | p[1]; }

int tb_cursor_image_parse(const uint8_t *payload, size_t len, struct tb_cursor_image *out) {
    if (!payload || !out || len < TB_CURSOR_IMAGE_HEADER) return -1;
    struct tb_cursor_image img;
    memset(&img, 0, sizeof(img));
    img.id = ((uint32_t)payload[0] << 24) | ((uint32_t)payload[1] << 16) |
             ((uint32_t)payload[2] << 8) | (uint32_t)payload[3];
    img.width = (int)be16(payload + 4);
    img.height = (int)be16(payload + 6);
    img.hot_x = (int)be16(payload + 8);
    img.hot_y = (int)be16(payload + 10);
    img.frame_width = (int)be16(payload + 12);
    img.frame_height = (int)be16(payload + 14);
    if (img.width < 1 || img.width > TB_CURSOR_IMAGE_MAX_SIDE ||
        img.height < 1 || img.height > TB_CURSOR_IMAGE_MAX_SIDE ||
        img.hot_x > img.width || img.hot_y > img.height ||
        img.frame_width < 1 || img.frame_width > TB_CURSOR_IMAGE_MAX_FRAME ||
        img.frame_height < 1 || img.frame_height > TB_CURSOR_IMAGE_MAX_FRAME) {
        return -1;
    }
    if (len - TB_CURSOR_IMAGE_HEADER != (size_t)img.width * (size_t)img.height * 4u) return -1;
    img.bgra = payload + TB_CURSOR_IMAGE_HEADER;
    *out = img;
    return 0;
}
