/* GPU tests for tb_metal_video.m, drawn offscreen and read back: BT.709 colour
 * in video and full range against the formula, IOSurface buffers made the way
 * FFmpeg's VideoToolbox hwaccel makes them, the CPU copy paths, and the
 * premultiplied pointer blend and position. Needs a Metal device, not a window;
 * prints SKIP and passes when there is none. */

#import <Foundation/Foundation.h>

#include "tb_metal_video.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_checks = 0;
static int g_failures = 0;

#define CHECK(cond) do { \
    g_checks++; \
    if (!(cond)) { g_failures++; fprintf(stdout, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } \
} while (0)

enum { W = 16, H = 16 };

static double clamp01(double v) { return v < 0 ? 0 : v > 1 ? 1 : v; }

/* BT.709 to 8-bit RGB, the formula the shader implements. */
static void expected_rgb(int y, int cb, int cr, int full, int rgb[3]) {
    double Y = full ? y / 255.0 : (y - 16.0) / 219.0;
    double U = full ? (cb - 128.0) / 255.0 : (cb - 128.0) / 224.0;
    double V = full ? (cr - 128.0) / 255.0 : (cr - 128.0) / 224.0;
    double r = Y + 1.5748 * V;
    double g = Y - 0.1873 * U - 0.4681 * V;
    double b = Y + 1.8556 * U;
    rgb[0] = (int)lround(clamp01(r) * 255.0);
    rgb[1] = (int)lround(clamp01(g) * 255.0);
    rgb[2] = (int)lround(clamp01(b) * 255.0);
}

static CVPixelBufferRef make_buffer(OSType format, int y, int cb, int cr, int vt_style) {
    NSDictionary *attrs = vt_style
        ? @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferOpenGLCompatibilityKey: @YES }
        : @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES };
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(NULL, W, H, format, (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *py = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    uint8_t *puv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), uvs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    for (int r = 0; r < H; r++) memset(py + r * ys, y, W);
    for (int r = 0; r < H / 2; r++)
        for (int c = 0; c < W / 2; c++) { puv[r * uvs + 2 * c] = (uint8_t)cb; puv[r * uvs + 2 * c + 1] = (uint8_t)cr; }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

static const uint8_t *pixel(const uint8_t *img, int x, int y) { return img + (y * W + x) * 4; }

static int close_to(const uint8_t *bgra, const int rgb[3], int tol) {
    return abs(bgra[2] - rgb[0]) <= tol && abs(bgra[1] - rgb[1]) <= tol && abs(bgra[0] - rgb[2]) <= tol;
}

static void check_colour(struct tb_mtl *m, OSType format, int y, int cb, int cr, int vt_style) {
    CVPixelBufferRef pb = make_buffer(format, y, cb, cr, vt_style);
    CHECK(pb != NULL);
    if (!pb) return;
    uint8_t img[W * H * 4];
    memset(img, 0, sizeof(img));
    CHECK(tb_mtl_render_offscreen(m, pb, NULL, W, H, img) == 0);
    int rgb[3];
    expected_rgb(y, cb, cr, format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, rgb);
    const uint8_t *p = pixel(img, W / 2, H / 2);
    if (!close_to(p, rgb, 2)) {
        fprintf(stdout, "  YCbCr %d,%d,%d %s: got RGB %d,%d,%d want %d,%d,%d\n", y, cb, cr,
                format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? "full" : "video",
                p[2], p[1], p[0], rgb[0], rgb[1], rgb[2]);
    }
    CHECK(close_to(p, rgb, 2));
    CVPixelBufferRelease(pb);
}

static void test_colours(struct tb_mtl *m) {
    const int samples[][3] = {
        { 16, 128, 128 },   /* black */
        { 235, 128, 128 },  /* white */
        { 63, 102, 240 },   /* BT.709 red */
        { 173, 42, 26 },    /* BT.709 green */
        { 32, 240, 118 },   /* BT.709 blue */
        { 126, 128, 128 },  /* mid grey */
    };
    for (size_t i = 0; i < sizeof(samples) / sizeof(samples[0]); i++) {
        check_colour(m, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, samples[i][0], samples[i][1], samples[i][2], 0);
        check_colour(m, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, samples[i][0], samples[i][1], samples[i][2], 1);
        check_colour(m, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, samples[i][0], samples[i][1], samples[i][2], 0);
    }
}

static void test_copies(struct tb_mtl *m) {
    /* CPU planes with padded strides into a pooled buffer. */
    uint8_t ybuf[H][W + 8], uvbuf[H / 2][W + 8];
    memset(ybuf, 63, sizeof(ybuf));
    for (int r = 0; r < H / 2; r++)
        for (int c = 0; c < W / 2; c++) { uvbuf[r][2 * c] = 102; uvbuf[r][2 * c + 1] = 240; }
    CVPixelBufferRef pb = tb_mtl_copy_planes(m, &ybuf[0][0], W + 8, &uvbuf[0][0], W + 8, W, H);
    CHECK(pb != NULL);
    uint8_t img[W * H * 4];
    int red[3];
    expected_rgb(63, 102, 240, 0, red);
    CHECK(pb && tb_mtl_render_offscreen(m, pb, NULL, W, H, img) == 0 && close_to(pixel(img, 3, 3), red, 2));

    /* A whole buffer copied (the fallback when decoder buffers cannot be textured). */
    CVPixelBufferRef src = make_buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 235, 128, 128, 1);
    CVPixelBufferRef copy = tb_mtl_copy_buffer(m, src);
    CHECK(copy != NULL && copy != src);
    int white[3] = { 255, 255, 255 };
    CHECK(copy && tb_mtl_render_offscreen(m, copy, NULL, W, H, img) == 0 && close_to(pixel(img, 8, 8), white, 2));

    /* Refused input. */
    CHECK(tb_mtl_copy_planes(m, NULL, W, &uvbuf[0][0], W, W, H) == NULL);
    CHECK(tb_mtl_copy_planes(m, &ybuf[0][0], W - 1, &uvbuf[0][0], W, W, H) == NULL);

    if (pb) CVPixelBufferRelease(pb);
    if (copy) CVPixelBufferRelease(copy);
    if (src) CVPixelBufferRelease(src);
}

static void test_cursor(struct tb_mtl *m) {
    /* 4x4 white at 50% (premultiplied) at x 4..8, y 2..6 over black. */
    uint8_t bitmap[4 * 4 * 4];
    for (int i = 0; i < 16; i++) { bitmap[i * 4 + 0] = 128; bitmap[i * 4 + 1] = 128; bitmap[i * 4 + 2] = 128; bitmap[i * 4 + 3] = 128; }
    tb_mtl_set_cursor_bitmap(m, bitmap, 4, 4, 16);
    CVPixelBufferRef black = make_buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 16, 128, 128, 0);
    struct tb_mtl_rect rect = { 4.0f, 2.0f, 4.0f, 4.0f };
    uint8_t img[W * H * 4];
    CHECK(tb_mtl_render_offscreen(m, black, &rect, W, H, img) == 0);
    int grey[3] = { 128, 128, 128 }, zero[3] = { 0, 0, 0 };
    CHECK(close_to(pixel(img, 5, 3), grey, 2));
    CHECK(close_to(pixel(img, 7, 5), grey, 2));
    CHECK(close_to(pixel(img, 3, 3), zero, 2));    /* left of it */
    CHECK(close_to(pixel(img, 5, 1), zero, 2));    /* above it */
    CHECK(close_to(pixel(img, 8, 3), zero, 2));    /* right of it */
    CHECK(close_to(pixel(img, 5, 6), zero, 2));    /* below it */

    /* No frame: black, pointer still drawn. */
    CHECK(tb_mtl_render_offscreen(m, NULL, &rect, W, H, img) == 0);
    CHECK(close_to(pixel(img, 5, 3), grey, 2) && close_to(pixel(img, 12, 12), zero, 2));

    /* Cleared pointer: nothing drawn. */
    tb_mtl_set_cursor_bitmap(m, NULL, 0, 0, 0);
    CHECK(tb_mtl_render_offscreen(m, black, &rect, W, H, img) == 0 && close_to(pixel(img, 5, 3), zero, 2));
    CVPixelBufferRelease(black);
}

int main(void) {
    @autoreleasepool {
        char why[256] = "";
        struct tb_mtl *m = tb_mtl_create_offscreen(why, sizeof(why));
        if (!m) {
            fprintf(stdout, "metal video tests: SKIP (%s)\n", why);
            return 0;
        }
        test_colours(m);
        test_copies(m);
        test_cursor(m);
        CHECK(tb_mtl_draw(m, NULL, NULL, 0) == TB_MTL_NO_DRAWABLE);   /* no layer offscreen */
        tb_mtl_destroy(m);
    }
    fprintf(stdout, "metal video tests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
