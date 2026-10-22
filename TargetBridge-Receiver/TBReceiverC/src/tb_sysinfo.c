/* tb_sysinfo.c — hardware decode and the start-up line. See tb_sysinfo.h. */

#include "tb_sysinfo.h"

#include <stdio.h>
#include <string.h>

#if defined(__APPLE__)
#include <sys/sysctl.h>
#include <CoreMedia/CoreMedia.h>
#include <VideoToolbox/VideoToolbox.h>
#endif

#if defined(__APPLE__)
/* -1: not asked yet. The receiver asks from its main thread only. */
static int g_hevc_hw = -1;
static int g_h264_hw = -1;
#endif

int tb_sysinfo_hevc_hw_decode(void) {
#if defined(__APPLE__)
    if (g_hevc_hw < 0) g_hevc_hw = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? 1 : 0;
    return g_hevc_hw;
#else
    return 1;
#endif
}

int tb_sysinfo_h264_hw_decode(void) {
#if defined(__APPLE__)
    if (g_h264_hw < 0) g_h264_hw = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) ? 1 : 0;
    return g_h264_hw;
#else
    return 1;
#endif
}

int tb_sysinfo_advertise_hevc(int ffmpeg_hw_ok, int vt_hw_decode) {
    return ffmpeg_hw_ok && vt_hw_decode;
}

#if defined(__APPLE__)
static void sysctl_text(const char *name, char *out, size_t size) {
    size_t len = size;
    if (size == 0) return;
    if (sysctlbyname(name, out, &len, NULL, 0) != 0 || len == 0) snprintf(out, size, "?");
    out[size - 1] = '\0';
}
#endif

char *tb_sysinfo_describe(char *buf, size_t size) {
    if (!buf || size == 0) return buf;
#if defined(__x86_64__)
    const char *arch = "x86_64";
#elif defined(__arm64__) || defined(__aarch64__)
    const char *arch = "arm64";
#else
    const char *arch = "other";
#endif
#if defined(__APPLE__)
    char model[64], version[32], build[32];
    sysctl_text("hw.model", model, sizeof(model));
    sysctl_text("kern.osproductversion", version, sizeof(version));
    sysctl_text("kern.osversion", build, sizeof(build));
    int translated = 0;
    size_t len = sizeof(translated);
    if (sysctlbyname("sysctl.proc_translated", &translated, &len, NULL, 0) != 0) translated = 0;   /* Intel: no such key */
    snprintf(buf, size, "%s macOS %s (%s) %s (%s) HEVC hw=%d H.264 hw=%d", model, version, build, arch,
             translated == 1 ? "Rosetta" : "native", tb_sysinfo_hevc_hw_decode(), tb_sysinfo_h264_hw_decode());
#else
    snprintf(buf, size, "%s", arch);
#endif
    return buf;
}

static char *sysinfo_value(const char *name, char *buf, size_t size) {
    if (!buf || size == 0) return buf;
    buf[0] = '\0';
#if defined(__APPLE__)
    sysctl_text(name, buf, size);
    if (strcmp(buf, "?") == 0) buf[0] = '\0';
#else
    (void)name;
#endif
    return buf;
}

char *tb_sysinfo_model(char *buf, size_t size) {
    return sysinfo_value("hw.model", buf, size);
}

char *tb_sysinfo_os_version(char *buf, size_t size) {
    return sysinfo_value("kern.osproductversion", buf, size);
}
