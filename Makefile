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
xephyr: tile
	@if ! command -v Xephyr >/dev/null; then \
	  echo "Xephyr not installed (apt: xserver-xephyr, arch: xorg-server-xephyr)"; \
	  exit 1; \
	fi
	-pkill -f "Xephyr :9" 2>/dev/null || true
	Xephyr -screen 1280x800 :9 &
	@sleep 1
	DISPLAY=:9 ./tile

xephyr-multi: tile
	-pkill -f "Xephyr :9" 2>/dev/null || true
	Xephyr +xinerama -screen 1280x800 -screen 1280x800 :9 &
	@sleep 1
	DISPLAY=:9 ./tile

clean:
	rm -f tile tile.o strip strip.o

.PHONY: all install uninstall clean xephyr xephyr-multi strip
