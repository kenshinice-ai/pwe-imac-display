/* test_log.c — the receiver's log file (src/tb_log.c): stamping, the copy of
 * stdout and stderr (perror included), rotation, and where the file goes. */

#include "tb_log.h"

#include <errno.h>
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

static void test_default_dir(void) {
    char out[512];
    setenv("HOME", "/Users/someone", 1);
    unsetenv("TB_RECEIVER_LOG");
    unsetenv("TB_RECEIVER_LOG_DIR");
    CHECK(tb_log_default_dir("PWE iMac Display Receiver", out, sizeof(out)) == 1 &&
          strcmp(out, "/Users/someone/Library/Logs/PWE iMac Display Receiver") == 0, "default dir: %s", out);
    setenv("TB_RECEIVER_LOG_DIR", "/tmp/x", 1);
    CHECK(tb_log_default_dir("App", out, sizeof(out)) == 1 && strcmp(out, "/tmp/x") == 0, "override: %s", out);
    setenv("TB_RECEIVER_LOG", "0", 1);
    CHECK(tb_log_default_dir("App", out, sizeof(out)) == 0, "TB_RECEIVER_LOG=0 turns the file off");
}

int main(void) {
    test_stamp();
    test_file_and_rotation();
    test_default_dir();
    printf("test_log: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
