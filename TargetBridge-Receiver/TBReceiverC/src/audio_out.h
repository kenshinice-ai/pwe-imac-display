/* audio_out.h — the receiver's sound output, kept off the main loop (PWE 1.1, T40).
 *
 * Every call that reaches CoreAudio runs on one worker thread: opening and
 * closing the SDL output device and setting the system volume. The main loop
 * only copies PCM into a ring under a lock of its own, which the device's
 * callback holds for a memcpy. Before this, the main loop opened and closed the
 * device itself and took SDL's device lock for every audio packet. SDL's
 * CoreAudio callback holds that lock while it hands each buffer back to the
 * audio queue (SDL 2.32.10, outputCallback), so an audio system that stalls
 * would stall the picture and the connection with it.
 *
 * The device opens on the first audio packet of a session and closes 5 s after
 * the session ends, unless the next session's sound arrives first (a picture
 * change reconnects within that time and keeps the device). An open output
 * device keeps the Mac awake (coreaudiod asserts PreventUserIdleSystemSleep),
 * so it is not kept longer.
 */

#ifndef TB_AUDIO_OUT_H
#define TB_AUDIO_OUT_H

#include <stddef.h>
#include <stdint.h>

#define TB_AUDIO_OUT_CLOSE_AFTER_MS 5000u
#define TB_AUDIO_OUT_RETRY_MS       5000u

struct tb_audio_out;

/* Start the worker. NULL if it could not start. */
struct tb_audio_out *tb_audio_out_create(void);

/* Main loop: queue one AUDIO_FRAME payload (48 kHz stereo s16le) and ask for
 * the device. Never waits on CoreAudio. */
void tb_audio_out_push(struct tb_audio_out *o, const uint8_t *pcm, size_t len);

/* Main loop: the session ended. Drops queued sound; the device closes later. */
void tb_audio_out_idle(struct tb_audio_out *o);

/* Main loop: set the system output volume (0..1) on the worker. */
void tb_audio_out_set_volume(struct tb_audio_out *o, double level);

/* Whether the output device is open now (tests). */
int  tb_audio_out_device_open(struct tb_audio_out *o);

/* At exit: close the device and stop the worker, waiting at most `wait_ms`.
 * 1 when the worker finished. 0 when it is still inside CoreAudio and was left
 * behind: the caller must not shut SDL's audio down under it (no SDL_Quit),
 * and should end the process with _exit(). */
int  tb_audio_out_destroy(struct tb_audio_out *o, unsigned wait_ms);

/* ---- The worker's decision, separate for the unit test ------------------- */

enum tb_audio_out_action {
    TB_AUDIO_OUT_NOTHING = 0,
    TB_AUDIO_OUT_OPEN,
    TB_AUDIO_OUT_CLOSE
};

/* want: sound is wanted now. is_open: the device is open. unwanted_since_ms:
 * when `want` last went to 0. retry_after_ms: no open attempt before this. */
enum tb_audio_out_action tb_audio_out_decide(int want, int is_open, uint64_t unwanted_since_ms,
                                             uint64_t retry_after_ms, uint64_t now_ms);

#endif
