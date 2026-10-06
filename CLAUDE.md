# tile

Tiling X11 window manager + bundled `strip` status bar, written in
x86_64 Linux assembly. No libc, no toolkit, pure syscalls + X11 wire
protocol.

## Build

```bash
make            # nasm + ld for both tile and strip
```

Two binaries land in this directory: `tile` (~70KB) and `strip` (~34KB).
`strip.asm` shares string helpers / X11 boilerplate via include — they
build independently but live in the same source tree because
`strip` is the status bar `tile` expects.

## Reload vs restart

- `Mod4+Shift+r` (`restart` action) → `execve("/proc/self/exe")` —
  picks up a new tile binary in place, preserving the X session and
  workspace state. Uses the action_restart pattern, with argv built
  on the **stack** (data in .text is read-only and writing argv
  pointers there segfaults).
- `pkill -USR1 -x tile` → `reload_runtime` re-reads `~/.tilerc`,
  re-grabs keys, re-paints borders, re-applies the visible
  workspace's layout. tileconf does this on save.

## Architecture

### Client tracking

Two parallel arrays indexed by client slot (max 256):
- `client_xid[N]`        — window XID (0 = empty slot)
- `client_ws[N]`         — workspace 1..10
- `client_color[N]`      — tab colour index (rotated by Mod4+c)
- `client_unmap_expected[N]` — flag for WM-initiated unmap suppression
- (more — see BSS section)

`find_client_index(xid)` returns slot index or -1. `track_client`
appends + honours `pending_assign_ws` (set by MapRequest's
`apply_assign` config-driven router). `untrack_client` zeros + shifts
to keep slots compact.

### Workspace layouts

`ws_layout[ws-1]` byte: 0=TABBED, 1=SPLIT_*. TABBED gives the active
tab fullscreen-of-output and unmaps the others. SPLIT_* runs
`apply_workspace_layout` which configures every visible client to its
slice. `set_active_tab_on_ws` re-configures the new active tab BEFORE
mapping it (in the TABBED branch) — required because the prior tab's
slice geometry would otherwise show through for one frame.

### Transient / dialog detection (Gimp tool windows)

`is_transient_window(xid)` checks **both** conventions a client might
use to say "I'm a floating thing":

1. ICCCM `WM_TRANSIENT_FOR` (predefined atom 68, type WINDOW=33)
2. EWMH `_NET_WM_WINDOW_TYPE` containing any of DIALOG, UTILITY,
   TOOLBAR, SPLASH, MENU, POPUP_MENU, DROPDOWN_MENU, NOTIFICATION,
   TOOLTIP (atoms interned at startup via `intern_one_atom`)

Most modern apps (GTK/Qt) use only EWMH. Older apps (xterm-style) use
only ICCCM. Skipping either pass misses one camp of apps.

`MapRequest`: if `is_transient_window` is true, just `MapWindow` the
window as-is and return — DO NOT call `track_client`. The window
keeps whatever geometry it requested.

`ConfigureRequest` from an unknown client (= a transient we chose not
to track) → `passthrough_configure_request` walks the request's
value-mask and re-emits a `ConfigureWindow` with exactly the fields
and values the client asked for. Without this, the default
"unknown→fullscreen" branch creates a flicker loop with apps that
re-request their preferred size after every fullscreen ConfigureNotify.

### Atom interning pattern

```nasm
lea rdi, [name_str]
mov esi, name_len
call intern_one_atom        ; eax = atom ID, 0 on failure
mov [my_atom], eax
```

`intern_one_atom` builds the InternAtom request, writes it, reads the
32-byte reply, returns the atom ID. Fail-closed: 0 on any error so
later GetProperty calls naturally skip themselves (`test eax,eax; jz`).

### GetProperty round-trip

`read_reply_or_queue(reply_buf)` handles the X11 reply read while
queueing any events that arrive in the meantime — events get drained
back to `event_loop` via `pending_events[]`. Always use this rather
than a bare `SYS_READ` to avoid losing keypresses / map notifies
during synchronous property reads.

## Key code sections

- `_start`: envp init, X11 connect (`x11_connect`), `intern_wm_atoms`,
  config load, key grab, event loop entry
- `event_loop`: drains `pending_events[]` first, then poll-reads
  socket, dispatches by event type
- `ev_map_request`: float check → assign → configure → track →
  stash-on-map → activate
- `ev_configure_request`: known client → re-apply layout / fullscreen;
  unknown client → passthrough
- `dispatch_keypress`: chord lookup against parsed `bind` table
- `apply_workspace_layout`: walks visible clients, configures each to
  its slice
- `render_bar`: row-of-squares + WS dim + layout glyph + tabs
- `intern_wm_atoms`: WM_PROTOCOLS, WM_DELETE_WINDOW, _TILE_SHELL_PID,
  _NET_ACTIVE_WINDOW, plus 10 EWMH window-type atoms
- `is_transient_window`: ICCCM + EWMH float-type detection
- `passthrough_configure_request`: re-emits ConfigureRequest as
  ConfigureWindow

## Bar layout (constants in tile.asm header)

```
SQUARE_GAP            = 2     ; px between WS squares
WS_SQUARE_GAP         = 4     ; px between squares within a group
WS_GROUP_GAP          = 14    ; px between groups of 3 squares
BAR_SEP_GAP           = 8     ; gap before/after vertical separator
BAR_SEP_WIDTH         = 2     ; vertical bar between WS strip + layout
LAYOUT_GLYPH_GAP      = 14    ; gap before tab strip
```

These are pragmatic hardcodes — could move to `~/.tilerc` later.

## Tests

`test/run.sh` holds one check per reported fault. A fix ships with a check
that fails without it: build the old `tile.asm` (`git show REV^:tile.asm`,
with `strip_glyphs.inc` beside it) and run `TILE=/path/to/old test/run.sh`.

- `test/xwin NAME [PARENT]` is a plain window; with PARENT it is a dialog.
- Workspaces change with faked keys (`go N`), bound in `test/tilerc`.
- A restarting tile runs `snixembed` and `notify-send` through the shell.
  Both are dummies in the test, and the session bus address points
  nowhere. Unsetting the address is not enough: programs then find the
  real bus through `XDG_RUNTIME_DIR`.
- Test adoption by stopping tile and starting a new one, not by a restart:
  an old build restarts into whatever tile is installed.

A restart lands on the workspace it came from (v0.1.71): the new tile
reads `_NET_CURRENT_DESKTOP` from the root before it draws its bar.

Two faults the tests found and that are not fixed (2026-10-06):

- A tile started fresh over a session that lost its tile (not a restart)
  lands on `startup_workspace`, and the window the old tile was showing
  stays on screen there until the first workspace switch.
- A dialog that is open during a restart is adopted as a normal tab on the
  workspace tile lands on. It no longer follows its parent.

## Pitfalls

See the global x86_64-asm skill for the 15 NASM/x86_64 pitfalls that
apply to every CHasm project. Tile-specific gotchas:

- **`pkill <name>` matches as regex** — use `pkill -x name` for exact
  match, otherwise `pkill strip` will also kill `stripconf`.
- **Data in .text is read-only** — `action_restart` builds argv on the
  stack, not as inline `db` data, because the latter would segfault
  on the first store.
- **`set_active_tab_on_ws` TABBED branch must configure BEFORE map** —
  otherwise a sibling tab keeps its old (wrong) slice geometry visible
  for a frame.
- **MAX_BINDS = 128, MAX_SEGMENTS = 32** — increase carefully; the
  segment table is in BSS and stride matters for offsets.
