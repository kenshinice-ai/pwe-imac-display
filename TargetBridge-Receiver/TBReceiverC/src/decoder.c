/* decoder.c — FFmpeg H.264/HEVC decoder, VideoToolbox when available.
 *
 * Hardware frames leave here as the CVPixelBufferRef VideoToolbox decoded
 * into, untouched: the display either textures its IOSurface directly (Metal,
 * no copy) or locks it and uploads the planes (OpenGL, one CPU read and one
 * upload per frame). Software frames leave as NV12 planes in CPU memory,
 * converted with swscale when FFmpeg's output is another format.
 * Zero ObjC at this layer.
 */

#include "decoder.h"

#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "tb_loopwatch.h"
#include "tb_sysinfo.h"
#include "tb_trace.h"

#if defined(__APPLE__)
#  include <CoreVideo/CoreVideo.h>
#  include <VideoToolbox/VideoToolbox.h>
#endif

#define ANNEXB_START   "\x00\x00\x00\x01"
#define ANNEXB_START_N 4

struct tb_decoder {
    const AVCodec    *codec;
    enum AVCodecID    codec_id;
    AVCodecContext   *ctx;
    AVBufferRef      *hw_dev;
    AVFrame          *hw_frame;
    AVFrame          *sw_frame;
    AVFrame          *nv12_frame;
    AVPacket         *pkt;
    struct SwsContext *sws;
    enum AVPixelFormat hw_pix_fmt;
    int               using_software_decode;

    uint8_t          *extradata;
    int               extradata_size;

    /* scratch for AVCC→Annex B conversion */
    uint8_t          *scratch;
    size_t            scratch_cap;

    tb_frame_cb       cb;
    void             *ud;

    int               opened;

    /* PWE (1.1.1): after a decode error or a (re)open, frames that are not a
     * keyframe would decode against missing references into smeared blocks.
     * They are dropped instead, and the screen keeps the last good picture. */
    int               await_keyframe;
    unsigned long     dropped_awaiting;
};

/* Detect available HW device type (platform-specific). */
static enum AVHWDeviceType pick_hwdev(void) {
#if defined(__APPLE__)
    return AV_HWDEVICE_TYPE_VIDEOTOOLBOX;
#elif defined(__linux__)
    return AV_HWDEVICE_TYPE_VAAPI;
#elif defined(_WIN32)
    return AV_HWDEVICE_TYPE_D3D11VA;
#else
    return AV_HWDEVICE_TYPE_NONE;
#endif
}

static enum AVPixelFormat get_hw_format(AVCodecContext *ctx,
                                        const enum AVPixelFormat *pix_fmts) {
    struct tb_decoder *d = (struct tb_decoder *)ctx->opaque;
    for (const enum AVPixelFormat *p = pix_fmts; *p != -1; p++) {
        if (d && *p == d->hw_pix_fmt) return *p;
    }

    /* VideoToolbox can advertise a codec but still reject an individual
     * stream on older GPUs. FFmpeg calls get_format again with software
     * formats in that case; accepting one keeps the session usable. */
    if (pix_fmts && *pix_fmts != AV_PIX_FMT_NONE) {
        if (d && !d->using_software_decode) {
            d->using_software_decode = 1;
            fprintf(stderr, "[dec] hardware decode unavailable for this stream; using software (%s)\n",
                    av_get_pix_fmt_name(*pix_fmts));
        }
        return *pix_fmts;
    }

    fprintf(stderr, "[dec] no compatible pixel format available\n");
    return AV_PIX_FMT_NONE;
}

struct tb_decoder *tb_dec_create(tb_frame_cb cb, void *ud) {
    struct tb_decoder *d = (struct tb_decoder *)calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->cb       = cb;
    d->ud       = ud;
    d->hw_frame = av_frame_alloc();
    d->sw_frame = av_frame_alloc();
    d->nv12_frame = av_frame_alloc();
    d->pkt      = av_packet_alloc();
    if (!d->hw_frame || !d->sw_frame || !d->nv12_frame || !d->pkt) {
        tb_dec_destroy(d); return NULL;
    }
#if defined(__APPLE__)
    /* FFmpeg only allows hardware HEVC, it does not require it: without a
     * hardware decoder VideoToolbox decodes in software and the log still
     * says videotoolbox_vld. The trace says which one this Mac has. */
    if (tb_trace_enabled()) {
        fprintf(stderr, "[trace] VTIsHardwareDecodeSupported HEVC=%d H.264=%d\n",
                (int)VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
                (int)VTIsHardwareDecodeSupported(kCMVideoCodecType_H264));
    }
#endif
    return d;
}

/* PWE: asked once. FFmpeg alone says yes on every Mac (it allows hardware
 * HEVC, it does not require it); tb_sysinfo adds whether VideoToolbox has a
 * hardware HEVC decoder here (tb_sysinfo.h). */
static int ffmpeg_hevc_hw_config(void);

int tb_dec_supports_hevc_hwdecode(void) {
    static int cached = -1;
    if (cached < 0) cached = tb_sysinfo_advertise_hevc(ffmpeg_hevc_hw_config(), tb_sysinfo_hevc_hw_decode());
    return cached;
}

static int ffmpeg_hevc_hw_config(void) {
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_HEVC);
    if (!codec) return 0;

    enum AVHWDeviceType type = pick_hwdev();
    if (type == AV_HWDEVICE_TYPE_NONE) return 0;

    enum AVPixelFormat supported_hw_pix_fmt = AV_PIX_FMT_NONE;
    for (int i = 0;; i++) {
        const AVCodecHWConfig *cfg = avcodec_get_hw_config(codec, i);
        if (!cfg) break;
        if ((cfg->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) &&
            cfg->device_type == type) {
            supported_hw_pix_fmt = cfg->pix_fmt;
            break;
        }
    }
    if (supported_hw_pix_fmt == AV_PIX_FMT_NONE) {
        return 0;
    }

    AVBufferRef *hw_dev = NULL;
    int status = av_hwdevice_ctx_create(&hw_dev, type, NULL, NULL, 0);
    if (hw_dev) {
        av_buffer_unref(&hw_dev);
    }
    return status >= 0 ? 1 : 0;
}

void tb_dec_reset(struct tb_decoder *d) {
    if (!d) return;
    const char *outer = TB_LOOP_ENTER("decoder: avcodec_free_context (VideoToolbox session)");
    if (d->ctx) avcodec_free_context(&d->ctx);
    TB_LOOP_LEAVE(outer);
    av_free(d->extradata);
    d->extradata      = NULL;
    d->extradata_size = 0;
    d->opened         = 0;
    /* hw_dev, hw_frame, sw_frame, pkt stay allocated for reuse. */
}

void tb_dec_destroy(struct tb_decoder *d) {
    if (!d) return;
    if (d->ctx)      avcodec_free_context(&d->ctx);
    if (d->hw_dev)   av_buffer_unref(&d->hw_dev);
    if (d->hw_frame) av_frame_free(&d->hw_frame);
    if (d->sw_frame) av_frame_free(&d->sw_frame);
    if (d->nv12_frame) av_frame_free(&d->nv12_frame);
    if (d->pkt)      av_packet_free(&d->pkt);
    if (d->sws)      sws_freeContext(d->sws);
    av_free(d->extradata);   /* allocated with av_malloc */
    free(d->scratch);
    free(d);
}

/* Parse param-set payload and build Annex B extradata buffer. */
static int build_extradata(struct tb_decoder *d,
                           const uint8_t *payload, size_t len) {
    if (len < 2) return -1;

    switch (payload[0]) {
    case 1:
        d->codec_id = AV_CODEC_ID_H264;
        break;
    case 2:
        d->codec_id = AV_CODEC_ID_HEVC;
        break;
    default:
        fprintf(stderr, "[dec] unsupported codec marker %u\n", (unsigned)payload[0]);
        return -1;
    }

    int count = payload[1];
    size_t off = 2;

    size_t need = 0;
    /* first pass: compute size */
    size_t tmp_off = off;
    for (int i = 0; i < count; i++) {
        if (tmp_off + 4 > len) return -1;
        uint32_t sz = ((uint32_t)payload[tmp_off]     << 24) |
                      ((uint32_t)payload[tmp_off + 1] << 16) |
                      ((uint32_t)payload[tmp_off + 2] << 8)  |
                       (uint32_t)payload[tmp_off + 3];
        tmp_off += 4;
        if (tmp_off + sz > len) return -1;
        need += ANNEXB_START_N + sz;
        tmp_off += sz;
    }

    av_free(d->extradata);
    d->extradata = (uint8_t *)av_malloc(need + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!d->extradata) return -1;
    memset(d->extradata + need, 0, AV_INPUT_BUFFER_PADDING_SIZE);

    size_t out = 0;
    for (int i = 0; i < count; i++) {
        uint32_t sz = ((uint32_t)payload[off]     << 24) |
                      ((uint32_t)payload[off + 1] << 16) |
                      ((uint32_t)payload[off + 2] << 8)  |
                       (uint32_t)payload[off + 3];
        off += 4;
        memcpy(d->extradata + out, ANNEXB_START, ANNEXB_START_N);
        out += ANNEXB_START_N;
        memcpy(d->extradata + out, payload + off, sz);
        out += sz;
        off += sz;
    }
    d->extradata_size = (int)need;
    return 0;
}

static int open_decoder(struct tb_decoder *d) {
    if (d->codec_id == AV_CODEC_ID_NONE) d->codec_id = AV_CODEC_ID_H264;
    d->codec = avcodec_find_decoder(d->codec_id);
    if (!d->codec) {
        fprintf(stderr, "[dec] decoder not found for codec id %d\n", d->codec_id);
        return -1;
    }

    /* find HW pix fmt that the codec advertises */
    enum AVHWDeviceType type = pick_hwdev();
    d->hw_pix_fmt = AV_PIX_FMT_NONE;
    d->using_software_decode = 0;
    for (int i = 0;; i++) {
        const AVCodecHWConfig *cfg = avcodec_get_hw_config(d->codec, i);
        if (!cfg) break;
        if ((cfg->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) &&
            cfg->device_type == type) {
            d->hw_pix_fmt = cfg->pix_fmt;
            break;
        }
    }
    if (d->hw_pix_fmt == AV_PIX_FMT_NONE) {
        fprintf(stderr, "[dec] WARNING: no HW pix fmt for codec, using SW decode (slow!)\n");
    } else {
        fprintf(stderr, "[dec] HW decode pix_fmt=%s device=%s\n",
                av_get_pix_fmt_name(d->hw_pix_fmt),
                av_hwdevice_get_type_name(type));
    }

    if (d->ctx) avcodec_free_context(&d->ctx);
    d->ctx = avcodec_alloc_context3(d->codec);
    if (!d->ctx) return -1;

    if (d->hw_pix_fmt != AV_PIX_FMT_NONE) {
        if (!d->hw_dev) {
            if (av_hwdevice_ctx_create(&d->hw_dev, type, NULL, NULL, 0) < 0) {
                fprintf(stderr, "[dec] av_hwdevice_ctx_create failed\n");
            }
        }
        if (d->hw_dev) {
            d->ctx->hw_device_ctx = av_buffer_ref(d->hw_dev);
            d->ctx->get_format    = get_hw_format;
            d->ctx->opaque        = d;
        }
    }

    /* Install extradata so FFmpeg knows VPS/SPS/PPS up front. */
    if (d->extradata && d->extradata_size > 0) {
        d->ctx->extradata =
            (uint8_t *)av_malloc(d->extradata_size + AV_INPUT_BUFFER_PADDING_SIZE);
        memcpy(d->ctx->extradata, d->extradata, d->extradata_size);
        memset(d->ctx->extradata + d->extradata_size, 0, AV_INPUT_BUFFER_PADDING_SIZE);
        d->ctx->extradata_size = d->extradata_size;
    }

    const char *outer = TB_LOOP_ENTER("decoder: avcodec_open2 (VideoToolbox session)");
    const int opened = avcodec_open2(d->ctx, d->codec, NULL);
    TB_LOOP_LEAVE(outer);
    if (opened < 0) {
        fprintf(stderr, "[dec] avcodec_open2 failed\n");
        avcodec_free_context(&d->ctx);
        return -1;
    }
    d->opened = 1;
    d->await_keyframe = 1;
    d->dropped_awaiting = 0;
    return 0;
}

int tb_dec_set_param_sets(struct tb_decoder *d, const uint8_t *payload, size_t len) {
    /* Sender re-emits VPS/SPS/PPS with every keyframe (every ~2 seconds).
     * Re-creating the decoder each time stalls decode for ~200ms causing
     * the fps drops to 4 seen in the logs. Only rebuild if param sets
     * actually changed (resolution change, codec reconfig, etc.). */
    uint8_t *prev_ed  = d->extradata;
    int      prev_sz  = d->extradata_size;
    d->extradata      = NULL;
    d->extradata_size = 0;

    if (build_extradata(d, payload, len) < 0) {
        d->extradata      = prev_ed;
        d->extradata_size = prev_sz;
        fprintf(stderr, "[dec] build_extradata failed\n");
        return -1;
    }

    if (d->opened && prev_ed && prev_sz == d->extradata_size &&
        memcmp(prev_ed, d->extradata, prev_sz) == 0) {
        /* Identical → no rebuild. Keep old, drop new. */
        av_free(d->extradata);
        d->extradata      = prev_ed;
        d->extradata_size = prev_sz;
        return 0;
    }

    av_free(prev_ed);
    fprintf(stderr, "[dec] param sets changed, opening decoder\n");
    return open_decoder(d);
}

/* Convert AVCC (length-prefixed) frame to Annex B (start codes) in scratch. */
/* Whether a NAL unit header starts a picture a decoder can begin from: an
 * H.264 IDR slice (type 5), or an HEVC IRAP picture (BLA, IDR, CRA: 16-21). */
static int nal_is_keyframe(enum AVCodecID codec, uint8_t header) {
    if (codec == AV_CODEC_ID_HEVC) {
        const int type = (header >> 1) & 0x3F;
        return type >= 16 && type <= 21;
    }
    return (header & 0x1F) == 5;
}

static int avcc_to_annexb(struct tb_decoder *d,
                          const uint8_t *in, size_t in_len,
                          uint8_t **out, size_t *out_len, int *is_keyframe) {
    *is_keyframe = 0;
    if (d->scratch_cap < in_len + AV_INPUT_BUFFER_PADDING_SIZE) {
        size_t nc = in_len + AV_INPUT_BUFFER_PADDING_SIZE;
        uint8_t *nb = (uint8_t *)realloc(d->scratch, nc);
        if (!nb) return -1;
        d->scratch     = nb;
        d->scratch_cap = nc;
    }

    size_t off = 0, dst = 0;
    while (off + 4 <= in_len) {
        uint32_t nal = ((uint32_t)in[off]     << 24) |
                       ((uint32_t)in[off + 1] << 16) |
                       ((uint32_t)in[off + 2] << 8)  |
                        (uint32_t)in[off + 3];
        off += 4;
        if (off + nal > in_len) return -1;
        if (dst + 4 + nal > d->scratch_cap) return -1;
        if (nal > 0 && nal_is_keyframe(d->codec_id, in[off])) *is_keyframe = 1;
        memcpy(d->scratch + dst, ANNEXB_START, ANNEXB_START_N);
        dst += ANNEXB_START_N;
        memcpy(d->scratch + dst, in + off, nal);
        dst += nal;
        off += nal;
    }
    memset(d->scratch + dst, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    *out     = d->scratch;
    *out_len = dst;
    return 0;
}

/* PWE (1.1.1): a decode error on every frame of a bad stretch (60 a second)
 * would flood the log and rotate it away within minutes. One line every 10 s,
 * with how many more there were since the last one, as main.c does for
 * refused senders. `r`: FFmpeg's error code, or 0 when there is none. */
static void tb_dec_log_error(const char *what, int r) {
    static uint64_t last_ms;
    static unsigned long quiet;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    const uint64_t t = (uint64_t)ts.tv_sec * 1000ull + (uint64_t)ts.tv_nsec / 1000000ull;
    if (last_ms && t - last_ms < 10000) { quiet++; return; }
    if (r) {
        char why[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(r, why, sizeof(why));
        fprintf(stderr, "[dec] %s=%d (%s)", what, r, why);
    } else {
        fprintf(stderr, "[dec] %s", what);
    }
    if (quiet) fprintf(stderr, "; %lu more decode errors since the last report", quiet);
    fputc('\n', stderr);
    last_ms = t;
    quiet = 0;
}

/* PWE (1.1.1): after a decode error, forget the broken references and hold
 * the last good picture until the next keyframe. */
static void tb_dec_hold_until_keyframe(struct tb_decoder *d) {
    if (d->ctx) avcodec_flush_buffers(d->ctx);
    if (!d->await_keyframe) d->dropped_awaiting = 0;
    d->await_keyframe = 1;
}

static uint32_t frame_trace_id(const AVFrame *f) {
    return (f->pts != AV_NOPTS_VALUE && f->pts > 0 && f->pts <= UINT32_MAX) ? (uint32_t)f->pts : 0;
}

int tb_dec_feed_frame(struct tb_decoder *d, const uint8_t *avcc, size_t len, uint32_t trace_id) {
    if (!d->opened) return -1;

    uint8_t *anb = NULL;
    size_t   anb_len = 0;
    int      keyframe = 0;
    if (avcc_to_annexb(d, avcc, len, &anb, &anb_len, &keyframe) < 0) return -1;

    if (d->await_keyframe) {
        if (!keyframe) {
            d->dropped_awaiting++;
            tb_trace_frame_replaced(trace_id);
            return 0;
        }
        if (d->dropped_awaiting) {
            fprintf(stderr, "[dec] keyframe: decoding again after %lu dropped frames\n", d->dropped_awaiting);
        }
        d->await_keyframe = 0;
        d->dropped_awaiting = 0;
    }

    d->pkt->data = anb;
    d->pkt->size = (int)anb_len;
    d->pkt->pts  = trace_id ? (int64_t)trace_id : AV_NOPTS_VALUE;

    const char *outer = TB_LOOP_ENTER("decoder: avcodec_send_packet (VideoToolbox decode)");
    int r = avcodec_send_packet(d->ctx, d->pkt);
    TB_LOOP_LEAVE(outer);
    if (r < 0 && r != AVERROR(EAGAIN)) {
        tb_dec_log_error("send_packet", r);
        tb_dec_hold_until_keyframe(d);
        return -1;
    }

    while (1) {
        r = avcodec_receive_frame(d->ctx, d->hw_frame);
        if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) return 0;
        if (r < 0) {
            tb_dec_log_error("recv_frame", r);
            tb_dec_hold_until_keyframe(d);
            return -1;
        }

#if defined(__APPLE__)
        /* VideoToolbox frames carry their CVPixelBufferRef in data[3]: pass it
         * on as it is, so the display can texture it without a copy. */
        if (d->hw_frame->format == d->hw_pix_fmt && d->hw_frame->data[3]) {
            CVPixelBufferRef pb = (CVPixelBufferRef)d->hw_frame->data[3];
            struct tb_frame f = {
                .width = (int)CVPixelBufferGetWidth(pb),
                .height = (int)CVPixelBufferGetHeight(pb),
                .pixel_buffer = pb,
                .trace_id = frame_trace_id(d->hw_frame),
            };
            d->cb(&f, d->ud);
            av_frame_unref(d->hw_frame);
            continue;
        }
#endif

        /* Generic path: HW transfer (Linux VAAPI / Windows D3D11VA / SW). */
        AVFrame *out = d->hw_frame;
        if (d->hw_frame->format == d->hw_pix_fmt) {
            d->sw_frame->format = AV_PIX_FMT_NV12;
            if (av_hwframe_transfer_data(d->sw_frame, d->hw_frame, 0) < 0) {
                tb_dec_log_error("hwframe_transfer failed", 0);
                av_frame_unref(d->hw_frame);
                continue;
            }
            out = d->sw_frame;
        }

        if (out->format == AV_PIX_FMT_NV12) {
            struct tb_frame f = {
                .y = out->data[0], .y_stride = out->linesize[0],
                .uv = out->data[1], .uv_stride = out->linesize[1],
                .width = out->width, .height = out->height,
                .trace_id = frame_trace_id(d->hw_frame),
            };
            d->cb(&f, d->ud);
        } else {
            d->sws = sws_getCachedContext(d->sws,
                                          out->width, out->height, (enum AVPixelFormat)out->format,
                                          out->width, out->height, AV_PIX_FMT_NV12,
                                          SWS_BILINEAR, NULL, NULL, NULL);
            av_frame_unref(d->nv12_frame);
            d->nv12_frame->format = AV_PIX_FMT_NV12;
            d->nv12_frame->width = out->width;
            d->nv12_frame->height = out->height;
            if (!d->sws || av_frame_get_buffer(d->nv12_frame, 32) < 0) {
                tb_dec_log_error("could not allocate NV12 software frame", 0);
            } else if (sws_scale(d->sws, (const uint8_t * const *)out->data, out->linesize,
                                 0, out->height, d->nv12_frame->data, d->nv12_frame->linesize) <= 0) {
                tb_dec_log_error("software frame conversion failed", 0);
            } else {
                struct tb_frame f = {
                    .y = d->nv12_frame->data[0], .y_stride = d->nv12_frame->linesize[0],
                    .uv = d->nv12_frame->data[1], .uv_stride = d->nv12_frame->linesize[1],
                    .width = d->nv12_frame->width, .height = d->nv12_frame->height,
                    .trace_id = frame_trace_id(d->hw_frame),
                };
                d->cb(&f, d->ud);
            }
        }
        av_frame_unref(d->nv12_frame);
        av_frame_unref(d->sw_frame);
        av_frame_unref(d->hw_frame);
    }
}
