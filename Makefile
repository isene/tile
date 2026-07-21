PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin

all: tile strip

tile: tile.asm
	nasm -f elf64 tile.asm -o tile.o
	ld tile.o -o tile
	rm -f tile.o

# strip — the status bar binary (phase 2a skeleton: window + render).
strip: strip.asm
	nasm -f elf64 strip.asm -o strip.o
	ld strip.o -o strip
	rm -f strip.o

install: tile strip
	install -Dm755 tile $(DESTDIR)$(BINDIR)/tile
	install -Dm755 strip $(DESTDIR)$(BINDIR)/strip
	@echo "Installed tile and strip to $(BINDIR)/"

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/tile $(DESTDIR)$(BINDIR)/strip

# Run inside Xephyr for development.
#
# Important: Xephyr (even in fullscreen) does NOT shield input from the
# host WM. The host's passive key grabs (e.g. i3 binding Mod4+Return)
# fire before Xephyr ever forwards the key inward, so tile would not
# see Mod4+anything that the host has bound. To work around this in
# phase 1a, tile uses Alt+ keybindings during development:
#
#   Alt+Return   -> exec glass / xterm (whichever is found)
#   Alt+q        -> kill latest mapped client
#   Alt+Shift+q  -> exit tile
#
# Real Mod4 binds land in phase 1b alongside the config parser.
#
#   make xephyr        — windowed Xephyr (1280x800), Alt+ binds work
#   make xephyr-multi  — windowed dual-output simulation via +xinerama,
#                        for testing workspace pinning + RandR logic
# Clean up any leftover Xephyr on :9 (process + lock + socket).
xephyr-clean:
	-@pkill -f "Xephyr :9" 2>/dev/null; true
	-@pkill -x Xephyr 2>/dev/null; true
	-@sleep 0.3
	-@rm -f /tmp/.X9-lock /tmp/.X11-unix/X9 2>/dev/null; true

xephyr: tile xephyr-clean
	@if ! command -v Xephyr >/dev/null; then \
	  echo "Xephyr not installed (apt: xserver-xephyr, arch: xorg-server-xephyr)"; \
	  exit 1; \
	fi
	@bash -c '\
	  Xephyr -terminate -screen 1280x800 :9 & \
	  XPID=$$!; \
	  sleep 1; \
	  DISPLAY=:9 ./tile; \
	  kill $$XPID 2>/dev/null; \
	  wait $$XPID 2>/dev/null; \
	  rm -f /tmp/.X9-lock /tmp/.X11-unix/X9 2>/dev/null; \
	  true'

xephyr-multi: tile xephyr-clean
	@bash -c '\
	  Xephyr -terminate +xinerama -screen 1280x800 -screen 1280x800 :9 & \
	  XPID=$$!; \
	  sleep 1; \
	  DISPLAY=:9 ./tile; \
	  kill $$XPID 2>/dev/null; \
	  wait $$XPID 2>/dev/null; \
	  rm -f /tmp/.X9-lock /tmp/.X11-unix/X9 2>/dev/null; \
	  true'

# Run tile under gdb in Xephyr. When it crashes, gdb stops; type 'bt'
# and 'info registers' to capture the diagnostic. 'q' to quit.
# Force SHELL=/bin/sh so gdb can launch the program (the user's bare
# shell doesn't recognise gdb's "exec" wrapper).
xephyr-gdb: tile xephyr-clean
	@bash -c '\
	  Xephyr -terminate -screen 1280x800 :9 & \
	  XPID=$$!; \
	  sleep 1; \
	  SHELL=/bin/sh DISPLAY=:9 gdb -ex "set startup-with-shell off" --args ./tile; \
	  kill $$XPID 2>/dev/null; \
	  wait $$XPID 2>/dev/null; \
	  rm -f /tmp/.X9-lock /tmp/.X11-unix/X9 2>/dev/null; \
	  true'

clean:
	rm -f tile tile.o strip strip.o

.PHONY: all install uninstall clean xephyr xephyr-clean xephyr-multi xephyr-gdb strip deb

# ── Debian package ─────────────────────────────────────────────────────
# Version comes from the README badge (the repo's single version marker).
# The strip binary installs as tile-strip: /usr/bin/strip is binutils'.
VERSION := $(shell grep -oP 'version-\K[0-9.]+(?=-blue)' README.md)

deb: tile strip
	rm -rf pkgroot
	install -Dm755 tile pkgroot/usr/bin/tile
	install -Dm755 strip pkgroot/usr/bin/tile-strip
	install -Dm644 tilerc.example pkgroot/usr/share/doc/tile/tilerc.example
	install -Dm644 LICENSE pkgroot/usr/share/doc/tile/copyright
	install -d pkgroot/DEBIAN
	printf 'Package: tile\nVersion: $(VERSION)\nArchitecture: amd64\nMaintainer: Geir Isene <g@isene.com>\nSection: x11\nPriority: optional\nHomepage: https://github.com/isene/tile\nDescription: Tiling window manager in x86_64 assembly\n No libc, pure syscalls, X11 wire protocol. Ten workspaces, tabs,\n splits, multi-output with workspace pinning, exposé. Ships the strip\n status bar as /usr/bin/tile-strip (the name strip belongs to binutils).\n' > pkgroot/DEBIAN/control
	dpkg-deb --build --root-owner-group pkgroot tile_$(VERSION)_amd64.deb
	rm -rf pkgroot
