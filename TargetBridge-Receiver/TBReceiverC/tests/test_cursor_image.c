/* Unit tests for the 0x39 pointer-picture parser. Pure C. */

#include "tb_cursor_image.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_checks = 0;
static int g_failures = 0;

#define CHECK(cond) do { \
    g_checks++; \
    if (!(cond)) { g_failures++; fprintf(stdout, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } \
} while (0)

static size_t build(uint8_t *buf, uint32_t id, int w, int h, int hx, int hy, int fw, int fh, size_t pixel_bytes) {
    const int v[6] = { w, h, hx, hy, fw, fh };
    buf[0] = (uint8_t)(id >> 24); buf[1] = (uint8_t)(id >> 16); buf[2] = (uint8_t)(id >> 8); buf[3] = (uint8_t)id;
    for (int i = 0; i < 6; i++) { buf[4 + 2 * i] = (uint8_t)(v[i] >> 8); buf[5 + 2 * i] = (uint8_t)v[i]; }
    for (size_t i = 0; i < pixel_bytes; i++) buf[TB_CURSOR_IMAGE_HEADER + i] = (uint8_t)i;
    return TB_CURSOR_IMAGE_HEADER + pixel_bytes;
}

int main(void) {
    static uint8_t buf[TB_CURSOR_IMAGE_HEADER + 257 * 257 * 4];
    struct tb_cursor_image img;

    /* The layout the sender's TBMonitorProtocolTests pins down. */
    size_t n = build(buf, 0x01020304, 2, 3, 1, 2, 4, 6, 2 * 3 * 4);
    CHECK(tb_cursor_image_parse(buf, n, &img) == 0);
    CHECK(img.id == 0x01020304);
    CHECK(img.width == 2 && img.height == 3 && img.hot_x == 1 && img.hot_y == 2);
    CHECK(img.frame_width == 4 && img.frame_height == 6);
    CHECK(img.bgra == buf + TB_CURSOR_IMAGE_HEADER && img.bgra[5] == 5);

    /* Largest picture, hot spot on the far corner. */
    n = build(buf, 9, 256, 256, 256, 256, 1024, 1024, 256 * 256 * 4);
    CHECK(tb_cursor_image_parse(buf, n, &img) == 0);

    /* Malformed. */
    CHECK(tb_cursor_image_parse(NULL, 100, &img) == -1);
    CHECK(tb_cursor_image_parse(buf, 15, &img) == -1);
    n = build(buf, 1, 0, 2, 0, 0, 2, 2, 0);
    CHECK(tb_cursor_image_parse(buf, n, &img) == -1);              /* zero width */
    n = build(buf, 1, 257, 1, 0, 0, 2, 2, 257 * 4);
    CHECK(tb_cursor_image_parse(buf, n, &img) == -1);              /* too wide */
    n = build(buf, 1, 2, 2, 3, 0, 2, 2, 16);
    CHECK(tb_cursor_image_parse(buf, n, &img) == -1);              /* hot spot outside */
    n = build(buf, 1, 2, 2, 0, 0, 0, 2, 16);
    CHECK(tb_cursor_image_parse(buf, n, &img) == -1);              /* no frame size */
    n = build(buf, 1, 2, 2, 0, 0, 1025, 2, 16);
    CHECK(tb_cursor_image_parse(buf, n, &img) == -1);              /* frame size too big */
    n = build(buf, 1, 2, 2, 0, 0, 2, 2, 15);
    CHECK(tb_cursor_image_parse(buf, n, &img) == -1);              /* short pixels */
    n = build(buf, 1, 2, 2, 0, 0, 2, 2, 17);
    CHECK(tb_cursor_image_parse(buf, n, &img) == -1);              /* trailing bytes */
    memset(&img, 0x5a, sizeof(img));
    struct tb_cursor_image before = img;
    CHECK(tb_cursor_image_parse(buf, 3, &img) == -1 && memcmp(&img, &before, sizeof(img)) == 0);  /* untouched on error */

    fprintf(stdout, "cursor image tests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
