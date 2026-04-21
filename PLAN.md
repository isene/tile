# tile — pure-asm tiling window manager

Part of the **CHasm** (CHange to ASM) suite, alongside
[bare](https://github.com/isene/bare) (shell),
[show](https://github.com/isene/show) (file viewer), and
[glass](https://github.com/isene/glass) (terminal emulator).

`tile` is an x86_64 Linux tiling window manager intended to replace i3
for the author's daily workflow. Pure NASM assembly, no libc, X11 wire
protocol over Unix domain socket, single static binary.

This document is the build plan agreed before implementation starts.

---

## Goals

- Replace i3 + i3bar + i3status + conky + stalonetray for the author's
  daily setup on a Dell XPS 14 (laptop only) or XPS 14 + external HDMI.
- No floating windows. Tiling only.
- Tabbed layout as the default (matches author's 98%-of-the-time
  workflow).
- Smart workspace cycling: Win+Right/Left walks only populated
  workspaces; Win+N jumps direct (improvement over i3).
- Workspace-pinned-to-output, so the external monitor always shows a
  designated workspace.
- A real bar (`strip`) with system tray (XEMBED), so nm-applet,
  fortinet client, and similar tray-only apps work.
- Fits the CHasm aesthetic: pure asm, no libc, no toolkit, no font
  engine, single static binary per component.

## Non-goals (out of scope, ever)

- Floating windows
- Stacking layout (only tabbed + split-h + split-v)
- i3-config full compatibility (config is a simple key=value format
  managed by `tileconf`)
- Wayland (X11 only)
- Custom rendering for tray icons (XEMBED handles it)
- HTTP/TLS in pure asm (weather/gmail/geolocation use refresher
  children that exec curl)

---

## Components

### `tile` — the window manager

Single `.asm` file, ~9.5k lines projected, ~75KB binary.

### `strip` — the bar with system tray

Single `.asm` file, ~5.4k lines projected, ~50KB binary.

Lives in the same repo, same Makefile.

### `tileconf` — Rust config TUI

Like `bareconf` and `glassconf`. Separate repo
(`github.com/isene/tileconf`). Built later, after the asm components
stabilise.

---

## Config: `~/.tilerc`

Simple line-based key=value (like `~/.barerc` and `~/.glassrc`).

```
# Modifier
mod = Mod4

# Bindings
bind Mod4+1                workspace 1
bind Mod4+2                workspace 2
bind Mod4+Shift+1          move-to 1
bind Mod4+Shift+2          move-to 2
bind Mod4+Right            workspace next-populated
bind Mod4+Left             workspace prev-populated
bind Mod4+q                kill
bind Mod4+f                fullscreen
bind Mod4+h                split horizontal
bind Mod4+v                split vertical
bind Mod4+t                layout tabbed
bind Mod4+e                layout default
bind Mod4+Return           exec glass
bind Mod4+space            exec rofi -show run
bind Mod4+Escape           exec i3lock -c 000000
bind Mod4+Shift+q          exit
bind Mod4+i                stash
bind Mod4+o                unstash
bind Mod4+Shift+Down       move-workspace-to-output down
bind Mod4+Shift+Up         move-workspace-to-output up

# Window assignments (substring match against WM_CLASS)
assign Weechat       1
assign discord       1
assign Firefox       3

# Multi-monitor
pin workspace 0 to HDMI-1
fallback workspace 0 to eDP-1   # if HDMI-1 disconnected, show on eDP-1

# Defaults
default_layout = tabbed
gaps = 1
focus_follows_mouse = no
border = none
font = -*-terminus-*-*-*-*-16-*-*-*-*-*-iso10646-1

# Autostart (one exec per line)
exec feh --bg-fill /home/geir/setup/wallpapers/blue.png
exec picom --config /home/geir/.config/picom/picom.conf
exec strip
exec nm-applet
exec /home/geir/bin/xps14
```

**Modifier names**: `Mod1` (Alt), `Mod4` (Win/Super), `Shift`, `Ctrl`.
**Key names**: any X11 keysym (we get them from GetKeyboardMapping —
parser accepts the common ones literally: `Return`, `Escape`, `space`,
`Tab`, `Left`, `Right`, `Up`, `Down`, `F1`–`F12`, `BackSpace`,
`Delete`, `Home`, `End`, `Page_Up`, `Page_Down`, single ASCII chars,
named symbols like `plus`, `minus`, `comma`, `period`, `less`).

**Actions**:
- `workspace N` / `workspace next-populated` / `workspace prev-populated` / `workspace back-and-forth`
- `move-to N`
- `kill`
- `fullscreen`
- `split horizontal` / `split vertical`
- `layout tabbed` / `layout default`
- `exec <command line>`
- `stash` / `unstash` (replaces scratchpad — see below)
- `move-workspace-to-output up|down|left|right|primary|secondary`
- `move-window-to-output ...`
- `exit`
- `reload` (re-read `~/.tilerc`)

---

## strip config: `~/.striprc`

```
# Strip — the CHasm bar
font_size = 16
bg = #000000
fg = #cccccc
height = 22
position = top

# Segments (left = workspaces, then title, then right segments in order)
segment workspaces
segment title
segment_right tray
segment_right weather   /tmp/strip-weather   600
segment_right gmail     /tmp/strip-gmail     300
segment_right geo       /tmp/strip-geo       3600
segment_right cpu
segment_right mem
segment_right disk
segment_right battery
segment_right ip
segment_right brightness
segment_right volume
segment_right datetime  "%H:%M  %Y-%m-%d"

# Refresher children (strip spawns these on startup)
refresher /tmp/strip-weather  600  curl -s "wttr.in/Tromso?format=%t+%C+%h"
refresher /tmp/strip-gmail    300  /home/geir/bin/gmail-count
refresher /tmp/strip-geo      3600 /home/geir/bin/geolocate

# Colors
color_workspace_active = #ffffff,#000000
color_workspace_inactive = #777777,#000000
color_title = #cccccc,#000000
color_status = #cccccc,#000000
```

**File-backed segments** (`segment_right NAME PATH INTERVAL`): strip
reads `PATH` every render (cheap), and re-spawns the matching
`refresher` every `INTERVAL` seconds to update the file. This is how
we get weather/email/geo without HTTP/TLS in asm.

**Built-in segments** (`workspaces`, `title`, `tray`, `cpu`, `mem`,
`disk`, `battery`, `ip`, `brightness`, `volume`, `datetime`): strip
reads `/proc`, `/sys`, syscalls directly.

**Tray segment** (`tray`): strip claims `_NET_SYSTEM_TRAY_S0`
selection ownership and accepts XEMBED reparent requests. Tray icons
appear as tiny embedded windows inside strip's window.

---

## Architecture

### tile event loop

```
init:
    connect X11 socket, authenticate (lift from glass)
    SubstructureRedirectMask + SubstructureNotifyMask on root
    SubstructureRedirectMask + SubstructureNotifyMask on root → fail = "another WM running"
    GrabKey for every binding in ~/.tilerc (with NumLock variants)
    parse ~/.tilerc, store binding table, exec autostart commands
    read RandR outputs, allocate per-output workspace pin map
    if any windows are already mapped (we restarted), adopt them

main loop:
    poll X11 socket
    dispatch by event type:
        MapRequest         → adopt window, place per assign rules, map
        ConfigureRequest   → grant our chosen geometry
        UnmapNotify        → remove from tree if real (not pseudo-unmap)
        DestroyNotify      → remove from tree
        KeyPress           → match against binding table, dispatch action
        EnterNotify        → focus window (if focus_follows_mouse)
        ButtonPress        → focus window, possibly start drag
        PropertyNotify     → if WM_NAME, push update to strip via IPC
        ClientMessage      → handle _NET_ACTIVE_WINDOW, _NET_WM_STATE_FULLSCREEN
        RandR ScreenChangeNotify → reconfigure workspace pinning
```

### Tree model

```
root
├── output eDP-1
│   ├── workspace 1 (active here)
│   │   └── tabs container
│   │       ├── window glass#1 (focused tab)
│   │       └── window firefox#42
│   ├── workspace 2 (hidden)
│   └── ...
└── output HDMI-1
    └── workspace 0 (pinned)
        └── tabs container
            └── window glass#9
```

Each container is one of: `tabs`, `split-h`, `split-v`, or a `window`
leaf. Tabbed is the default; `split` is created by Win+h / Win+v
inside an existing tab.

### Smart workspace cycling

Maintain `populated_workspaces`: bitset of 10 bits, one per workspace.
Set bit when first window arrives; clear when last window leaves.

`workspace next-populated`:
- find next set bit after current (wrap around)
- if none other than current is set, no-op

`workspace N` (direct): always switches, even if empty.

This is the author's improvement over i3.

### Workspace pinning

Each workspace has an `output` field (default: any).

Pinned workspaces (`pin workspace 0 to HDMI-1`) only appear on their
designated output. If the output is disconnected, fallback rule kicks
in (`fallback workspace 0 to eDP-1`).

When RandR signals an output change, tile:
1. For each pinned workspace, check if its output exists
2. If not, move all windows on that workspace to its fallback output
3. If the lost output had any non-pinned workspaces, redistribute them
   to the primary output

### Stash (scratchpad replacement)

Single LIFO stack of XIDs (max 8 entries).

`stash`: unmap focused window (XUnmapWindow), push XID to stash, set
flag so UnmapNotify is ignored, focus next window in tree.

`unstash`: pop XID, find which workspace+container should receive it
(default: current workspace, current container), insert into tree,
XMapWindow.

Used for: ff-marionette (was scratchpad in i3), random "hide this for
now" workflow.

### Layout commands

`layout tabbed` (default): converts the workspace's root container to
a tabs container if it isn't already.

`split horizontal` (Win+h): wraps the focused window in a new split-h
container; future maps go into the same split.

`split vertical` (Win+v): same with split-v.

`layout default`: collapses splits back into the root tabs container.

### Multi-monitor

Use RandR 1.5: `RRGetScreenResources`, `RRGetOutputInfo`. Listen for
`RRScreenChangeNotify`.

Each output is identified by its name (`HDMI-1`, `eDP-1`,
`DisplayPort-2`). Pin rules match by name.

`move-workspace-to-output up`: takes the focused workspace's container
and moves it to the output above the current one (sorted by Y
position).

Mirroring (author's "even better" wish): `mirror workspace 0` config
option — when set, the same workspace is rendered on both outputs.
Implementation: each output gets its own root container, and tile
shares the window list; render-time, both outputs draw the same tree.

For v0.1, simpler implementation: just pin workspace 0 to external,
and accept that the laptop screen shows a different workspace. Add
real mirroring in a later phase if it becomes essential.

### Autostart

Lines like `exec feh ...` in `~/.tilerc` run once on tile startup,
after init, in fork+execve children. No `exec_always` (no reload
re-execs).

### Window assignments

`assign Firefox 3`: when a window's `WM_CLASS` (instance or class
substring) matches, it goes to workspace 3 instead of the current
workspace. Read the property on first MapRequest.

### `_NET_*` properties tile sets and updates

- `_NET_SUPPORTED` — list of supported atoms
- `_NET_NUMBER_OF_DESKTOPS` — 10
- `_NET_CURRENT_DESKTOP` — current workspace index
- `_NET_DESKTOP_NAMES` — `["1","2",...,"10"]`
- `_NET_CLIENT_LIST` — all managed XIDs
- `_NET_CLIENT_LIST_STACKING` — same in stacking order
- `_NET_ACTIVE_WINDOW` — focused XID
- `_NET_SUPPORTING_WM_CHECK` — child window with `_NET_WM_NAME=tile`
- `_NET_WM_DESKTOP` — per-window, which workspace
- `_NET_WM_STATE_FULLSCREEN` — track per-window
- `_NET_WORKAREA` — bar reservations
- `_NET_FRAME_EXTENTS` — 0,0,0,0 (no frames)

### `_NET_*` properties tile reads

- `WM_CLASS` (assignments)
- `WM_NAME` / `_NET_WM_NAME` (passed to strip)
- `WM_PROTOCOLS` / `WM_DELETE_WINDOW` (kill behaviour)
- `WM_NORMAL_HINTS` (size hints — relevant only for minimum sizes)
- `_NET_WM_STATE` (initial fullscreen request)
- `_NET_WM_WINDOW_TYPE` (skip frames for `_NET_WM_WINDOW_TYPE_DESKTOP`,
  `_DOCK`, `_TOOLTIP`, `_MENU`)

---

## strip architecture

### Bar window

- One InputOutput window per output (so each monitor has its own bar)
- Override-redirect = false; override-redirect should NOT be set or
  the bar is invisible to the WM. Instead: WM_HINTS, set
  `_NET_WM_WINDOW_TYPE_DOCK` so tile knows to reserve work area
- `_NET_WM_STRUT_PARTIAL` to reserve top N pixels per output
- Background/foreground from `~/.striprc`, default colors as spec'd

### Render loop

- Subscribe to PropertyNotify on root for `_NET_ACTIVE_WINDOW`,
  `_NET_CURRENT_DESKTOP`
- Subscribe to PropertyNotify on active window for `_NET_WM_NAME`
- Tick every 1s for clock and any segment with stale data (compare
  file mtime to interval)
- Refresher children: spawned on startup, each has its own pid; check
  liveness, respawn if dead

### Render order

Left → Right:
- Left segments (workspaces, then title)
- Right segments (in reverse order, anchored to right edge)
- Tray segment claims a fixed-width region; tray icons reparented into
  it

### Workspaces segment

Reads `_NET_NUMBER_OF_DESKTOPS`, `_NET_CURRENT_DESKTOP`,
`_NET_DESKTOP_NAMES`, and the populated set (from tile via IPC, or
inferred from `_NET_CLIENT_LIST` + `_NET_WM_DESKTOP` per window).

Renders the populated workspaces with the active one highlighted.
Click handler: ButtonPress → ClientMessage `_NET_CURRENT_DESKTOP` to
root → tile switches.

### Title segment

Reads `_NET_WM_NAME` of `_NET_ACTIVE_WINDOW`. Truncates with ellipsis
on overflow.

### Tray segment (XEMBED + system-tray protocol)

1. SetSelectionOwner for `_NET_SYSTEM_TRAY_S0`
2. Broadcast a `MANAGER` ClientMessage on the root window so tray apps
   discover us
3. On `ClientMessage` `_NET_SYSTEM_TRAY_OPCODE` (data.l[1]=0,
   data.l[2]=XID), accept the icon: ReparentWindow to our tray area,
   send XEMBED_EMBEDDED_NOTIFY
4. Layout: pack icons left-to-right at fixed cell width
5. On UnmapNotify of an icon, remove from layout; on DestroyNotify,
   same

This is the standard XEMBED system-tray spec. ~1200 lines including
ICCCM selection ownership, MANAGER broadcast, XEMBED message handling,
icon layout. Fully sufficient for nm-applet, fortinet, blueman,
discord systray.

### File-backed segment renderer

`segment_right NAME PATH INTERVAL`:
- On render: open(PATH), read up to 256 bytes, render as text
- Background tick: if (now - last_spawn) > INTERVAL, fork+exec the
  matching `refresher` command, redirect stdout > PATH

### IPC with tile (optional, for v0.1)

For v0.1, strip just reads X11 properties — simpler, no IPC needed.

In a later phase, add `/tmp/tile-${UID}/sock` for richer state push
(populated workspace bitset, tab counts per workspace, etc.).

---

## Build & install

```
cd tile
make             # builds tile and strip
sudo make install
```

Installs to `/usr/local/bin/{tile,strip}` and a sample config to
`/etc/tile/tilerc.example`.

To use as your X session: add to `~/.xinitrc` or DM session file:

```
exec /usr/local/bin/tile
```

(strip is launched from `~/.tilerc` via `exec strip`.)

---

## Phases (sequencing)

### Phase 1a — WM core (~2.5k lines)

- X11 connect (lift from glass)
- SubstructureRedirect grab on root
- Event loop dispatcher
- Single workspace, single output assumption
- MapRequest → reparent, map
- ConfigureRequest → grant our geometry
- UnmapNotify, DestroyNotify
- KeyPress dispatch (manual binding table for development)
- Hardcoded actions: kill (Win+q), fullscreen (Win+f), exec glass
  (Win+Return), exit (Win+Shift+q)
- WM_DELETE_WINDOW protocol

**Done when:** can run `Xephyr :1 &; DISPLAY=:1 ./tile` then launch
glass and type, kill it with Win+q, exit with Win+Shift+q.

### Phase 1b — workspaces, layouts, config (~3k lines)

- Tree model (tabs, split-h, split-v, window leaves)
- 10 workspaces, switch + move-to + smart cycling
- Tabbed default; Win+h/v create splits
- Focus next/prev tab
- Config parser (`~/.tilerc`): bind, exec, assign, defaults
- Autostart exec on init
- assign class → workspace
- stash/unstash

**Done when:** the author's normal i3 keybindings (translated to
`~/.tilerc`) work; tabbed mode with multiple windows behaves as in i3;
exec autostart launches strip placeholder, picom, feh.

### Phase 1c — multi-monitor (~1.5k lines)

- RandR query: outputs, geometry
- Workspace pinning (`pin workspace N to OUTPUT`)
- Fallback rules
- `move-window-to-output` / `move-workspace-to-output`
- RandR ScreenChangeNotify → re-evaluate pinning

**Done when:** plugging in HDMI moves WS 0 to it; unplugging falls
back; both outputs render their own active workspace.

### Phase 2a — strip skeleton (~2k lines)

- X11 connect, own window per output
- `_NET_WM_WINDOW_TYPE_DOCK` + `_NET_WM_STRUT_PARTIAL`
- Font rendering (lift from glass: terminus XLFDs, ImageText16)
- Workspaces segment + title segment + datetime segment
- Reads X11 properties for state
- 1s tick

**Done when:** the bar shows workspace numbers, current window title,
and clock.

### Phase 2b — strip status segments (~1.5k lines)

- /proc/loadavg, /proc/meminfo, statfs, /sys/class/power_supply,
  /sys/class/backlight, /proc/net/route
- Volume via shell-out to `wpctl status` parsed
- File-backed segments + refresher fork
- Color customisation per segment

**Done when:** the bar matches conky's content (CPU, mem, disk,
battery, IP, brightness, volume, weather, gmail, geolocation).

### Phase 2c — strip tray (~1.2k lines)

- `_NET_SYSTEM_TRAY_S0` selection ownership
- MANAGER broadcast
- ClientMessage `_NET_SYSTEM_TRAY_OPCODE` handler
- ReparentWindow + XEMBED protocol
- Icon layout

**Done when:** nm-applet, fortinet client, discord, blueman icons
embed and behave correctly.

### Phase 3 — polish

As-needed features once tile/strip is the daily driver:
- Resize mode
- Stacking layout (only if author wants it)
- Real workspace mirroring across outputs
- Urgency hints + Win+z
- focus_follows_mouse refinement
- IPC socket for `tile-msg`
- `tileconf` Rust TUI

---

## Projected size

| Component | Lines | Binary |
|-----------|-------|--------|
| tile | ~9.5k | ~75KB |
| strip | ~5.4k | ~50KB |
| **Total tile/ repo** | **~14.9k** | **~125KB** |

Whole CHasm suite after tile lands:

| Tool | Lines | Binary |
|------|-------|--------|
| bare | ~12k | ~140KB |
| show | ~3.5k | ~40KB |
| glass | ~12k | ~110KB |
| tile | ~9.5k | ~75KB |
| strip | ~5.4k | ~50KB |
| **Total** | **~42k** | **~415KB** |

Five binaries, zero shared dependencies (each is a single static ELF).

---

## Testing strategy

- **Xephyr** for development: `Xephyr :1 -screen 1280x800 &; DISPLAY=:1 ./tile`
- **xdotool** for keypress automation (same pattern used in glass
  audit): drive workspace switches, splits, kills from a script
- **Specific apps to verify** before declaring v0.1 done:
  - glass (CHasm terminal) — must work
  - bare (CHasm shell) — already works inside glass
  - Firefox — assignments, fullscreen, close, multi-window
  - mpv — fullscreen
  - GIMP — multi-window (but no floating, so it'll all tile)
  - rofi — exec-spawned, accepts focus
  - i3lock — exec-spawned, full screen lock
  - nm-applet — tray icon embeds in strip
  - fortinet client — tray icon embeds in strip
  - discord — tray + workspace assignment
  - feh — sets root background, tile leaves it alone
  - picom — composites tile + strip + clients

---

## Open questions before phase 1 starts

1. Does tile need to be a **drop-in replacement** all at once (cold
   switchover from i3), or is it OK to develop **alongside i3** in
   Xephyr until v0.1 is solid? **Author's call.**
2. **Mirror workspace** support: phase 1c (real RRSetCrtcConfig
   mirroring) or phase 3 (deferred)? **Author's call.**
3. **strip vs. existing tray (stalonetray, trayer)**: ship strip with
   tray in v0.1, or initially run trayer as a child and add tray to
   strip in phase 3? **Author's call.**
