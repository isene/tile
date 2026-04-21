# tile - Pure Assembly Tiling Window Manager

![Version](https://img.shields.io/badge/version-0.0.1-blue)
![Assembly](https://img.shields.io/badge/language-x86__64%20Assembly-purple)
![License](https://img.shields.io/badge/license-Unlicense-green)
![Platform](https://img.shields.io/badge/platform-Linux%20x86__64-blue)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)
![X11](https://img.shields.io/badge/protocol-X11%20wire-ff6600)

Tiling window manager written in x86_64 Linux assembly. No libc, no
toolkit, pure syscalls. Speaks X11 wire protocol directly via Unix
socket.

Part of the **CHasm** (CHange to ASM) suite, alongside
[bare](https://github.com/isene/bare) (shell),
[show](https://github.com/isene/show) (file viewer), and
[glass](https://github.com/isene/glass) (terminal emulator).

**Status: phase 1a (early development).** See
[PLAN.md](PLAN.md) for the full architecture and roadmap.

## Goals

- Replace i3 + i3bar + i3status + conky + stalonetray for the
  author's daily workflow
- No floating windows. Tiling only.
- Tabbed layout as default (matches typical vim/glass usage)
- Smart workspace cycling (Win+Right/Left walks only populated
  workspaces; Win+N jumps direct)
- Workspace pinned to output (external monitor always shows a
  designated workspace)
- A real bar (`strip`) with system tray (XEMBED) — coming in phase 2

## Build (requires nasm and ld)

```bash
git clone https://github.com/isene/tile.git
cd tile
make
```

## Run safely under Xephyr (development)

[Xephyr](https://www.freedesktop.org/wiki/Software/Xephyr/) is a
nested X server that runs as a window inside your existing X
session. tile inside Xephyr cannot affect your host i3/Gnome/KDE
session, so a crash or bug just kills the Xephyr window.

```bash
sudo apt install xserver-xephyr        # Debian/Ubuntu (Arch: xorg-server-xephyr)

make xephyr                            # windowed Xephyr (1280x800)
make xephyr-multi                      # dual-output simulation (+xinerama)
```

### A subtlety about keybindings

Xephyr (even with `-fullscreen`) does **not** shield keystrokes from
the host window manager. The host WM's passive key grabs fire first —
if your host i3 binds `Mod4+Return`, then `Mod4+Return` typed inside
Xephyr is captured by i3, not delivered to tile.

To stay out of the host's way during phase 1a development, tile uses
Alt-based dev binds (Alt is essentially unused by typical i3 configs):

| Key | Action |
|-----|--------|
| `Alt+Return`  | Spawn glass (or xterm fallback) |
| `Alt+q`       | Kill the most-recently-mapped client |
| `Alt+Shift+q` | Exit tile (Xephyr stays open, just unmanaged) |

These are hardcoded for now. Real `Mod4+`-style binds, fully
configurable from `~/.tilerc`, arrive in phase 1b.

To launch a test app inside the Xephyr session:

```bash
DISPLAY=:9 glass                        # or: DISPLAY=:9 xterm
```

## Phase 1a current capabilities

This is the absolute MVP, used to validate the X11 plumbing.

- Connects to X11 via Unix socket, MIT-MAGIC-COOKIE-1 authentication
- Claims SubstructureRedirectMask on the root window (single WM
  enforcement)
- Maps incoming MapRequest windows full-screen (no tiling yet, no
  workspaces)
- Grants ConfigureRequest geometry (clamped to screen)
- Three hardcoded keybindings (Alt-based for windowed-Xephyr compatibility,
  see "A subtlety about keybindings" above):
  - `Alt+Return` → exec glass (or fall back to xterm)
  - `Alt+q` → kill the focused (most recent) window
  - `Alt+Shift+q` → exit tile

No config, no layouts, no workspaces, no bar. Those land in phases
1b through 2c — see PLAN.md.

## License

[Unlicense](https://unlicense.org/) (public domain)
