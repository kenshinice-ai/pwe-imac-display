/* tb_metal_video.m — zero-copy video on SDL's Metal layer. See tb_metal_video.h. */

#import "tb_metal_video.h"

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include "tb_trace.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Compiled at run time (a few ms, once), so the build needs no Metal toolchain. */
static NSString *const kShaderSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VOut { float4 pos [[position]]; float2 uv; };\n"
     "/* A quad as a 4-vertex strip; rect = left, top, right, bottom in clip space. */\n"
     "vertex VOut tb_quad_vertex(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {\n"
     "    VOut o;\n"
     "    float2 p = float2((vid & 1) ? rect.z : rect.x, (vid & 2) ? rect.w : rect.y);\n"
     "    o.pos = float4(p, 0.0, 1.0);\n"
     "    o.uv = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);\n"
     "    return o;\n"
     "}\n"
     "/* m[0] = offset, m[1..3] = R, G, B coefficients (float4 for alignment). */\n"
     "fragment float4 tb_nv12_fragment(VOut in [[stage_in]],\n"
     "                                 texture2d<float> luma [[texture(0)]],\n"
     "                                 texture2d<float> chroma [[texture(1)]],\n"
     "                                 sampler s [[sampler(0)]],\n"
     "                                 constant float4 *m [[buffer(0)]]) {\n"
     "    float3 yuv = float3(luma.sample(s, in.uv).r, chroma.sample(s, in.uv).rg) + m[0].xyz;\n"
     "    return float4(dot(yuv, m[1].xyz), dot(yuv, m[2].xyz), dot(yuv, m[3].xyz), 1.0);\n"
     "}\n"
     "fragment float4 tb_cursor_fragment(VOut in [[stage_in]],\n"
     "                                   texture2d<float> image [[texture(0)]],\n"
     "                                   sampler s [[sampler(0)]]) {\n"
     "    return image.sample(s, in.uv);\n"
     "}\n";

/* BT.709 video range: the same constants as SDL's OpenGL NV12 shader, so both
 * renderers show the same colours. (SDL 2.32.10's own Metal renderer uses the
 * full-range BT.601 matrix for BT709 — another reason not to use its NV12 path.) */
static const float kBT709Video[16] = {
    -0.0627451017f, -0.501960814f, -0.501960814f, 0.0f,
     1.1644f,  0.0000f,  1.7927f, 0.0f,
     1.1644f, -0.2132f, -0.5329f, 0.0f,
     1.1644f,  2.1124f,  0.0000f, 0.0f,
};
static const float kBT709Full[16] = {
     0.0f, -0.501960814f, -0.501960814f, 0.0f,
     1.0f,  0.0000f,  1.5748f, 0.0f,
     1.0f, -0.1873f, -0.4681f, 0.0f,
     1.0f,  1.8556f,  0.0000f, 0.0f,
};

/* Marks buffers from our own pool (tb_mtl_copy_planes). */
static CFStringRef const kTBPoolAttachment = CFSTR("PWEReceiverPoolBuffer");

@interface TBMetalVideo : NSObject
@property (nonatomic, strong) CAMetalLayer *layer;            /* nil offscreen (tests) */
@property (nonatomic, assign) MTLPixelFormat pixelFormat;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic, strong) id<MTLRenderPipelineState> videoPipe;
@property (nonatomic, strong) id<MTLRenderPipelineState> cursorPipe;
@property (nonatomic, strong) id<MTLSamplerState> sampler;
@property (nonatomic, strong) id<MTLTexture> cursorTexture;
@property (nonatomic, assign) CVMetalTextureCacheRef cache;
@property (nonatomic, assign) CVPixelBufferPoolRef pool;
@property (nonatomic, assign) int poolWidth;
@property (nonatomic, assign) int poolHeight;
@property (nonatomic, assign) unsigned long draws;
@end

@implementation TBMetalVideo
- (void)dealloc {
    if (_cache) CFRelease(_cache);
    if (_pool) CVPixelBufferPoolRelease(_pool);
}
@end

static TBMetalVideo *tb_mtl_obj(struct tb_mtl *m) { return (__bridge TBMetalVideo *)(void *)m; }

static void tb_mtl_why(char *why, size_t size, NSString *text) {
    if (why && size) snprintf(why, size, "%s", text.UTF8String ? text.UTF8String : "unknown");
}

static int tb_mtl_is_nv12(OSType format) {
    return format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

/* Both planes of an 8-bit NV12 buffer as textures (+1 each), or 0 on failure. */
static int tb_mtl_wrap(TBMetalVideo *v, CVPixelBufferRef pb, CVMetalTextureRef *y, CVMetalTextureRef *uv) {
    *y = NULL;
    *uv = NULL;
    if (!pb || !tb_mtl_is_nv12(CVPixelBufferGetPixelFormatType(pb)) || CVPixelBufferGetPlaneCount(pb) != 2) return 0;
    /* Test hooks: "texture" fails every real frame (the OpenGL fallback),
     * "wrap" only the decoder's own buffers (the copy fallback). */
    static int fail_for_test = -1;
    if (fail_for_test < 0) {
        const char *f = getenv("TB_RECEIVER_METAL_FAIL");
        fail_for_test = !f ? 0 : strcmp(f, "texture") == 0 ? 1 : strcmp(f, "wrap") == 0 ? 2 : 0;
    }
    if (fail_for_test && CVPixelBufferGetWidth(pb) > 64 &&
        (fail_for_test == 1 || !CVBufferGetAttachment(pb, kTBPoolAttachment, NULL))) return 0;
    size_t w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0);
    size_t cw = CVPixelBufferGetWidthOfPlane(pb, 1), ch = CVPixelBufferGetHeightOfPlane(pb, 1);
    CVReturn ry = CVMetalTextureCacheCreateTextureFromImage(NULL, v.cache, pb, NULL, MTLPixelFormatR8Unorm, w, h, 0, y);
    CVReturn ruv = CVMetalTextureCacheCreateTextureFromImage(NULL, v.cache, pb, NULL, MTLPixelFormatRG8Unorm, cw, ch, 1, uv);
    if (ry != kCVReturnSuccess || ruv != kCVReturnSuccess || !*y || !*uv ||
        !CVMetalTextureGetTexture(*y) || !CVMetalTextureGetTexture(*uv)) {
        if (*y) CFRelease(*y);
        if (*uv) CFRelease(*uv);
        *y = NULL;
        *uv = NULL;
        return 0;
    }
    return 1;
}

static id<MTLRenderPipelineState> tb_mtl_pipeline(TBMetalVideo *v, id<MTLLibrary> lib, NSString *fragment,
                                                  MTLPixelFormat format, BOOL blend, NSError **error) {
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.label = fragment;
    desc.vertexFunction = [lib newFunctionWithName:@"tb_quad_vertex"];
    desc.fragmentFunction = [lib newFunctionWithName:fragment];
    desc.colorAttachments[0].pixelFormat = format;
    if (blend) {   /* premultiplied alpha */
        desc.colorAttachments[0].blendingEnabled = YES;
        desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    }
    return [v.device newRenderPipelineStateWithDescriptor:desc error:error];
}

static void tb_mtl_encode_quad(id<MTLRenderCommandEncoder> enc, float l, float t, float r, float b) {
    const float rect[4] = { l, t, r, b };
    [enc setVertexBytes:rect length:sizeof(rect) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

/* Encode the wrapped planes of a buffer in `format` over the whole target. */
static void tb_mtl_encode_video(TBMetalVideo *v, id<MTLRenderCommandEncoder> enc, OSType format,
                                CVMetalTextureRef ty, CVMetalTextureRef tuv) {
    const float *matrix = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? kBT709Full : kBT709Video;
    [enc setRenderPipelineState:v.videoPipe];
    [enc setFragmentTexture:CVMetalTextureGetTexture(ty) atIndex:0];
    [enc setFragmentTexture:CVMetalTextureGetTexture(tuv) atIndex:1];
    [enc setFragmentSamplerState:v.sampler atIndex:0];
    [enc setFragmentBytes:matrix length:sizeof(kBT709Video) atIndex:0];
    tb_mtl_encode_quad(enc, -1.0f, 1.0f, 1.0f, -1.0f);
}

/* The whole picture on a dw x dh target: the frame (if any) stretched over it,
 * then the pointer bitmap at `cursor` (drawable pixels, top-left origin). */
static void tb_mtl_encode_scene(TBMetalVideo *v, id<MTLRenderCommandEncoder> enc, CVPixelBufferRef frame,
                                CVMetalTextureRef ty, CVMetalTextureRef tuv,
                                const struct tb_mtl_rect *cursor, float dw, float dh) {
    if (frame) tb_mtl_encode_video(v, enc, CVPixelBufferGetPixelFormatType(frame), ty, tuv);
    id<MTLTexture> cursor_tex = v.cursorTexture;
    if (cursor && cursor_tex && dw > 0 && dh > 0 && cursor->w > 0 && cursor->h > 0) {
        [enc setRenderPipelineState:v.cursorPipe];
        [enc setFragmentTexture:cursor_tex atIndex:0];
        [enc setFragmentSamplerState:v.sampler atIndex:0];
        tb_mtl_encode_quad(enc,
                           cursor->x / dw * 2.0f - 1.0f,
                           1.0f - cursor->y / dh * 2.0f,
                           (cursor->x + cursor->w) / dw * 2.0f - 1.0f,
                           1.0f - (cursor->y + cursor->h) / dh * 2.0f);
    }
}

static CVPixelBufferRef tb_mtl_pool_buffer(TBMetalVideo *v, int w, int h) {
    if (w <= 0 || h <= 0) return NULL;
    if (!v.pool || v.poolWidth != w || v.poolHeight != h) {
        if (v.pool) CVPixelBufferPoolRelease(v.pool);
        v.pool = NULL;
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferWidthKey: @(w),
            (id)kCVPixelBufferHeightKey: @(h),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        };
        CVPixelBufferPoolRef pool = NULL;
        if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &pool) != kCVReturnSuccess) return NULL;
        v.pool = pool;
        v.poolWidth = w;
        v.poolHeight = h;
    }
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, v.pool, &pb) != kCVReturnSuccess) return NULL;
    CVBufferSetAttachment(pb, kTBPoolAttachment, kCFBooleanTrue, kCVAttachmentMode_ShouldNotPropagate);
    return pb;
}

static void tb_mtl_copy_plane(uint8_t *dst, size_t dst_stride, const uint8_t *src, size_t src_stride,
                              size_t row_bytes, size_t rows) {
    if (dst_stride == src_stride && row_bytes == src_stride) {
        memcpy(dst, src, row_bytes * rows);
        return;
    }
    for (size_t r = 0; r < rows; r++) memcpy(dst + r * dst_stride, src + r * src_stride, row_bytes);
}

CVPixelBufferRef tb_mtl_copy_planes(struct tb_mtl *m, const uint8_t *y, int y_stride,
                                    const uint8_t *uv, int uv_stride, int w, int h) {
    if (!m || !y || !uv || w <= 0 || h <= 0 || y_stride < w || uv_stride < w) return NULL;
    TBMetalVideo *v = tb_mtl_obj(m);
    CVPixelBufferRef pb = tb_mtl_pool_buffer(v, w, h);
    if (!pb) return NULL;
    if (CVPixelBufferLockBaseAddress(pb, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(pb);
        return NULL;
    }
    tb_mtl_copy_plane((uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0), CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
                      y, (size_t)y_stride, (size_t)w, (size_t)h);
    tb_mtl_copy_plane((uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1), CVPixelBufferGetBytesPerRowOfPlane(pb, 1),
                      uv, (size_t)uv_stride, (size_t)((w + 1) & ~1), (size_t)((h + 1) / 2));
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

CVPixelBufferRef tb_mtl_copy_buffer(struct tb_mtl *m, CVPixelBufferRef src) {
    if (!m || !src || CVPixelBufferGetPlaneCount(src) != 2) return NULL;
    if (CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NULL;
    CVPixelBufferRef out = tb_mtl_copy_planes(m,
        (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(src, 0), (int)CVPixelBufferGetBytesPerRowOfPlane(src, 0),
        (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(src, 1), (int)CVPixelBufferGetBytesPerRowOfPlane(src, 1),
        (int)CVPixelBufferGetWidth(src), (int)CVPixelBufferGetHeight(src));
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return out;
}

/* Draw into an offscreen w x h target and wait; read it back as BGRA if `out`. */
static BOOL tb_mtl_offscreen(TBMetalVideo *v, CVPixelBufferRef frame, const struct tb_mtl_rect *cursor,
                             int w, int h, uint8_t *out, NSString **why) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:v.pixelFormat
                                                                                  width:(NSUInteger)w
                                                                                 height:(NSUInteger)h
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeManaged;   /* readable on Intel/AMD Macs too */
    id<MTLTexture> target = [v.device newTextureWithDescriptor:td];
    if (!target) {
        *why = @"could not create an offscreen target";
        return NO;
    }
    CVMetalTextureRef ty = NULL, tuv = NULL;
    if (frame && !tb_mtl_wrap(v, frame, &ty, &tuv)) {
        *why = @"an IOSurface buffer did not become a Metal texture";
        return NO;
    }
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cmd = [v.queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
    tb_mtl_encode_scene(v, enc, frame, ty, tuv, cursor, (float)w, (float)h);
    [enc endEncoding];
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    [blit synchronizeResource:target];
    [blit endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];
    if (ty) CFRelease(ty);
    if (tuv) CFRelease(tuv);
    if (cmd.status != MTLCommandBufferStatusCompleted) {
        *why = [NSString stringWithFormat:@"offscreen draw failed: %@", cmd.error.localizedDescription ?: @"unknown"];
        return NO;
    }
    if (out) {
        [target getBytes:out bytesPerRow:(NSUInteger)w * 4 fromRegion:MTLRegionMake2D(0, 0, (NSUInteger)w, (NSUInteger)h)
             mipmapLevel:0];
    }
    return YES;
}

/* Everything except the layer: queue, shader, pipelines, texture cache, and
 * the check that runs before the first real frame — a buffer made the way
 * FFmpeg's VideoToolbox hwaccel makes them (IOSurface, OpenGL-compatible, no
 * Metal key), wrapped and drawn offscreen once. */
static TBMetalVideo *tb_mtl_build(id<MTLDevice> device, MTLPixelFormat format, NSString **why) {
    TBMetalVideo *v = [TBMetalVideo new];
    v.device = device;
    v.pixelFormat = format;
    v.queue = [device newCommandQueue];
    v.queue.label = @"PWE receiver video";

    NSError *error = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:kShaderSource options:nil error:&error];
    if (!lib) {
        *why = [NSString stringWithFormat:@"shader compile: %@", error.localizedDescription];
        return nil;
    }
    v.videoPipe = tb_mtl_pipeline(v, lib, @"tb_nv12_fragment", format, NO, &error);
    if (v.videoPipe) v.cursorPipe = tb_mtl_pipeline(v, lib, @"tb_cursor_fragment", format, YES, &error);
    if (!v.videoPipe || !v.cursorPipe) {
        *why = [NSString stringWithFormat:@"pipeline: %@", error.localizedDescription];
        return nil;
    }
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    v.sampler = [device newSamplerStateWithDescriptor:sd];
    if (!v.sampler) {
        *why = @"no sampler";
        return nil;
    }
    CVMetalTextureCacheRef cache = NULL;
    if (CVMetalTextureCacheCreate(NULL, NULL, device, NULL, &cache) != kCVReturnSuccess || !cache) {
        *why = @"CVMetalTextureCacheCreate failed";
        return nil;
    }
    v.cache = cache;

    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferOpenGLCompatibilityKey: @YES,
    };
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(NULL, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess || !pb) {
        *why = @"could not create a test IOSurface buffer";
        return nil;
    }
    BOOL ok = tb_mtl_offscreen(v, pb, NULL, 64, 64, NULL, why);
    CVPixelBufferRelease(pb);
    return ok ? v : nil;
}

struct tb_mtl *tb_mtl_create(void *metal_layer, int vsync, char *why, size_t why_size) {
    @autoreleasepool {
        const char *fail = getenv("TB_RECEIVER_METAL_FAIL");
        if (fail && strcmp(fail, "init") == 0) {
            tb_mtl_why(why, why_size, @"TB_RECEIVER_METAL_FAIL=init");
            return NULL;
        }
        CAMetalLayer *layer = (__bridge CAMetalLayer *)metal_layer;
        if (![layer isKindOfClass:[CAMetalLayer class]] || !layer.device) {
            tb_mtl_why(why, why_size, @"the renderer has no Metal layer");
            return NULL;
        }
        NSString *reason = nil;
        TBMetalVideo *v = tb_mtl_build(layer.device, layer.pixelFormat, &reason);
        if (!v) {
            tb_mtl_why(why, why_size, reason ?: @"unknown");
            return NULL;
        }
        v.layer = layer;
        layer.displaySyncEnabled = vsync ? YES : NO;
        /* 3 is CAMetalLayer's default; 2 queues one frame less. */
        const char *count = getenv("TB_RECEIVER_DRAWABLES");
        layer.maximumDrawableCount = (count && strcmp(count, "2") == 0) ? 2 : 3;

        fprintf(stderr, "[metal] zero-copy video on %s, vsync=%d, drawables=%lu\n",
                v.device.name.UTF8String, vsync ? 1 : 0, (unsigned long)layer.maximumDrawableCount);
        return (__bridge_retained struct tb_mtl *)v;
    }
}

struct tb_mtl *tb_mtl_create_offscreen(char *why, size_t why_size) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            tb_mtl_why(why, why_size, @"no Metal device");
            return NULL;
        }
        NSString *reason = nil;
        TBMetalVideo *v = tb_mtl_build(device, MTLPixelFormatBGRA8Unorm, &reason);
        if (!v) {
            tb_mtl_why(why, why_size, reason ?: @"unknown");
            return NULL;
        }
        return (__bridge_retained struct tb_mtl *)v;
    }
}

int tb_mtl_render_offscreen(struct tb_mtl *m, CVPixelBufferRef frame, const struct tb_mtl_rect *cursor,
                            int w, int h, uint8_t *bgra_out) {
    if (!m || w <= 0 || h <= 0) return -1;
    @autoreleasepool {
        NSString *why = nil;
        if (!tb_mtl_offscreen(tb_mtl_obj(m), frame, cursor, w, h, bgra_out, &why)) {
            fprintf(stderr, "[metal] %s\n", why.UTF8String);
            return -1;
        }
        return 0;
    }
}

void tb_mtl_destroy(struct tb_mtl *m) {
    if (!m) return;
    @autoreleasepool {
        /* In-flight frames hold their own references (completion handlers). */
        CFRelease((CFTypeRef)m);
    }
}

void tb_mtl_set_cursor_bitmap(struct tb_mtl *m, const uint8_t *bgra, int w, int h, int stride) {
    if (!m) return;
    @autoreleasepool {
        TBMetalVideo *v = tb_mtl_obj(m);
        if (!bgra || w <= 0 || h <= 0) {
            v.cursorTexture = nil;
            return;
        }
        /* A new texture per image: an in-flight frame may still read the old one. */
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:(NSUInteger)w
                                                                                     height:(NSUInteger)h
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> tex = [v.device newTextureWithDescriptor:td];
        [tex replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)w, (NSUInteger)h) mipmapLevel:0
                 withBytes:bgra bytesPerRow:(NSUInteger)stride];
        v.cursorTexture = tex;
    }
}

static NSWindow *tb_mtl_window(TBMetalVideo *v) {
    id delegate = v.layer.delegate;
    return [delegate isKindOfClass:[NSView class]] ? [(NSView *)delegate window] : nil;
}

enum tb_mtl_draw_result tb_mtl_draw(struct tb_mtl *m, CVPixelBufferRef frame,
                                    const struct tb_mtl_rect *cursor, uint32_t trace_id) {
    if (!m) return TB_MTL_NO_DRAWABLE;
    @autoreleasepool {
        TBMetalVideo *v = tb_mtl_obj(m);

        if (!v.layer) return TB_MTL_NO_DRAWABLE;
        CVMetalTextureRef ty = NULL, tuv = NULL;
        if (frame && !tb_mtl_wrap(v, frame, &ty, &tuv)) return TB_MTL_TEXTURE_FAILED;
        tb_trace_mark_now(trace_id, TB_TRACE_TEX_READY);

        /* A hidden or covered window may get no drawable for a second; never
         * block the main loop on that. */
        id<CAMetalDrawable> drawable = tb_mtl_window_visible(m) ? [v.layer nextDrawable] : nil;
        if (!drawable) {
            if (ty) CFRelease(ty);
            if (tuv) CFRelease(tuv);
            return TB_MTL_NO_DRAWABLE;
        }
        const float dw = (float)drawable.texture.width, dh = (float)drawable.texture.height;

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLCommandBuffer> cmd = [v.queue commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
        tb_mtl_encode_scene(v, enc, frame, ty, tuv, cursor, dw, dh);
        [enc endEncoding];

        if (trace_id) {
            [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
                CFTimeInterval at = shown.presentedTime;
                if (at > 0) tb_trace_mark(trace_id, TB_TRACE_PRESENTED, (uint64_t)(at * 1e9));
                else tb_trace_frame_replaced(trace_id);   /* the compositor dropped it */
            }];
        }
        [cmd presentDrawable:drawable];

        /* Keep the decoded buffer and its textures until the GPU has read them. */
        if (frame) CVPixelBufferRetain(frame);
        [cmd addCompletedHandler:^(id<MTLCommandBuffer> done) {
            (void)done;
            if (ty) CFRelease(ty);
            if (tuv) CFRelease(tuv);
            if (frame) CVPixelBufferRelease(frame);
        }];
        tb_trace_mark_now(trace_id, TB_TRACE_SUBMITTED);
        [cmd commit];

        if ((++v.draws % 120) == 0) CVMetalTextureCacheFlush(v.cache, 0);
        return TB_MTL_DRAWN;
    }
}

int tb_mtl_window_visible(struct tb_mtl *m) {
    if (!m) return 1;
    @autoreleasepool {
        NSWindow *window = tb_mtl_window(tb_mtl_obj(m));
        return !window || (window.occlusionState & NSWindowOcclusionStateVisible) ? 1 : 0;
    }
}

void tb_mtl_drawable_size(struct tb_mtl *m, int *w, int *h) {
    if (w) *w = 0;
    if (h) *h = 0;
    if (!m) return;
    CGSize size = tb_mtl_obj(m).layer.drawableSize;
    if (w) *w = (int)size.width;
    if (h) *h = (int)size.height;
}

uint32_t tb_mtl_display_id(struct tb_mtl *m) {
    if (!m) return 0;
    @autoreleasepool {
        NSScreen *screen = tb_mtl_window(tb_mtl_obj(m)).screen;
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        return number ? number.unsignedIntValue : 0;
    }
}

int tb_mtl_os_defaults_to_opengl(void) {
    if (@available(macOS 26.0, *)) return 1;
    return 0;
}
