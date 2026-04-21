PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin

all: tile

tile: tile.asm
	nasm -f elf64 tile.asm -o tile.o
	ld tile.o -o tile
	rm -f tile.o

# strip (the bar) lands in phase 2a — placeholder rule for now.
strip:
	@echo "strip not yet implemented (phase 2a)"

install: tile
	install -Dm755 tile $(DESTDIR)$(BINDIR)/tile
	@echo "Installed tile to $(BINDIR)/tile"

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

.PHONY: all install uninstall clean xephyr xephyr-clean xephyr-multi xephyr-gdb strip
