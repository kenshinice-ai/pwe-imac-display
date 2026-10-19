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
endif

C_SRC = src/main.c src/net.c src/decoder.c src/display.c src/input_queue.c src/idle_watchdog.c src/receiver_profile.c src/tb_i18n.c
# Receiver rendering (PWE 1.1): frame timing behind TB_RECEIVER_TRACE=1, Metal
# zero-copy video paced to the display refresh.
C_SRC += src/tb_trace.c src/tb_vsync.c
# Receiver-drawn pointer: the picture packet (0x39).
C_SRC += src/tb_cursor_image.c
OBJC_SRC_PWE_RENDER = src/tb_metal_video.m
LDFLAGS += -framework Metal -framework QuartzCore
OBJC_SRC = src/tb_gesture_bridge.m src/tb_display_tweaks.m src/tb_login_item.m
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
	rm -f $(OBJ) $(BIN) $(TEST_BIN) $(TEST_INPUT_QUEUE_BIN) $(TEST_IDLE_WATCHDOG_BIN) $(TEST_RECEIVER_PROFILE_BIN) test_monitor_shield
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

test_net_parser: tests/test_net_parser.c src/net.c src/net.h src/proto.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_net_parser.c src/net.c $(TEST_LDFLAGS) -o $@

$(TEST_INPUT_QUEUE_BIN): tests/test_input_queue.c src/input_queue.c src/input_queue.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_input_queue.c src/input_queue.c -o $@

$(TEST_IDLE_WATCHDOG_BIN): tests/test_idle_watchdog.c src/idle_watchdog.c src/idle_watchdog.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_idle_watchdog.c src/idle_watchdog.c -o $@

$(TEST_RECEIVER_PROFILE_BIN): tests/test_receiver_profile.c src/receiver_profile.c src/receiver_profile.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_receiver_profile.c src/receiver_profile.c -o $@

# Receiver rendering (PWE 1.1): tests for the pure-C parts.
PWE_RENDER_TEST_BINS = test_trace test_metal_video test_cursor_image


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

test: $(TEST_BIN) $(TEST_INPUT_QUEUE_BIN) $(TEST_IDLE_WATCHDOG_BIN) $(TEST_RECEIVER_PROFILE_BIN) $(PWE_RENDER_TEST_BINS) $(TEST_SECURE_BIN)
	./$(TEST_BIN)
	./$(TEST_INPUT_QUEUE_BIN)
	./$(TEST_IDLE_WATCHDOG_BIN)
	./$(TEST_RECEIVER_PROFILE_BIN)
	for t in $(PWE_RENDER_TEST_BINS); do ./$$t || exit 1; done
	./$(TEST_SECURE_BIN)

test_trace: tests/test_trace.c src/tb_trace.c src/tb_trace.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_trace.c src/tb_trace.c -o $@

test_cursor_image: tests/test_cursor_image.c src/tb_cursor_image.c src/tb_cursor_image.h
	$(CC) $(TEST_CFLAGS) -Isrc tests/test_cursor_image.c src/tb_cursor_image.c -o $@

# Needs a Metal device (any Mac), not a window; prints SKIP without one.
test_metal_video: tests/test_metal_video.m src/tb_metal_video.m src/tb_metal_video.h src/tb_trace.c src/tb_trace.h
	$(CC) -O2 -g -Wall -Wextra -Wno-unused-parameter -fobjc-arc -Isrc tests/test_metal_video.m src/tb_metal_video.m \
	    src/tb_trace.c -framework Foundation -framework AppKit -framework Metal -framework QuartzCore \
	    -framework CoreVideo -framework IOSurface -o $@

# AppKit lifecycle coverage requires a logged-in macOS GUI session.
test_monitor_shield: tests/test_monitor_shield.m src/tb_gesture_bridge.m src/tb_gesture_bridge.h
	$(CC) -fobjc-arc -framework AppKit -framework CoreGraphics tests/test_monitor_shield.m -o $@

test-monitor-shield: test_monitor_shield
	./test_monitor_shield

.PHONY: all clean test test-monitor-shield test-loopback bench-secure
