# TBReceiver pure-C build (macOS target).
#
# Prerequisites on the iMac (Intel) running OCLP macOS 14:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
#   brew install ffmpeg sdl2 pkgconf
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
OBJ = $(C_SRC:.c=.o) $(OBJC_SRC:.m=.o)
BIN = tbreceiver

all: $(BIN)

$(BIN): $(OBJ)
	$(CC) -o $@ $(OBJ) $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.m
	$(CC) $(CFLAGS) -fobjc-arc -c -o $@ $<

clean:
	rm -f $(OBJ) $(BIN) $(TEST_BIN) $(TEST_INPUT_QUEUE_BIN) $(TEST_IDLE_WATCHDOG_BIN) $(TEST_RECEIVER_PROFILE_BIN) test_monitor_shield
	rm -f $(PWE_RENDER_TEST_BINS)

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

test: $(TEST_BIN) $(TEST_INPUT_QUEUE_BIN) $(TEST_IDLE_WATCHDOG_BIN) $(TEST_RECEIVER_PROFILE_BIN) $(PWE_RENDER_TEST_BINS)
	./$(TEST_BIN)
	./$(TEST_INPUT_QUEUE_BIN)
	./$(TEST_IDLE_WATCHDOG_BIN)
	./$(TEST_RECEIVER_PROFILE_BIN)
	for t in $(PWE_RENDER_TEST_BINS); do ./$$t || exit 1; done

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

.PHONY: all clean test test-monitor-shield
