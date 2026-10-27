/* test_sysinfo.c — the hardware-decode answer and the [sys] line (PWE 1.1).
 * Runs on any Mac; what VideoToolbox answers depends on the Mac, so the test
 * checks that the answer is stable and the decision and line are right. */

#include "../src/tb_sysinfo.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg) do {                                              \
    g_checks++;                                                            \
    if (!(cond)) {                                                         \
        g_failures++;                                                      \
        fprintf(stderr, "FAIL %s:%d — %s\n", __FILE__, __LINE__, (msg));   \
    }                                                                      \
} while (0)

int main(void) {
    /* The decision: FFmpeg's yes is not enough without the hardware decoder. */
    CHECK(tb_sysinfo_advertise_hevc(1, 1) == 1, "FFmpeg config and hardware decoder: advertise HEVC");
    CHECK(tb_sysinfo_advertise_hevc(1, 0) == 0, "no hardware HEVC decoder (2014/2015 5K iMac): H.264");
    CHECK(tb_sysinfo_advertise_hevc(0, 1) == 0, "no FFmpeg hardware config: H.264");
    CHECK(tb_sysinfo_advertise_hevc(0, 0) == 0, "neither: H.264");

    const int hevc = tb_sysinfo_hevc_hw_decode(), h264 = tb_sysinfo_h264_hw_decode();
    CHECK(hevc == 0 || hevc == 1, "HEVC answer is 0 or 1");
    CHECK(h264 == 0 || h264 == 1, "H.264 answer is 0 or 1");
    for (int i = 0; i < 100; i++) {
        CHECK(tb_sysinfo_hevc_hw_decode() == hevc, "HEVC answer is stable (cached)");
        CHECK(tb_sysinfo_h264_hw_decode() == h264, "H.264 answer is stable (cached)");
    }

    char line[192];
    tb_sysinfo_describe(line, sizeof(line));
    printf("test_sysinfo: [sys] %s\n", line);
    CHECK(strstr(line, " macOS ") != NULL, "line names the macOS version");
    CHECK(strstr(line, "x86_64 (") || strstr(line, "arm64 ("), "line names the process architecture");
    CHECK(strstr(line, "(native)") || strstr(line, "(Rosetta)"), "line says native or Rosetta");
    char want[64];
    snprintf(want, sizeof(want), "HEVC hw=%d H.264 hw=%d", hevc, h264);
    CHECK(strstr(line, want) != NULL, "line carries the cached hardware answers");
    CHECK(line[0] != '?', "line starts with the hardware model");
    char host[256] = "";
    if (gethostname(host, sizeof(host)) == 0 && strlen(host) > 3) {
        char *dot = strchr(host, '.');
        if (dot) *dot = '\0';
        CHECK(strstr(line, host) == NULL, "line carries no host name");
    }
    const char *user = getenv("USER");
    if (user && strlen(user) > 3) CHECK(strstr(line, user) == NULL, "line carries no user name");

    /* PWE (1.1.1): the Bonjour record's model and os, and the line agrees. */
    char model[64], os[32];
    tb_sysinfo_model(model, sizeof(model));
    tb_sysinfo_os_version(os, sizeof(os));
    printf("test_sysinfo: model=%s os=%s\n", model, os);
    CHECK(model[0] && strchr(model, ' ') == NULL && strchr(model, ',') != NULL, "model looks like Mac14,2 or iMac18,3");
    CHECK(os[0] >= '1' && os[0] <= '9' && strchr(os, '.') != NULL && strchr(os, ' ') == NULL, "os looks like 13.7.8");
    CHECK(strncmp(line, model, strlen(model)) == 0, "the line starts with the same model");
    char os_in_line[48];
    snprintf(os_in_line, sizeof(os_in_line), " macOS %s ", os);
    CHECK(strstr(line, os_in_line) != NULL, "the line carries the same macOS version");

    char tiny[8];
    tb_sysinfo_describe(tiny, sizeof(tiny));
    CHECK(strlen(tiny) < sizeof(tiny), "a short buffer is cut, not overrun");

    if (g_failures) {
        fprintf(stderr, "test_sysinfo: %d of %d checks FAILED\n", g_failures, g_checks);
        return 1;
    }
    printf("test_sysinfo: all %d checks passed\n", g_checks);
    return 0;
}
