/* tb_log.h — the receiver's log file (PWE 1.1).
 *
 * Opened from Finder or at login, the receiver's stderr goes nowhere, and
 * launched from Terminal it runs with Terminal's privacy permissions instead
 * of its own. So everything it writes to stdout and stderr (its own lines,
 * FFmpeg's, SDL's, perror's) is also appended to
 *
 *   ~/Library/Logs/<app name>/receiver.log
 *
 * each line stamped with the local time. At max_bytes the file becomes
 * receiver.old.log (replacing the previous one) and a new receiver.log starts,
 * so the two together never hold much more than 2 x max_bytes. stdout and
 * stderr still reach wherever they pointed before.
 *
 * Nothing secret may be printed: the pairing code, keys and typed key codes
 * stay out of every log line (main.c logs that a code is shown, not the code).
 *
 * TB_RECEIVER_LOG_DIR replaces the directory (tests); TB_RECEIVER_LOG=0 turns
 * the file off.
 */

#ifndef TB_LOG_H
#define TB_LOG_H

#include <stddef.h>

#define TB_LOG_MAX_BYTES (2u * 1024u * 1024u)

/* Start copying stdout and stderr into <dir>/receiver.log. 0 on success; -1
 * leaves stdout and stderr untouched. Call once, before anything is printed. */
int  tb_log_start(const char *dir, size_t max_bytes);

/* A line that opens every file a rotation starts (the receiver's version,
 * build, Mac and pid), so receiver.log read alone still says what wrote it.
 * Call before tb_log_start; empty or NULL: none. */
void tb_log_set_header(const char *line);

/* Flush, restore stdout and stderr and close the file (also run at exit). */
void tb_log_stop(void);

/* The file tb_log_start opened (<dir>/receiver.log), for a message that points
 * at it; NULL when the log was never started. Still valid after tb_log_stop. */
const char *tb_log_path(void);

/* The directory tb_log_start is given by main(): TB_RECEIVER_LOG_DIR, else
 * ~/Library/Logs/<app_name>. 0 when there is none (no home, or TB_RECEIVER_LOG=0). */
int  tb_log_default_dir(const char *app_name, char *out, size_t size);

/* PWE (1.1.1): the last line of <dir>/receiver.log, without its newline, for
 * telling whether the previous run ended normally. Call before tb_log_start.
 * 1 when there is one; 0 when the file is missing or empty. */
int  tb_log_read_last_line(const char *dir, char *out, size_t size);

/* Whether a stamped log line is the receiver's last word on a normal exit
 * ("[main] bye", with or without a reason after it). */
int  tb_log_line_is_clean_exit(const char *line);

/* PWE (1.1.1, R2): receivers before 1.1.1 logged sampled key events (kind
 * keyDown/keyUp, the first 20 of a session and every 100th, with millisecond
 * stamps; 1.1.0 wrote whether a key code came, never which). On a Mac with no
 * other screen those are often a password typed on the iMac. Delete
 * <dir>/receiver.log and <dir>/receiver.old.log when one holds key-event lines
 * and was written (in part) by a receiver older than `before` ("1.1.1"); call
 * before tb_log_start. Logs of this version or later, and development builds
 * (version 3.x), are kept. Returns how many files were removed. */
int  tb_log_forget_old_key_lines(const char *dir, const char *before);

/* For the unit test: whether log text holds key-event lines and a start line
 * ("[log] receiver X.Y.Z") of a version older than `before`. */
int  tb_log_text_has_old_key_lines(const char *text, size_t len, const char *before);

/* For the unit test: 1 when version `v` ("1.1.0") is older than `than`. */
int  tb_log_version_older(const char *v, const char *than);

/* For the unit test: stamp `in` (any bytes) into lines as the file gets them.
 * `at_line_start` carries over between calls. Returns the bytes written to `out`. */
size_t tb_log_stamp(const char *in, size_t len, const char *stamp, int *at_line_start,
                    char *out, size_t out_size);

#endif
