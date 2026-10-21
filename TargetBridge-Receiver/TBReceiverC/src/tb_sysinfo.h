/* tb_sysinfo.h — what this Mac can decode in hardware, and one log line about
 * it (PWE 1.1).
 *
 * FFmpeg lists a VideoToolbox HEVC configuration on every Mac, and VideoToolbox
 * decodes HEVC in software where the GPU cannot (2014 and mid-2015 5K iMacs).
 * The receiver told every sender it decodes HEVC, so those iMacs got HEVC and
 * decoded 5K on the CPU. VTIsHardwareDecodeSupported says whether the hardware
 * decoder exists; it is asked once and the answer kept.
 */

#ifndef TB_SYSINFO_H
#define TB_SYSINFO_H

#include <stddef.h>

/* Hardware decode, asked once per process (cached). 1 yes, 0 no.
 * Off Apple platforms: always 1, so the FFmpeg check alone decides there. */
int tb_sysinfo_hevc_hw_decode(void);
int tb_sysinfo_h264_hw_decode(void);

/* Whether to tell the sender "supportsHEVCDecode": FFmpeg can open a
 * hardware HEVC decoder (`ffmpeg_hw_ok`) and, on Apple platforms, the
 * hardware decoder exists. */
int tb_sysinfo_advertise_hevc(int ffmpeg_hw_ok, int vt_hw_decode);

/* One line for remote testers' logs, without personal data (no host or user
 * name): "iMac18,3 macOS 13.7.8 (22H730) x86_64 (native) HEVC hw=1 H.264 hw=1".
 * Returns `buf`. */
char *tb_sysinfo_describe(char *buf, size_t size);

#endif
