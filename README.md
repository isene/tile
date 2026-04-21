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

For development under i3, bind tile to chords i3 doesn't grab. Alt is
essentially unused by typical i3 configs, so the built-in defaults
(when there is no `~/.tilerc`) are:

| Key | Action |
|-----|--------|
| `Alt+Return`  | Spawn glass |
| `Alt+q`       | Close the focused window cleanly (WM_DELETE_WINDOW) |
| `Alt+Shift+q` | Exit tile |

Once you cold-switch from i3 to tile on real hardware, `Mod4+`-style
binds work fine — see `tilerc.example` for the config syntax.

To launch a test app inside the Xephyr session:

```bash
DISPLAY=:9 glass                        # or: DISPLAY=:9 xterm
```

## Current capabilities (phases 1a + 1b.1 + 1b.2 + 1b.3a)

- Connects to X11 via Unix socket, MIT-MAGIC-COOKIE-1 authentication
- Claims SubstructureRedirectMask on the root window (single-WM enforcement)
- Maps incoming MapRequest windows full-screen
- ICCCM `WM_DELETE_WINDOW` protocol — `kill` asks the app to close
  cleanly rather than yanking its X11 connection
- **10 workspaces** with `workspace N` / `move-to N` / smart cycling
  (`workspace next-populated` walks only workspaces that have at least
  one window — improvement over i3) / `workspace back-and-forth`
- **Tabbed semantics per workspace** — every workspace is a flat tab
  list. New windows append as tabs; only the active tab is mapped at
  any time. `focus next-tab` / `focus prev-tab` cycles tabs.
  `move-tab left/right` reorders. Closing the active tab auto-focuses
  the next-most-recent one. (Phase 1b.3a — visual tab bar lands in
  1b.3a.2.)
- WM-initiated unmaps don't get treated as window-closed
- `~/.tilerc` config parser

See `tilerc.example` for the full config syntax. Recognised statements:
`bind <chord> <action> [arg]`, `exec <cmdline>`, `# comments`.
Modifiers: `Shift`, `Ctrl`/`Control`, `Alt`/`Mod1`, `Mod4`/`Win`/`Super`.
Actions: `exec`, `kill`, `exit`, `workspace`, `move-to`, `focus`, `move-tab`.

No tab bar UI yet, no splits, no multi-monitor, no `strip` bar yet.
Those land in phases 1b.3a.2 through 2c — see PLAN.md.

## License

[Unlicense](https://unlicense.org/) (public domain)
