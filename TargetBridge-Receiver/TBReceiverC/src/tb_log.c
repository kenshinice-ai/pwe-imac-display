/* tb_log.c — the receiver's log file. See tb_log.h.
 *
 * stdout and stderr (file descriptors 1 and 2) are pointed at one pipe; a
 * thread reads it, passes every byte on to the original stderr and appends
 * it, stamped line by line, to the file. Working at the descriptor level
 * catches everything: fprintf, perror (which writes to the descriptor
 * directly) and the libraries' own output. */

#include "tb_log.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static struct {
    atomic_int running;
    int       pipe_read;
    int       saved_stdout;
    int       saved_stderr;
    int       file;
    size_t    file_bytes;
    size_t    max_bytes;
    int       at_line_start;
    char      path[PATH_MAX];
    char      old_path[PATH_MAX];
    pthread_t reader;
    atomic_int reader_done;
    int       started;   /* tb_log_start succeeded once: `path` names the file */
    char      header[512];
} g_log = { .pipe_read = -1, .saved_stdout = -1, .saved_stderr = -1, .file = -1, .at_line_start = 1 };

size_t tb_log_stamp(const char *in, size_t len, const char *stamp, int *at_line_start,
                    char *out, size_t out_size) {
    const size_t stamp_len = strlen(stamp);
    size_t n = 0;
    for (size_t i = 0; i < len; i++) {
        if (*at_line_start) {
            if (n + stamp_len >= out_size) break;
            memcpy(out + n, stamp, stamp_len);
            n += stamp_len;
            *at_line_start = 0;
        }
        if (n + 1 > out_size) break;
        out[n++] = in[i];
        if (in[i] == '\n') *at_line_start = 1;
    }
    return n;
}

static int tb_log_open_file(void) {
    g_log.file = open(g_log.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (g_log.file < 0) return -1;
    struct stat st;
    g_log.file_bytes = fstat(g_log.file, &st) == 0 ? (size_t)st.st_size : 0;
    return 0;
}

static void tb_log_write_all(int fd, const char *buf, size_t len) {
    while (len > 0) {
        ssize_t w = write(fd, buf, len);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return;
        buf += w;
        len -= (size_t)w;
    }
}

void tb_log_set_header(const char *line) {
    snprintf(g_log.header, sizeof(g_log.header), "%s", line ? line : "");
}

/* Between lines only, so no line is ever split across the two files. The new
 * file opens with the header (PWE 1.1.1). */
static void tb_log_rotate_if_full(const char *stamp) {
    if (!g_log.at_line_start || g_log.file_bytes < g_log.max_bytes) return;
    close(g_log.file);
    g_log.file = -1;
    (void)rename(g_log.path, g_log.old_path);
    if (tb_log_open_file() < 0 || !g_log.header[0]) return;
    char line[sizeof(g_log.header) + 128];
    const int n = snprintf(line, sizeof(line), "%s[log] %s (continued; earlier lines in receiver.old.log)\n",
                           stamp, g_log.header);
    if (n <= 0) return;
    const size_t len = (size_t)n < sizeof(line) ? (size_t)n : sizeof(line) - 1;
    tb_log_write_all(g_log.file, line, len);
    g_log.file_bytes += len;
}

/* Appends `len` bytes to the file, a line at a time so rotation can fall in between. */
static void tb_log_append(const char *buf, size_t len) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm_now;
    localtime_r(&tv.tv_sec, &tm_now);
    char stamp[48];
    size_t s = strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &tm_now);
    snprintf(stamp + s, sizeof(stamp) - s, ".%03d ", (int)(tv.tv_usec / 1000));

    while (len > 0) {
        tb_log_rotate_if_full(stamp);
        if (g_log.file < 0) return;
        const char *nl = memchr(buf, '\n', len);
        const size_t line = nl ? (size_t)(nl - buf) + 1 : len;
        char out[4096 + 64];
        size_t done = 0;
        while (done < line) {
            /* One chunk at most fills `out`; a long line takes several. */
            size_t chunk = line - done;
            if (chunk > 4096) chunk = 4096;
            size_t n = tb_log_stamp(buf + done, chunk, stamp, &g_log.at_line_start, out, sizeof(out));
            tb_log_write_all(g_log.file, out, n);
            g_log.file_bytes += n;
            done += chunk;
        }
        buf += line;
        len -= line;
    }
}

static void *tb_log_reader(void *unused) {
    (void)unused;
    char buf[4096];
    for (;;) {
        ssize_t n = read(g_log.pipe_read, buf, sizeof(buf));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;   /* every write end closed (tb_log_stop), or a broken pipe */
        if (g_log.saved_stderr >= 0) tb_log_write_all(g_log.saved_stderr, buf, (size_t)n);
        tb_log_append(buf, (size_t)n);
    }
    if (g_log.running) {
        /* Not asked to stop: nobody would read the pipe any more. */
        if (g_log.saved_stdout >= 0) dup2(g_log.saved_stdout, STDOUT_FILENO);
        if (g_log.saved_stderr >= 0) dup2(g_log.saved_stderr, STDERR_FILENO);
    }
    atomic_store(&g_log.reader_done, 1);
    return NULL;
}

int tb_log_default_dir(const char *app_name, char *out, size_t size) {
    if (!out || size == 0) return 0;
    out[0] = '\0';
    const char *off = getenv("TB_RECEIVER_LOG");
    if (off && strcmp(off, "0") == 0) return 0;
    const char *dir = getenv("TB_RECEIVER_LOG_DIR");
    if (dir && *dir) {
        snprintf(out, size, "%s", dir);
        return 1;
    }
    const char *home = getenv("HOME");
    if (!home || !*home || !app_name || !*app_name) return 0;
    snprintf(out, size, "%s/Library/Logs/%s", home, app_name);
    return 1;
}

const char *tb_log_path(void) {
    return g_log.started ? g_log.path : NULL;
}

int tb_log_read_last_line(const char *dir, char *out, size_t size) {
    if (!out || size == 0) return 0;
    out[0] = '\0';
    if (!dir || !*dir) return 0;
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/receiver.log", dir);
    const int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    char tail[2048];
    struct stat st;
    const off_t from = fstat(fd, &st) == 0 && st.st_size > (off_t)sizeof(tail) ? st.st_size - (off_t)sizeof(tail) : 0;
    const ssize_t n = pread(fd, tail, sizeof(tail), from);
    close(fd);
    if (n <= 0) return 0;
    size_t end = (size_t)n;
    while (end > 0 && (tail[end - 1] == '\n' || tail[end - 1] == '\r')) end--;
    if (end == 0) return 0;
    size_t start = end;
    while (start > 0 && tail[start - 1] != '\n') start--;
    const size_t len = end - start < size - 1 ? end - start : size - 1;
    memcpy(out, tail + start, len);
    out[len] = '\0';
    return 1;
}

int tb_log_line_is_clean_exit(const char *line) {
    /* "2026-10-20 18:47:01.123 [main] bye" */
    static const char bye[] = "[main] bye";
    return line && strlen(line) >= 24 + sizeof(bye) - 1 && strncmp(line + 24, bye, sizeof(bye) - 1) == 0;
}

int tb_log_start(const char *dir, size_t max_bytes) {
    if (g_log.running || !dir || !*dir) return -1;
    if (mkdir(dir, 0755) != 0 && errno != EEXIST) return -1;
    snprintf(g_log.path, sizeof(g_log.path), "%s/receiver.log", dir);
    snprintf(g_log.old_path, sizeof(g_log.old_path), "%s/receiver.old.log", dir);
    g_log.max_bytes = max_bytes > 0 ? max_bytes : TB_LOG_MAX_BYTES;
    g_log.at_line_start = 1;
    if (tb_log_open_file() < 0) return -1;

    int fds[2];
    if (pipe(fds) != 0) {
        close(g_log.file);
        g_log.file = -1;
        return -1;
    }
    fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    fflush(stdout);
    fflush(stderr);
    g_log.saved_stdout = dup(STDOUT_FILENO);
    g_log.saved_stderr = dup(STDERR_FILENO);
    g_log.pipe_read = fds[0];
    atomic_store(&g_log.reader_done, 0);
    g_log.running = 1;
    if (pthread_create(&g_log.reader, NULL, tb_log_reader, NULL) != 0) {
        g_log.running = 0;
        close(fds[0]);
        close(fds[1]);
        if (g_log.saved_stdout >= 0) close(g_log.saved_stdout);
        if (g_log.saved_stderr >= 0) close(g_log.saved_stderr);
        close(g_log.file);
        g_log.pipe_read = g_log.saved_stdout = g_log.saved_stderr = g_log.file = -1;
        return -1;
    }
    dup2(fds[1], STDOUT_FILENO);
    dup2(fds[1], STDERR_FILENO);
    close(fds[1]);
    /* stdout now goes to a pipe, which stdio would buffer in full. */
    setvbuf(stdout, NULL, _IOLBF, 0);
    atexit(tb_log_stop);
    g_log.started = 1;
    return 0;
}

void tb_log_stop(void) {
    if (!g_log.running) return;
    g_log.running = 0;
    fflush(stdout);
    fflush(stderr);
    /* Give 1 and 2 back; the pipe's last write end closes and the reader
     * drains what is left, then ends. A child process that inherited 1 or 2
     * keeps the pipe open: wait at most half a second, then leave the reader. */
    if (g_log.saved_stdout >= 0) dup2(g_log.saved_stdout, STDOUT_FILENO);
    if (g_log.saved_stderr >= 0) dup2(g_log.saved_stderr, STDERR_FILENO);
    for (int i = 0; i < 50 && !atomic_load(&g_log.reader_done); i++) usleep(10000);
    if (!atomic_load(&g_log.reader_done)) {
        pthread_detach(g_log.reader);
        return;
    }
    pthread_join(g_log.reader, NULL);
    close(g_log.pipe_read);
    if (g_log.saved_stdout >= 0) close(g_log.saved_stdout);
    if (g_log.saved_stderr >= 0) close(g_log.saved_stderr);
    if (g_log.file >= 0) close(g_log.file);
    g_log.pipe_read = g_log.saved_stdout = g_log.saved_stderr = g_log.file = -1;
}
