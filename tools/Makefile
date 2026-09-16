# Builds build/tools/fakeinput, a CLI that injects pointer and keyboard events
# into a KWin Wayland session through org_kde_kwin_fake_input.
#
#   make -C tools                  build build/tools/fakeinput
#   make -C tools desktop          register the binary with KWin (see below)
#   make -C tools uninstall        remove that registration
#   make -C tools clean            remove build/tools
#
# Generated protocol code lands in build/tools/ next to the binary.
#
# KWin hides org_kde_kwin_fake_input from every client except those whose
# executable is the Exec= of an installed .desktop file listing the interface
# in X-KDE-Wayland-Interfaces (kwin src/wayland_server.cpp,
# KWinDisplay::allowInterface). The `desktop` target writes such a file into
# $XDG_DATA_HOME/applications with the absolute path of the built binary and
# refreshes the KService cache so a running KWin picks it up. Rerun it after
# moving the checkout.

TOOLS := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TOP   := $(abspath $(TOOLS)/..)
OUT   := $(TOP)/build/tools

PKG_CONFIG ?= pkg-config
WAYLAND_SCANNER ?= wayland-scanner
CC ?= cc

WL_CFLAGS := $(shell $(PKG_CONFIG) --cflags wayland-client)
WL_LIBS   := $(shell $(PKG_CONFIG) --libs wayland-client)

CFLAGS  ?= -O2 -g
CFLAGS  += -std=c11 -Wall -Wextra -I$(OUT) -I$(TOOLS) $(WL_CFLAGS)
LDLIBS  += $(WL_LIBS)

PROTO   := $(TOOLS)/protocols/fake-input.xml
PROTO_H := $(OUT)/fake-input-client-protocol.h
PROTO_C := $(OUT)/fake-input-protocol.c
BIN     := $(OUT)/fakeinput

XDG_DATA_HOME ?= $(HOME)/.local/share
DESKTOP_DIR   := $(XDG_DATA_HOME)/applications
DESKTOP       := $(DESKTOP_DIR)/kwin-canvas-fakeinput.desktop

.PHONY: all desktop uninstall clean

all: $(BIN)

$(OUT):
	mkdir -p $(OUT)

$(PROTO_H): $(PROTO) | $(OUT)
	$(WAYLAND_SCANNER) client-header $< $@

$(PROTO_C): $(PROTO) | $(OUT)
	$(WAYLAND_SCANNER) private-code $< $@

$(OUT)/fakeinput.o: $(TOOLS)/fakeinput.c $(TOOLS)/keys.h $(PROTO_H) | $(OUT)
	$(CC) $(CFLAGS) -c -o $@ $<

$(OUT)/fake-input-protocol.o: $(PROTO_C) | $(OUT)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BIN): $(OUT)/fakeinput.o $(OUT)/fake-input-protocol.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

desktop: $(DESKTOP)

$(DESKTOP): $(TOOLS)/fakeinput.desktop.in $(BIN)
	mkdir -p $(DESKTOP_DIR)
	sed 's|@BIN@|$(BIN)|' $< > $@
	-kbuildsycoca6 >/dev/null 2>&1

uninstall:
	rm -f $(DESKTOP)
	-kbuildsycoca6 >/dev/null 2>&1

clean:
	rm -rf $(OUT)
