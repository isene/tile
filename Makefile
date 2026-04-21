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

# Run inside Xephyr for development. Two modes:
#
#   make xephyr       — windowed Xephyr (1280x800). Does not interfere
#                       with the host WM, BUT host key grabs (e.g. i3's
#                       Mod4+Return) fire FIRST and never reach tile.
#                       Useful for visual / mapping checks. To send keys
#                       to tile, briefly switch host WM keybinds OR use
#                       a chord the host doesn't bind.
#
#   make xephyr-full  — fullscreen Xephyr with -terminate. Host WM
#                       cannot see any keys; tile receives everything
#                       including Mod4+Return. When you exit tile via
#                       Mod4+Shift+q, Xephyr exits with it and the
#                       host WM regains control. The standard
#                       window-manager development workflow.
#
#   make xephyr-multi — windowed dual-output simulation via +xinerama,
#                       for testing workspace pinning + RandR logic.
xephyr: tile
	@if ! command -v Xephyr >/dev/null; then \
	  echo "Xephyr not installed (apt: xserver-xephyr, arch: xorg-server-xephyr)"; \
	  exit 1; \
	fi
	-pkill -f "Xephyr :9" 2>/dev/null || true
	Xephyr -screen 1280x800 :9 &
	@sleep 1
	DISPLAY=:9 ./tile

xephyr-full: tile
	@if ! command -v Xephyr >/dev/null; then \
	  echo "Xephyr not installed (apt: xserver-xephyr, arch: xorg-server-xephyr)"; \
	  exit 1; \
	fi
	-pkill -f "Xephyr :9" 2>/dev/null || true
	Xephyr -fullscreen -terminate :9 &
	@sleep 1
	DISPLAY=:9 ./tile

xephyr-multi: tile
	-pkill -f "Xephyr :9" 2>/dev/null || true
	Xephyr +xinerama -screen 1280x800 -screen 1280x800 :9 &
	@sleep 1
	DISPLAY=:9 ./tile

clean:
	rm -f tile tile.o strip strip.o

.PHONY: all install uninstall clean xephyr xephyr-full xephyr-multi strip
