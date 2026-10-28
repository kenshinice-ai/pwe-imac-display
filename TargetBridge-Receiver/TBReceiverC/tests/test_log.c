/* test_log.c — the receiver's log file (src/tb_log.c): stamping, the copy of
 * stdout and stderr (perror included), rotation, and where the file goes. */

#include "tb_log.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures = 0;
static int checks = 0;

#define CHECK(cond, ...) do { \
    checks++; \
    if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
                   fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } \
} while (0)

static char *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)n + 1);
    size_t got = fread(buf, 1, (size_t)n, f);
    buf[got] = '\0';
    fclose(f);
    if (len) *len = got;
    return buf;
}

static void test_stamp(void) {
    char out[64];
    int start = 1;
    size_t n = tb_log_stamp("a\nb", 3, "T ", &start, out, sizeof(out));
    out[n] = '\0';
    CHECK(strcmp(out, "T a\nT b") == 0, "stamp: got \"%s\"", out);
    CHECK(start == 0, "stamp: a line is still open");
    n = tb_log_stamp("c\n", 2, "T ", &start, out, sizeof(out));
    out[n] = '\0';
    CHECK(strcmp(out, "c\n") == 0, "stamp: an open line continues unstamped, got \"%s\"", out);
    CHECK(start == 1, "stamp: the newline ends the line");
}

/* Every line in `text` starts with a stamp and is one of ours, whole. */
static int lines_whole(const char *text, int *count) {
    *count = 0;
    for (const char *line = text; *line; ) {
        const char *nl = strchr(line, '\n');
        if (!nl) return 0;
        /* "2026-10-20 18:47:01.123 " */
        if (nl - line < 24 || line[4] != '-' || line[13] != ':' || line[19] != '.' || line[23] != ' ') return 0;
        if (strncmp(line + 24, "line ", 5) != 0 && strncmp(line + 24, "out ", 4) != 0 &&
            strncmp(line + 24, "perror", 6) != 0) return 0;
        (*count)++;
        line = nl + 1;
    }
    return 1;
}

static void test_file_and_rotation(void) {
    char dir[] = "/tmp/tb_log_test.XXXXXX";
    CHECK(mkdtemp(dir) != NULL, "mkdtemp");
    char sub[256];
    snprintf(sub, sizeof(sub), "%s/Logs", dir);   /* tb_log_start makes it */

    CHECK(tb_log_start(sub, 400) == 0, "tb_log_start");
    for (int i = 0; i < 40; i++) fprintf(stderr, "line %02d of the test\n", i);
    printf("out on stdout\n");
    errno = ENOENT;
    perror("perror");
    tb_log_stop();

    char path[300], old[300];
    snprintf(path, sizeof(path), "%s/receiver.log", sub);
    snprintf(old, sizeof(old), "%s/receiver.old.log", sub);
    size_t len = 0, old_len = 0;
    char *cur = slurp(path, &len);
    char *prev = slurp(old, &old_len);
    CHECK(cur != NULL, "receiver.log exists");
    CHECK(prev != NULL, "receiver.old.log exists after rotation");
    if (cur && prev) {
        int n_cur = 0, n_prev = 0;
        CHECK(lines_whole(cur, &n_cur), "receiver.log: whole, stamped lines");
        CHECK(lines_whole(prev, &n_prev), "receiver.old.log: whole, stamped lines");
        /* Rotation waits for the end of a line: at most one line past the limit. */
        CHECK(len < 400 + 64 && old_len < 400 + 64, "sizes %zu and %zu stay near the limit", len, old_len);
        CHECK(strstr(cur, "out on stdout\n") != NULL, "stdout is in the file");
        CHECK(strstr(cur, "perror: No such file or directory") != NULL, "perror is in the file");
        CHECK(strstr(cur, "line 39 of the test") || strstr(prev, "line 39 of the test"), "the last stderr line is kept");
        CHECK(strstr(prev, "line 00") == NULL, "only one previous file is kept");
    }
    free(cur);
    free(prev);
    unlink(path);
    unlink(old);
    rmdir(sub);
    rmdir(dir);
}

/* PWE (1.1.1): a file started by rotation opens with the header line. */
static void test_rotation_header(void) {
    char dir[] = "/tmp/tb_log_test.XXXXXX";
    CHECK(mkdtemp(dir) != NULL, "mkdtemp");
    tb_log_set_header("receiver 9.9 (test), pid 1; Mac1,1, macOS 1.0");
    CHECK(tb_log_start(dir, 200) == 0, "tb_log_start (header)");
    /* 53-byte lines: four fill the first file, so six rotate exactly once. */
    for (int i = 0; i < 6; i++) fprintf(stderr, "line %02d of the header test\n", i);
    tb_log_stop();
    tb_log_set_header(NULL);

    char path[300], old[300];
    snprintf(path, sizeof(path), "%s/receiver.log", dir);
    snprintf(old, sizeof(old), "%s/receiver.old.log", dir);
    char *cur = slurp(path, NULL);
    char *prev = slurp(old, NULL);
    CHECK(cur && prev, "both files exist after rotation");
    if (cur) {
        static const char want[] = "[log] receiver 9.9 (test), pid 1; Mac1,1, macOS 1.0 (continued";
        CHECK(strlen(cur) > 24 && strncmp(cur + 24, want, sizeof(want) - 1) == 0,
              "the new file opens with the header, got \"%.100s\"", cur);
        CHECK(strstr(cur, "line 05 of the header test") != NULL, "the last line follows the header");
    }
    if (prev) CHECK(strstr(prev, "line 00 of the header test") == prev + 24, "the first file has no header");
    free(cur);
    free(prev);
    unlink(path);
    unlink(old);
    rmdir(dir);
}

/* PWE (1.1.1): the previous run's last line, and what counts as a clean exit. */
static void test_last_line(void) {
    CHECK(tb_log_line_is_clean_exit("2026-10-20 18:47:01.123 [main] bye"), "bye is clean");
    CHECK(tb_log_line_is_clean_exit("2026-10-20 18:47:01.123 [main] bye (sound device still closing)"),
          "bye with a reason is clean");
    CHECK(!tb_log_line_is_clean_exit("2026-10-20 18:47:01.123 [main] 60 fps"), "another line is not");
    CHECK(!tb_log_line_is_clean_exit("[main] bye"), "an unstamped line is not");
    CHECK(!tb_log_line_is_clean_exit(NULL), "NULL is not");

    char dir[] = "/tmp/tb_log_test.XXXXXX";
    CHECK(mkdtemp(dir) != NULL, "mkdtemp");
    char out[128];
    CHECK(tb_log_read_last_line(dir, out, sizeof(out)) == 0 && out[0] == '\0', "no file: no line");
    char path[300];
    snprintf(path, sizeof(path), "%s/receiver.log", dir);
    FILE *f = fopen(path, "w");
    for (int i = 0; i < 200; i++) fprintf(f, "2026-10-20 18:47:01.123 line %03d of a long file\n", i);
    fprintf(f, "2026-10-20 18:47:02.000 [main] bye\n");
    fclose(f);
    CHECK(tb_log_read_last_line(dir, out, sizeof(out)) == 1 && strcmp(out, "2026-10-20 18:47:02.000 [main] bye") == 0,
          "the last line of a long file, got \"%s\"", out);
    f = fopen(path, "a");
    fprintf(f, "2026-10-20 18:47:03.000 [dec] cut off mid-li");
    fclose(f);
    CHECK(tb_log_read_last_line(dir, out, sizeof(out)) == 1 && strcmp(out, "2026-10-20 18:47:03.000 [dec] cut off mid-li") == 0,
          "an unfinished last line, got \"%s\"", out);
    char small[16];
    CHECK(tb_log_read_last_line(dir, small, sizeof(small)) == 1 && strlen(small) == sizeof(small) - 1,
          "a short buffer is cut, not overrun");
    unlink(path);
    rmdir(dir);
}

static void test_default_dir(void) {
    char out[512];
    setenv("HOME", "/Users/someone", 1);
    unsetenv("TB_RECEIVER_LOG");
    unsetenv("TB_RECEIVER_LOG_DIR");
    CHECK(tb_log_default_dir("PWE Screen Encore Receiver", out, sizeof(out)) == 1 &&
          strcmp(out, "/Users/someone/Library/Logs/PWE Screen Encore Receiver") == 0, "default dir: %s", out);
    setenv("TB_RECEIVER_LOG_DIR", "/tmp/x", 1);
    CHECK(tb_log_default_dir("App", out, sizeof(out)) == 1 && strcmp(out, "/tmp/x") == 0, "override: %s", out);
    setenv("TB_RECEIVER_LOG", "0", 1);
    CHECK(tb_log_default_dir("App", out, sizeof(out)) == 0, "TB_RECEIVER_LOG=0 turns the file off");
}

/* PWE (1.1.1, R2): logs from older receivers that hold sampled key events. */
static void test_old_key_lines(void) {
    CHECK(tb_log_version_older("1.1.0", "1.1.1"), "%s", "tb_log_version_older(\"1.1.0\", \"1.1.1\")");
    CHECK(tb_log_version_older("1.0.1", "1.1.1"), "%s", "tb_log_version_older(\"1.0.1\", \"1.1.1\")");
    CHECK(!tb_log_version_older("1.1.1", "1.1.1"), "%s", "!tb_log_version_older(\"1.1.1\", \"1.1.1\")");
    CHECK(!tb_log_version_older("1.2.0", "1.1.1"), "%s", "!tb_log_version_older(\"1.2.0\", \"1.1.1\")");
    CHECK(!tb_log_version_older("3.6.0", "1.1.1"), "%s", "!tb_log_version_older(\"3.6.0\", \"1.1.1\")");   /* development builds */
    CHECK(!tb_log_version_older("", "1.1.1"), "%s", "!tb_log_version_older(\"\", \"1.1.1\")");

    const char *old_keys =
        "2026-10-22 18:50:44.821 [log] receiver 1.1.0 (20261022173038) started, pid 75269\n"
        "2026-10-22 18:56:50.501 [input][receiver->sender] send #1 kind=keyDown dx=0 dy=0 sx=0 sy=0 key=yes mode=receiverMaster\n";
    CHECK(tb_log_text_has_old_key_lines(old_keys, strlen(old_keys), "1.1.1"), "%s", "tb_log_text_has_old_key_lines(old_keys, strlen(old_keys), \"1.1.1\")");
    /* A 1.1.0 log without key lines is kept. */
    const char *old_moves =
        "2026-10-22 18:50:44.821 [log] receiver 1.1.0 (20261022173038) started, pid 75269\n"
        "2026-10-22 18:56:50.501 [input][receiver->sender] send #1 kind=move dx=1 dy=0 sx=0 sy=0 key=no mode=receiverMaster\n";
    CHECK(!tb_log_text_has_old_key_lines(old_moves, strlen(old_moves), "1.1.1"), "%s", "!tb_log_text_has_old_key_lines(old_moves, strlen(old_moves), \"1.1.1\")");
    /* Key lines written only by 1.1.1 or a development build (debug switch) are kept. */
    const char *new_keys =
        "2026-11-04 10:00:00.000 [log] receiver 1.1.1 (20261104) started, pid 1\n"
        "2026-11-04 10:00:01.000 [input][receiver->sender] send #1 kind=keyDown dx=0 dy=0 sx=0 sy=0 key=yes mode=receiverMaster\n"
        "2026-11-04 11:00:00.000 [log] receiver 3.6.0 (dev) started, pid 2\n";
    CHECK(!tb_log_text_has_old_key_lines(new_keys, strlen(new_keys), "1.1.1"), "%s", "!tb_log_text_has_old_key_lines(new_keys, strlen(new_keys), \"1.1.1\")");
    /* A file 1.1.1 went on appending to after 1.1.0: removed. */
    const char *mixed =
        "2026-10-22 18:50:44.821 [log] receiver 1.1.0 (20261022173038) started, pid 75269\n"
        "2026-10-22 18:56:50.501 [input][sender->receiver] received #3 kind=keyUp len=31\n"
        "2026-11-04 10:00:00.000 [log] receiver 1.1.1 (20261104) started, pid 1\n";
    CHECK(tb_log_text_has_old_key_lines(mixed, strlen(mixed), "1.1.1"), "%s", "tb_log_text_has_old_key_lines(mixed, strlen(mixed), \"1.1.1\")");
    /* The rotation header names the version too. */
    const char *rotated =
        "2026-10-22 19:00:00.000 [log] receiver 1.1.0 (20261022173038), pid 75269; iMac18,3 (continued)\n"
        "2026-10-22 19:00:01.000 [input][receiver->sender] send #100 kind=keyUp mode=receiverMaster\n";
    CHECK(tb_log_text_has_old_key_lines(rotated, strlen(rotated), "1.1.1"), "%s", "tb_log_text_has_old_key_lines(rotated, strlen(rotated), \"1.1.1\")");
    /* Not NUL-terminated within len: only the first len bytes count. */
    CHECK(!tb_log_text_has_old_key_lines(old_keys, 40, "1.1.1"), "%s", "!tb_log_text_has_old_key_lines(old_keys, 40, \"1.1.1\")");

    /* The files. */
    char dir[] = "/tmp/test_log_keys.XXXXXX";
    CHECK(mkdtemp(dir) != NULL, "%s", "mkdtemp(dir) != NULL");
    char path[PATH_MAX], old_path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/receiver.log", dir);
    snprintf(old_path, sizeof(old_path), "%s/receiver.old.log", dir);
    FILE *f = fopen(path, "w");
    if (f) { fputs(new_keys, f); fclose(f); }
    f = fopen(old_path, "w");
    if (f) { fputs(old_keys, f); fclose(f); }
    CHECK(tb_log_forget_old_key_lines(dir, "1.1.1") == 1, "%s", "tb_log_forget_old_key_lines(dir, \"1.1.1\") == 1");
    CHECK(access(path, F_OK) == 0, "%s", "access(path, F_OK) == 0");       /* kept */
    CHECK(access(old_path, F_OK) != 0, "%s", "access(old_path, F_OK) != 0");   /* removed */
    CHECK(tb_log_forget_old_key_lines(dir, "1.1.1") == 0, "%s", "tb_log_forget_old_key_lines(dir, \"1.1.1\") == 0");
    CHECK(tb_log_forget_old_key_lines(NULL, "1.1.1") == 0, "%s", "tb_log_forget_old_key_lines(NULL, \"1.1.1\") == 0");
    unlink(path);
    rmdir(dir);
}

int main(void) {
    test_old_key_lines();
    test_stamp();
    test_file_and_rotation();
    test_rotation_header();
    test_last_line();
    test_default_dir();
    printf("test_log: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
