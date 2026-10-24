# TBReceiver pure-C build (macOS target).
#
# Prerequisites on the iMac (Intel) running OCLP macOS 14:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
#   brew install ffmpeg sdl2 pkgconf libsodium   (libsodium: PWE pairing and encryption)
#
# Build:
#   make
#
# Run:
#   ./tbreceiver              # fullscreen
#   ./tbreceiver --windowed   # debug windowed
#
# Linux target (later): identical sources, swap LDFLAGS to pkgconf on
#   libavcodec libavutil sdl2 ; drop -framework lines.

CC       ?= clang
PKG      ?= pkgconf
APP_VERSION ?= 3.6.0
APP_BUILD   ?= dev

MACOSX_DEPLOYMENT_TARGET ?= 11.0
export MACOSX_DEPLOYMENT_TARGET

CFLAGS   += -O2 -g -Wall -Wextra -Wno-unused-parameter -std=c11
CFLAGS   += $(shell $(PKG) --cflags libavcodec libavutil libswscale sdl2)
CFLAGS   += -DTB_RECEIVER_VERSION=\"$(APP_VERSION)\" -DTB_RECEIVER_BUILD=\"$(APP_BUILD)\"
CFLAGS   += -DTB_LANGUAGE_SOURCE_DIR=\"$(abspath ../../TargetBridge-Shared/Languages)\"

# 1 = a calm idle screen (name, what it waits for, one hint); I shows the details.
COMPACT_IDLE ?= 0
CFLAGS   += -DTB_RECEIVER_COMPACT_IDLE=$(COMPACT_IDLE)

# 1 = ask once whether to open at login; A on the details screen turns it on or off.
OFFER_LOGIN_ITEM ?= 0
CFLAGS   += -DTB_RECEIVER_OFFER_LOGIN_ITEM=$(OFFER_LOGIN_ITEM)

# 1 = accept senders only over direct links (Thunderbolt Bridge, USB, loopback)
# unless the user turns on AllowLocalNetwork; 0 = accept on every interface.
# Either way a sender on any other link must resume an encrypted, already
# paired session (net.h, tb_net_accept_policy).
DIRECT_LINK_ONLY ?= 0
CFLAGS   += -DTB_RECEIVER_DIRECT_LINK_ONLY=$(DIRECT_LINK_ONLY)

LDFLAGS  += $(shell $(PKG) --libs libavcodec libavutil libswscale sdl2)

# ---- PWE: pairing and encrypted sessions -----------------------------------
# libsodium (ISC, static in release builds: pwe/receiver-deps.sh). The secure
# layer is shared with the sender and lives in TargetBridge-Shared/secure/.
SEC_DIR  := ../../TargetBridge-Shared/secure
SODIUM_CFLAGS = $(shell $(PKG) --cflags libsodium)
SODIUM_LIBS   = $(shell $(PKG) --libs libsodium)
CFLAGS   += -I$(SEC_DIR) $(SODIUM_CFLAGS)
LDFLAGS  += $(SODIUM_LIBS) -framework Security
SEC_OBJ  = src/tb_conn.o src/pwe_secure.o src/pwe_keystore.o src/tb_pairing_menu.o
# 1 = test hooks (code file, loopback counts as the cable, test keychain
# service); never in a release build.
TEST_HOOKS ?= 0
CFLAGS   += -DTB_RECEIVER_TEST_HOOKS=$(TEST_HOOKS)
# ---- end PWE ---------------------------------------------------------------

UNAME_S  := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
LDFLAGS  += -framework ApplicationServices -framework AppKit -framework CoreFoundation -framework CoreGraphics -framework CoreText -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework IOSurface -framework CoreServices -framework CoreAudio -framework SystemConfiguration -framework ServiceManagement
# PWE (1.1.1): IOPMAssertionDeclareUserActivity wakes the screen when a session starts.
LDFLAGS  += -framework IOKit
endif

C_SRC = src/main.c src/net.c src/audio_ring.c src/decoder.c src/display.c src/input_queue.c src/idle_watchdog.c src/receiver_profile.c src/tb_i18n.c
# Receiver rendering (PWE 1.1): frame timing behind TB_RECEIVER_TRACE=1, Metal
# zero-copy video paced to the display refresh.
C_SRC += src/tb_trace.c src/tb_vsync.c
# Receiver-drawn pointer: the picture packet (0x39).
C_SRC += src/tb_cursor_image.c
# The log file, ~/Library/Logs/<app>/receiver.log (PWE 1.1).
C_SRC += src/tb_log.c
# The main loop's watchdog: names a call that blocks the loop (PWE 1.1, T40).
C_SRC += src/tb_loopwatch.c
# The global event tap on its own run-loop thread, and its rate line (PWE 1.1.1, A15).
C_SRC += src/tb_runloop_thread.c src/tb_input_rate.c
# Brightness on the display the window is on (PWE 1.1.1, A6).
C_SRC += src/tb_brightness.c
# Sound output and volume on their own thread, off the main loop (PWE 1.1, T40).
C_SRC += src/audio_out.c
# Hardware decode as VideoToolbox reports it, and the [sys] start-up line (PWE 1.1).
C_SRC += src/tb_sysinfo.c
OBJC_SRC_PWE_RENDER = src/tb_metal_video.m
LDFLAGS += -framework Metal -framework QuartzCore
OBJC_SRC = src/tb_gesture_bridge.m src/tb_display_tweaks.m src/tb_login_item.m
# The iMac's clipboard on its own thread, off the main loop (PWE 1.1, T40).
OBJC_SRC += src/tb_clipboard.m
# The copy already running, when a second one starts (PWE 1.1.1).
OBJC_SRC += src/tb_running_app.m
OBJC_SRC += $(OBJC_SRC_PWE_RENDER)
OBJ = $(C_SRC:.c=.o) $(OBJC_SRC:.m=.o) $(SEC_OBJ)
BIN = tbreceiver

all: $(BIN)

$(BIN): $(OBJ)
	$(CC) -o $@ $(OBJ) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.m
	$(CC) $(CFLAGS) -fobjc-arc -c -o $@ $<

# PWE: shared sources build their objects here, not in TargetBridge-Shared/.
src/pwe_%.o: $(SEC_DIR)/pwe_%.c $(SEC_DIR)/pwe_secure.h
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJ) $(BIN) $(TEST_BIN) $(TEST_INPUT_QUEUE_BIN) $(TEST_IDLE_WATCHDOG_BIN) $(TEST_RECEIVER_PROFILE_BIN) $(TEST_AUDIO_RING_BIN) $(TEST_AUDIO_OUT_BIN) $(TEST_CLIPBOARD_BIN) $(TEST_SYSINFO_BIN) test_monitor_shield
	rm -f smoke_peer pboard_tool post_moves
	rm -f $(PWE_RENDER_TEST_BINS)
	rm -f $(TEST_SECURE_BIN) bench_secure secure_receiver secure_peer
	rm -rf *.dSYM

# Unit tests for the packet parser. net.c is pure POSIX, so this needs no
# ffmpeg/SDL/pkgconf — it runs anywhere, including CI, with no hardware.
TEST_CFLAGS = -O2 -g -Wall -Wextra -Wno-unused-parameter -std=c11
TEST_LDFLAGS =
ifeq ($(UNAME_S),Darwin)
TEST_LDFLAGS += -framework CoreFoundation -framework SystemConfiguration
endif
TEST_BIN = test_net_parser
TEST_INPUT_QUEUE_BIN = test_input_queue
TEST_IDLE_WATCHDOG_BIN = test_idle_watchdog
TEST_RECEIVER_PROFILE_BIN = test_receiver_profile
TEST_AUDIO_RING_BIN = test_audio_ring
# PWE (T40): the sound output thread; SDL's dummy audio driver, no device.
TEST_AUDIO_OUT_BIN = test_audio_out
# PWE (T40): the clipboard thread; named test pasteboards, never the system clipboard.
TEST_CLIPBOARD_BIN = test_clipboard
# PWE: hardware decode answer and the [sys] line.
TEST_SYSINFO_BIN = test_sysinfo

test_net_parser: tests/test_net_parser.c src/net.c src/net.h src/proto.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_net_parser.c src/net.c $(TEST_LDFLAGS) -o $@

$(TEST_INPUT_QUEUE_BIN): tests/test_input_queue.c src/input_queue.c src/input_queue.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_input_queue.c src/input_queue.c -o $@

$(TEST_IDLE_WATCHDOG_BIN): tests/test_idle_watchdog.c src/idle_watchdog.c src/idle_watchdog.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_idle_watchdog.c src/idle_watchdog.c -o $@

$(TEST_AUDIO_RING_BIN): tests/test_audio_ring.c src/audio_ring.c src/audio_ring.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_audio_ring.c src/audio_ring.c -o $@

$(TEST_AUDIO_OUT_BIN): tests/test_audio_out.c src/audio_out.c src/audio_out.h src/audio_ring.c src/audio_ring.h
	$(CC) $(TEST_CFLAGS) -DTB_RECEIVER_TEST_HOOKS=1 -Isrc $(shell $(PKG) --cflags sdl2) tests/test_audio_out.c src/audio_out.c src/audio_ring.c \
	    $(shell $(PKG) --libs sdl2) -o $@

$(TEST_CLIPBOARD_BIN): tests/test_clipboard.m src/tb_clipboard.m src/tb_clipboard.h
	$(CC) -O2 -g -Wall -Wextra -Wno-unused-parameter -fobjc-arc -DTB_RECEIVER_TEST_HOOKS=1 -Isrc tests/test_clipboard.m src/tb_clipboard.m \
	    -framework Foundation -framework AppKit -o $@

$(TEST_SYSINFO_BIN): tests/test_sysinfo.c src/tb_sysinfo.c src/tb_sysinfo.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_sysinfo.c src/tb_sysinfo.c \
	    -framework VideoToolbox -framework CoreMedia -framework CoreFoundation -o $@

$(TEST_RECEIVER_PROFILE_BIN): tests/test_receiver_profile.c src/receiver_profile.c src/receiver_profile.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_receiver_profile.c src/receiver_profile.c -o $@

# Receiver rendering (PWE 1.1): tests for the pure-C parts.
PWE_RENDER_TEST_BINS = test_trace test_metal_video test_cursor_image test_log test_loopwatch
# PWE (1.1.1): log windows per kind of event.
PWE_RENDER_TEST_BINS += test_ratelimit
# PWE (1.1.1): only the newest picture of a backlog is shown.
PWE_RENDER_TEST_BINS += test_catchup
# PWE (1.1.1): the event tap on its own run-loop thread, and its rate line.
PWE_RENDER_TEST_BINS += test_runloop_thread test_input_rate
# PWE (1.1.1): threads for software decoding.
PWE_RENDER_TEST_BINS += test_decthreads
# PWE (1.1.1): brightness on the window's display only.
PWE_RENDER_TEST_BINS += test_brightness


# ---- PWE: secure layer tests (need libsodium; AddressSanitizer on) -----------
TEST_SECURE_BIN = test_secure
SEC_TEST_FLAGS = $(TEST_CFLAGS) -O1 -fsanitize=address,undefined -fno-omit-frame-pointer \
                 -D_DARWIN_C_SOURCE -Isrc -I$(SEC_DIR) $(SODIUM_CFLAGS)
SEC_TEST_LIBS  = $(SODIUM_LIBS) $(TEST_LDFLAGS) -framework Security
SEC_TEST_SRC   = $(SEC_DIR)/pwe_secure.c $(SEC_DIR)/pwe_keystore.c src/tb_conn.c src/net.c

$(TEST_SECURE_BIN): tests/test_secure.c $(SEC_TEST_SRC) $(SEC_DIR)/pwe_secure.h src/net.h src/proto.h
	$(CC) $(SEC_TEST_FLAGS) tests/test_secure.c $(SEC_TEST_SRC) $(SEC_TEST_LIBS) -o $@

secure_receiver: tests/secure_receiver.c $(SEC_TEST_SRC) $(SEC_DIR)/pwe_keystore.h
	$(CC) $(SEC_TEST_FLAGS) tests/secure_receiver.c $(SEC_TEST_SRC) $(SEC_TEST_LIBS) -o $@

secure_peer: tests/secure_peer.c $(SEC_TEST_SRC) $(SEC_DIR)/pwe_keystore.h
	$(CC) $(SEC_TEST_FLAGS) tests/secure_peer.c $(SEC_TEST_SRC) $(SEC_TEST_LIBS) -o $@

# PWE (T40): the receiver smoke's encrypted sender for its clipboard phase:
# secure_peer without sanitizers (it runs under Rosetta for x86_64), and the
# helper that copies on a named test pasteboard.
smoke_peer: tests/secure_peer.c $(SEC_TEST_SRC) $(SEC_DIR)/pwe_secure.h $(SEC_DIR)/pwe_keystore.h
	$(CC) $(TEST_CFLAGS) -D_DARWIN_C_SOURCE -Isrc -I$(SEC_DIR) $(SODIUM_CFLAGS) \
	  tests/secure_peer.c $(SEC_TEST_SRC) $(SEC_TEST_LIBS) -o $@

# PWE (1.1.1): input for the smoke's event-tap phase (still mouse moves).
post_moves: tests/post_moves.c
	$(CC) -O2 -g -Wall -Wextra tests/post_moves.c -framework ApplicationServices -o $@

pboard_tool: tests/pboard_tool.m
	$(CC) -O2 -g -Wall -Wextra -fobjc-arc tests/pboard_tool.m -framework Foundation -framework AppKit -o $@

# Pairing + encrypted stream between two processes over loopback, with the
# login keychain. A test hook until main.c uses tb_conn (step R2).
test-loopback: secure_receiver secure_peer
	zsh tests/secure_loopback.sh

# Without sanitizers, optimised as the apps are.
bench_secure: tests/test_secure.c $(SEC_TEST_SRC)
	$(CC) $(TEST_CFLAGS) -D_DARWIN_C_SOURCE -Isrc -I$(SEC_DIR) $(SODIUM_CFLAGS) \
	  tests/test_secure.c $(SEC_TEST_SRC) $(SEC_TEST_LIBS) -o $@

bench-secure: bench_secure
	./bench_secure --bench
# ---- end PWE ---------------------------------------------------------------

test: $(TEST_BIN) $(TEST_INPUT_QUEUE_BIN) $(TEST_IDLE_WATCHDOG_BIN) $(TEST_RECEIVER_PROFILE_BIN) $(TEST_AUDIO_RING_BIN) $(TEST_AUDIO_OUT_BIN) $(TEST_CLIPBOARD_BIN) $(TEST_SYSINFO_BIN) $(PWE_RENDER_TEST_BINS) $(TEST_SECURE_BIN)
	./$(TEST_BIN)
	./$(TEST_INPUT_QUEUE_BIN)
	./$(TEST_IDLE_WATCHDOG_BIN)
	./$(TEST_RECEIVER_PROFILE_BIN)
	./$(TEST_AUDIO_RING_BIN)
	./$(TEST_AUDIO_OUT_BIN)
	./$(TEST_CLIPBOARD_BIN)
	./$(TEST_SYSINFO_BIN)
	for t in $(PWE_RENDER_TEST_BINS); do ./$$t || exit 1; done
	./$(TEST_SECURE_BIN)

test_trace: tests/test_trace.c src/tb_trace.c src/tb_trace.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_trace.c src/tb_trace.c -o $@

test_log: tests/test_log.c src/tb_log.c src/tb_log.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_log.c src/tb_log.c -o $@

test_loopwatch: tests/test_loopwatch.c src/tb_loopwatch.c src/tb_loopwatch.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_loopwatch.c src/tb_loopwatch.c -o $@

test_ratelimit: tests/test_ratelimit.c src/tb_ratelimit.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_ratelimit.c -o $@

test_catchup: tests/test_catchup.c src/tb_catchup.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_catchup.c -o $@

test_runloop_thread: tests/test_runloop_thread.c src/tb_runloop_thread.c src/tb_runloop_thread.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_runloop_thread.c src/tb_runloop_thread.c -framework CoreFoundation -o $@

test_input_rate: tests/test_input_rate.c src/tb_input_rate.c src/tb_input_rate.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_input_rate.c src/tb_input_rate.c -o $@

test_decthreads: tests/test_decthreads.c src/tb_decthreads.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_decthreads.c -o $@

test_brightness: tests/test_brightness.c src/tb_brightness.c src/tb_brightness.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_brightness.c src/tb_brightness.c -framework CoreGraphics -o $@

test_cursor_image: tests/test_cursor_image.c src/tb_cursor_image.c src/tb_cursor_image.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_cursor_image.c src/tb_cursor_image.c -o $@

# Needs a Metal device (any Mac), not a window; prints SKIP without one.
test_metal_video: tests/test_metal_video.m src/tb_metal_video.m src/tb_metal_video.h src/tb_trace.c src/tb_trace.h src/tb_loopwatch.c
	$(CC) -O2 -g -Wall -Wextra -Wno-unused-parameter -fobjc-arc -Isrc tests/test_metal_video.m src/tb_metal_video.m \
	    src/tb_trace.c src/tb_loopwatch.c -framework Foundation -framework AppKit -framework Metal -framework QuartzCore \
	    -framework CoreVideo -framework IOSurface -o $@

# AppKit lifecycle coverage requires a logged-in macOS GUI session.
test_monitor_shield: tests/test_monitor_shield.m src/tb_gesture_bridge.m src/tb_gesture_bridge.h
	$(CC) -fobjc-arc -framework AppKit -framework CoreGraphics tests/test_monitor_shield.m -o $@

test-monitor-shield: test_monitor_shield
	./test_monitor_shield

.PHONY: all clean test test-monitor-shield test-loopback bench-secure
