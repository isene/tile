; tile - Pure-asm tiling window manager (CHasm suite, phase 1a.1)
; x86_64 Linux, NASM syntax, no libc, X11 wire protocol over Unix socket.
;
; Phase 1a.1 capabilities:
;   - Connect & authenticate to X11
;   - Claim SubstructureRedirect on root (single-WM enforcement)
;   - Map MapRequest windows full-screen
;   - Grant ConfigureRequest (clamped to screen)
;   - Hardcoded keybinds: Mod4+Return (exec glass/xterm),
;     Mod4+q (kill latest mapped client), Mod4+Shift+q (exit)

; ══════════════════════════════════════════════════════════════════════
; Syscall numbers
; ══════════════════════════════════════════════════════════════════════
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_POLL        7
%define SYS_SOCKET      41
%define SYS_CONNECT     42
%define SYS_FORK        57
%define SYS_EXECVE      59
%define SYS_EXIT        60
%define SYS_WAIT4       61
%define SYS_RT_SIGACTION    13
%define SYS_RT_SIGRETURN    15

; Signals + sigaction flags
%define SIGUSR1         10
%define SA_RESTORER     0x04000000
%define SA_RESTART      0x10000000
%define EINTR           4

; ══════════════════════════════════════════════════════════════════════
; Constants
; ══════════════════════════════════════════════════════════════════════
%define AF_UNIX                 1
%define SOCK_STREAM             1

; X11 opcodes
%define X11_CREATE_WINDOW       1
%define X11_CHANGE_WINDOW_ATTRS 2
%define X11_GET_WINDOW_ATTRS    3
%define X11_DESTROY_WINDOW      4
%define X11_REPARENT_WINDOW     7
%define X11_MAP_WINDOW          8
%define X11_UNMAP_WINDOW        10
%define X11_CONFIGURE_WINDOW    12
%define X11_INTERN_ATOM         16
%define X11_CHANGE_PROPERTY     18
%define X11_GET_PROPERTY        20
%define X11_GRAB_KEY            33
%define X11_UNGRAB_KEY          34
%define X11_GET_KEYBOARD_MAPPING 101
%define X11_KILL_CLIENT         113
%define X11_QUERY_EXTENSION     98

; Xinerama sub-opcodes (sent with major = xinerama_major).
%define XIN_QUERY_VERSION       0
%define XIN_GET_STATE           1
%define XIN_QUERY_SCREENS       5

%define MAX_OUTPUTS             4
%define X11_SET_INPUT_FOCUS     42
%define X11_SEND_EVENT          25
%define X11_CREATE_GC           55
%define X11_CHANGE_GC           56
%define X11_FREE_GC             60
%define X11_POLY_RECTANGLE      67
%define X11_POLY_FILL_RECT      70

; CW masks (for CreateWindow / ChangeWindowAttributes value mask)
; CW_EVENT_MASK (0x00000800) is already defined further down in this file.
%define CW_BACK_PIXEL           0x00000002
%define CW_BORDER_PIXEL         0x00000008
%define CW_OVERRIDE_REDIRECT    0x00000200
%define EXPOSURE_MASK           0x00008000
%define EV_EXPOSE               12

; GC value mask (CreateGC / ChangeGC)
%define GC_FOREGROUND           0x00000004
%define GC_BACKGROUND           0x00000008

; X11 event types
%define EV_KEY_PRESS            2
%define EV_KEY_RELEASE          3
%define EV_BUTTON_PRESS         4
%define EV_DESTROY_NOTIFY       17
%define EV_UNMAP_NOTIFY         18
%define EV_MAP_NOTIFY           19
%define EV_MAP_REQUEST          20
%define EV_CONFIGURE_NOTIFY     22
%define EV_CONFIGURE_REQUEST    23
%define EV_PROPERTY_NOTIFY      28

; X11 event masks
%define KEY_PRESS_MASK              0x00000001
%define BUTTON_PRESS_MASK           0x00000004
%define ENTER_WINDOW_MASK           0x00000010
%define STRUCTURE_NOTIFY_MASK       0x00020000
%define SUBSTRUCTURE_NOTIFY_MASK    0x00080000
%define SUBSTRUCTURE_REDIRECT_MASK  0x00100000
%define PROPERTY_CHANGE_MASK        0x00400000

; CW value mask bits
%define CW_EVENT_MASK               0x00000800

; ConfigureWindow value mask bits
%define CFG_X        0x01
%define CFG_Y        0x02
%define CFG_WIDTH    0x04
%define CFG_HEIGHT   0x08
%define CFG_BORDER   0x10
%define CFG_SIBLING  0x20
%define CFG_STACK    0x40

; X11 modifier masks
%define MOD_SHIFT       0x0001
%define MOD_LOCK        0x0002
%define MOD_CONTROL     0x0004
%define MOD_MOD1        0x0008
%define MOD_MOD2        0x0010
%define MOD_MOD4        0x0040
%define MOD_NUM_LOCK    0x0010


; Limits
%define MAX_CLIENTS     128
%define MAX_BINDS       128
%define MAX_EXECS       32
%define BIND_STRIDE     16        ; bytes per bind entry (see layout below)
%define ARG_POOL_SIZE   16384
%define CFG_BUF_SIZE    16384

; Action IDs (encoded in bind entries' action_id byte)
%define ACT_NONE        0
%define ACT_EXEC        1
%define ACT_KILL        2
%define ACT_EXIT        3
%define ACT_WORKSPACE   4
%define ACT_MOVE_TO     5
%define ACT_FOCUS       6
%define ACT_MOVE_TAB    7
%define ACT_TAB_COLOR   8
%define ACT_STASH       9
%define ACT_UNSTASH     10
%define ACT_LAYOUT      11
%define ACT_SPAWN_SPLIT 12
%define ACT_EXEC_HERE   13
%define ACT_RELOAD      14
%define ACT_RESTART     15

%define MAX_STASH       8

; Per-workspace layouts. Phase 1b.3b uses a flat single-level model:
; a workspace is in exactly one layout at a time, no nested containers.
; Covers the user's 98%-tabbed / 2%-split workflow without dragging in
; full container-tree complexity.
%define LAYOUT_TABBED   0
%define LAYOUT_SPLIT_H  1
%define LAYOUT_SPLIT_V  2
%define LAYOUT_MASTER   3

; ACT_LAYOUT arg_int sentinels — mirror the workspace pattern.
%define LAY_SET_TABBED  1
%define LAY_SET_SPLIT_H 2
%define LAY_SET_SPLIT_V 3
%define LAY_SET_MASTER  4
%define LAY_TOGGLE      0xff

%define DEFAULT_MASTER_RATIO 50      ; percent of workspace width given to master

; Bar (the row-of-squares strip at the top of the screen).
%define DEFAULT_BAR_HEIGHT      10
%define DEFAULT_BAR_PAD         4     ; pixels before first tab / after last WS
%define DEFAULT_TAB_DIM_FACTOR  40    ; inactive tab brightness, 0..100
%define DEFAULT_BORDER_WIDTH    1     ; pixels of focus border around managed windows
%define DEFAULT_BORDER_FOCUSED   0xFFffffff
%define DEFAULT_BORDER_UNFOCUSED 0xFF222222
%define MAX_PALETTE             16
%define WS_TAB_GAP              8     ; pixels of gap between WS and tab squares (legacy; kept for clarity)
%define SQUARE_GAP              2     ; pixels of gap between adjacent tab squares
%define WS_SQUARE_GAP           6     ; pixels of gap between WS squares within a group
%define WS_GROUP_GAP            14    ; extra gap before WS positions 4, 7, 10 (group breaks)
%define BAR_SEP_GAP             14    ; full WS_GROUP_GAP space on each side of the vertical separator
%define BAR_SEP_WIDTH           1     ; width of the vertical separator bar (1 px hairline)
%define LAYOUT_GLYPH_GAP        14    ; group-sized gap after the layout indicator before tabs
                                      ; (separates the special "0" slot and
                                      ; groups the rest into 1-3, 4-6, 7-9)

; Workspace count and special arg_int sentinels for ACT_WORKSPACE.
%define WS_COUNT        10
%define WS_NEXT_POP     0xff
%define WS_PREV_POP     0xfe
%define WS_BACK_FORTH   0xfd

; Focus and move-tab arg_int sentinels (single byte, also stored in arg_int).
%define FOC_NEXT_TAB    1
%define FOC_PREV_TAB    2
%define FOC_RIGHT       3
%define FOC_LEFT        4
%define FOC_UP          5
%define FOC_DOWN        6
%define MTAB_LEFT       1
%define MTAB_RIGHT      2

; ACT_SPAWN_SPLIT direction sentinels. The spawn-split action takes a
; direction keyword and a command string; the direction implies both
; the layout (right/left → SPLIT_H, up/down → SPLIT_V) and where the
; new client lands relative to the focused one.
%define SPAWN_RIGHT     1
%define SPAWN_LEFT      2
%define SPAWN_UP        3
%define SPAWN_DOWN      4

; ══════════════════════════════════════════════════════════════════════
; Data
; ══════════════════════════════════════════════════════════════════════
section .data

x11_sock_pre:    db "/tmp/.X11-unix/X", 0
auth_name:       db "MIT-MAGIC-COOKIE-1"
auth_name_len    equ 18

err_x11:         db "tile: cannot connect to X server", 10
err_x11_len      equ $ - err_x11
err_redirect:    db "tile: another window manager is already running (substructure redirect denied)", 10
err_redirect_len equ $ - err_redirect

env_display:     db "DISPLAY=", 0  ; placeholder; tile inherits envp directly

; ICCCM atoms we intern at startup so we can speak the WM_DELETE_WINDOW
; protocol — gives apps a chance to save state before closing rather
; than the connection being yanked out from under them with KillClient.
wm_protocols_str: db "WM_PROTOCOLS"
wm_protocols_len  equ 12
wm_delete_str:    db "WM_DELETE_WINDOW"
wm_delete_len     equ 16
tile_shell_pid_str: db "_TILE_SHELL_PID"
tile_shell_pid_len equ 15
net_active_window_str: db "_NET_ACTIVE_WINDOW"
net_active_window_len equ 18

; EWMH window-type atoms — used to detect dialog/utility/tool/menu
; windows that should NOT be tiled (Gimp tool palettes, file pickers,
; tooltips, splash screens, …). Apps that don't set
; WM_TRANSIENT_FOR (most modern GTK/Qt apps) communicate "I am a
; floating thing" via _NET_WM_WINDOW_TYPE = one of these atoms.
nwwt_str:        db "_NET_WM_WINDOW_TYPE"
nwwt_len         equ 19
nwwt_dialog_str: db "_NET_WM_WINDOW_TYPE_DIALOG"
nwwt_dialog_len  equ 26
nwwt_util_str:   db "_NET_WM_WINDOW_TYPE_UTILITY"
nwwt_util_len    equ 27
nwwt_tool_str:   db "_NET_WM_WINDOW_TYPE_TOOLBAR"
nwwt_tool_len    equ 27
nwwt_splash_str: db "_NET_WM_WINDOW_TYPE_SPLASH"
nwwt_splash_len  equ 26
nwwt_menu_str:   db "_NET_WM_WINDOW_TYPE_MENU"
nwwt_menu_len    equ 24
nwwt_popup_str:  db "_NET_WM_WINDOW_TYPE_POPUP_MENU"
nwwt_popup_len   equ 30
nwwt_drop_str:   db "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU"
nwwt_drop_len    equ 33
nwwt_notif_str:  db "_NET_WM_WINDOW_TYPE_NOTIFICATION"
nwwt_notif_len   equ 32
nwwt_tooltip_str:db "_NET_WM_WINDOW_TYPE_TOOLTIP"
nwwt_tooltip_len equ 27

; XINERAMA extension name (uppercase per X11 convention).
xinerama_name:    db "XINERAMA"
xinerama_name_len equ 8
randr_name:       db "RANDR"
randr_name_len    equ 5

; Path suffixes
tilerc_suffix:    db "/.tilerc", 0
tilerc_suffix_len equ 8

; Modifier name → mask table. Format: name, NUL, mask (CARD16), pad.
; Entries packed contiguously, terminator = empty name (one NUL byte).
mod_table:
    db "Shift", 0
    dw 0x0001
    db "Ctrl", 0
    dw 0x0004
    db "Control", 0
    dw 0x0004
    db "Mod1", 0
    dw 0x0008
    db "Alt", 0
    dw 0x0008
    db "Mod4", 0
    dw 0x0040
    db "Win", 0
    dw 0x0040
    db "Super", 0
    dw 0x0040
    db 0                       ; terminator (empty name)

; Named key → keysym (CARD32). Same packed format: name, NUL, keysym.
key_table:
    db "Return", 0
    dd 0xff0d
    db "Escape", 0
    dd 0xff1b
    db "space", 0
    dd 0x0020
    db "Tab", 0
    dd 0xff09
    db "BackSpace", 0
    dd 0xff08
    db "Delete", 0
    dd 0xffff
    db "Left", 0
    dd 0xff51
    db "Up", 0
    dd 0xff52
    db "Right", 0
    dd 0xff53
    db "Down", 0
    dd 0xff54
    db "Home", 0
    dd 0xff50
    db "End", 0
    dd 0xff57
    db "Page_Up", 0
    dd 0xff55
    db "Page_Down", 0
    dd 0xff56
    db "F1", 0
    dd 0xffbe
    db "F2", 0
    dd 0xffbf
    db "F3", 0
    dd 0xffc0
    db "F4", 0
    dd 0xffc1
    db "F5", 0
    dd 0xffc2
    db "F6", 0
    dd 0xffc3
    db "F7", 0
    dd 0xffc4
    db "F8", 0
    dd 0xffc5
    db "F9", 0
    dd 0xffc6
    db "F10", 0
    dd 0xffc7
    db "F11", 0
    dd 0xffc8
    db "F12", 0
    dd 0xffc9
    db "plus", 0
    dd 0x002b
    db "minus", 0
    dd 0x002d
    db "underscore", 0
    dd 0x005f
    db "equal", 0
    dd 0x003d
    db "comma", 0
    dd 0x002c
    db "period", 0
    dd 0x002e
    db "less", 0
    dd 0x003c
    db "greater", 0
    dd 0x003e
    db "slash", 0
    dd 0x002f
    db "backslash", 0
    dd 0x005c
    db "semicolon", 0
    dd 0x003b
    db "apostrophe", 0
    dd 0x0027
    db "bracketleft", 0
    dd 0x005b
    db "bracketright", 0
    dd 0x005d
    db "bar", 0
    dd 0x007c                  ; |  (Norwegian layout: AltGr+something)
    ; XF86 multimedia keysyms (laptop function-row keys).
    db "XF86AudioMute", 0
    dd 0x1008ff12
    db "XF86AudioLowerVolume", 0
    dd 0x1008ff11
    db "XF86AudioRaiseVolume", 0
    dd 0x1008ff13
    db "XF86MonBrightnessDown", 0
    dd 0x1008ff03
    db "XF86MonBrightnessUp", 0
    dd 0x1008ff02
    db 0                       ; terminator

; Action keyword table: name, NUL, action_id (BYTE), pad.
action_table:
    db "exec", 0
    db ACT_EXEC, 0
    db "kill", 0
    db ACT_KILL, 0
    db "exit", 0
    db ACT_EXIT, 0
    db "workspace", 0
    db ACT_WORKSPACE, 0
    db "move-to", 0
    db ACT_MOVE_TO, 0
    db "focus", 0
    db ACT_FOCUS, 0
    db "move-tab", 0
    db ACT_MOVE_TAB, 0
    db "tab-color-cycle", 0
    db ACT_TAB_COLOR, 0
    db "stash", 0
    db ACT_STASH, 0
    db "unstash", 0
    db ACT_UNSTASH, 0
    db "layout", 0
    db ACT_LAYOUT, 0
    db "spawn-split", 0
    db ACT_SPAWN_SPLIT, 0
    db "exec-here", 0
    db ACT_EXEC_HERE, 0
    db "reload", 0
    db ACT_RELOAD, 0
    db "restart", 0
    db ACT_RESTART, 0
    db 0                       ; terminator

; layout arg keyword table: `layout tabbed | split-h | split-v | toggle`.
layout_arg_table:
    db "tabbed", 0
    db LAY_SET_TABBED, 0
    db "split-h", 0
    db LAY_SET_SPLIT_H, 0
    db "split-v", 0
    db LAY_SET_SPLIT_V, 0
    db "master", 0
    db LAY_SET_MASTER, 0
    db "toggle", 0
    db LAY_TOGGLE, 0
    db 0

; Focus arg keyword table for `focus <direction>`.
focus_arg_table:
    db "next-tab", 0
    db FOC_NEXT_TAB, 0
    db "prev-tab", 0
    db FOC_PREV_TAB, 0
    db "right", 0
    db FOC_RIGHT, 0
    db "left", 0
    db FOC_LEFT, 0
    db "up", 0
    db FOC_UP, 0
    db "down", 0
    db FOC_DOWN, 0
    db 0

; move-tab arg keyword table.
mtab_arg_table:
    db "left", 0
    db MTAB_LEFT, 0
    db "right", 0
    db MTAB_RIGHT, 0
    db 0

; spawn-split direction keyword table.
spawn_split_arg_table:
    db "right", 0
    db SPAWN_RIGHT, 0
    db "left", 0
    db SPAWN_LEFT, 0
    db "up", 0
    db SPAWN_UP, 0
    db "down", 0
    db SPAWN_DOWN, 0
    db 0

; Workspace argument keyword table for `workspace <name>`. Same packed
; format: name, NUL, value (BYTE), pad. Values are sentinels in the
; 0xfd..0xff range so they don't collide with literal workspace numbers.
ws_arg_table:
    db "next-populated", 0
    db WS_NEXT_POP, 0
    db "prev-populated", 0
    db WS_PREV_POP, 0
    db "back-and-forth", 0
    db WS_BACK_FORTH, 0
    db 0

; Default exec command for the built-in Alt+Return bind, used when no
; ~/.tilerc is found. Goes through fork_exec_string → /bin/sh -c, so
; PATH search resolves the binary; users install glass anywhere on PATH.
default_glass_arg:
    db "glass", 0
default_glass_arg_len equ $ - default_glass_arg - 1


; ══════════════════════════════════════════════════════════════════════
; BSS
; ══════════════════════════════════════════════════════════════════════
section .bss

envp:                resq 1
display_num:         resq 1
x11_fd:              resq 1
x11_seq:             resd 1
x11_rid_base:        resd 1
x11_rid_mask:        resd 1
x11_rid_next:        resd 1
x11_root_window:     resd 1
x11_screen_width:    resw 1
x11_screen_height:   resw 1
x11_min_keycode:     resb 1
x11_max_keycode:     resb 1
x11_root_visual:     resd 1
x11_root_depth:      resb 1
x11_white_pixel:     resd 1
x11_black_pixel:     resd 1

keysyms_per_kc:      resd 1
; keysym_map[keycode * 8 + sym_index]: 256 keycodes × up to 8 syms each
keysym_map:          resd 256 * 8

; Bar (the row-of-squares strip across the top of the screen).
;   bar_height          height in pixels (also the side length of each square)
;   bar_window_id       XID of tile's override-redirect bar window
;   bar_gc_id           GC for filling the bar
;   client_color[i]     palette index for client i. 0 = tab_default colour;
;                       1..palette_count = palette[idx-1].
bar_height:              resw 1
bar_window_id:           resd 1
bar_gc_id:               resd 1
client_color:            resb MAX_CLIENTS

; Configurable bar colors (CARD32 X11 pixel values, set by load_config).
cfg_bar_bg:              resd 1
cfg_tab_default:         resd 1
cfg_tab_dim_factor:      resb 1
cfg_tab_palette:         resd MAX_PALETTE
cfg_tab_palette_count:   resb 1
cfg_ws_active:           resd 1
cfg_ws_populated:        resd 1
; Per-workspace fixed colour (overrides the active/populated default).
; Indexed as cfg_ws_colors[ws-1] for ws 1..10. 0xFFFFFFFF = unset
; (use cfg_ws_active / cfg_ws_populated as before).
cfg_ws_colors:           resd 10
; WS-specific dim factor (% brightness for non-active WSes that use
; cfg_ws_colors). Separate from cfg_tab_dim_factor because an
; aggressive tab dim (e.g. 40%) leaves a configured ws_color barely
; visible. Default 70.
cfg_ws_dim_factor:       resb 1

; Per-class window-to-workspace assignments. `assign <class> <ws>` in
; ~/.tilerc populates the parallel arrays below: assign_class[i] is an
; offset into arg_pool naming the WM_CLASS string to match (the
; "class" half — second NUL-terminated string in the WM_CLASS
; property), and assign_ws[i] is the target workspace 1..10. When a
; new client lands, MapRequest reads its WM_CLASS, walks the table,
; and routes the client to the matched workspace before tracking it.
%define MAX_ASSIGNS 32
assign_class:            resw MAX_ASSIGNS
assign_ws:               resb MAX_ASSIGNS
assign_count:            resd 1

; Per-class stash-on-map list. Same shape as assign_*, but no ws
; payload: any new client whose class matches this list is immediately
; stashed (i3 scratchpad equivalent) instead of joining its destination
; workspace's tab strip. Used for the marionette Firefox.
%define MAX_STASH_ON_MAP 16
stash_class:             resw MAX_STASH_ON_MAP
stash_class_count:       resd 1

; Override channel: when MapRequest decides the new client should land
; on a workspace other than current_ws (because of an `assign` rule),
; it sets pending_assign_ws to the target ws. track_client honours
; this in place of current_ws, then the byte is cleared.
pending_assign_ws:       resb 1

; Scratch buffer for one synchronous WM_CLASS GetProperty round-trip.
; 32-byte reply header + room for the value bytes (instance\0class\0).
%define WM_CLASS_BUF_SIZE 512
wm_class_buf:            resb WM_CLASS_BUF_SIZE

; Reload coordination. SIGUSR1 sets `reload_pending`; the main event
; loop drains it between events and calls reload_runtime. Keeps the
; signal handler tiny — no async-unsafe calls inside it.
reload_pending:          resb 1

; sigaction(2) struct used to install the SIGUSR1 handler. Layout is
; the kernel's struct sigaction (not glibc's): handler ptr at +0,
; sa_flags at +8, sa_restorer at +16, sa_mask at +24 (8 bytes for the
; first 64 signals). 32 bytes total.
sigact_buf:              resb 32

; Snapshot of the original config line being parsed, captured before
; tokenization mutates the buffer with NUL bytes. Used by the stderr
; warning emitter so users see their actual text in the diagnostic.
cfg_line_buf:            resb 256
cfg_line_recognized:     resb 1

; Pixels of horizontal padding inside the bar — leaves breathing room
; before the leftmost tab square and after the rightmost workspace
; square. Defaults to a few pixels; ~/.tilerc may override via
; `bar_pad`.
cfg_bar_pad:             resw 1

; Pixels of vertical padding at the BOTTOM of the bar — gives the
; workspace squares / tabs a thin breathing strip above the cell area
; instead of touching the row of clients below. Default 1.
; ~/.tilerc may override via `bar_pad_bottom`. Clamped to bar_height-1
; at render time so the bar can never collapse to nothing.
cfg_bar_pad_bottom:      resw 1

; Inner gap: pixels of padding inside each managed window (so neighbouring
; windows / the bar get visual breathing room). Equivalent to i3's
; `gaps inner N`. Tabs already mean only one window is visible at a time
; in phase 1b.3a, so the gap manifests as a uniform border around the
; active client.
cfg_gap_inner:           resw 1

; Vertical pixels reserved at the top of output 0 for the strip status
; bar (a separate binary). Tile's row-of-squares lands immediately
; below this; managed-window geometry then reserves
; (cfg_strip_height + bar_height) at the top. 0 = no strip running.
cfg_strip_height:        resw 1

; Focus-border state. Every managed window gets a 1px border (width
; configurable). The currently-focused window's border is drawn in
; cfg_border_focused; everyone else gets cfg_border_unfocused. Border
; width 0 disables the feature entirely.
cfg_border_width:        resb 1
cfg_border_focused:      resd 1
cfg_border_unfocused:    resd 1
focused_xid:             resd 1

; Master/stack layout: master takes cfg_master_ratio percent of the
; workspace's width on the left; the remaining clients stack as equal-
; height vertical strips on the right. The "master" is the first
; client (in client_xids order) whose client_ws matches.
cfg_master_ratio:        resb 1
; Color of the layout indicator glyph (between WS strip and tabs).
; 0 = use cfg_tab_default. Otherwise an ARGB CARD32 pixel value.
cfg_layout_color:        resd 1
; Frame colour drawn around the active workspace square AND the active
; tab square. 0 = disabled (no frame). Otherwise an ARGB CARD32 pixel
; value — drawn with PolyRectangle (1 px outline) on top of the fill.
cfg_active_frame:        resd 1

; Xinerama / multi-monitor state (phase 1c).
;
; xinerama_major = the major opcode the X server assigned to the
; XINERAMA extension (0 if the extension isn't present — fall back to
; single-screen mode using x11_screen_width/x11_screen_height).
;
; output_count = number of physical screens reported by Xinerama.
; output_x / output_y / output_w / output_h = each output's geometry
; in root coordinates. Output 0 is the primary; non-zero indices are
; secondaries, ordered as Xinerama returned them.
;
; ws_pinned_output[w-1] = which output workspace w lives on. Set at
; startup based on the user's wishes (default: WS 1..9 → output 0,
; WS 10 → output 1 if a secondary exists, else also output 0).
xinerama_major:          resb 1

; RandR is queried alongside Xinerama. We don't use RandR for output
; discovery (Xinerama already gives us the right rectangles); RandR's
; only job here is to deliver RRScreenChangeNotify events when monitors
; come or go, so we can re-run discover_outputs without restarting tile.
randr_major:             resb 1
randr_event_base:        resb 1
randr_present:           resb 1
output_count:            resb 1
output_x:                resw MAX_OUTPUTS
output_y:                resw MAX_OUTPUTS
output_w:                resw MAX_OUTPUTS
output_h:                resw MAX_OUTPUTS
ws_pinned_output:        resb WS_COUNT

; User-supplied per-workspace output overrides from `pin N M` lines in
; ~/.tilerc. 0xFF = no override (fall back to discover_outputs default);
; any other value is the desired output index (clamped to output_count
; after discovery). Filled during parse_config_line; applied in
; apply_pin_overrides right after discover_outputs.
ws_pin_override:         resb WS_COUNT

; Per-output state: which workspace is currently visible on each
; output. Allows the external monitor to keep showing WS 10 even
; while the laptop user switches between workspaces 1..9. Initialized
; in discover_outputs: output_current_ws[0] = 1 (laptop view defaults
; to WS 1), output_current_ws[1] = 10 if a secondary exists.
;
; The global current_ws still tracks the most-recently-focused
; workspace (used for "what does kill act on", "where does a new
; client land", etc.).
output_current_ws:       resb MAX_OUTPUTS

; Per-workspace layout (LAYOUT_TABBED / LAYOUT_SPLIT_H / LAYOUT_SPLIT_V).
; Default 0 = TABBED.
ws_layout:               resb WS_COUNT

; Stash: a small LIFO of "hidden" client XIDs. `stash` unmaps the
; currently focused tab and pushes its XID; `unstash` pops and
; re-tracks it on the current workspace as the active tab. Replaces
; i3's scratchpad for the user's ff-marionette workflow.
stash_xids:              resd MAX_STASH
stash_count:             resd 1

; Pending spawn-split state. When a spawn-split action fires, it
; records the focused window's XID here as the "anchor". The next
; MapRequest's track_client will reorder the appended client into
; position relative to this anchor (just before or just after) so it
; lands where the user asked, instead of at the end of client_xids.
; pending_spawn_xid == 0 means no pending spawn.
pending_spawn_xid:       resd 1
pending_spawn_after:     resb 1

; Tracked top-level clients (most recent / focused at the end of the
; stack — kill action acts on the top entry of the current workspace).
client_xids:             resd MAX_CLIENTS
; Parallel byte arrays:
;   client_ws[i]              = workspace this client belongs to (1..10)
;   client_unmap_expected[i]  = nonzero when WE issued an UnmapWindow on
;                               this client (e.g. workspace switch); the
;                               UnmapNotify it generates must NOT be
;                               treated as the client closing.
client_ws:               resb MAX_CLIENTS
client_unmap_expected:   resb MAX_CLIENTS
client_count:            resd 1

; Workspace state.
;   current_ws               = active workspace, 1..10
;   prev_ws                  = workspace we last switched away from (for
;                               `workspace back-and-forth`); 0 = none yet
;   workspace_populated[w-1] = client count on workspace w, byte
;   ws_active_xid[w-1]       = XID of the currently-visible tab on
;                              workspace w (0 if the workspace is empty).
;                              Phase 1b.3a: each workspace is a flat
;                              tab list; only ws_active_xid[w-1] is
;                              actually mapped at any given time.
current_ws:              resb 1
prev_ws:                 resb 1
workspace_populated:     resb WS_COUNT
ws_active_xid:           resd WS_COUNT

; ICCCM atoms (resolved at startup via InternAtom).
wm_protocols_atom:   resd 1
wm_delete_atom:      resd 1
tile_shell_pid_atom: resd 1
net_active_window_atom: resd 1

; EWMH window-type atoms (resolved at startup; 0 if unresolved means
; the X server has never seen the atom, which implies no window has
; that type either, so the comparison naturally fails closed).
nwwt_atom:           resd 1            ; _NET_WM_WINDOW_TYPE (the property)
nwwt_dialog_atom:    resd 1
nwwt_util_atom:      resd 1
nwwt_tool_atom:      resd 1
nwwt_splash_atom:    resd 1
nwwt_menu_atom:      resd 1
nwwt_popup_atom:     resd 1
nwwt_drop_atom:      resd 1
nwwt_notif_atom:     resd 1
nwwt_tooltip_atom:   resd 1
; Buffer for _NET_WM_WINDOW_TYPE GetProperty reply: 32-byte header +
; up to 16 atoms (4 bytes each).
nwwt_reply_buf:      resb 32 + 64

; Pending-event queue. Used when a synchronous X reply read (e.g. for
; GetProperty during the exec-here action) accidentally drains an
; event from the wire. event_loop drains the queue before reading the
; socket, so no event is lost.
%define PENDING_MAX 16
pending_events:      resb 32 * PENDING_MAX
pending_count:       resd 1
pending_head:        resd 1

; Binding table.
; Per-entry layout (BIND_STRIDE = 16):
;   +0  CARD32  keysym (during parse)
;   +4  CARD32  keycode (low 8 bits used; resolved after GetKeyboardMapping)
;   +8  CARD16  modifiers
;   +10 BYTE    action_id
;   +11 BYTE    pad
;   +12 CARD16  arg_off (offset into arg_pool; 0 = no arg)
;   +14 CARD16  pad
bind_table:          resb MAX_BINDS * BIND_STRIDE
bind_count:          resd 1

; Autostart command list. Each entry is a CARD16 offset into arg_pool.
exec_list:           resw MAX_EXECS
exec_count:          resd 1

; Pool for null-terminated argument strings (exec commands, etc).
; Index 0 is reserved as "no arg" sentinel; we always start writes
; at offset 1.
arg_pool:            resb ARG_POOL_SIZE
arg_pool_pos:        resd 1

; Buffer used to slurp ~/.tilerc.
config_buf:          resb CFG_BUF_SIZE
config_len:          resq 1
config_path:         resb 512

; X11 buffers
conn_setup_buf:      resb 16384
sockaddr_buf:        resb 112
xauth_buf:           resb 4096
xauth_data:          resb 16
xauth_len:           resq 1
tmp_buf:             resb 16384
x11_read_buf:        resb 65536
x11_write_buf:       resb 65536
x11_write_pos:       resq 1
dkp_buf:             resb 64

; ══════════════════════════════════════════════════════════════════════
; Code
; ══════════════════════════════════════════════════════════════════════
section .text
global _start

_start:
    ; Save envp (after argv NULL terminator)
    mov rdi, [rsp]               ; argc
    lea rsi, [rsp + 8]           ; argv
    lea rax, [rdi + 1]
    lea rcx, [rsi + rax*8]
    mov [envp], rcx

    call parse_display
    call read_xauthority

    call x11_connect
    test rax, rax
    jnz .die_x11

    call x11_parse_setup
    call x11_get_keymap

    ; Reserve arg_pool[0] as the "no arg" sentinel and load ~/.tilerc.
    mov dword [arg_pool_pos], 1
    mov byte [arg_pool], 0
    ; Start on workspace 1.
    mov byte [current_ws], 1
    mov byte [prev_ws], 0
    ; Bar defaults (~/.tilerc may override).
    mov word [bar_height], DEFAULT_BAR_HEIGHT
    mov dword [cfg_bar_bg], 0xFF000000
    mov dword [cfg_tab_default], 0xFF555555
    mov byte [cfg_tab_dim_factor], DEFAULT_TAB_DIM_FACTOR
    mov dword [cfg_ws_active], 0xFFffffff
    mov dword [cfg_ws_populated], 0xFF555555
    mov byte [cfg_ws_dim_factor], 70
    ; Per-workspace colour overrides — sentinel 0xFFFFFFFF means "use
    ; the active/populated default for this slot".
    mov rcx, 10
    lea rdi, [cfg_ws_colors]
    mov eax, 0xFFFFFFFF
    rep stosd
    mov byte [cfg_tab_palette_count], 0
    mov word [cfg_gap_inner], 0
    mov word [cfg_strip_height], 0
    mov word [cfg_bar_pad], DEFAULT_BAR_PAD
    mov word [cfg_bar_pad_bottom], 1
    mov byte [cfg_border_width], DEFAULT_BORDER_WIDTH
    mov dword [cfg_border_focused], DEFAULT_BORDER_FOCUSED
    mov dword [cfg_border_unfocused], DEFAULT_BORDER_UNFOCUSED
    mov dword [focused_xid], 0
    mov byte [cfg_master_ratio], DEFAULT_MASTER_RATIO
    mov dword [cfg_layout_color], 0           ; 0 → fall back to cfg_tab_default
    mov dword [cfg_active_frame], 0           ; 0 → no frame drawn
    ; Initialise pin override table to "unset" (0xFF). load_config
    ; will populate any explicit `pin N M` lines.
    mov rax, 0xFFFFFFFFFFFFFFFF
    mov [ws_pin_override], rax
    mov word [ws_pin_override + 8], 0xFFFF
    call load_config

    ; Become the WM by selecting substructure-redirect on root.
    call select_substructure_redirect
    call x11_flush
    call check_redirect_ok
    test rax, rax
    jnz .die_redirect

    ; Resolve the ICCCM atoms used for WM_DELETE_WINDOW.
    call intern_wm_atoms

    ; Discover physical outputs via the XINERAMA extension. Falls back
    ; to a single-output table covering the whole root window if the
    ; extension isn't present. After this returns, output_count is at
    ; least 1 and ws_pinned_output[] is initialised.
    call discover_outputs
    call dbg_dump_outputs
    call apply_pin_overrides
    call randr_setup

    ; Resolve every bind's keysym to a keycode and grab them on root.
    call resolve_and_grab_binds
    call dbg_dump_binds
    call x11_flush

    ; Create the row-of-squares bar window across the top of the screen.
    call create_bar
    call render_bar
    call x11_flush

    ; SIGUSR1 → reload ~/.tilerc without restarting.
    call install_sigusr1

    ; Run autostart entries from ~/.tilerc.
    call run_autostart

    ; Enter event loop.
    jmp event_loop

.die_x11:
    mov rax, SYS_WRITE
    mov rdi, 2
    lea rsi, [err_x11]
    mov rdx, err_x11_len
    syscall
    jmp .die

.die_redirect:
    mov rax, SYS_WRITE
    mov rdi, 2
    lea rsi, [err_redirect]
    mov rdx, err_redirect_len
    syscall

.die:
    mov rax, SYS_EXIT
    mov edi, 1
    syscall

; ══════════════════════════════════════════════════════════════════════
; X11 connection setup
; ══════════════════════════════════════════════════════════════════════

parse_display:
    push rbx
    mov rdi, [envp]
.pd_loop:
    mov rax, [rdi]
    test rax, rax
    jz .pd_default
    cmp dword [rax], 'DISP'
    jne .pd_next
    cmp dword [rax+4], 'LAY='
    jne .pd_next
    add rax, 8
    cmp byte [rax], ':'
    jne .pd_default
    inc rax
    xor ebx, ebx
.pd_num:
    movzx edx, byte [rax]
    cmp dl, '0'
    jb .pd_num_done
    cmp dl, '9'
    ja .pd_num_done
    sub dl, '0'
    imul ebx, 10
    add ebx, edx
    inc rax
    jmp .pd_num
.pd_num_done:
    mov [display_num], rbx
    pop rbx
    ret
.pd_next:
    add rdi, 8
    jmp .pd_loop
.pd_default:
    mov qword [display_num], 0
    pop rbx
    ret

read_xauthority:
    push rbx
    push r12
    mov rdi, [envp]
.rxa_loop:
    mov rax, [rdi]
    test rax, rax
    jz .rxa_try_home
    cmp dword [rax], 'XAUT'
    jne .rxa_next
    cmp dword [rax+4], 'HORI'
    jne .rxa_next
    cmp word [rax+8], 'TY'
    jne .rxa_next
    cmp byte [rax+10], '='
    jne .rxa_next
    lea rsi, [rax + 11]
    jmp .rxa_open
.rxa_next:
    add rdi, 8
    jmp .rxa_loop
.rxa_try_home:
    mov rdi, [envp]
.rxa_h_loop:
    mov rax, [rdi]
    test rax, rax
    jz .rxa_done
    cmp dword [rax], 'HOME'
    jne .rxa_h_next
    cmp byte [rax+4], '='
    jne .rxa_h_next
    lea rsi, [rax + 5]
    lea rdi, [tmp_buf]
.rxa_cp_home:
    mov al, [rsi]
    test al, al
    jz .rxa_append
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .rxa_cp_home
.rxa_append:
    mov dword [rdi], '/.Xa'
    mov dword [rdi+4], 'utho'
    mov dword [rdi+8], 'rity'
    mov byte [rdi+12], 0
    lea rsi, [tmp_buf]
    jmp .rxa_open
.rxa_h_next:
    add rdi, 8
    jmp .rxa_h_loop

.rxa_open:
    mov rax, SYS_OPEN
    mov rdi, rsi
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .rxa_done
    mov rbx, rax
    mov rax, SYS_READ
    mov rdi, rbx
    lea rsi, [xauth_buf]
    mov rdx, 4096
    syscall
    mov r12, rax
    mov rax, SYS_CLOSE
    mov rdi, rbx
    syscall
    lea rsi, [xauth_buf]
    lea rdi, [xauth_buf]
    add rdi, r12
.rxa_parse:
    cmp rsi, rdi
    jge .rxa_done
    add rsi, 2                ; family
    movzx eax, byte [rsi]
    shl eax, 8
    movzx ecx, byte [rsi+1]
    or eax, ecx
    add rsi, 2
    add rsi, rax              ; addr
    movzx eax, byte [rsi]
    shl eax, 8
    movzx ecx, byte [rsi+1]
    or eax, ecx
    add rsi, 2
    add rsi, rax              ; number
    movzx eax, byte [rsi]
    shl eax, 8
    movzx ecx, byte [rsi+1]
    or eax, ecx
    add rsi, 2
    mov rbx, rax
    add rsi, rbx              ; name
    movzx eax, byte [rsi]
    shl eax, 8
    movzx ecx, byte [rsi+1]
    or eax, ecx
    add rsi, 2
    cmp eax, 16
    jne .rxa_skip_data
    lea rdi, [xauth_data]
    mov ecx, 16
.rxa_cp_cookie:
    mov bl, [rsi]
    mov [rdi], bl
    inc rsi
    inc rdi
    dec ecx
    jnz .rxa_cp_cookie
    mov qword [xauth_len], 16
    jmp .rxa_done
.rxa_skip_data:
    add rsi, rax
    jmp .rxa_parse
.rxa_done:
    pop r12
    pop rbx
    ret

x11_connect:
    push rbx
    push r12
    mov rax, SYS_SOCKET
    mov rdi, AF_UNIX
    mov rsi, SOCK_STREAM
    xor edx, edx
    syscall
    test rax, rax
    js .xc_fail
    mov [x11_fd], rax
    mov rbx, rax

    lea rdi, [sockaddr_buf]
    mov word [rdi], AF_UNIX
    add rdi, 2
    lea rsi, [x11_sock_pre]
.xc_cp_path:
    mov al, [rsi]
    test al, al
    jz .xc_cp_num
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .xc_cp_path
.xc_cp_num:
    mov rax, [display_num]
    push rdi
    call itoa
    pop rdi
    add rdi, rax
    mov byte [rdi], 0

    mov rax, SYS_CONNECT
    mov rdi, rbx
    lea rsi, [sockaddr_buf]
    mov rdx, 110
    syscall
    test rax, rax
    js .xc_fail

    ; Build connection-setup request.
    lea rdi, [tmp_buf]
    mov byte [rdi], 0x6C       ; little-endian
    mov byte [rdi+1], 0
    mov word [rdi+2], 11
    mov word [rdi+4], 0
    mov word [rdi+6], auth_name_len
    movzx eax, word [xauth_len]
    mov word [rdi+8], ax
    mov word [rdi+10], 0
    lea rsi, [auth_name]
    lea rdi, [tmp_buf + 12]
    mov ecx, auth_name_len
.xc_cp_name:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz .xc_cp_name
    ; Pad to 4
    mov ecx, auth_name_len
    and ecx, 3
    jz .xc_data
    mov edx, 4
    sub edx, ecx
.xc_pad:
    mov byte [rdi], 0
    inc rdi
    dec edx
    jnz .xc_pad
.xc_data:
    lea rsi, [xauth_data]
    mov ecx, 16
.xc_cp_cookie:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz .xc_cp_cookie

    mov rdx, rdi
    lea rsi, [tmp_buf]
    sub rdx, rsi
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    syscall

    ; Read connection setup reply
    xor r12, r12
.xc_read:
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [conn_setup_buf]
    add rsi, r12
    mov rdx, 16384
    sub rdx, r12
    jle .xc_read_done
    syscall
    test rax, rax
    jle .xc_fail
    add r12, rax
    cmp r12, 8
    jl .xc_read
    movzx eax, word [conn_setup_buf + 6]
    shl eax, 2
    add eax, 8
    cmp r12d, eax
    jl .xc_read
.xc_read_done:
    cmp byte [conn_setup_buf], 1
    jne .xc_fail
    xor eax, eax
    pop r12
    pop rbx
    ret
.xc_fail:
    mov rax, -1
    pop r12
    pop rbx
    ret

x11_parse_setup:
    push rbx
    push r12
    lea rsi, [conn_setup_buf]
    mov eax, [rsi + 12]
    mov [x11_rid_base], eax
    mov eax, [rsi + 16]
    mov [x11_rid_mask], eax
    mov dword [x11_rid_next], 1
    movzx eax, byte [rsi + 34]
    mov [x11_min_keycode], al
    movzx eax, byte [rsi + 35]
    mov [x11_max_keycode], al

    movzx eax, word [rsi + 24]
    mov rbx, rax
    add rbx, 3
    and rbx, ~3
    movzx ecx, byte [rsi + 29]
    imul ecx, 8

    lea r12, [rsi + 40]
    add r12, rbx
    add r12, rcx

    mov eax, [r12]
    mov [x11_root_window], eax
    mov eax, [r12 + 8]
    mov [x11_white_pixel], eax
    mov eax, [r12 + 12]
    mov [x11_black_pixel], eax
    movzx eax, word [r12 + 20]
    mov [x11_screen_width], ax
    movzx eax, word [r12 + 22]
    mov [x11_screen_height], ax
    mov eax, [r12 + 32]
    mov [x11_root_visual], eax
    movzx eax, byte [r12 + 38]
    mov [x11_root_depth], al

    mov dword [x11_seq], 1     ; first request will be seq 1
    pop r12
    pop rbx
    ret

x11_get_keymap:
    push rbx
    push r12
    push r13

    movzx eax, byte [x11_min_keycode]
    mov r12d, eax
    movzx ecx, byte [x11_max_keycode]
    sub ecx, eax
    inc ecx
    mov r13d, ecx

    lea rdi, [tmp_buf]
    mov byte [rdi], X11_GET_KEYBOARD_MAPPING
    mov byte [rdi+1], 0
    mov word [rdi+2], 2
    mov [rdi+4], r12b
    mov [rdi+5], r13b
    mov word [rdi+6], 0

    lea rsi, [tmp_buf]
    mov rdx, 8
    call x11_buffer
    inc dword [x11_seq]
    call x11_flush

    ; Read 32-byte reply header
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [x11_read_buf]
    mov rdx, 32
    syscall
    cmp rax, 32
    jl .xgk_done

    movzx eax, byte [x11_read_buf + 1]
    mov [keysyms_per_kc], eax
    mov ebx, eax

    mov eax, [x11_read_buf + 4]
    shl eax, 2
    mov r13d, eax

    xor r12d, r12d
.xgk_read:
    cmp r12d, r13d
    jge .xgk_parse
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [x11_read_buf]
    add rsi, r12
    mov edx, r13d
    sub edx, r12d
    cmp edx, 65536
    jle .xgk_read_ok
    mov edx, 65536
.xgk_read_ok:
    syscall
    test eax, eax
    jle .xgk_done
    add r12d, eax
    jmp .xgk_read

.xgk_parse:
    movzx eax, byte [x11_min_keycode]
    mov ecx, eax
    xor edx, edx
    mov ebx, [keysyms_per_kc]
.xgk_kc_loop:
    cmp edx, r12d
    jge .xgk_done
    xor esi, esi
.xgk_sym_loop:
    cmp esi, ebx
    jge .xgk_next_kc
    cmp esi, 8
    jge .xgk_skip
    cmp edx, r12d
    jge .xgk_done
    mov eax, ecx
    shl eax, 3
    add eax, esi
    mov r8d, [x11_read_buf + rdx]
    mov [keysym_map + rax*4], r8d
    add edx, 4
    inc esi
    jmp .xgk_sym_loop
.xgk_skip:
    add edx, 4
    inc esi
    jmp .xgk_sym_loop
.xgk_next_kc:
    inc ecx
    cmp ecx, 256
    jge .xgk_done
    jmp .xgk_kc_loop
.xgk_done:
    pop r13
    pop r12
    pop rbx
    ret

; Find first keycode whose group-1 keysym matches eax. Returns keycode in
; al (0 if not found).
find_keycode_for_keysym:
    push rbx
    mov ebx, eax
    movzx ecx, byte [x11_min_keycode]
    movzx edx, byte [x11_max_keycode]
.fkc_loop:
    cmp ecx, edx
    jg .fkc_none
    mov eax, ecx
    shl eax, 3                ; keycode * 8 (8 syms per keycode)
    cmp dword [keysym_map + rax*4], ebx
    je .fkc_hit
    inc ecx
    jmp .fkc_loop
.fkc_none:
    xor eax, eax
    pop rbx
    ret
.fkc_hit:
    mov eax, ecx
    pop rbx
    ret

; Walk every bind in bind_table, look up its keysym in keysym_map, store
; the resulting keycode at offset +4. Then GrabKey it on root with all
; lock-state combinations. Skips entries whose keysym doesn't resolve.
resolve_and_grab_binds:
    push rbx
    push r12
    push r13
    xor ebx, ebx                 ; iterator
.rgb_loop:
    cmp ebx, [bind_count]
    jge .rgb_done
    mov r12, rbx
    imul r12, BIND_STRIDE
    add r12, bind_table          ; r12 = &bind_table[i]
    mov eax, [r12]               ; keysym
    call find_keycode_for_keysym
    test eax, eax
    jz .rgb_skip
    mov [r12 + 4], eax           ; store resolved keycode (low 8 bits used)
    movzx esi, word [r12 + 8]    ; modifiers
    mov edi, eax                 ; keycode
    call grab_one_key
.rgb_skip:
    inc ebx
    jmp .rgb_loop
.rgb_done:
    pop r13
    pop r12
    pop rbx
    ret

; ══════════════════════════════════════════════════════════════════════
; Become the WM
; ══════════════════════════════════════════════════════════════════════

select_substructure_redirect:
    ; ChangeWindowAttributes(root, CW_EVENT_MASK, mask)
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_CHANGE_WINDOW_ATTRS
    mov byte [rdi+1], 0
    mov word [rdi+2], 4         ; request length = 4 words
    mov eax, [x11_root_window]
    mov [rdi+4], eax
    mov dword [rdi+8], CW_EVENT_MASK
    mov dword [rdi+12], SUBSTRUCTURE_REDIRECT_MASK | SUBSTRUCTURE_NOTIFY_MASK | PROPERTY_CHANGE_MASK | KEY_PRESS_MASK
    lea rsi, [tmp_buf]
    mov rdx, 16
    call x11_buffer
    inc dword [x11_seq]
    ret

; After flushing the substructure-redirect request, read once with a short
; poll; if an X error of code BadAccess arrives, another WM is running.
check_redirect_ok:
    push rbx
    ; poll(fd, POLLIN, 100ms)
    sub rsp, 16
    mov dword [rsp], 0          ; padding
    mov eax, [x11_fd]
    mov [rsp + 0], eax
    mov word [rsp + 4], 1       ; POLLIN
    mov word [rsp + 6], 0
    mov rax, SYS_POLL
    lea rdi, [rsp]
    mov esi, 1
    mov edx, 100                ; ms
    syscall
    test rax, rax
    jle .cro_ok                 ; timeout = no error = we own it
    ; Read a 32-byte event/error
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [x11_read_buf]
    mov rdx, 32
    syscall
    cmp rax, 32
    jl .cro_ok
    cmp byte [x11_read_buf], 0  ; 0 = error
    jne .cro_ok
    cmp byte [x11_read_buf + 1], 10   ; 10 = BadAccess
    jne .cro_ok
    add rsp, 16
    mov rax, 1
    pop rbx
    ret
.cro_ok:
    add rsp, 16
    xor eax, eax
    pop rbx
    ret

; edi = keycode (low 8 bits), esi = base modifier mask (low 16 bits).
; Grabs all four lock-state combinations (none, CapsLock, NumLock,
; CapsLock+NumLock) so the binding fires regardless of lock state.
; Uses callee-saved r12/r13/rbx because x11_buffer clobbers ecx/edx.
grab_one_key:
    push rbx
    push r12
    push r13
    mov r12d, edi              ; keycode
    mov r13d, esi              ; base modifiers
    xor ebx, ebx               ; iterator: 0..3 over lock combinations
.gok_loop:
    mov ecx, r13d
    test ebx, 1
    jz .gok_no_caps
    or ecx, MOD_LOCK
.gok_no_caps:
    test ebx, 2
    jz .gok_no_num
    or ecx, MOD_MOD2
.gok_no_num:
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_GRAB_KEY
    mov byte [rdi+1], 1                ; owner_events
    mov word [rdi+2], 4                ; request length (4 words = 16 bytes)
    mov eax, [x11_root_window]
    mov [rdi+4], eax
    mov word [rdi+8], cx               ; modifiers
    mov [rdi+10], r12b                 ; keycode
    mov byte [rdi+11], 1               ; pointer-mode = Async
    mov byte [rdi+12], 1               ; keyboard-mode = Async
    mov byte [rdi+13], 0
    mov byte [rdi+14], 0
    mov byte [rdi+15], 0
    lea rsi, [tmp_buf]
    mov rdx, 16
    call x11_buffer
    inc dword [x11_seq]
    inc ebx
    cmp ebx, 4
    jl .gok_loop
    pop r13
    pop r12
    pop rbx
    ret

; ══════════════════════════════════════════════════════════════════════
; X11 buffered I/O
; ══════════════════════════════════════════════════════════════════════

; Allocate a new X resource ID. Returns the XID in eax.
alloc_xid:
    mov eax, [x11_rid_next]
    inc dword [x11_rid_next]
    and eax, [x11_rid_mask]
    or eax, [x11_rid_base]
    ret

; rsi = data, rdx = length — append to write buffer.
x11_buffer:
    push rbx
    mov rbx, [x11_write_pos]
    lea rdi, [x11_write_buf + rbx]
    xor ecx, ecx
.xb_loop:
    cmp rcx, rdx
    jge .xb_done
    movzx eax, byte [rsi + rcx]
    mov [rdi + rcx], al
    inc rcx
    jmp .xb_loop
.xb_done:
    add [x11_write_pos], rdx
    pop rbx
    ret

x11_flush:
    mov rdx, [x11_write_pos]
    test rdx, rdx
    jz .xf_done
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    lea rsi, [x11_write_buf]
    syscall
    mov qword [x11_write_pos], 0
.xf_done:
    ret

; ══════════════════════════════════════════════════════════════════════
; Event loop
; ══════════════════════════════════════════════════════════════════════

event_loop:
    ; SIGUSR1 may have asked for a reload while we were busy or
    ; sleeping in read(). Handle it here, between events, where the
    ; X11 connection is in a known state (no half-sent requests).
    cmp byte [reload_pending], 0
    je .el_no_reload
    call reload_runtime
.el_no_reload:
    ; Always flush before sleeping so the server sees our requests.
    call x11_flush

    ; Drain any events queued during a synchronous reply read (e.g.
    ; GetProperty in action_exec_here). The queue holds at most
    ; PENDING_MAX 32-byte events; we copy one into x11_read_buf and
    ; jump straight to dispatch.
    cmp dword [pending_count], 0
    je .el_read_socket
    mov ebx, [pending_head]
    mov rax, rbx
    shl rax, 5                   ; * 32
    lea rsi, [pending_events + rax]
    lea rdi, [x11_read_buf]
    mov ecx, 4
.el_drain_copy:
    mov rax, [rsi]
    mov [rdi], rax
    add rsi, 8
    add rdi, 8
    dec ecx
    jnz .el_drain_copy
    inc ebx
    cmp ebx, PENDING_MAX
    jl .el_drain_no_wrap
    xor ebx, ebx
.el_drain_no_wrap:
    mov [pending_head], ebx
    dec dword [pending_count]
    jmp .el_dispatch

.el_read_socket:
    ; Read one 32-byte event (X11 always sends events as 32-byte units).
    ; A blocking read on a Unix socket sleeps the process; that's the
    ; only path we should ever take when at idle. If the X server has
    ; gone away, read returns 0 (EOF) — without the .x11_dead exit
    ; below, we'd spin re-reading the dead socket forever, which is
    ; exactly the 100%-CPU bug that made tile a battery hog when its
    ; Xephyr was killed.
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [x11_read_buf]
    mov rdx, 32
    syscall
    test rax, rax
    jz .x11_dead                 ; 0 = EOF (server gone)
    js .el_read_err              ; negative = -errno; tolerate -EINTR
    cmp rax, 32
    jl event_loop                ; genuine short read — retry
.el_dispatch:

    movzx eax, byte [x11_read_buf]
    and al, 0x7F                 ; strip SendEvent bit
    cmp al, EV_MAP_REQUEST
    je .ev_map_request
    cmp al, EV_CONFIGURE_REQUEST
    je .ev_configure_request
    cmp al, EV_KEY_PRESS
    je .ev_key_press
    cmp al, EV_UNMAP_NOTIFY
    je .ev_unmap_notify
    cmp al, EV_DESTROY_NOTIFY
    je .ev_destroy_notify
    cmp al, EV_EXPOSE
    je .ev_expose
    ; RandR ScreenChangeNotify? Only check if RandR was successfully set
    ; up at startup (otherwise randr_event_base could collide with 0).
    cmp byte [randr_present], 0
    je .el_unknown
    cmp al, byte [randr_event_base]
    je .ev_rr_screen_change
.el_unknown:
    ; Ignore anything else (MapNotify, ConfigureNotify, errors, replies).
    jmp event_loop

.ev_rr_screen_change:
    call rediscover_outputs
    jmp event_loop

.ev_expose:
    ; Expose bytes 8-11 = window. Only redraw if it's our bar window.
    mov eax, [x11_read_buf + 8]
    cmp eax, [bar_window_id]
    jne event_loop
    call render_bar
    jmp event_loop

.el_read_err:
    ; -EINTR (signal handler ran during the read, e.g. SIGUSR1) — go
    ; back to the top of the loop so reload_pending gets drained.
    cmp rax, -EINTR
    je event_loop
    ; Other errors are fatal in the same way EOF is.
.x11_dead:
    ; X server connection lost (e.g. xephyr was killed, real X11 crashed).
    ; Exit cleanly rather than spin on a dead socket.
    mov rax, SYS_EXIT
    xor edi, edi
    syscall

.ev_map_request:
    ; Debug: log map-req arrival with the XID
    mov eax, [x11_read_buf + 8]
    call dbg_log_mapreq
    ; Transient / dialog popups (Gimp save-changes prompt, GTK
    ; FileChooser, etc.) signal their floating role via
    ; WM_TRANSIENT_FOR or _NET_WM_WINDOW_TYPE_DIALOG/UTILITY/etc.
    ; Force-tiling them produces a flicker loop because GIMP-style
    ; apps fight tile's ConfigureWindow → workspace-fullscreen with
    ; their own "I want 400×300 centered" geometry hints, unmapping
    ; and remapping until something gives.
    ;
    ; Just MapWindow these — they keep whatever geometry they asked
    ; for and stay outside the tab strip. Standalone-style windows
    ; without a transient parent (forticlient login, etc.) DON'T
    ; match this check and continue to land as full-cell tabs.
    ;
    ; The synchronous GetProperty inside is_transient_window is now
    ; bounded by read_reply_or_queue's 250 ms poll budget, so the
    ; slack-file-picker-style lockup the previous transient path
    ; allowed can no longer wedge tile.
    mov edi, [x11_read_buf + 8]
    call is_transient_window
    test eax, eax
    jz .ev_mr_not_transient
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_MAP_WINDOW
    mov byte [rdi+1], 0
    mov word [rdi+2], 2
    mov eax, [x11_read_buf + 8]
    mov [rdi+4], eax
    lea rsi, [tmp_buf]
    mov rdx, 8
    call x11_buffer
    inc dword [x11_seq]
    call x11_flush
    jmp event_loop
.ev_mr_not_transient:
    ; New client. Two optional config-driven detours before the default
    ; "land on current workspace, become active tab" path:
    ;   1. `assign <class> <ws>`   → route to <ws> instead of current
    ;   2. `stash-on-map <class>`  → after tracking, push to stash
    ;                                 (i3-scratchpad equivalent)
    mov edi, [x11_read_buf + 8]
    call apply_assign                     ; eax = target ws or 0
    test eax, eax
    jnz .ev_mr_assigned
    movzx esi, byte [current_ws]
    jmp .ev_mr_configure
.ev_mr_assigned:
    mov [pending_assign_ws], al
    movzx esi, al
.ev_mr_configure:
    ; Debug: also log the workspace decision
    push rsi
    push rdi
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    lea rdi, [dkp_buf]
    mov byte [rdi+0], 't'
    mov byte [rdi+1], 'i'
    mov byte [rdi+2], 'l'
    mov byte [rdi+3], 'e'
    mov byte [rdi+4], ':'
    mov byte [rdi+5], ' '
    mov byte [rdi+6], 'm'
    mov byte [rdi+7], 'r'
    mov byte [rdi+8], '-'
    mov byte [rdi+9], 'w'
    mov byte [rdi+10], 's'
    mov byte [rdi+11], '='
    add rdi, 12
    mov rax, [rsp + 56]                    ; saved rsi (workspace target)
    movzx eax, al
    call dbg_u32_dec
    mov byte [rdi], 10
    inc rdi
    lea rsi, [dkp_buf]
    mov rdx, rdi
    sub rdx, rsi
    mov rax, SYS_WRITE
    mov edi, 2
    syscall
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rdi
    pop rsi
    mov edi, [x11_read_buf + 8]
    call configure_client_for_workspace
    mov eax, [x11_read_buf + 8]
    call track_client                     ; honours pending_assign_ws
    mov byte [pending_assign_ws], 0
    ; Debug: log post-track state.
    mov eax, 0x100                         ; sentinel "after-track"
    call dbg_log_mrtag

    ; stash-on-map?
    mov edi, [x11_read_buf + 8]
    call apply_stash_on_map
    push rax                               ; save stash result
    movzx eax, al
    add eax, 0x200                         ; sentinel "stash result"
    call dbg_log_mrtag
    pop rax
    test eax, eax
    jnz .ev_mr_done                       ; stashed — skip activation

    ; Default: become the active tab on whatever ws we ended up on.
    mov eax, [x11_read_buf + 8]
    call find_client_index
    push rax
    add eax, 0x300                         ; sentinel "find_client_index result"
    call dbg_log_mrtag
    pop rax
    cmp eax, -1
    je .ev_mr_done
    movzx esi, byte [client_ws + rax]
    mov eax, [x11_read_buf + 8]
    ; Debug: log set_active_tab_on_ws entry args
    push rax
    push rsi
    movzx eax, sil
    add eax, 0x400                         ; sentinel "sat target ws"
    call dbg_log_mrtag
    pop rsi
    pop rax
    call set_active_tab_on_ws
.ev_mr_done:
    jmp event_loop

.ev_configure_request:
    ; A managed client is asking to resize. Behaviour depends on the
    ; client's workspace layout:
    ;   TABBED  → re-confirm fullscreen-of-output (the same geometry
    ;             we already gave it; clients sometimes ask for it
    ;             after their own internal events).
    ;   SPLIT_* → re-apply the workspace's split layout so the
    ;             requesting client doesn't get its self-requested
    ;             "go full screen" wish granted on top of our slice.
    ; Unknown clients (untracked) get TABBED-style fullscreen on the
    ; current workspace as a sane default.
    mov eax, [x11_read_buf + 8]
    push rax
    call find_client_index
    cmp eax, -1
    je .ev_cr_default_ws
    movzx esi, byte [client_ws + rax]
    pop rax
    push rax
    push rsi
    mov ecx, esi
    dec ecx
    movzx ecx, byte [ws_layout + rcx]
    test ecx, ecx
    jz .ev_cr_tabbed
    ; SPLIT_*: re-apply workspace layout, ignore the request's geometry.
    pop rsi
    pop rax
    mov eax, esi
    call apply_workspace_layout
    jmp event_loop
.ev_cr_tabbed:
    pop rsi
    pop rax
    mov edi, eax
    call configure_client_for_workspace
    jmp event_loop
.ev_cr_default_ws:
    ; Unknown client — typically a transient/dialog window we chose
    ; not to track in MapRequest. Pass the request through verbatim
    ; so e.g. Gimp's tool windows get the size+position they ask
    ; for. Without this, we'd fullscreen-them via
    ; configure_client_for_workspace, the client would re-request
    ; its real size, and we'd re-fullscreen → flicker loop.
    pop rax
    call passthrough_configure_request
    jmp event_loop

.ev_unmap_notify:
    ; If the unmap matches a pending WM-initiated unmap (workspace
    ; switch, move-to), just clear the flag and leave the client in
    ; the stack. Real client-initiated closes get untracked.
    mov eax, [x11_read_buf + 8]
    call find_client_index
    cmp eax, -1
    je event_loop
    mov ebx, eax
    cmp byte [client_unmap_expected + rbx], 0
    je .eun_real
    mov byte [client_unmap_expected + rbx], 0
    jmp event_loop
.eun_real:
    mov eax, [x11_read_buf + 8]
    call client_closed
    jmp event_loop

.ev_destroy_notify:
    mov eax, [x11_read_buf + 8]
    call client_closed
    jmp event_loop

.ev_key_press:
    ; KeyPress layout: byte 1 = keycode, bytes 28-29 = state (modifiers).
    movzx eax, byte [x11_read_buf + 1]
    movzx edx, word [x11_read_buf + 28]
    and edx, ~(MOD_LOCK | MOD_MOD2)      ; strip locks
    push rax
    push rdx
    call dbg_keypress
    pop rdx
    pop rax
    call dispatch_keypress
    jmp event_loop

; Debug: log every KeyPress to stderr so a session log can prove
; whether tile is actually receiving keys. eax = keycode, edx = mods.
; Format: "tile: kp=NNN mod=0xHH\n"
dbg_keypress:
    push rax
    push rdx
    push rcx
    lea rdi, [dkp_buf]
    lea rsi, [.dkp_pre]
    mov ecx, .dkp_pre_len
.dkp_copy:
    test ecx, ecx
    jz .dkp_kc
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jmp .dkp_copy
.dkp_kc:
    lea rdi, [dkp_buf + .dkp_pre_len]    ; resume after the prefix
    mov rax, [rsp + 16]                  ; original eax (keycode)
    ; itoa decimal, 3 digits with leading space-pad; simple loop
    mov rcx, 100
    xor edx, edx
    div rcx
    add al, '0'
    mov [rdi], al
    inc rdi
    mov rax, rdx
    mov rcx, 10
    xor edx, edx
    div rcx
    add al, '0'
    mov [rdi], al
    inc rdi
    mov al, dl
    add al, '0'
    mov [rdi], al
    inc rdi
    mov byte [rdi], ' '
    inc rdi
    mov byte [rdi], 'm'
    inc rdi
    mov byte [rdi], '='
    inc rdi
    mov byte [rdi], '0'
    inc rdi
    mov byte [rdi], 'x'
    inc rdi
    mov rax, [rsp + 8]                   ; original edx (mods)
    mov rdx, rax
    shr rdx, 4
    and edx, 0xF
    cmp dl, 10
    jl .dkp_hi_dig
    add dl, 'a' - 10 - '0'
.dkp_hi_dig:
    add dl, '0'
    mov [rdi], dl
    inc rdi
    and eax, 0xF
    cmp al, 10
    jl .dkp_lo_dig
    add al, 'a' - 10 - '0'
.dkp_lo_dig:
    add al, '0'
    mov [rdi], al
    inc rdi
    mov byte [rdi], 10
    inc rdi
    lea rsi, [dkp_buf]
    mov rdx, rdi
    sub rdx, rsi
    mov rax, SYS_WRITE
    mov edi, 2
    syscall
    pop rcx
    pop rdx
    pop rax
    ret
.dkp_pre: db "tile: kp="
.dkp_pre_len equ $ - .dkp_pre

; Debug: dump output table to stderr.
;   "tile: outputs=N\n"
;   "  out 0  x=NNN y=NNN w=NNNN h=NNNN  cur_ws=N pinned=N\n"
;   ... per output, plus per-workspace pinned-output info.
dbg_dump_outputs:
    push rbx
    push r12
    ; Build "tile: outputs=N screen=WWWWxHHHH\n" and emit
    movzx eax, byte [output_count]
    mov rdi, dkp_buf
    mov dword [rdi+0], 0x656c6974
    mov byte  [rdi+4], ':'
    mov byte  [rdi+5], ' '
    mov dword [rdi+6], 0x70747568        ; "hutp" → little-endian: 'h','u','t','p' → "huts" wrong; just write bytes:
    ; Easier approach: write byte-by-byte.
    mov byte [rdi+0], 't'
    mov byte [rdi+1], 'i'
    mov byte [rdi+2], 'l'
    mov byte [rdi+3], 'e'
    mov byte [rdi+4], ':'
    mov byte [rdi+5], ' '
    mov byte [rdi+6], 'o'
    mov byte [rdi+7], 'u'
    mov byte [rdi+8], 't'
    mov byte [rdi+9], 'p'
    mov byte [rdi+10], 'u'
    mov byte [rdi+11], 't'
    mov byte [rdi+12], 's'
    mov byte [rdi+13], '='
    add al, '0'
    mov [rdi+14], al
    mov byte [rdi+15], 10
    mov rax, SYS_WRITE
    mov edi, 2
    lea rsi, [dkp_buf]
    mov edx, 16
    syscall
    ; Per-output: "  out N x=NNN y=NNN w=NNNN h=NNNN cur=N\n"
    xor ebx, ebx
.ddo_loop:
    movzx eax, byte [output_count]
    cmp ebx, eax
    jge .ddo_done
    ; Build line: "out N x=NNN y=NNN w=NNNN h=NNNN cur=N\n"
    mov rdi, dkp_buf
    mov byte [rdi+0], 'o'
    mov byte [rdi+1], 'u'
    mov byte [rdi+2], 't'
    mov byte [rdi+3], ' '
    mov al, bl
    add al, '0'
    mov [rdi+4], al
    mov byte [rdi+5], ' '
    mov byte [rdi+6], 'x'
    mov byte [rdi+7], '='
    add rdi, 8
    movzx eax, word [output_x + rbx*2]
    call dbg_u16_dec                    ; writes up to 5 digits, advances rdi
    mov byte [rdi], ' '
    mov byte [rdi+1], 'y'
    mov byte [rdi+2], '='
    add rdi, 3
    movzx eax, word [output_y + rbx*2]
    call dbg_u16_dec
    mov byte [rdi], ' '
    mov byte [rdi+1], 'w'
    mov byte [rdi+2], '='
    add rdi, 3
    movzx eax, word [output_w + rbx*2]
    call dbg_u16_dec
    mov byte [rdi], ' '
    mov byte [rdi+1], 'h'
    mov byte [rdi+2], '='
    add rdi, 3
    movzx eax, word [output_h + rbx*2]
    call dbg_u16_dec
    mov byte [rdi], ' '
    mov byte [rdi+1], 'c'
    mov byte [rdi+2], 'u'
    mov byte [rdi+3], 'r'
    mov byte [rdi+4], '='
    add rdi, 5
    movzx eax, byte [output_current_ws + rbx]
    call dbg_u16_dec
    mov byte [rdi], 10
    inc rdi
    lea rsi, [dkp_buf]
    mov rdx, rdi
    sub rdx, rsi
    mov rax, SYS_WRITE
    mov edi, 2
    syscall
    inc ebx
    jmp .ddo_loop
.ddo_done:
    pop r12
    pop rbx
    ret

; rdi = destination buffer position, eax = unsigned 16-bit value to
; print as decimal (up to 5 digits, leading zeros suppressed). After
; the call, rdi points past the last digit written. Clobbers eax/edx/r9.
dbg_u16_dec:
    test eax, eax
    jnz .du16_nonzero
    mov byte [rdi], '0'
    inc rdi
    ret
.du16_nonzero:
    ; Build digits in reverse on a small local stack via r9.
    sub rsp, 8
    mov r9, rsp                          ; write head
.du16_div:
    test eax, eax
    jz .du16_emit
    xor edx, edx
    mov ecx, 10
    div ecx                              ; eax /= 10, edx = remainder
    add dl, '0'
    mov [r9], dl
    inc r9
    jmp .du16_div
.du16_emit:
    ; r9 - rsp = digit count; write them out in reverse.
.du16_emit_loop:
    cmp r9, rsp
    je .du16_emit_done
    dec r9
    mov al, [r9]
    mov [rdi], al
    inc rdi
    jmp .du16_emit_loop
.du16_emit_done:
    add rsp, 8
    ret

; Debug dump: at startup, log "tile: binds N" then one line per entry
; with keysym, keycode, mods, action_id, arg_int, arg_off.
dbg_dump_binds:
    push rbx
    push r12
    ; Header: "tile: bind_count=NN\n"
    lea rdi, [dkp_buf]
    mov dword [rdi+0], 0x656c6974    ; "tile" (LE: 't','i','l','e' = 0x65,0x6c,0x69,0x74 → little-endian dword)
    mov dword [rdi+4], 0x6e69623a    ; ":bin"
    mov dword [rdi+8], 0x6f635f64    ; "d_co"
    mov dword [rdi+12], 0x3d746e75   ; "unt="
    mov rax, [bind_count]
    cmp al, 100
    jl .ddb_lt100
    mov byte [rdi+16], '?'
    mov byte [rdi+17], 10
    mov edx, 18
    jmp .ddb_hdr_emit
.ddb_lt100:
    mov dl, al
    mov al, 0
.ddb_d10:
    cmp dl, 10
    jl .ddb_d10_done
    sub dl, 10
    inc al
    jmp .ddb_d10
.ddb_d10_done:
    add al, '0'
    mov [rdi+16], al
    add dl, '0'
    mov [rdi+17], dl
    mov byte [rdi+18], 10
    mov edx, 19
.ddb_hdr_emit:
    mov rax, SYS_WRITE
    mov edi, 2
    lea rsi, [dkp_buf]
    syscall
    ; Per-entry: write keysym(hex 4) + space + keycode(dec 3) + space +
    ; mod(hex 2) + space + a(dec 2) + space + i(dec 2) + LF
    xor ebx, ebx
.ddb_loop:
    cmp ebx, [bind_count]
    jge .ddb_done
    mov rax, rbx
    imul rax, BIND_STRIDE
    lea r12, [bind_table + rax]
    ; Build line in dkp_buf
    lea rdi, [dkp_buf]
    mov byte [rdi+0], 'b'
    movzx eax, bl
    cmp al, 10
    jl .ddb_b1
    mov dl, al
    mov al, 0
.ddb_bd:
    cmp dl, 10
    jl .ddb_bd_done
    sub dl, 10
    inc al
    jmp .ddb_bd
.ddb_bd_done:
    add al, '0'
    mov [rdi+1], al
    add dl, '0'
    mov [rdi+2], dl
    mov rdi, dkp_buf + 3
    jmp .ddb_b_after
.ddb_b1:
    add al, '0'
    mov [rdi+1], al
    mov rdi, dkp_buf + 2
.ddb_b_after:
    mov byte [rdi], ' '
    mov byte [rdi+1], 'k'
    mov byte [rdi+2], 'c'
    mov byte [rdi+3], '='
    add rdi, 4
    movzx eax, byte [r12 + 4]            ; resolved keycode (low byte)
    cmp al, 100
    jl .ddb_kc_lt100
    mov dl, 0
.ddb_kc_h:
    cmp al, 100
    jl .ddb_kc_h_done
    sub al, 100
    inc dl
    jmp .ddb_kc_h
.ddb_kc_h_done:
    add dl, '0'
    mov [rdi], dl
    inc rdi
.ddb_kc_lt100:
    cmp al, 10
    jl .ddb_kc_one
    mov dl, 0
.ddb_kc_t:
    cmp al, 10
    jl .ddb_kc_t_done
    sub al, 10
    inc dl
    jmp .ddb_kc_t
.ddb_kc_t_done:
    add dl, '0'
    mov [rdi], dl
    inc rdi
.ddb_kc_one:
    add al, '0'
    mov [rdi], al
    inc rdi
    mov byte [rdi], ' '
    mov byte [rdi+1], 'm'
    mov byte [rdi+2], '='
    mov byte [rdi+3], '0'
    mov byte [rdi+4], 'x'
    add rdi, 5
    movzx eax, word [r12 + 8]            ; modifiers
    mov edx, eax
    shr edx, 4
    and edx, 0xF
    cmp dl, 10
    jl .ddb_m_hi_d
    add dl, 'a' - 10 - '0'
.ddb_m_hi_d:
    add dl, '0'
    mov [rdi], dl
    and eax, 0xF
    cmp al, 10
    jl .ddb_m_lo_d
    add al, 'a' - 10 - '0'
.ddb_m_lo_d:
    add al, '0'
    mov [rdi+1], al
    add rdi, 2
    mov byte [rdi], ' '
    mov byte [rdi+1], 'a'
    mov byte [rdi+2], '='
    add rdi, 3
    movzx eax, byte [r12 + 10]           ; action_id
    cmp al, 10
    jl .ddb_a1
    mov dl, 0
.ddb_a_t:
    cmp al, 10
    jl .ddb_a_t_done
    sub al, 10
    inc dl
    jmp .ddb_a_t
.ddb_a_t_done:
    add dl, '0'
    mov [rdi], dl
    inc rdi
.ddb_a1:
    add al, '0'
    mov [rdi], al
    inc rdi
    mov byte [rdi], ' '
    mov byte [rdi+1], 'i'
    mov byte [rdi+2], '='
    add rdi, 3
    movzx eax, byte [r12 + 11]           ; arg_int
    cmp al, 100
    jl .ddb_i_lt100
    mov dl, 0
.ddb_i_h:
    cmp al, 100
    jl .ddb_i_h_done
    sub al, 100
    inc dl
    jmp .ddb_i_h
.ddb_i_h_done:
    add dl, '0'
    mov [rdi], dl
    inc rdi
.ddb_i_lt100:
    cmp al, 10
    jl .ddb_i_one
    mov dl, 0
.ddb_i_t:
    cmp al, 10
    jl .ddb_i_t_done
    sub al, 10
    inc dl
    jmp .ddb_i_t
.ddb_i_t_done:
    add dl, '0'
    mov [rdi], dl
    inc rdi
.ddb_i_one:
    add al, '0'
    mov [rdi], al
    inc rdi
    mov byte [rdi], 10
    inc rdi
    lea rsi, [dkp_buf]
    mov rdx, rdi
    sub rdx, rsi
    mov rax, SYS_WRITE
    mov edi, 2
    syscall
    inc ebx
    jmp .ddb_loop
.ddb_done:
    pop r12
    pop rbx
    ret

; ══════════════════════════════════════════════════════════════════════
; Window management actions
; ══════════════════════════════════════════════════════════════════════

; rdi = window XID. Configure to (0, bar_height, screen_w, screen_h-bar_height)
; Old single-output entry point — defaults to current_ws so existing
; callers (and any caller without explicit workspace context) keep
; working. New per-workspace logic delegates to
; configure_client_for_workspace.
configure_client_fullscreen:
    push rdi
    movzx esi, byte [current_ws]
    pop rdi
    jmp configure_client_for_workspace

; edi = window XID, esi = workspace number (1..WS_COUNT). Configures
; the window to fill the workspace's pinned output's rectangle, minus
; the bar reservation on output 0 and minus the inner gap on every
; side. With Xinerama, each output has its own (x, y, w, h) in root
; coordinates — that's where the bar reservation also goes.
configure_client_for_workspace:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi                       ; window XID
    ; Resolve workspace → output index. Defaults to 0 if ws is out of
    ; range (e.g. a freshly-mapped client during init).
    movzx eax, sil
    test eax, eax
    jz .ccfw_use_primary
    cmp eax, WS_COUNT
    jg .ccfw_use_primary
    movzx ebx, byte [ws_pinned_output + rax - 1]
    cmp bl, byte [output_count]
    jl .ccfw_have_output
.ccfw_use_primary:
    xor ebx, ebx
.ccfw_have_output:
    ; r13 = output index, fetch its rectangle.
    mov r13d, ebx
    movzx r14d, word [output_x + r13*2]    ; ox
    movzx r15d, word [output_y + r13*2]    ; oy
    movzx ecx, word [output_w + r13*2]     ; ow
    movzx edx, word [output_h + r13*2]     ; oh

    ; Reserve (strip + bar) only on the bar's home output (output 0).
    ; Other outputs use their full height.
    movzx eax, word [bar_height]
    movzx edi, word [cfg_strip_height]
    add eax, edi                           ; strip + bar
    test r13d, r13d
    jnz .ccfw_no_bar
    add r15d, eax                          ; oy += reserved
    sub edx, eax                           ; oh -= reserved
.ccfw_no_bar:

    ; Apply inner gap on all four sides — but only when the workspace
    ; is in a SPLIT layout. TABBED is single fullscreen and shouldn't
    ; have any cosmetic frame.
    movzx eax, sil                         ; ws number (still in sil)
    test eax, eax
    jz .ccfw_apply_gap                     ; ws=0 fallback → keep gap
    cmp eax, WS_COUNT
    jg .ccfw_apply_gap
    dec eax
    movzx eax, byte [ws_layout + rax]      ; LAYOUT_TABBED = 0
    test eax, eax
    jz .ccfw_skip_gap
.ccfw_apply_gap:
    movzx eax, word [cfg_gap_inner]
    add r14d, eax                          ; ox += gap
    add r15d, eax                          ; oy += gap
    mov edi, eax
    shl edi, 1                             ; 2*gap
    sub ecx, edi                           ; ow -= 2*gap
    sub edx, edi                           ; oh -= 2*gap
.ccfw_skip_gap:

    ; Debug: log "tile: ccfw xid=N x=N y=N w=N h=N\n"
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r10
    push r11
    mov r10d, ecx                          ; w
    mov r11d, edx                          ; h
    lea rdi, [dkp_buf]
    mov byte [rdi+0], 't'
    mov byte [rdi+1], 'i'
    mov byte [rdi+2], 'l'
    mov byte [rdi+3], 'e'
    mov byte [rdi+4], ':'
    mov byte [rdi+5], ' '
    mov byte [rdi+6], 'c'
    mov byte [rdi+7], 'c'
    mov byte [rdi+8], 'f'
    mov byte [rdi+9], 'w'
    mov byte [rdi+10], ' '
    mov byte [rdi+11], 'x'
    mov byte [rdi+12], 'i'
    mov byte [rdi+13], 'd'
    mov byte [rdi+14], '='
    add rdi, 15
    mov eax, r12d
    call dbg_u32_dec
    mov byte [rdi], ' '
    mov byte [rdi+1], 'x'
    mov byte [rdi+2], '='
    add rdi, 3
    mov eax, r14d
    call dbg_u32_dec
    mov byte [rdi], ' '
    mov byte [rdi+1], 'y'
    mov byte [rdi+2], '='
    add rdi, 3
    mov eax, r15d
    call dbg_u32_dec
    mov byte [rdi], ' '
    mov byte [rdi+1], 'w'
    mov byte [rdi+2], '='
    add rdi, 3
    mov eax, r10d
    call dbg_u32_dec
    mov byte [rdi], ' '
    mov byte [rdi+1], 'h'
    mov byte [rdi+2], '='
    add rdi, 3
    mov eax, r11d
    call dbg_u32_dec
    mov byte [rdi], 10
    inc rdi
    lea rsi, [dkp_buf]
    mov rdx, rdi
    sub rdx, rsi
    mov rax, SYS_WRITE
    mov edi, 2
    syscall
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    ; Build ConfigureWindow request: x, y, w, h, border-width=0. In
    ; TABBED mode only one client is visible per workspace, so the focus
    ; border is redundant — explicitly setting border-width to 0 here
    ; both hides it (matching the user's expectation) and keeps the
    ; visible footprint at exactly w x h (X draws borders OUTSIDE the
    ; geometry, which would otherwise leak into the bar reservation).
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_CONFIGURE_WINDOW
    mov byte [rdi+1], 0
    mov word [rdi+2], 8                    ; 3 header + 5 values = 8 words
    mov [rdi+4], r12d                      ; window
    mov word [rdi+8], CFG_X | CFG_Y | CFG_WIDTH | CFG_HEIGHT | CFG_BORDER
    mov word [rdi+10], 0
    mov dword [rdi+12], r14d               ; x
    mov dword [rdi+16], r15d               ; y
    mov dword [rdi+20], ecx                ; w
    mov dword [rdi+24], edx                ; h
    mov dword [rdi+28], 0                  ; border-width = 0
    lea rsi, [tmp_buf]
    mov rdx, 32
    call x11_buffer
    inc dword [x11_seq]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; eax = window XID. Preserves rax across the x11_buffer call so a
; subsequent call (e.g. set_input_focus) can reuse the XID without
; reloading from memory.
send_map_window:
    call dbg_log_map                       ; logs "tile: map xid=N\n", preserves rax
    push rax
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_MAP_WINDOW
    mov byte [rdi+1], 0
    mov word [rdi+2], 2
    pop rax
    mov [rdi+4], eax
    lea rsi, [tmp_buf]
    mov rdx, 8
    push rax
    call x11_buffer
    pop rax
    inc dword [x11_seq]
    ret

; eax = sentinel + value. Writes "tile: tag=0xHHHH\n" to stderr —
; lightweight checkpoint to trace which branches the MapRequest flow
; reaches. Sentinels: 0x100 = post-track, 0x200|n = stash returned n,
; 0x300|n = find_client_index returned n, 0x400|n = SAT entered with
; ws=n.
dbg_log_mrtag:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov r10d, eax
    lea rdi, [dkp_buf]
    mov byte [rdi+0], 't'
    mov byte [rdi+1], 'i'
    mov byte [rdi+2], 'l'
    mov byte [rdi+3], 'e'
    mov byte [rdi+4], ':'
    mov byte [rdi+5], ' '
    mov byte [rdi+6], 't'
    mov byte [rdi+7], 'a'
    mov byte [rdi+8], 'g'
    mov byte [rdi+9], '='
    mov byte [rdi+10], '0'
    mov byte [rdi+11], 'x'
    add rdi, 12
    ; Emit 4 hex digits MSB-first (low 16 bits of r10d).
    mov ecx, 12                            ; first shift = 12 (nibble 3)
.dlt_hex:
    mov eax, r10d
    shr eax, cl
    and al, 0xF
    cmp al, 10
    jl .dlt_dig
    add al, 'a' - 10 - '0'
.dlt_dig:
    add al, '0'
    mov [rdi], al
    inc rdi
    sub ecx, 4
    jns .dlt_hex                           ; loop while >= 0
    mov byte [rdi], 10
    inc rdi
    lea rsi, [dkp_buf]
    mov rdx, rdi
    sub rdx, rsi
    mov rax, SYS_WRITE
    mov edi, 2
    syscall
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; eax = window XID. Writes "tile: map-req xid=NNNN\n" to stderr.
dbg_log_mapreq:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov r10d, eax
    lea rdi, [dkp_buf]
    mov byte [rdi+0], 't'
    mov byte [rdi+1], 'i'
    mov byte [rdi+2], 'l'
    mov byte [rdi+3], 'e'
    mov byte [rdi+4], ':'
    mov byte [rdi+5], ' '
    mov byte [rdi+6], 'm'
    mov byte [rdi+7], 'r'
    mov byte [rdi+8], ' '
    mov byte [rdi+9], 'x'
    mov byte [rdi+10], 'i'
    mov byte [rdi+11], 'd'
    mov byte [rdi+12], '='
    add rdi, 13
    mov eax, r10d
    call dbg_u32_dec
    mov byte [rdi], 10
    inc rdi
    lea rsi, [dkp_buf]
    mov rdx, rdi
    sub rdx, rsi
    mov rax, SYS_WRITE
    mov edi, 2
    syscall
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; eax = window XID. Writes "tile: map xid=NNNN\n" to stderr. Preserves
; ALL caller registers (callers like send_map_window assume that
; calling helpers near send doesn't clobber working state).
dbg_log_map:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov r10d, eax                          ; save XID
    lea rdi, [dkp_buf]
    mov byte [rdi+0], 't'
    mov byte [rdi+1], 'i'
    mov byte [rdi+2], 'l'
    mov byte [rdi+3], 'e'
    mov byte [rdi+4], ':'
    mov byte [rdi+5], ' '
    mov byte [rdi+6], 'm'
    mov byte [rdi+7], 'a'
    mov byte [rdi+8], 'p'
    mov byte [rdi+9], ' '
    mov byte [rdi+10], 'x'
    mov byte [rdi+11], 'i'
    mov byte [rdi+12], 'd'
    mov byte [rdi+13], '='
    add rdi, 14
    mov eax, r10d
    call dbg_u32_dec
    mov byte [rdi], 10
    inc rdi
    lea rsi, [dkp_buf]
    mov rdx, rdi
    sub rdx, rsi
    mov rax, SYS_WRITE
    mov edi, 2
    syscall
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; rdi = buffer position, eax = unsigned 32-bit value (decimal, no
; leading zeros). Updates rdi past the last digit. Clobbers eax/edx/r9.
dbg_u32_dec:
    test eax, eax
    jnz .du32_nz
    mov byte [rdi], '0'
    inc rdi
    ret
.du32_nz:
    sub rsp, 16
    mov r9, rsp
.du32_div:
    test eax, eax
    jz .du32_emit
    xor edx, edx
    mov ecx, 10
    div ecx
    add dl, '0'
    mov [r9], dl
    inc r9
    jmp .du32_div
.du32_emit:
    cmp r9, rsp
    je .du32_emit_done
    dec r9
    mov al, [r9]
    mov [rdi], al
    inc rdi
    jmp .du32_emit
.du32_emit_done:
    add rsp, 16
    ret

; eax = window XID. SetInputFocus(window, RevertToParent=2, time=0).
; eax = window XID, edx = pixel value. Sends ChangeWindowAttributes
; setting the BorderPixel attribute. Cheap (~16-byte request); safe to
; call on any tracked client. Skipped when cfg_border_width == 0.
set_window_border:
    push rax
    cmp byte [cfg_border_width], 0
    je .swb_done
    push rdx
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_CHANGE_WINDOW_ATTRS
    mov byte [rdi+1], 0
    mov word [rdi+2], 4
    pop rdx
    mov [rdi+4], eax             ; window
    mov dword [rdi+8], CW_BORDER_PIXEL
    mov [rdi+12], edx            ; border pixel
    lea rsi, [tmp_buf]
    mov rdx, 16
    call x11_buffer
    inc dword [x11_seq]
.swb_done:
    pop rax
    ret

; eax = window XID. Updates focus borders so the previously-focused
; window dims and the new one brightens, then sends X SetInputFocus.
; Idempotent if eax == focused_xid. eax == 0 just dims the previous
; without focusing anything new (used when a workspace empties out).
set_input_focus:
    push rbx
    mov ebx, eax                          ; new XID (may be 0)
    cmp ebx, [focused_xid]
    je .sif_x                             ; same window — only re-issue X focus
    ; Dim previous if any, brighten new if any.
    mov eax, [focused_xid]
    test eax, eax
    jz .sif_brighten
    mov edx, [cfg_border_unfocused]
    call set_window_border
.sif_brighten:
    test ebx, ebx
    jz .sif_clear
    mov eax, ebx
    mov edx, [cfg_border_focused]
    call set_window_border
    mov [focused_xid], ebx
    jmp .sif_x
.sif_clear:
    mov dword [focused_xid], 0
    pop rbx
    ret
.sif_x:
    test ebx, ebx
    jz .sif_clear_active                  ; nothing to focus → clear EWMH too
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_SET_INPUT_FOCUS
    mov byte [rdi+1], 2          ; revert-to = Parent
    mov word [rdi+2], 3
    mov [rdi+4], ebx
    mov dword [rdi+8], 0         ; time = CurrentTime
    lea rsi, [tmp_buf]
    mov rdx, 12
    call x11_buffer
    inc dword [x11_seq]
    ; Publish _NET_ACTIVE_WINDOW on root so EWMH-aware apps (kitty,
    ; GTK, etc.) recognise the focus change. Without this, those apps
    ; can stay in "inactive" visual state (dimmed text/borders) even
    ; after X grants them keyboard focus.
    mov eax, [net_active_window_atom]
    test eax, eax
    jz .sif_done                          ; atom not interned, skip
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_CHANGE_PROPERTY
    mov byte [rdi+1], 0                   ; mode = Replace
    mov word [rdi+2], 7                   ; length: 6 base + 1 value word
    mov eax, [x11_root_window]
    mov [rdi+4], eax
    mov eax, [net_active_window_atom]
    mov [rdi+8], eax                      ; property
    mov dword [rdi+12], 33                ; type = WINDOW (atom 33)
    mov byte [rdi+16], 32                 ; format = 32 bits
    mov byte [rdi+17], 0
    mov byte [rdi+18], 0
    mov byte [rdi+19], 0
    mov dword [rdi+20], 1                 ; value-length (in 4-byte units of format)
    mov [rdi+24], ebx                     ; the new active window XID
    lea rsi, [tmp_buf]
    mov rdx, 28
    call x11_buffer
    inc dword [x11_seq]
.sif_done:
    pop rbx
    ret
.sif_clear_active:
    ; Focus-to-nothing: still publish _NET_ACTIVE_WINDOW = 0 so apps
    ; clear their "I'm active" state. Useful when a workspace empties.
    mov eax, [net_active_window_atom]
    test eax, eax
    jz .sif_done
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_CHANGE_PROPERTY
    mov byte [rdi+1], 0
    mov word [rdi+2], 7
    mov eax, [x11_root_window]
    mov [rdi+4], eax
    mov eax, [net_active_window_atom]
    mov [rdi+8], eax
    mov dword [rdi+12], 33
    mov byte [rdi+16], 32
    mov byte [rdi+17], 0
    mov byte [rdi+18], 0
    mov byte [rdi+19], 0
    mov dword [rdi+20], 1
    mov dword [rdi+24], 0
    lea rsi, [tmp_buf]
    mov rdx, 28
    call x11_buffer
    inc dword [x11_seq]
    pop rbx
    ret

; eax = window XID. Append to client_xids on the current workspace.
; If a spawn-split action set pending_spawn_xid, the new client is
; rotated into position immediately before/after the anchor (depending
; on pending_spawn_after) so it lands where the user asked rather than
; at the end. The pending state is cleared either way.
track_client:
    push rbx
    push r12
    push r13
    mov r12d, eax                         ; new XID
    mov ebx, [client_count]
    cmp ebx, MAX_CLIENTS
    jge .tc_full
    mov [client_xids + rbx*4], r12d
    ; Target workspace: pending_assign_ws if set (one-shot, set by the
    ; MapRequest handler when an `assign` rule matched), else current_ws.
    movzx ecx, byte [pending_assign_ws]
    test ecx, ecx
    jnz .tc_have_ws
    movzx ecx, byte [current_ws]
.tc_have_ws:
    mov [client_ws + rbx], cl
    mov byte [client_unmap_expected + rbx], 0
    mov byte [client_color + rbx], 0      ; tab_default colour
    inc dword [client_count]
    ; Debug: log "tile: trk xid=N idx=N cnt=N\n"
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    lea rdi, [dkp_buf]
    mov byte [rdi+0], 't'
    mov byte [rdi+1], 'i'
    mov byte [rdi+2], 'l'
    mov byte [rdi+3], 'e'
    mov byte [rdi+4], ':'
    mov byte [rdi+5], ' '
    mov byte [rdi+6], 't'
    mov byte [rdi+7], 'r'
    mov byte [rdi+8], 'k'
    mov byte [rdi+9], ' '
    mov byte [rdi+10], 'x'
    mov byte [rdi+11], 'i'
    mov byte [rdi+12], 'd'
    mov byte [rdi+13], '='
    add rdi, 14
    mov eax, r12d
    call dbg_u32_dec
    mov byte [rdi], ' '
    mov byte [rdi+1], 'i'
    mov byte [rdi+2], 'd'
    mov byte [rdi+3], 'x'
    mov byte [rdi+4], '='
    add rdi, 5
    mov eax, ebx
    call dbg_u32_dec
    mov byte [rdi], ' '
    mov byte [rdi+1], 'c'
    mov byte [rdi+2], 'n'
    mov byte [rdi+3], 't'
    mov byte [rdi+4], '='
    add rdi, 5
    mov eax, [client_count]
    call dbg_u32_dec
    mov byte [rdi], 10
    inc rdi
    lea rsi, [dkp_buf]
    mov rdx, rdi
    sub rdx, rsi
    mov rax, SYS_WRITE
    mov edi, 2
    syscall
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ; Bump populated count for the workspace this client lives on.
    movzx eax, cl
    dec eax
    inc byte [workspace_populated + rax]

    ; Paint the new client's border with the unfocused colour. If it
    ; ends up focused (typical case for a fresh map), set_input_focus
    ; will overwrite this with the focused colour.
    mov eax, r12d
    mov edx, [cfg_border_unfocused]
    call set_window_border

    ; Pending spawn-split reorder?
    mov r13d, [pending_spawn_xid]
    test r13d, r13d
    jz .tc_full
    mov dword [pending_spawn_xid], 0      ; consume — fire-once

    ; Find anchor index. If anchor is gone or appears at/after the new
    ; client, just leave the new client at the end (already correct).
    mov eax, r13d
    call find_client_index
    cmp eax, -1
    je .tc_full
    cmp eax, ebx
    jge .tc_full                          ; anchor is already at/after new

    ; Compute target index: anchor + 1 if "after", else anchor.
    mov ecx, eax                          ; anchor index
    movzx edx, byte [pending_spawn_after]
    test edx, edx
    jz .tc_have_target
    inc ecx
.tc_have_target:
    cmp ecx, ebx
    jge .tc_full                          ; target already == new index

    ; Rotate slot ebx to slot ecx by walking down. ecx..ebx-1 each get
    ; their successor's data; ebx itself becomes the saved new client.
    ; Save new client's parallel data into r8/r9/r10/r11 first.
    mov r8d, [client_xids + rbx*4]
    movzx r9d, byte [client_ws + rbx]
    movzx r10d, byte [client_unmap_expected + rbx]
    movzx r11d, byte [client_color + rbx]
    mov edi, ebx                          ; cursor = ebx, walking down to ecx+1
.tc_rotate:
    cmp edi, ecx
    jle .tc_rotate_done
    mov esi, edi
    dec esi                               ; src = cursor - 1
    mov eax, [client_xids + rsi*4]
    mov [client_xids + rdi*4], eax
    mov al, [client_ws + rsi]
    mov [client_ws + rdi], al
    mov al, [client_unmap_expected + rsi]
    mov [client_unmap_expected + rdi], al
    mov al, [client_color + rsi]
    mov [client_color + rdi], al
    dec edi
    jmp .tc_rotate
.tc_rotate_done:
    ; Drop the saved new-client data into slot ecx.
    mov [client_xids + rcx*4], r8d
    mov [client_ws + rcx], r9b
    mov [client_unmap_expected + rcx], r10b
    mov [client_color + rcx], r11b
.tc_full:
    pop r13
    pop r12
    pop rbx
    ret

; eax = window XID. Remove from client_xids (no-op if not present),
; including its parallel client_ws and client_unmap_expected entries,
; and decrement the workspace-populated counter.
untrack_client:
    push rbx
    push r12
    mov r12d, eax
    xor ebx, ebx
.uc_find:
    cmp ebx, [client_count]
    jge .uc_done
    cmp [client_xids + rbx*4], r12d
    je .uc_remove
    inc ebx
    jmp .uc_find
.uc_remove:
    ; Decrement populated for this client's workspace.
    movzx ecx, byte [client_ws + rbx]
    test ecx, ecx
    jz .uc_no_dec                   ; defensive: unset workspace
    dec ecx
    dec byte [workspace_populated + rcx]
.uc_no_dec:
    ; Shift parallel arrays down.
.uc_shift:
    mov eax, [client_count]
    dec eax
    cmp ebx, eax
    jge .uc_dec
    mov ecx, ebx
    inc ecx
    mov edx, [client_xids + rcx*4]
    mov [client_xids + rbx*4], edx
    mov dl, [client_ws + rcx]
    mov [client_ws + rbx], dl
    mov dl, [client_unmap_expected + rcx]
    mov [client_unmap_expected + rbx], dl
    mov dl, [client_color + rcx]
    mov [client_color + rbx], dl
    inc ebx
    jmp .uc_shift
.uc_dec:
    dec dword [client_count]
.uc_done:
    pop r12
    pop rbx
    ret

; Returns the index of the client with XID = eax, or -1 in eax if not
; present.
find_client_index:
    push rbx
    mov ebx, eax
    ; Debug: log "tile: find xid=N cnt=N first=N\n"
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    lea rdi, [dkp_buf]
    mov byte [rdi+0], 't'
    mov byte [rdi+1], 'i'
    mov byte [rdi+2], 'l'
    mov byte [rdi+3], 'e'
    mov byte [rdi+4], ':'
    mov byte [rdi+5], ' '
    mov byte [rdi+6], 'f'
    mov byte [rdi+7], 'i'
    mov byte [rdi+8], 'n'
    mov byte [rdi+9], 'd'
    mov byte [rdi+10], ' '
    mov byte [rdi+11], 'x'
    mov byte [rdi+12], '='
    add rdi, 13
    mov eax, ebx
    call dbg_u32_dec
    mov byte [rdi], ' '
    mov byte [rdi+1], 'c'
    mov byte [rdi+2], '='
    add rdi, 3
    mov eax, [client_count]
    call dbg_u32_dec
    mov byte [rdi], ' '
    mov byte [rdi+1], 'f'
    mov byte [rdi+2], '0'
    mov byte [rdi+3], '='
    add rdi, 4
    mov eax, [client_xids]
    call dbg_u32_dec
    mov byte [rdi], 10
    inc rdi
    lea rsi, [dkp_buf]
    mov rdx, rdi
    sub rdx, rsi
    mov rax, SYS_WRITE
    mov edi, 2
    syscall
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    xor ecx, ecx
.fci_loop:
    cmp ecx, [client_count]
    jge .fci_none
    cmp [client_xids + rcx*4], ebx
    je .fci_found
    inc ecx
    jmp .fci_loop
.fci_none:
    mov eax, -1
    pop rbx
    ret
.fci_found:
    mov eax, ecx
    pop rbx
    ret

; eax = window XID. UnmapWindow request. Preserves rax across the
; x11_buffer call (see send_map_window comment).
send_unmap_window:
    push rax
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_UNMAP_WINDOW
    mov byte [rdi+1], 0
    mov word [rdi+2], 2
    pop rax
    mov [rdi+4], eax
    lea rsi, [tmp_buf]
    mov rdx, 8
    push rax
    call x11_buffer
    pop rax
    inc dword [x11_seq]
    ret

; Close the focused (active-tab) window on the current workspace.
; Prefer WM_DELETE_WINDOW; fall back to KillClient if the atoms aren't
; available. Replaces phase 1a.2's action_kill_latest, which killed the
; chronologically last-mapped client — wrong once tabs make the active
; tab independent of map order.
action_kill_focused:
    movzx ecx, byte [current_ws]
    test ecx, ecx
    jz .akf_none
    dec ecx
    mov eax, [ws_active_xid + rcx*4]
    test eax, eax
    jz .akf_none

    ; Pre-map the would-be-next-active so the moment the focused window
    ; dies there's already a mapped window covering its area —
    ; eliminates the wallpaper flash that otherwise appears between the
    ; dying app's UnmapNotify (X already removed it) and tile sending
    ; MapWindow for the new active in client_closed. Only meaningful
    ; for TABBED layout (in SPLIT every client is already mapped).
    push rax                                ; save dying XID
    movzx edi, byte [current_ws]
    dec edi
    movzx edi, byte [ws_layout + rdi]
    test edi, edi                            ; LAYOUT_TABBED = 0
    jnz .akf_no_premap                       ; SPLIT — already mapped
    mov eax, [rsp]                           ; dying XID
    mov edx, eax                             ; exclude this one
    movzx eax, byte [current_ws]
    call find_top_excluding
    test eax, eax
    jz .akf_no_premap                        ; no other client → nothing to pre-map
    push rax                                 ; save next-active XID
    mov edi, eax
    movzx esi, byte [current_ws]
    call configure_client_for_workspace
    pop rax
    push rax
    call send_map_window
    pop rax
    call set_input_focus                     ; also publishes _NET_ACTIVE_WINDOW
    call x11_flush                           ; push to X before WM_DELETE
.akf_no_premap:
    pop rax                                  ; restore dying XID

    mov ecx, [wm_protocols_atom]
    test ecx, ecx
    jz .akf_force
    mov ecx, [wm_delete_atom]
    test ecx, ecx
    jz .akf_force
    mov edi, eax
    call send_delete_message
    ret
.akf_force:
    push rax
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_KILL_CLIENT
    mov byte [rdi+1], 0
    mov word [rdi+2], 2
    pop rax
    mov [rdi+4], eax
    lea rsi, [tmp_buf]
    mov rdx, 8
    call x11_buffer
    inc dword [x11_seq]
.akf_none:
    ret

; ══════════════════════════════════════════════════════════════════════
; ICCCM: WM_PROTOCOLS / WM_DELETE_WINDOW
; ══════════════════════════════════════════════════════════════════════

; Intern WM_PROTOCOLS and WM_DELETE_WINDOW atoms.
; ══════════════════════════════════════════════════════════════════════
; Multi-monitor discovery (XINERAMA)
;
; The X server's XINERAMA extension exposes the geometry of each
; physical output as a flat list of rectangles in root coordinates.
; We use it (rather than RandR) because it answers our exact question
; — "what are the screen rectangles?" — in a single round-trip with a
; trivial reply, and it works on every reasonable X server config the
; user is likely to encounter (laptop alone, laptop + extended HDMI).
; If the extension isn't present, we fall back to a single output
; covering the whole root window, which collapses behaviour to the
; single-screen case.
; ══════════════════════════════════════════════════════════════════════

; rdi = extension name (data ptr), rsi = name length.
; Returns eax = major opcode (1..255) if the extension is present,
; or 0 if not. Synchronous: must be called before the event loop or
; while no async events are queued.
query_extension:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13d, esi
    call x11_flush

    lea rdi, [tmp_buf]
    mov byte [rdi], X11_QUERY_EXTENSION
    mov byte [rdi+1], 0
    ; Length = 2 + ceil(name_len / 4)
    mov ecx, r13d
    add ecx, 3
    shr ecx, 2
    add ecx, 2
    mov word [rdi+2], cx
    mov word [rdi+4], r13w           ; name length
    mov word [rdi+6], 0
    ; Copy name bytes
    lea rdi, [tmp_buf + 8]
    mov rsi, r12
    mov ecx, r13d
.qe_cp:
    test ecx, ecx
    jz .qe_pad
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jmp .qe_cp
.qe_pad:
    ; Pad to 4-byte boundary
    mov ecx, r13d
    and ecx, 3
    jz .qe_send
    mov edx, 4
    sub edx, ecx
.qe_pl:
    mov byte [rdi], 0
    inc rdi
    dec edx
    jnz .qe_pl
.qe_send:
    mov rdx, rdi
    lea rsi, [tmp_buf]
    sub rdx, rsi
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    syscall
    inc dword [x11_seq]

    ; Read 32-byte reply
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [x11_read_buf]
    mov rdx, 32
    syscall
    cmp rax, 32
    jl .qe_no
    cmp byte [x11_read_buf + 8], 0   ; present
    je .qe_no
    movzx eax, byte [x11_read_buf + 9]   ; major opcode
    pop r13
    pop r12
    pop rbx
    ret
.qe_no:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

; Issue Xinerama QueryScreens (sub-opcode 5). Fills output_x/y/w/h
; arrays and output_count. Requires xinerama_major to be set.
xinerama_query_screens:
    push rbx
    push r12
    push r13
    call x11_flush

    lea rdi, [tmp_buf]
    movzx eax, byte [xinerama_major]
    mov [rdi], al                    ; major opcode
    mov byte [rdi+1], XIN_QUERY_SCREENS
    mov word [rdi+2], 1              ; length = 1 word

    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    lea rsi, [tmp_buf]
    mov rdx, 4
    syscall
    inc dword [x11_seq]

    ; Read the 32-byte reply header
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [x11_read_buf]
    mov rdx, 32
    syscall
    cmp rax, 32
    jl .xqs_fail

    ; Number of screens at offset 8 (CARD32)
    mov ebx, [x11_read_buf + 8]
    cmp ebx, MAX_OUTPUTS
    jle .xqs_count_ok
    mov ebx, MAX_OUTPUTS
.xqs_count_ok:
    test ebx, ebx
    jz .xqs_fail

    ; Reply additional length in bytes = reply_len_word * 4
    mov edx, [x11_read_buf + 4]
    shl edx, 2
    test edx, edx
    jz .xqs_fail

    ; Read screen-info bytes into x11_read_buf + 32
    xor r12, r12
.xqs_read:
    cmp r12, rdx
    jge .xqs_parse
    push rdx
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [x11_read_buf + 32]
    add rsi, r12
    mov rcx, rdx
    sub rcx, r12
    mov rdx, rcx
    syscall
    pop rdx
    test rax, rax
    jle .xqs_fail
    add r12, rax
    jmp .xqs_read

.xqs_parse:
    mov [output_count], bl
    xor r13d, r13d
.xqs_loop:
    cmp r13d, ebx
    jge .xqs_done
    mov rax, r13
    shl rax, 3                       ; idx * 8 bytes per screen
    lea rsi, [x11_read_buf + 32]
    add rsi, rax
    movzx eax, word [rsi]
    mov [output_x + r13*2], ax
    movzx eax, word [rsi + 2]
    mov [output_y + r13*2], ax
    movzx eax, word [rsi + 4]
    mov [output_w + r13*2], ax
    movzx eax, word [rsi + 6]
    mov [output_h + r13*2], ax
    inc r13
    jmp .xqs_loop
.xqs_done:
    pop r13
    pop r12
    pop rbx
    ret
.xqs_fail:
    mov byte [output_count], 0
    pop r13
    pop r12
    pop rbx
    ret

; Discover physical outputs. After this returns, output_count >= 1
; and ws_pinned_output[] is initialised. Must be called after
; intern_wm_atoms (so we don't interleave InternAtom and QueryExtension
; replies on the wire).
discover_outputs:
    push rbx
    lea rdi, [xinerama_name]
    mov esi, xinerama_name_len
    call query_extension
    test eax, eax
    jz .do_fallback
    mov [xinerama_major], al
    call xinerama_query_screens
    cmp byte [output_count], 0
    jne .do_pin
.do_fallback:
    ; XINERAMA absent or returned no screens — single virtual output
    ; covering the whole root window.
    mov byte [output_count], 1
    mov word [output_x], 0
    mov word [output_y], 0
    mov ax, [x11_screen_width]
    mov [output_w], ax
    mov ax, [x11_screen_height]
    mov [output_h], ax
.do_pin:
    ; Default workspace pinning: every workspace on output 0.
    xor ebx, ebx
.do_pin_loop:
    cmp ebx, WS_COUNT
    jge .do_pin_check_ws10
    mov byte [ws_pinned_output + rbx], 0
    inc ebx
    jmp .do_pin_loop
.do_pin_check_ws10:
    ; If a secondary output exists, route WS 10 (the special "0" slot
    ; in the bar) to it. Acts as the user's external-monitor pin —
    ; works out-of-the-box for the laptop+HDMI setup; user can
    ; override via `pin workspace N to OUTPUT_INDEX` in ~/.tilerc later.
    cmp byte [output_count], 2
    jl .do_pin_set_outputs
    mov byte [ws_pinned_output + 9], 1
.do_pin_set_outputs:
    ; Initialise per-output current workspace.
    ;   output 0 (laptop): defaults to WS 1
    ;   output 1+ (external): defaults to whichever workspace is
    ;                         pinned there. With the default pinning
    ;                         that's WS 10 on output 1.
    mov byte [output_current_ws + 0], 1
    cmp byte [output_count], 2
    jl .do_pin_done
    mov byte [output_current_ws + 1], 10
.do_pin_done:
    pop rbx
    ret

; Walk ws_pin_override and overlay each set entry onto ws_pinned_output.
; Indices >= output_count are clamped to 0 so a `pin N M` line with M
; pointing at a not-yet-attached monitor still leaves the workspace
; reachable on the laptop. Also recomputes output_current_ws so each
; output's "currently visible" workspace stays consistent with the
; override.
apply_pin_overrides:
    push rbx
    push r12
    movzx r12d, byte [output_count]
    xor ebx, ebx
.apo_loop:
    cmp ebx, WS_COUNT
    jge .apo_recompute
    movzx eax, byte [ws_pin_override + rbx]
    cmp eax, 0xFF
    je .apo_next
    cmp eax, r12d
    jl .apo_set
    xor eax, eax                          ; clamp to output 0
.apo_set:
    mov [ws_pinned_output + rbx], al
.apo_next:
    inc ebx
    jmp .apo_loop
.apo_recompute:
    ; For each output, pick the lowest-numbered workspace pinned there
    ; as the initial visible workspace. Output 0 always defaults to
    ; WS 1 if nothing else is pinned (matches discover_outputs).
    xor ebx, ebx
.apo_out_loop:
    cmp ebx, r12d
    jge .apo_done
    xor edx, edx                          ; running visible-ws (0 = none yet)
    xor ecx, ecx
.apo_scan:
    cmp ecx, WS_COUNT
    jge .apo_out_pick
    movzx eax, byte [ws_pinned_output + rcx]
    cmp eax, ebx
    jne .apo_scan_next
    test edx, edx
    jnz .apo_scan_next
    mov edx, ecx
    inc edx                               ; ws number is 1-based
.apo_scan_next:
    inc ecx
    jmp .apo_scan
.apo_out_pick:
    test edx, edx
    jnz .apo_store
    test ebx, ebx
    jnz .apo_store_blank
    mov edx, 1                            ; output 0 default = WS 1
    jmp .apo_store
.apo_store_blank:
    xor edx, edx                          ; output >0 with nothing pinned: blank
.apo_store:
    mov [output_current_ws + rbx], dl
    inc ebx
    jmp .apo_out_loop
.apo_done:
    pop r12
    pop rbx
    ret

; Query the RANDR extension and select RRScreenChangeNotify events on
; root. After this returns, randr_present = 1 if randr is available;
; randr_event_base is the base byte for randr events. event_loop
; dispatches RR events to rediscover_outputs.
randr_setup:
    push rbx
    lea rdi, [randr_name]
    mov esi, randr_name_len
    call query_extension
    test eax, eax
    jz .rrs_done
    mov [randr_major], al
    movzx eax, byte [x11_read_buf + 10]   ; first_event byte (set by query_extension's reply)
    mov [randr_event_base], al
    mov byte [randr_present], 1
    ; RRSelectInput(window=root, mask=RRScreenChangeNotifyMask=1)
    lea rdi, [tmp_buf]
    movzx eax, byte [randr_major]
    mov [rdi], al
    mov byte [rdi+1], 4                   ; RRSelectInput sub-opcode
    mov word [rdi+2], 3                   ; length = 3 words
    mov eax, [x11_root_window]
    mov [rdi+4], eax
    mov word [rdi+8], 1                   ; mask = ScreenChangeNotify
    mov word [rdi+10], 0
    lea rsi, [tmp_buf]
    mov rdx, 12
    call x11_buffer
    inc dword [x11_seq]
    call x11_flush
.rrs_done:
    pop rbx
    ret

; Re-run Xinerama QueryScreens after a hot-plug, re-apply pin
; overrides, resize the bar to output 0's new geometry, and re-apply
; every visible workspace's layout. Uses read_reply_or_queue so events
; arriving on the wire while we wait for the reply aren't lost.
; Safe to call from inside event_loop dispatch.
rediscover_outputs:
    push rbx
    push r12
    push r13
    push r14
    cmp byte [xinerama_major], 0
    je .rdo_done                          ; no Xinerama, can't refresh

    ; Send Xinerama QueryScreens (sub-opcode 5).
    call x11_flush
    lea rdi, [tmp_buf]
    movzx eax, byte [xinerama_major]
    mov [rdi], al
    mov byte [rdi+1], XIN_QUERY_SCREENS
    mov word [rdi+2], 1
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    lea rsi, [tmp_buf]
    mov rdx, 4
    syscall
    inc dword [x11_seq]

    ; Reply header read via the event-safe path.
    lea rdi, [tmp_buf + 1024]
    call read_reply_or_queue
    test eax, eax
    jz .rdo_done

    mov ebx, [tmp_buf + 1024 + 8]         ; n_screens
    cmp ebx, MAX_OUTPUTS
    jle .rdo_count_ok
    mov ebx, MAX_OUTPUTS
.rdo_count_ok:
    test ebx, ebx
    jz .rdo_done
    mov edx, [tmp_buf + 1024 + 4]         ; reply additional length (4-byte words)
    shl edx, 2
    test edx, edx
    jz .rdo_done

    ; Drain the reply data (no events interleave inside a reply payload).
    xor r14, r14
.rdo_read:
    cmp r14, rdx
    jge .rdo_parse
    push rdx
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [tmp_buf + 2048]
    add rsi, r14
    mov rcx, rdx
    sub rcx, r14
    mov rdx, rcx
    syscall
    pop rdx
    test rax, rax
    jle .rdo_done
    add r14, rax
    jmp .rdo_read

.rdo_parse:
    mov [output_count], bl
    xor r13d, r13d
.rdo_loop:
    cmp r13d, ebx
    jge .rdo_after_parse
    mov rax, r13
    shl rax, 3
    lea rsi, [tmp_buf + 2048]
    add rsi, rax
    movzx eax, word [rsi]
    mov [output_x + r13*2], ax
    movzx eax, word [rsi + 2]
    mov [output_y + r13*2], ax
    movzx eax, word [rsi + 4]
    mov [output_w + r13*2], ax
    movzx eax, word [rsi + 6]
    mov [output_h + r13*2], ax
    inc r13
    jmp .rdo_loop

.rdo_after_parse:
    ; Re-apply pin overrides + recompute output_current_ws.
    call apply_pin_overrides
    ; Resize the bar to output 0's (possibly new) width.
    call resize_bar_to_output0
    ; Re-apply layout for every visible workspace.
    xor r12d, r12d
.rdo_apply_loop:
    movzx eax, byte [output_count]
    cmp r12d, eax
    jge .rdo_render
    movzx eax, byte [output_current_ws + r12]
    test eax, eax
    jz .rdo_apply_next
    call apply_workspace_layout
.rdo_apply_next:
    inc r12d
    jmp .rdo_apply_loop
.rdo_render:
    call render_bar
    call x11_flush
.rdo_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ConfigureWindow on the bar to match output 0's current geometry.
; No-op if the bar hasn't been created yet.
resize_bar_to_output0:
    push rbx
    cmp dword [bar_window_id], 0
    je .rbo_done
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_CONFIGURE_WINDOW
    mov byte [rdi+1], 0
    mov word [rdi+2], 7
    mov eax, [bar_window_id]
    mov [rdi+4], eax
    mov word [rdi+8], CFG_X | CFG_Y | CFG_WIDTH | CFG_HEIGHT
    mov word [rdi+10], 0
    movzx eax, word [output_x]
    mov [rdi+12], eax
    movzx eax, word [output_y]
    movzx ecx, word [cfg_strip_height]
    add eax, ecx                          ; tile bar lands below strip
    mov [rdi+16], eax
    movzx eax, word [output_w]
    mov [rdi+20], eax
    movzx eax, word [bar_height]
    mov [rdi+24], eax
    lea rsi, [tmp_buf]
    mov rdx, 28
    call x11_buffer
    inc dword [x11_seq]
.rbo_done:
    pop rbx
    ret

intern_wm_atoms:
    push rbx
    push r12
    ; Flush so any prior writes are out before we issue InternAtom.
    call x11_flush

    ; --- WM_PROTOCOLS ---
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_INTERN_ATOM
    mov byte [rdi+1], 0                    ; only-if-exists = false
    mov word [rdi+2], 2 + (wm_protocols_len + 3) / 4
    mov word [rdi+4], wm_protocols_len
    mov word [rdi+6], 0
    lea rsi, [wm_protocols_str]
    lea rbx, [tmp_buf + 8]
    xor ecx, ecx
.iwa_cp1:
    cmp ecx, wm_protocols_len
    jge .iwa_pad1
    movzx eax, byte [rsi + rcx]
    mov [rbx + rcx], al
    inc ecx
    jmp .iwa_cp1
.iwa_pad1:
    mov eax, wm_protocols_len
    add eax, 3
    and eax, ~3
    add eax, 8
    mov rdx, rax
    lea rsi, [tmp_buf]
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    syscall
    inc dword [x11_seq]
    ; Read 32-byte reply
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [x11_read_buf]
    mov rdx, 32
    syscall
    mov eax, [x11_read_buf + 8]
    mov [wm_protocols_atom], eax

    ; --- WM_DELETE_WINDOW ---
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_INTERN_ATOM
    mov byte [rdi+1], 0
    mov word [rdi+2], 2 + (wm_delete_len + 3) / 4
    mov word [rdi+4], wm_delete_len
    mov word [rdi+6], 0
    lea rsi, [wm_delete_str]
    lea rbx, [tmp_buf + 8]
    xor ecx, ecx
.iwa_cp2:
    cmp ecx, wm_delete_len
    jge .iwa_pad2
    movzx eax, byte [rsi + rcx]
    mov [rbx + rcx], al
    inc ecx
    jmp .iwa_cp2
.iwa_pad2:
    mov eax, wm_delete_len
    add eax, 3
    and eax, ~3
    add eax, 8
    mov rdx, rax
    lea rsi, [tmp_buf]
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    syscall
    inc dword [x11_seq]
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [x11_read_buf]
    mov rdx, 32
    syscall
    mov eax, [x11_read_buf + 8]
    mov [wm_delete_atom], eax

    ; --- _TILE_SHELL_PID ---
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_INTERN_ATOM
    mov byte [rdi+1], 0
    mov word [rdi+2], 2 + (tile_shell_pid_len + 3) / 4
    mov word [rdi+4], tile_shell_pid_len
    mov word [rdi+6], 0
    lea rsi, [tile_shell_pid_str]
    lea rbx, [tmp_buf + 8]
    xor ecx, ecx
.iwa_cp3:
    cmp ecx, tile_shell_pid_len
    jge .iwa_pad3
    movzx eax, byte [rsi + rcx]
    mov [rbx + rcx], al
    inc ecx
    jmp .iwa_cp3
.iwa_pad3:
    mov eax, tile_shell_pid_len
    add eax, 3
    and eax, ~3
    add eax, 8
    mov rdx, rax
    lea rsi, [tmp_buf]
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    syscall
    inc dword [x11_seq]
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [x11_read_buf]
    mov rdx, 32
    syscall
    mov eax, [x11_read_buf + 8]
    mov [tile_shell_pid_atom], eax

    ; --- _NET_ACTIVE_WINDOW --- (EWMH active-window hint; many apps,
    ; including kitty and GTK clients, dim themselves when this points
    ; at a different window even if X focus is on them.)
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_INTERN_ATOM
    mov byte [rdi+1], 0
    mov word [rdi+2], 2 + (net_active_window_len + 3) / 4
    mov word [rdi+4], net_active_window_len
    mov word [rdi+6], 0
    lea rsi, [net_active_window_str]
    lea rbx, [tmp_buf + 8]
    xor ecx, ecx
.iwa_cp4:
    cmp ecx, net_active_window_len
    jge .iwa_pad4
    movzx eax, byte [rsi + rcx]
    mov [rbx + rcx], al
    inc ecx
    jmp .iwa_cp4
.iwa_pad4:
    mov eax, net_active_window_len
    add eax, 3
    and eax, ~3
    add eax, 8
    mov rdx, rax
    lea rsi, [tmp_buf]
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    syscall
    inc dword [x11_seq]
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [x11_read_buf]
    mov rdx, 32
    syscall
    mov eax, [x11_read_buf + 8]
    mov [net_active_window_atom], eax

    ; --- EWMH window-type atoms ---
    ; Intern the property atom + the float-class type atoms in one
    ; sweep. intern_one_atom does the same dance as the blocks above
    ; (request, write, read, return atom in eax) but factored.
    lea rdi, [nwwt_str]
    mov esi, nwwt_len
    call intern_one_atom
    mov [nwwt_atom], eax

    lea rdi, [nwwt_dialog_str]
    mov esi, nwwt_dialog_len
    call intern_one_atom
    mov [nwwt_dialog_atom], eax

    lea rdi, [nwwt_util_str]
    mov esi, nwwt_util_len
    call intern_one_atom
    mov [nwwt_util_atom], eax

    lea rdi, [nwwt_tool_str]
    mov esi, nwwt_tool_len
    call intern_one_atom
    mov [nwwt_tool_atom], eax

    lea rdi, [nwwt_splash_str]
    mov esi, nwwt_splash_len
    call intern_one_atom
    mov [nwwt_splash_atom], eax

    lea rdi, [nwwt_menu_str]
    mov esi, nwwt_menu_len
    call intern_one_atom
    mov [nwwt_menu_atom], eax

    lea rdi, [nwwt_popup_str]
    mov esi, nwwt_popup_len
    call intern_one_atom
    mov [nwwt_popup_atom], eax

    lea rdi, [nwwt_drop_str]
    mov esi, nwwt_drop_len
    call intern_one_atom
    mov [nwwt_drop_atom], eax

    lea rdi, [nwwt_notif_str]
    mov esi, nwwt_notif_len
    call intern_one_atom
    mov [nwwt_notif_atom], eax

    lea rdi, [nwwt_tooltip_str]
    mov esi, nwwt_tooltip_len
    call intern_one_atom
    mov [nwwt_tooltip_atom], eax

    pop r12
    pop rbx
    ret

; rdi = name pointer, esi = name length. Returns interned atom in eax
; (0 on any failure / X reply hiccup). Mirrors the per-atom blocks
; inlined above; factored out to keep new EWMH atoms cheap to add.
intern_one_atom:
    push rbx
    push r12
    push r13
    mov r12, rdi                           ; name ptr
    mov r13d, esi                          ; name len
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_INTERN_ATOM
    mov byte [rdi+1], 0                    ; only-if-exists = false
    mov eax, r13d
    add eax, 3
    shr eax, 2
    add eax, 2
    mov [rdi+2], ax                        ; request length (words)
    mov [rdi+4], r13w                      ; name length
    mov word [rdi+6], 0
    ; Copy name into request payload at tmp_buf+8.
    lea rbx, [tmp_buf + 8]
    xor ecx, ecx
.ioa_cp:
    cmp ecx, r13d
    jge .ioa_pad
    movzx eax, byte [r12 + rcx]
    mov [rbx + rcx], al
    inc ecx
    jmp .ioa_cp
.ioa_pad:
    ; Total bytes written = 8 + ((len + 3) & ~3).
    mov eax, r13d
    add eax, 3
    and eax, ~3
    add eax, 8
    mov rdx, rax
    lea rsi, [tmp_buf]
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    syscall
    inc dword [x11_seq]
    ; Read 32-byte reply.
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [x11_read_buf]
    mov rdx, 32
    syscall
    cmp rax, 32
    jl .ioa_fail
    mov eax, [x11_read_buf + 8]
    pop r13
    pop r12
    pop rbx
    ret
.ioa_fail:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

; rdi, rsi = NUL-terminated strings. Returns 1 in eax if equal, 0 otherwise.
str_eq:
.se_loop:
    mov al, [rdi]
    cmp al, [rsi]
    jne .se_no
    test al, al
    je .se_yes
    inc rdi
    inc rsi
    jmp .se_loop
.se_yes:
    mov eax, 1
    ret
.se_no:
    xor eax, eax
    ret

; rdi = window XID. Sends GetProperty(WM_CLASS, STRING) and reads the
; reply (queueing any events that arrive in the meantime). Returns
; rax = pointer into wm_class_buf at the start of the CLASS string
; (the second NUL-terminated half of WM_CLASS), or 0 on any failure.
read_wm_class:
    push rbx
    push r12
    mov r12d, edi
    call x11_flush
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_GET_PROPERTY
    mov byte [rdi+1], 0
    mov word [rdi+2], 6
    mov [rdi+4], r12d
    mov dword [rdi+8], 67                 ; XA_WM_CLASS
    mov dword [rdi+12], 31                ; XA_STRING
    mov dword [rdi+16], 0                 ; long-offset
    mov dword [rdi+20], 64                ; long-length (256 bytes)
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    lea rsi, [tmp_buf]
    mov rdx, 24
    syscall
    inc dword [x11_seq]

    lea rdi, [wm_class_buf]
    call read_reply_or_queue
    test eax, eax
    jz .rwc_fail

    ; Reply value-length at +16; reply_length (CARD32 units) at +4.
    mov ecx, [wm_class_buf + 16]
    test ecx, ecx
    jz .rwc_fail

    ; Read the value bytes that follow the 32-byte header.
    mov eax, [wm_class_buf + 4]
    shl eax, 2                            ; bytes following header
    test eax, eax
    jz .rwc_fail
    cmp eax, WM_CLASS_BUF_SIZE - 32
    jbe .rwc_read_len_ok
    mov eax, WM_CLASS_BUF_SIZE - 32
.rwc_read_len_ok:
    mov rdx, rax
.rwc_read_loop:
    test rdx, rdx
    jz .rwc_after_read
    push rdx
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [wm_class_buf + 32]
    syscall
    pop rdx
    test rax, rax
    jle .rwc_fail
    sub rdx, rax
    jmp .rwc_read_loop
.rwc_after_read:

    ; WM_CLASS is "instance\0class\0..." — find the NUL after instance.
    lea rsi, [wm_class_buf + 32]
    mov ecx, [wm_class_buf + 16]          ; value-length in bytes
    test rcx, rcx
    jz .rwc_fail
    mov rax, rsi                          ; remember start
.rwc_find_nul:
    test rcx, rcx
    jz .rwc_fail
    cmp byte [rsi], 0
    je .rwc_after_nul
    inc rsi
    dec rcx
    jmp .rwc_find_nul
.rwc_after_nul:
    inc rsi                               ; skip the NUL
    dec rcx
    jz .rwc_fail                          ; no class part
    ; Make sure CLASS is NUL-terminated within the buffer.
    mov rax, rsi
    pop r12
    pop rbx
    ret
.rwc_fail:
    xor eax, eax
    pop r12
    pop rbx
    ret

; rdi = window XID. Returns rax=1 if the window should NOT be tiled —
; i.e. it's a transient (WM_TRANSIENT_FOR) OR has an EWMH window-type
; that signifies a floating role (DIALOG, UTILITY, TOOLBAR, SPLASH,
; MENU, POPUP_MENU, DROPDOWN_MENU, NOTIFICATION, TOOLTIP). Apps split
; roughly 50/50 between the two conventions: GTK/Qt apps like Gimp
; use _NET_WM_WINDOW_TYPE_UTILITY for tool palettes; xterm-style
; apps use WM_TRANSIENT_FOR for dialogs. We honour both.
is_transient_window:
    push rbx
    push r12
    mov r12d, edi
    ; --- Pass 1: WM_TRANSIENT_FOR (predefined atoms 68/33). ---
    call x11_flush
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_GET_PROPERTY
    mov byte [rdi+1], 0                    ; delete = false
    mov word [rdi+2], 6
    mov [rdi+4], r12d
    mov dword [rdi+8], 68                  ; XA_WM_TRANSIENT_FOR
    mov dword [rdi+12], 33                 ; XA_WINDOW
    mov dword [rdi+16], 0                  ; long-offset
    mov dword [rdi+20], 1                  ; long-length (1 CARD32)
    mov rdx, 24
    lea rsi, [tmp_buf]
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    syscall
    inc dword [x11_seq]

    lea rdi, [tmp_buf + 64]
    call read_reply_or_queue
    test eax, eax
    jz .itw_try_ewmh
    mov eax, [tmp_buf + 64 + 16]           ; value-length (bytes)
    test eax, eax
    jz .itw_try_ewmh
    cmp eax, 4
    jb .itw_drain_to_ewmh
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [tmp_buf + 96]
    mov rdx, 4
    syscall
    cmp rax, 4
    jl .itw_try_ewmh
    mov eax, [tmp_buf + 96]
    test eax, eax
    jnz .itw_yes
    jmp .itw_try_ewmh
.itw_drain_to_ewmh:
    push rax
    mov ecx, eax
.itw_d2e_loop:
    test ecx, ecx
    jz .itw_d2e_done
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [tmp_buf + 96]
    mov rdx, 1
    syscall
    test rax, rax
    jle .itw_d2e_done
    sub ecx, eax
    jmp .itw_d2e_loop
.itw_d2e_done:
    pop rax

.itw_try_ewmh:
    ; --- Pass 2: _NET_WM_WINDOW_TYPE (atom = nwwt_atom, type = ATOM=4). ---
    ; Skipped if startup atom-intern failed for some reason.
    mov eax, [nwwt_atom]
    test eax, eax
    jz .itw_no
    call x11_flush
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_GET_PROPERTY
    mov byte [rdi+1], 0
    mov word [rdi+2], 6
    mov [rdi+4], r12d
    mov [rdi+8], eax                       ; property = _NET_WM_WINDOW_TYPE
    mov dword [rdi+12], 4                  ; type = XA_ATOM
    mov dword [rdi+16], 0                  ; long-offset
    mov dword [rdi+20], 16                 ; up to 16 atoms (64 bytes)
    mov rdx, 24
    lea rsi, [tmp_buf]
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    syscall
    inc dword [x11_seq]

    lea rdi, [nwwt_reply_buf]
    call read_reply_or_queue
    test eax, eax
    jz .itw_no
    mov ecx, [nwwt_reply_buf + 16]         ; value-length (bytes)
    test ecx, ecx
    jz .itw_no
    cmp ecx, 64
    jbe .itw_have_len
    mov ecx, 64
.itw_have_len:
    ; Read value bytes that follow the 32-byte header.
    push rcx
    mov rdx, rcx
.itw_read_loop:
    test rdx, rdx
    jz .itw_match_loop_pre
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [nwwt_reply_buf + 32]
    syscall
    test rax, rax
    jle .itw_no_pop1
    sub rdx, rax
    jmp .itw_read_loop
.itw_match_loop_pre:
    pop rcx
    ; Walk the 4-byte atom values; if any matches one of our float
    ; types, return 1.
    xor ebx, ebx                           ; offset
.itw_match_loop:
    cmp ebx, ecx
    jge .itw_no
    mov eax, [nwwt_reply_buf + 32 + rbx]
    add ebx, 4
    test eax, eax
    jz .itw_match_loop
    cmp eax, [nwwt_dialog_atom]
    je .itw_yes
    cmp eax, [nwwt_util_atom]
    je .itw_yes
    cmp eax, [nwwt_tool_atom]
    je .itw_yes
    cmp eax, [nwwt_splash_atom]
    je .itw_yes
    cmp eax, [nwwt_menu_atom]
    je .itw_yes
    cmp eax, [nwwt_popup_atom]
    je .itw_yes
    cmp eax, [nwwt_drop_atom]
    je .itw_yes
    cmp eax, [nwwt_notif_atom]
    je .itw_yes
    cmp eax, [nwwt_tooltip_atom]
    je .itw_yes
    jmp .itw_match_loop

.itw_no_pop1:
    pop rcx
.itw_no:
    xor eax, eax
    pop r12
    pop rbx
    ret
.itw_yes:
    mov eax, 1
    pop r12
    pop rbx
    ret

; rdi = window XID. If WM_CLASS class half matches an `assign` table
; entry, returns target ws (1..10) in eax. Returns 0 on no match,
; lookup failure, or any X11 hiccup. Skips the round-trip entirely
; when the assign table is empty.
apply_assign:
    cmp dword [assign_count], 0
    jne .aa_have_table
    xor eax, eax
    ret
.aa_have_table:
    push rbx
    push r12
    push r13
    push r14
    call read_wm_class
    test rax, rax
    jz .aa_no_match
    mov r13, rax                          ; class string ptr
    xor ebx, ebx
.aa_loop:
    cmp ebx, [assign_count]
    jge .aa_no_match
    movzx eax, word [assign_class + rbx*2]
    lea rsi, [arg_pool + rax]
    mov rdi, r13
    call str_eq
    test eax, eax
    jnz .aa_match
    inc ebx
    jmp .aa_loop
.aa_match:
    movzx eax, byte [assign_ws + rbx]
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.aa_no_match:
    xor eax, eax
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rdi = window XID. If the class matches a `stash-on-map` entry,
; immediately stashes the window (pushes to stash_xids LIFO, untracks,
; sends UnmapWindow) and returns 1 in eax. Otherwise returns 0. Re-uses
; the WM_CLASS read from a recent apply_assign when one happened, but
; the X server caches well enough that re-reading is cheap.
apply_stash_on_map:
    cmp dword [stash_class_count], 0
    jne .asom_have_table
    xor eax, eax
    ret
.asom_have_table:
    push rbx
    push r12
    push r13
    mov r12d, edi                         ; XID
    call read_wm_class
    test rax, rax
    jz .asom_no_match
    mov r13, rax                          ; class ptr
    xor ebx, ebx
.asom_loop:
    cmp ebx, [stash_class_count]
    jge .asom_no_match
    movzx eax, word [stash_class + rbx*2]
    lea rsi, [arg_pool + rax]
    mov rdi, r13
    call str_eq
    test eax, eax
    jnz .asom_match
    inc ebx
    jmp .asom_loop
.asom_match:
    ; Stash this XID. Bail if stash full.
    mov eax, [stash_count]
    cmp eax, MAX_STASH
    jge .asom_no_match
    mov [stash_xids + rax*4], r12d
    inc dword [stash_count]
    ; Find tracked index, mark expected unmap, send unmap, untrack.
    mov eax, r12d
    call find_client_index
    cmp eax, -1
    je .asom_done                         ; not tracked yet — shouldn't happen
    mov byte [client_unmap_expected + rax], 1
    mov eax, r12d
    call send_unmap_window
    mov eax, r12d
    call untrack_client
.asom_done:
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    ret
.asom_no_match:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

; Read 32-byte chunks off x11_fd until a reply (byte 0 == 1) lands.
; Stash any events that arrive in the meantime into pending_events so
; event_loop processes them on its next tick. Errors (byte 0 == 0) are
; dropped silently — a GetProperty against a window that doesn't have
; the requested property simply replies with type=0 length=0.
;
; rdi = output buffer (must be ≥ 32 bytes). Returns rax = 1 on success
; (reply written to [rdi]), 0 on failure (EOF / error reading).
read_reply_or_queue:
    push rbx
    push r12
    push r13
    mov r12, rdi                          ; reply dest
    ; Cap total wait at ~250ms across all attempts so a misbehaving X
    ; server reply (or a popup that floods events) can never wedge
    ; tile's event loop indefinitely. r13 = remaining ms.
    mov r13, 250
.rrq_loop:
    ; poll(x11_fd, POLLIN, r13_ms) before every read so a stalled
    ; reply trips the timeout instead of blocking forever. The user
    ; reported a complete tile lockup when slack opened a file
    ; picker — Mod4+Shift+q wouldn't fire because the event loop
    ; was stuck in this read. Bounded poll keeps tile responsive.
    test r13, r13
    jle .rrq_fail
    sub rsp, 16
    mov rax, [x11_fd]
    mov [rsp], eax
    mov word [rsp + 4], 1                 ; POLLIN
    mov word [rsp + 6], 0                 ; revents
    mov rdx, r13                          ; timeout ms
    mov rdi, rsp
    mov rsi, 1
    mov rax, SYS_POLL
    syscall
    add rsp, 16
    test rax, rax
    jle .rrq_fail                         ; timeout (0) or error → fail
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    mov rsi, r12
    mov rdx, 32
    syscall
    test rax, rax
    jle .rrq_fail
    cmp rax, 32
    jl .rrq_loop                          ; partial read — retry
    mov al, [r12]
    cmp al, 1
    je .rrq_reply
    cmp al, 0
    je .rrq_loop                          ; X error — drop, keep waiting
    ; Event — append to pending queue.
    mov ecx, [pending_count]
    cmp ecx, PENDING_MAX
    jge .rrq_loop                         ; queue full — drop oldest by reading next
    mov ebx, [pending_head]
    add ebx, ecx
    cmp ebx, PENDING_MAX
    jl .rrq_no_wrap
    sub ebx, PENDING_MAX
.rrq_no_wrap:
    mov rax, rbx
    shl rax, 5
    lea rdi, [pending_events + rax]
    mov rsi, r12
    mov ecx, 4
.rrq_copy:
    mov rax, [rsi]
    mov [rdi], rax
    add rsi, 8
    add rdi, 8
    dec ecx
    jnz .rrq_copy
    inc dword [pending_count]
    jmp .rrq_loop
.rrq_reply:
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    ret
.rrq_fail:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

; Send a ClientMessage(WM_PROTOCOLS, WM_DELETE_WINDOW) to a window.
; edi = target window XID. The wire format is a 32-byte SendEvent
; request whose body is a 32-byte ClientMessage event.
;
; Apps that listed WM_DELETE_WINDOW in their WM_PROTOCOLS property
; respond by closing themselves cleanly (xterm, glass, browsers, etc).
; Apps that didn't will silently ignore it; their window stays open and
; the user can fall back to action_force_kill (TBD in a later phase).
send_delete_message:
    push rbx
    mov ebx, edi                            ; target window
    lea rdi, [tmp_buf]
    ; SendEvent: opcode=25, propagate=0, length=11
    mov byte [rdi], X11_SEND_EVENT
    mov byte [rdi+1], 0                     ; propagate
    mov word [rdi+2], 11                    ; request length in 4-byte units
    mov [rdi+4], ebx                        ; destination window
    mov dword [rdi+8], 0                    ; event-mask = 0 (delivered to client)
    ; --- 32-byte ClientMessage event body starts at offset 12 ---
    mov byte [rdi+12], 33                   ; type = ClientMessage
    mov byte [rdi+13], 32                   ; format
    mov word [rdi+14], 0                    ; sequence (ignored by send)
    mov [rdi+16], ebx                       ; window
    mov eax, [wm_protocols_atom]
    mov [rdi+20], eax                       ; message type
    mov eax, [wm_delete_atom]
    mov [rdi+24], eax                       ; data.l[0] = WM_DELETE_WINDOW
    mov dword [rdi+28], 0                   ; data.l[1] = CurrentTime
    mov dword [rdi+32], 0                   ; data.l[2..4] padding
    mov dword [rdi+36], 0
    mov dword [rdi+40], 0
    lea rsi, [tmp_buf]
    mov rdx, 44
    call x11_buffer
    inc dword [x11_seq]
    pop rbx
    ret

; ══════════════════════════════════════════════════════════════════════
; Tab semantics (phase 1b.3a)
; ══════════════════════════════════════════════════════════════════════

; eax = ws (1..WS_COUNT). Returns the XID of the highest-indexed client
; on that workspace (or 0 if the workspace is empty).
find_top_of_workspace:
    push rbx
    mov ebx, eax
    mov ecx, [client_count]
.ftow_loop:
    test ecx, ecx
    jz .ftow_none
    dec ecx
    movzx eax, byte [client_ws + rcx]
    cmp eax, ebx
    jne .ftow_loop
    mov eax, [client_xids + rcx*4]
    pop rbx
    ret
.ftow_none:
    xor eax, eax
    pop rbx
    ret

; eax = ws, edx = XID to exclude. Returns the highest-indexed client on
; ws whose XID isn't `edx` (or 0). Used by action_kill_focused to find
; what would become the new active after the focused window dies.
find_top_excluding:
    push rbx
    push r12
    mov ebx, eax
    mov r12d, edx
    mov ecx, [client_count]
.ftx_loop:
    test ecx, ecx
    jz .ftx_none
    dec ecx
    movzx eax, byte [client_ws + rcx]
    cmp eax, ebx
    jne .ftx_loop
    mov eax, [client_xids + rcx*4]
    cmp eax, r12d
    je .ftx_loop
    pop r12
    pop rbx
    ret
.ftx_none:
    xor eax, eax
    pop r12
    pop rbx
    ret

; eax = new XID. Make it the active tab on the current workspace.
; In TABBED layout only the active is visible, so we unmap the
; previous active and map the new one (only if the workspace is
; currently shown on its output). In SPLIT layouts every client on
; the workspace is mapped simultaneously, so we just update state
; and re-apply the layout to slot the (possibly-new) client into
; the side-by-side strip arrangement.
;
; Idempotent if eax already equals the workspace's active XID.
; Wrapper for the common case: make EAX the active tab on the
; current workspace.
set_active_tab:
    movzx esi, byte [current_ws]
    ; fall through to set_active_tab_on_ws

; eax = new active XID, esi = workspace number (1..WS_COUNT).
set_active_tab_on_ws:
    push rbx
    push r12
    push r13
    mov r12d, eax                ; new active XID
    mov r13d, esi                ; target workspace
    test r13d, r13d
    jz .sat_done
    mov ecx, r13d
    dec ecx
    mov ebx, [ws_active_xid + rcx*4]
    cmp ebx, r12d
    je .sat_done
    mov [ws_active_xid + rcx*4], r12d

    ; Find the workspace's pinned output and check visibility.
    mov eax, r13d
    dec eax
    movzx edi, byte [ws_pinned_output + rax]
    cmp dil, byte [output_count]
    jge .sat_render
    movzx eax, byte [output_current_ws + rdi]
    cmp eax, r13d
    jne .sat_render             ; workspace not on screen — record only

    ; Branch on workspace layout.
    movzx eax, byte [ws_layout + r13 - 1]
    test eax, eax
    jnz .sat_split
    ; ----- TABBED: map new FIRST, then unmap old. Reverse order
    ; eliminates a one-frame root-window flash (the old wallpaper
    ; flicker) — both windows are at the same fullscreen geometry, so
    ; the new one fully obscures the old before X destroys the old's
    ; pixels. All requests share a single x11_flush below, so X
    ; processes them in order without releasing the screen between
    ; them.
    ;
    ; Configure first: a sibling that was last sized in MASTER/SPLIT
    ; layout still carries that geometry. Without this re-configure
    ; it would map at half-width (or whatever its previous strip
    ; size was), exposing the wallpaper next to it.
    mov edi, r12d
    mov esi, r13d
    call configure_client_for_workspace
    mov eax, r12d
    call send_map_window
    mov eax, r12d
    call set_input_focus
    test ebx, ebx
    jz .sat_render
    mov eax, ebx
    call find_client_index
    cmp eax, -1
    je .sat_render
    mov byte [client_unmap_expected + rax], 1
    mov eax, ebx
    call send_unmap_window
    jmp .sat_render
.sat_split:
    ; ----- SPLIT: re-apply layout (handles new client + re-slice) -----
    mov eax, r13d
    call apply_workspace_layout
    mov eax, r12d
    call set_input_focus
.sat_render:
    call render_bar
    call x11_flush
.sat_done:
    pop r13
    pop r12
    pop rbx
    ret

; eax = workspace number. Unmaps every client mapped on the workspace.
; In TABBED only the active was mapped; in SPLIT all clients were.
; Always safe to call — UnmapWindow on an already-unmapped window
; is a no-op on the wire and the resulting UnmapNotify is filtered
; out via client_unmap_expected.
hide_workspace_clients:
    push rbx
    push r12
    test eax, eax
    jz .hwc_done
    mov r12d, eax                       ; ws number
    xor ebx, ebx
.hwc_loop:
    cmp ebx, [client_count]
    jge .hwc_done
    movzx eax, byte [client_ws + rbx]
    cmp eax, r12d
    jne .hwc_next
    mov byte [client_unmap_expected + rbx], 1
    mov eax, [client_xids + rbx*4]
    call send_unmap_window
.hwc_next:
    inc ebx
    jmp .hwc_loop
.hwc_done:
    pop r12
    pop rbx
    ret

; eax = XID that has been destroyed or unmapped client-initiated.
; Untracks it, then for any workspace whose active tab pointed at the
; dying XID, elects a new top and (if that workspace is visible on
; its pinned output) re-applies the workspace's layout. In TABBED
; mode the new active becomes mapped; in SPLIT modes the remaining
; clients re-slice to fill the freed strip. Steals keyboard focus
; only if the dying window's workspace matches the global current_ws.
client_closed:
    push rbx
    push r12
    push r13
    mov r12d, eax                ; the dying XID
    cmp r12d, [focused_xid]
    jne .cc_no_focus_clear
    mov dword [focused_xid], 0   ; X has already moved focus away
.cc_no_focus_clear:
    mov eax, r12d
    call untrack_client
    xor ebx, ebx                 ; ws index 0..9
.cc_loop:
    cmp ebx, WS_COUNT
    jge .cc_done
    mov r13d, 0                  ; r13 = "this ws was affected"
    cmp [ws_active_xid + rbx*4], r12d
    jne .cc_check_split
    ; Active was the dying XID — re-elect.
    mov eax, ebx
    inc eax
    call find_top_of_workspace
    mov [ws_active_xid + rbx*4], eax
    mov r13d, 1
.cc_check_split:
    ; If workspace is in SPLIT mode, ANY client departure changes the
    ; layout (remaining strips need to expand).
    movzx eax, byte [ws_layout + rbx]
    test eax, eax
    jz .cc_decide
    ; Was the dying client on this ws? workspace_populated already
    ; decremented in untrack_client; if any client of this ws still
    ; lives, we should re-slice. Heuristic: if populated > 0 OR ws
    ; was just emptied, mark affected.
    mov r13d, 1
.cc_decide:
    test r13d, r13d
    jz .cc_next
    ; Is this workspace visible on its pinned output?
    movzx edx, byte [ws_pinned_output + rbx]
    cmp dl, byte [output_count]
    jge .cc_next
    movzx ecx, byte [output_current_ws + rdx]
    mov edx, ebx
    inc edx                      ; ws number
    cmp ecx, edx
    jne .cc_next                 ; not visible
    mov eax, edx
    call apply_workspace_layout
    ; Re-focus the new active if this is the global current_ws.
    ; edx was clobbered by apply_workspace_layout (caller-saved); rebuild
    ; the ws number from rbx (callee-saved across the call). Without this
    ; rebuild, set_input_focus almost never fired in split/master modes —
    ; tabbed escaped because action_kill_focused pre-focuses before kill.
    movzx ecx, byte [current_ws]
    mov edx, ebx
    inc edx
    cmp ecx, edx
    jne .cc_next
    mov eax, [ws_active_xid + rbx*4]
    test eax, eax
    jz .cc_next
    call set_input_focus
.cc_next:
    inc ebx
    jmp .cc_loop
.cc_done:
    call render_bar
    call x11_flush
    pop r13
    pop r12
    pop rbx
    ret

; edi = direction (1 = forward, -1 = backward). Cycles the active tab
; on the current workspace by one position.
focus_cycle_tab:
    push rbx
    push r12
    push r13
    mov r13d, edi                ; +1 or -1
    movzx ecx, byte [current_ws]
    dec ecx
    mov ebx, [ws_active_xid + rcx*4]
    test ebx, ebx
    jz .fct_done                 ; empty
    mov eax, ebx
    call find_client_index
    cmp eax, -1
    je .fct_done
    mov r12d, eax                ; current index
    movzx ecx, byte [current_ws]
    mov edx, [client_count]
    test edx, edx
    jz .fct_done
.fct_walk:
    add r12d, r13d
    cmp r12d, edx
    jl .fct_neg
    xor r12d, r12d
    jmp .fct_check
.fct_neg:
    test r12d, r12d
    jns .fct_check
    mov r12d, edx
    dec r12d
.fct_check:
    cmp byte [client_ws + r12], cl
    jne .fct_walk
    mov eax, [client_xids + r12*4]
    cmp eax, ebx
    je .fct_done                 ; only one tab on this ws
    call set_active_tab
.fct_done:
    pop r13
    pop r12
    pop rbx
    ret

; edi = direction (1 = right, -1 = left). Reorder the active tab one
; slot in the workspace's tab order (= order it appears in client_xids
; restricted to the same workspace). Swaps the active tab with its
; nearest same-ws neighbor in the requested direction.
move_tab:
    push rbx
    push r12
    push r13
    mov r13d, edi
    movzx ecx, byte [current_ws]
    dec ecx
    mov ebx, [ws_active_xid + rcx*4]
    test ebx, ebx
    jz .mt_done
    mov eax, ebx
    call find_client_index
    cmp eax, -1
    je .mt_done
    mov r12d, eax                ; current index
    movzx ecx, byte [current_ws]
    mov edx, [client_count]
    mov esi, r12d                ; scan position
.mt_search:
    add esi, r13d
    cmp esi, edx
    jge .mt_done
    test esi, esi
    js .mt_done
    cmp byte [client_ws + rsi], cl
    jne .mt_search
    ; esi points at next same-ws neighbor. Swap entry r12 with esi.
    mov eax, [client_xids + r12*4]
    mov edi, [client_xids + rsi*4]
    mov [client_xids + rsi*4], eax
    mov [client_xids + r12*4], edi
    mov al, [client_ws + r12]
    mov dil, [client_ws + rsi]
    mov [client_ws + rsi], al
    mov [client_ws + r12], dil
    mov al, [client_unmap_expected + r12]
    mov dil, [client_unmap_expected + rsi]
    mov [client_unmap_expected + rsi], al
    mov [client_unmap_expected + r12], dil
    mov al, [client_color + r12]
    mov dil, [client_color + rsi]
    mov [client_color + rsi], al
    mov [client_color + r12], dil
    call render_bar
    call x11_flush
.mt_done:
    pop r13
    pop r12
    pop rbx
    ret

; ══════════════════════════════════════════════════════════════════════
; Bind dispatch + actions
; ══════════════════════════════════════════════════════════════════════

; eax = keycode, edx = modifier state (locks already stripped).
; Walks bind_table for an exact (keycode, modifier) match and runs the
; bound action. Silently no-ops on miss.
dispatch_keypress:
    push rbx
    push r12
    push r13
    mov r13d, eax                ; keycode
    mov r12d, edx                ; modifiers
    xor ebx, ebx
.dk_loop:
    cmp ebx, [bind_count]
    jge .dk_done
    mov rax, rbx
    imul rax, BIND_STRIDE
    lea rcx, [bind_table + rax]
    mov eax, [rcx + 4]           ; resolved keycode
    test eax, eax
    jz .dk_skip
    cmp eax, r13d
    jne .dk_skip
    movzx eax, word [rcx + 8]    ; modifiers
    cmp eax, r12d
    jne .dk_skip
    ; Match — dispatch by action_id. arg_off (CARD16) lives at +12;
    ; arg_int (BYTE) lives at +11 and carries small numeric args
    ; (workspace numbers, sentinels) for actions that don't need a
    ; string.
    movzx eax, byte [rcx + 10]
    movzx edx, word [rcx + 12]
    movzx esi, byte [rcx + 11]
    ; Debug: log the matched bind ("tile: dk-match a=NN i=NN\n")
    push rax
    push rsi
    push rcx
    push rdx
    lea rdi, [dkp_buf]
    mov byte [rdi+0], 't'
    mov byte [rdi+1], 'i'
    mov byte [rdi+2], 'l'
    mov byte [rdi+3], 'e'
    mov byte [rdi+4], ':'
    mov byte [rdi+5], ' '
    mov byte [rdi+6], 'd'
    mov byte [rdi+7], 'k'
    mov byte [rdi+8], '='
    ; action id (one or two digits)
    mov rax, [rsp + 24]                  ; saved rax (action_id)
    cmp al, 10
    jl .dkm_one
    mov dl, al
    mov al, 0
.dkm_div10:
    cmp dl, 10
    jl .dkm_div_done
    sub dl, 10
    inc al
    jmp .dkm_div10
.dkm_div_done:
    add al, '0'
    mov [rdi+9], al
    add dl, '0'
    mov [rdi+10], dl
    mov rdi, dkp_buf + 11
    jmp .dkm_arg
.dkm_one:
    add al, '0'
    mov [rdi+9], al
    mov rdi, dkp_buf + 10
.dkm_arg:
    mov byte [rdi], ' '
    mov byte [rdi+1], 'i'
    mov byte [rdi+2], '='
    add rdi, 3
    mov rax, [rsp + 16]                  ; saved rsi (arg_int)
    cmp al, 10
    jl .dkm_one2
    mov dl, al
    mov al, 0
.dkm_div10b:
    cmp dl, 10
    jl .dkm_div_doneb
    sub dl, 10
    inc al
    jmp .dkm_div10b
.dkm_div_doneb:
    add al, '0'
    mov [rdi], al
    add dl, '0'
    mov [rdi+1], dl
    add rdi, 2
    jmp .dkm_lf
.dkm_one2:
    add al, '0'
    mov [rdi], al
    inc rdi
.dkm_lf:
    mov byte [rdi], 10
    inc rdi
    lea rsi, [dkp_buf]
    mov rdx, rdi
    sub rdx, rsi
    mov rax, SYS_WRITE
    mov edi, 2
    syscall
    pop rdx
    pop rcx
    pop rsi
    pop rax
    cmp eax, ACT_EXEC
    je .dk_exec
    cmp eax, ACT_KILL
    je .dk_kill
    cmp eax, ACT_EXIT
    je .dk_exit
    cmp eax, ACT_WORKSPACE
    je .dk_workspace
    cmp eax, ACT_MOVE_TO
    je .dk_move_to
    cmp eax, ACT_FOCUS
    je .dk_focus
    cmp eax, ACT_MOVE_TAB
    je .dk_move_tab
    cmp eax, ACT_TAB_COLOR
    je .dk_tab_color
    cmp eax, ACT_STASH
    je .dk_stash
    cmp eax, ACT_UNSTASH
    je .dk_unstash
    cmp eax, ACT_LAYOUT
    je .dk_layout
    cmp eax, ACT_SPAWN_SPLIT
    je .dk_spawn_split
    cmp eax, ACT_EXEC_HERE
    je .dk_exec_here
    cmp eax, ACT_RELOAD
    je .dk_reload
    cmp eax, ACT_RESTART
    je .dk_restart
    jmp .dk_done
.dk_exec:
    test edx, edx
    jz .dk_done
    lea rdi, [arg_pool + rdx]
    call fork_exec_string
    jmp .dk_done
.dk_kill:
    call action_kill_focused
    jmp .dk_done
.dk_exit:
    mov rax, SYS_EXIT
    xor edi, edi
    syscall
.dk_workspace:
    cmp esi, WS_NEXT_POP
    je .dk_ws_next
    cmp esi, WS_PREV_POP
    je .dk_ws_prev
    cmp esi, WS_BACK_FORTH
    je .dk_ws_baf
    mov edi, esi
    call switch_workspace
    jmp .dk_done
.dk_ws_next:
    call workspace_next_populated
    jmp .dk_done
.dk_ws_prev:
    call workspace_prev_populated
    jmp .dk_done
.dk_ws_baf:
    movzx edi, byte [prev_ws]
    test edi, edi
    jz .dk_done
    call switch_workspace
    jmp .dk_done
.dk_move_to:
    mov edi, esi
    call move_focused_to_workspace
    jmp .dk_done
.dk_focus:
    cmp esi, FOC_NEXT_TAB
    jne .dk_focus_prev
    mov edi, 1
    call focus_cycle_tab
    jmp .dk_done
.dk_focus_prev:
    cmp esi, FOC_PREV_TAB
    jne .dk_focus_dir
    mov edi, -1
    call focus_cycle_tab
    jmp .dk_done
.dk_focus_dir:
    ; right/left/up/down: in TABBED any direction cycles sequentially;
    ; in SPLIT_H only right/left act (up/down are no-ops); in SPLIT_V
    ; only up/down act. Maps right/down → +1, left/up → -1.
    mov edi, esi
    call action_focus_dir
    jmp .dk_done
.dk_move_tab:
    cmp esi, MTAB_LEFT
    jne .dk_mt_right
    mov edi, -1
    call move_tab
    jmp .dk_done
.dk_mt_right:
    cmp esi, MTAB_RIGHT
    jne .dk_done
    mov edi, 1
    call move_tab
    jmp .dk_done
.dk_tab_color:
    call tab_color_cycle
    jmp .dk_done
.dk_stash:
    call action_stash
    jmp .dk_done
.dk_unstash:
    call action_unstash
    jmp .dk_done
.dk_layout:
    mov edi, esi                          ; sentinel/value in arg_int
    call action_layout
    jmp .dk_done
.dk_spawn_split:
    ; arg_int = direction (esi), arg_off = command offset (edx).
    test edx, edx
    jz .dk_done                           ; need a command
    mov edi, esi                          ; direction
    lea rsi, [arg_pool + rdx]             ; cmd
    call action_spawn_split
    jmp .dk_done
.dk_exec_here:
    test edx, edx
    jz .dk_done
    lea rdi, [arg_pool + rdx]
    call action_exec_here
    jmp .dk_done
.dk_reload:
    call reload_runtime
    jmp .dk_done
.dk_restart:
    call action_restart
    ; only returns on failure
    jmp .dk_done
.dk_skip:
    inc ebx
    jmp .dk_loop
.dk_done:
    pop r13
    pop r12
    pop rbx
    ret

; rdi = null-terminated command line. Forks; child execve's via /bin/sh
; -c so users don't have to write absolute paths and so we get shell
; expansion for free.
fork_exec_string:
    push rbx
    push r12
    mov r12, rdi                 ; save command string
    ; Debug: log every spawn attempt with PID return value, so the
    ; session log shows exactly what tile tried to launch and whether
    ; fork succeeded.
    push rdi
    mov rax, SYS_WRITE
    mov edi, 2
    lea rsi, [.fes_pre]
    mov edx, .fes_pre_len
    syscall
    mov rax, SYS_WRITE
    mov edi, 2
    mov rsi, r12
    xor ecx, ecx
.fes_dlen:
    cmp byte [rsi + rcx], 0
    je .fes_dlen_done
    inc ecx
    cmp ecx, 200
    jl .fes_dlen
.fes_dlen_done:
    mov edx, ecx
    syscall
    mov rax, SYS_WRITE
    mov edi, 2
    lea rsi, [.fes_lf]
    mov edx, 1
    syscall
    pop rdi
    mov rax, SYS_FORK
    syscall
    test rax, rax
    jnz .fes_parent
    ; child: build argv = [/bin/sh, -c, cmd, NULL]
    sub rsp, 32
    lea rax, [.fes_sh]
    mov [rsp], rax
    lea rax, [.fes_dashc]
    mov [rsp + 8], rax
    mov [rsp + 16], r12
    mov qword [rsp + 24], 0
    mov rax, SYS_EXECVE
    lea rdi, [.fes_sh]
    mov rsi, rsp
    mov rdx, [envp]
    syscall
    mov rax, SYS_EXIT
    mov edi, 127
    syscall
.fes_parent:
    ; Don't wait4: autostart and exec actions are fire-and-forget.
    ; Without WAIT, children become zombies until reaped — set a
    ; SIGCHLD ignore so the kernel auto-reaps. (Default action of
    ; SIGCHLD is already SIG_DFL which doesn't auto-reap; we'll fix
    ; that in a phase 1b polish pass with proper SIGCHLD handler.)
    pop r12
    pop rbx
    ret
.fes_sh:    db "/bin/sh", 0
.fes_dashc: db "-c", 0
.fes_pre:   db "tile: fork-exec: "
.fes_pre_len equ $ - .fes_pre
.fes_lf:    db 10

; ──────────────────────────────────────────────────────────────────────
; Reload — re-read ~/.tilerc without restarting tile.
;
; Triggered by SIGUSR1 (e.g. `pkill -USR1 tile`) or by a `reload`
; bind action. The signal handler itself does the absolute minimum
; (sets a flag) so we stay async-safe; the real work happens at the
; top of the event loop, between events. Re-runs key-grabs and pin
; overrides, refreshes the bar, but deliberately does NOT re-run
; autostart — that would spawn a duplicate strip, feh, etc.
; ──────────────────────────────────────────────────────────────────────
sigusr1_handler:
    ; Mark a reload as needing to happen. Touch nothing else from a
    ; signal context — async-signal-unsafe code (X11 writes, etc.) in
    ; here would race the main loop and break the world.
    mov byte [reload_pending], 1
    ret

; Install the SIGUSR1 handler. Uses the kernel sigaction layout (NOT
; glibc's). The kernel demands SA_RESTORER + a restorer that issues
; rt_sigreturn — without it the signal would corrupt rip on return
; from user space.
install_sigusr1:
    push rbx
    lea rdi, [sigact_buf]
    lea rax, [sigusr1_handler]
    mov [rdi], rax                        ; sa_handler
    mov qword [rdi + 8], SA_RESTORER | SA_RESTART
    lea rax, [sigreturn_trampoline]
    mov [rdi + 16], rax                   ; sa_restorer
    mov qword [rdi + 24], 0               ; sa_mask (no extra blocks)
    mov rax, SYS_RT_SIGACTION
    mov rdi, SIGUSR1
    lea rsi, [sigact_buf]
    xor edx, edx
    mov r10, 8                            ; sigsetsize
    syscall
    pop rbx
    ret

sigreturn_trampoline:
    mov rax, SYS_RT_SIGRETURN
    syscall

; Drop every key we grabbed on root, so a subsequent regrab won't
; collide with the previous set (which might bind different keysyms).
ungrab_all_keys:
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_UNGRAB_KEY
    mov byte [rdi+1], 0                   ; key = AnyKey
    mov word [rdi+2], 3                   ; length = 3 words = 12 bytes
    mov eax, [x11_root_window]
    mov [rdi+4], eax
    mov word [rdi+8], 0x8000              ; modifiers = AnyModifier
    mov word [rdi+10], 0
    lea rsi, [tmp_buf]
    mov rdx, 12
    call x11_buffer
    inc dword [x11_seq]
    ret

; In-place restart: re-execs /proc/self/exe so a freshly-built tile
; binary takes over without dropping any X clients (X owns the windows
; — they remain mapped while the WM disconnects and reconnects). Same
; pattern as i3's `restart` command. Only returns if execve fails (in
; which case the running tile keeps going and the user sees nothing).
action_restart:
    ; Close the X server connection cleanly so the new instance can
    ; reconnect on the same DISPLAY without the kernel-side socket
    ; lingering.
    mov rax, SYS_CLOSE
    mov edi, [x11_fd]
    syscall
    ; Build argv = ["/proc/self/exe", NULL] on the stack (.text is
    ; read-only). execve copies argv into the kernel before unmapping
    ; the caller's pages, so stack storage is fine.
    sub rsp, 16
    lea rax, [rel .ar_path]
    mov [rsp], rax
    mov qword [rsp + 8], 0
    mov rax, SYS_EXECVE
    lea rdi, [rel .ar_path]
    mov rsi, rsp
    mov rdx, [envp]
    syscall
    ; execve failed (binary missing / not executable). Restore stack and
    ; return — the running tile keeps going.
    add rsp, 16
    ret
.ar_path:    db "/proc/self/exe", 0

; Drained at the top of event_loop. Do the actual reload work here
; — outside any signal context, with the X server in a sane state.
reload_runtime:
    push rbx
    push r12
    mov byte [reload_pending], 0
    call ungrab_all_keys
    ; load_config zeroes bind_count + exec_count and re-parses the file.
    call load_config
    call resolve_and_grab_binds
    call apply_pin_overrides
    ; Re-paint border colours on every tracked client so a changed
    ; border_focused / border_unfocused / border_width takes effect on
    ; existing windows.
    xor ebx, ebx
.rr_border_loop:
    cmp ebx, [client_count]
    jge .rr_border_done
    mov eax, [client_xids + rbx*4]
    cmp eax, [focused_xid]
    jne .rr_border_dim
    mov edx, [cfg_border_focused]
    jmp .rr_border_apply
.rr_border_dim:
    mov edx, [cfg_border_unfocused]
.rr_border_apply:
    call set_window_border
    inc ebx
    jmp .rr_border_loop
.rr_border_done:
    ; Re-apply layout for every output's currently visible workspace.
    ; Picks up changed gap_inner / strip_height / border_width on
    ; already-mapped windows. Skips outputs with no current ws.
    movzx r12d, byte [output_count]
    xor ebx, ebx
.rr_layout_loop:
    cmp ebx, r12d
    jge .rr_layout_done
    movzx eax, byte [output_current_ws + rbx]
    test eax, eax
    jz .rr_layout_next
    call apply_workspace_layout
.rr_layout_next:
    inc ebx
    jmp .rr_layout_loop
.rr_layout_done:
    call render_bar
    call x11_flush
    pop r12
    pop rbx
    ret

; Iterate exec_list, fire-and-forget each command.
run_autostart:
    push rbx
    xor ebx, ebx
.ra_loop:
    cmp ebx, [exec_count]
    jge .ra_done
    movzx eax, word [exec_list + rbx*2]
    test eax, eax
    jz .ra_next
    lea rdi, [arg_pool + rax]
    call fork_exec_string
.ra_next:
    inc ebx
    jmp .ra_loop
.ra_done:
    pop rbx
    ret

; ══════════════════════════════════════════════════════════════════════
; Workspace actions
; ══════════════════════════════════════════════════════════════════════

; edi = target workspace (1..WS_COUNT). No-op if already there or out
; of range. With the per-workspace tab model only the active tab on
; each workspace is ever mapped, so a switch is just "unmap old active,
; map new active". Stash target ws in r12 (callee-saved) and old ws in
; r13 because find_client_index/send_unmap_window/send_map_window all
; clobber rdi (caller-saved).
; edi = target workspace (1..WS_COUNT). With multi-monitor, switching
; only affects the OUTPUT this workspace is pinned to — other outputs
; keep showing whatever they were showing. So switching from WS 5
; (laptop) to WS 10 (external) leaves the laptop displaying WS 5;
; switching back from WS 10 to WS 5 leaves the external displaying
; WS 10. The bar always reflects the global current_ws.
switch_workspace:
    push rbx
    push r12
    push r13
    push r14
    push r15
    ; Debug: write "tile: ws=N (was M)\n" to stderr.
    push rdi
    lea rdi, [dkp_buf]
    mov byte [rdi+0], 't'
    mov byte [rdi+1], 'i'
    mov byte [rdi+2], 'l'
    mov byte [rdi+3], 'e'
    mov byte [rdi+4], ':'
    mov byte [rdi+5], ' '
    mov byte [rdi+6], 'w'
    mov byte [rdi+7], 's'
    mov byte [rdi+8], '='
    mov rax, [rsp]
    add al, '0'
    mov [rdi+9], al
    mov byte [rdi+10], ' '
    mov byte [rdi+11], '('
    mov byte [rdi+12], 'w'
    mov byte [rdi+13], 'a'
    mov byte [rdi+14], 's'
    mov byte [rdi+15], ' '
    movzx eax, byte [current_ws]
    add al, '0'
    mov [rdi+16], al
    mov byte [rdi+17], ')'
    mov byte [rdi+18], 10
    mov rax, SYS_WRITE
    mov edi, 2
    lea rsi, [dkp_buf]
    mov edx, 19
    syscall
    pop rdi
    test edi, edi
    jz .sw_done
    cmp edi, WS_COUNT
    jg .sw_done
    movzx r13d, byte [current_ws]
    cmp edi, r13d
    jne .sw_proceed
    ; Already on the requested workspace — i3 auto back-and-forth.
    movzx eax, byte [prev_ws]
    test eax, eax
    jz .sw_done
    mov edi, eax
.sw_proceed:
    mov r12d, edi                ; r12 = target ws
    mov [prev_ws], r13b
    mov [current_ws], r12b

    ; Determine target workspace's pinned output.
    mov eax, r12d
    dec eax
    movzx r14d, byte [ws_pinned_output + rax]
    cmp r14b, byte [output_count]
    jl .sw_have_output
    xor r14d, r14d
.sw_have_output:

    ; If target ws is already shown on its output, skip the visibility
    ; swap and just refocus.
    movzx eax, byte [output_current_ws + r14]
    cmp eax, r12d
    je .sw_just_focus

    ; Show the target workspace BEFORE hiding the old one — both maps
    ; and unmaps share a single x11_flush below, so X processes them
    ; back-to-back. With the target's windows mapped first (over the
    ; old workspace's), the old's pixels stay covered until they're
    ; unmapped, eliminating a one-frame root-window flash that showed
    ; the wallpaper between the unmap and the map.
    movzx ebx, byte [output_current_ws + r14]    ; rbx = old ws (was already preserved on entry to switch_workspace)
    mov [output_current_ws + r14], r12b
    mov eax, r12d
    call apply_workspace_layout

    ; Now hide the previously-visible workspace's clients.
    test ebx, ebx
    jz .sw_no_old_hide
    mov eax, ebx
    call hide_workspace_clients
.sw_no_old_hide:
.sw_just_focus:
    ; Focus the target workspace's active tab if any.
    mov ecx, r12d
    dec ecx
    mov eax, [ws_active_xid + rcx*4]
    test eax, eax
    jz .sw_render
    call set_input_focus
.sw_render:
    call render_bar
    call x11_flush
.sw_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Switch to the next workspace that has at least one client. Wraps
; around. No-op if the only populated workspace is the current one.
workspace_next_populated:
    push rbx
    movzx ebx, byte [current_ws]
    mov ecx, WS_COUNT
.wnp_loop:
    inc ebx
    cmp ebx, WS_COUNT
    jle .wnp_check
    mov ebx, 1
.wnp_check:
    movzx eax, byte [current_ws]
    cmp ebx, eax
    je .wnp_skip                  ; back to current — nothing populated elsewhere
    mov eax, ebx
    dec eax
    movzx eax, byte [workspace_populated + rax]
    test eax, eax
    jnz .wnp_found
.wnp_skip:
    dec ecx
    jnz .wnp_loop
    pop rbx
    ret
.wnp_found:
    mov edi, ebx
    pop rbx
    jmp switch_workspace          ; tail call

; Mirror of the above, walking backwards.
workspace_prev_populated:
    push rbx
    movzx ebx, byte [current_ws]
    mov ecx, WS_COUNT
.wpp_loop:
    dec ebx
    cmp ebx, 1
    jge .wpp_check
    mov ebx, WS_COUNT
.wpp_check:
    movzx eax, byte [current_ws]
    cmp ebx, eax
    je .wpp_skip
    mov eax, ebx
    dec eax
    movzx eax, byte [workspace_populated + rax]
    test eax, eax
    jnz .wpp_found
.wpp_skip:
    dec ecx
    jnz .wpp_loop
    pop rbx
    ret
.wpp_found:
    mov edi, ebx
    pop rbx
    jmp switch_workspace

; edi = target workspace. Move the active tab from the current
; workspace to the target. With multi-monitor:
;   - If both source and target are on the same output, only that
;     output is touched (unmap moving from view, map source's new top).
;   - If target is on a different output (e.g. laptop → external),
;     the moving window appears on the target's output (if that
;     output is currently displaying target_ws — typically true for
;     the always-pinned WS 10 / external pair) AND the source's
;     output re-renders its new active tab.
; Focus stays with the source workspace per i3 convention; the user
; can switch to target_ws explicitly if they want to follow.
move_focused_to_workspace:
    push rbx
    push r12
    push r13
    push r14
    push r15
    test edi, edi
    jz .mtw_done
    cmp edi, WS_COUNT
    jg .mtw_done
    movzx eax, byte [current_ws]
    cmp edi, eax
    je .mtw_done                  ; same ws — no-op
    mov r13d, edi                 ; r13 = target ws
    movzx ecx, byte [current_ws]
    dec ecx
    mov ebx, [ws_active_xid + rcx*4]
    test ebx, ebx
    jz .mtw_done                  ; nothing to move
    mov eax, ebx
    call find_client_index
    cmp eax, -1
    je .mtw_done
    mov r12d, eax                 ; r12 = moving client's index

    ; Update populated counters and per-client workspace.
    movzx eax, byte [client_ws + r12]
    dec eax
    dec byte [workspace_populated + rax]
    mov [client_ws + r12], r13b
    mov eax, r13d
    dec eax
    inc byte [workspace_populated + rax]

    ; Snapshot prev target active before overwriting, for the
    ; target-output refresh below.
    mov eax, r13d
    dec eax
    mov r14d, [ws_active_xid + rax*4]   ; r14 = prev target active

    ; Re-elect source's new active tab. find_top_of_workspace sees
    ; client_ws already updated, so the moving client is excluded.
    movzx eax, byte [current_ws]
    call find_top_of_workspace
    mov r15d, eax                       ; r15 = new top of source
    movzx edx, byte [current_ws]
    dec edx
    mov [ws_active_xid + rdx*4], r15d

    ; Make moving the active tab on target.
    mov eax, r13d
    dec eax
    mov [ws_active_xid + rax*4], ebx

    ; Refresh source's output if it shows source.
    movzx eax, byte [current_ws]
    dec eax
    movzx edx, byte [ws_pinned_output + rax]
    cmp dl, byte [output_count]
    jge .mtw_skip_source
    movzx ecx, byte [output_current_ws + rdx]
    movzx edi, byte [current_ws]
    cmp ecx, edi
    jne .mtw_skip_source
    ; Unmap moving (was visible on source's output).
    mov byte [client_unmap_expected + r12], 1
    mov eax, ebx
    call send_unmap_window
    ; Map source's new top (if any) and focus it.
    test r15d, r15d
    jz .mtw_skip_source
    mov eax, r15d
    call send_map_window
    mov eax, r15d
    call set_input_focus
.mtw_skip_source:

    ; Refresh target's output if it shows target.
    mov eax, r13d
    dec eax
    movzx edx, byte [ws_pinned_output + rax]
    cmp dl, byte [output_count]
    jge .mtw_render
    movzx ecx, byte [output_current_ws + rdx]
    cmp ecx, r13d
    jne .mtw_render
    ; Unmap previous target active (if any and tracked).
    test r14d, r14d
    jz .mtw_target_map
    mov eax, r14d
    call find_client_index
    cmp eax, -1
    je .mtw_target_map
    mov byte [client_unmap_expected + rax], 1
    mov eax, r14d
    call send_unmap_window
.mtw_target_map:
    mov eax, ebx
    call send_map_window
    ; Focus stays on source per convention; do not steal it here.
.mtw_render:
    call render_bar
    call x11_flush
.mtw_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ══════════════════════════════════════════════════════════════════════
; Layouts (phase 1b.3b)
;
; Each workspace has a single layout: TABBED, SPLIT_H, or SPLIT_V.
; In TABBED mode only the workspace's active tab is mapped — the rest
; are unmapped and the bar's tab squares serve as the navigation UI.
; In SPLIT_H / SPLIT_V mode every client on the workspace is mapped
; simultaneously, sliced into equal-width or equal-height strips of
; the workspace's pinned output's rectangle (minus bar reservation
; on output 0 and minus inner gap all around).
;
; apply_workspace_layout(ws) is the single source of truth for "what
; should be mapped where" on a given workspace. Call it whenever the
; workspace's window set, layout, active tab, or visibility changes.
; The function is a no-op if the workspace isn't currently visible
; on its pinned output.
; ══════════════════════════════════════════════════════════════════════

; rdi = window XID, esi = x, edx = y, ecx = w, r8d = h.
; Sends a single ConfigureWindow with all four geometry values.
; Configure a managed window into a slot rect (esi=x, edx=y, ecx=w,
; r8d=h). Folds in the focus border: shifts the inner content by
; cfg_border_width on each side and shrinks W/H by 2 * border so the
; border (drawn outside the window geometry by X) fits inside the slot.
; Sends a single ConfigureWindow with X|Y|W|H|BORDER values.
configure_window_rect:
    push rbx
    mov rbx, rdi                          ; preserve XID across x11_buffer
    ; Debug: log "tile: cfg xid=N x=N y=N w=N h=N\n"
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    push r9
    push r10
    push r11
    mov r10, rdi                           ; XID
    lea rdi, [dkp_buf]
    mov byte [rdi+0], 't'
    mov byte [rdi+1], 'i'
    mov byte [rdi+2], 'l'
    mov byte [rdi+3], 'e'
    mov byte [rdi+4], ':'
    mov byte [rdi+5], ' '
    mov byte [rdi+6], 'c'
    mov byte [rdi+7], 'f'
    mov byte [rdi+8], 'g'
    mov byte [rdi+9], ' '
    mov byte [rdi+10], 'x'
    mov byte [rdi+11], 'i'
    mov byte [rdi+12], 'd'
    mov byte [rdi+13], '='
    add rdi, 14
    mov eax, r10d
    call dbg_u32_dec
    mov byte [rdi], ' '
    mov byte [rdi+1], 'x'
    mov byte [rdi+2], '='
    add rdi, 3
    mov eax, [rsp + 48]                    ; saved esi
    call dbg_u32_dec
    mov byte [rdi], ' '
    mov byte [rdi+1], 'y'
    mov byte [rdi+2], '='
    add rdi, 3
    mov eax, [rsp + 40]                    ; saved edx
    call dbg_u32_dec
    mov byte [rdi], ' '
    mov byte [rdi+1], 'w'
    mov byte [rdi+2], '='
    add rdi, 3
    mov eax, [rsp + 32]                    ; saved ecx
    call dbg_u32_dec
    mov byte [rdi], ' '
    mov byte [rdi+1], 'h'
    mov byte [rdi+2], '='
    add rdi, 3
    mov eax, [rsp + 24]                    ; saved r8
    call dbg_u32_dec
    mov byte [rdi], 10
    inc rdi
    lea rsi, [dkp_buf]
    mov rdx, rdi
    sub rdx, rsi
    mov rax, SYS_WRITE
    mov edi, 2
    syscall
    pop r11
    pop r10
    pop r9
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    ; Apply border inset: shift x,y by border, shrink w,h by 2*border.
    movzx eax, byte [cfg_border_width]
    test eax, eax
    jz .cwr_skip_inset
    add esi, eax
    add edx, eax
    sub ecx, eax
    sub ecx, eax
    sub r8d, eax
    sub r8d, eax
.cwr_skip_inset:
    push rax                              ; border width
    push rsi
    push rdx
    push rcx
    push r8
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_CONFIGURE_WINDOW
    mov byte [rdi+1], 0
    mov word [rdi+2], 8                   ; 7 base + 1 extra value (BORDER)
    mov [rdi+4], ebx
    mov word [rdi+8], CFG_X | CFG_Y | CFG_WIDTH | CFG_HEIGHT | CFG_BORDER
    mov word [rdi+10], 0
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rax                               ; border width
    mov [rdi+12], esi                     ; x
    mov [rdi+16], edx                     ; y
    mov [rdi+20], ecx                     ; w
    mov [rdi+24], r8d                     ; h
    mov [rdi+28], eax                     ; border-width
    lea rsi, [tmp_buf]
    mov rdx, 32
    push rax                              ; x11_buffer clobbers eax via its
    call x11_buffer                       ; byte-read loop; preserve so
    pop rax                               ; callers can rely on rax post-call
    inc dword [x11_seq]
    pop rbx
    ret

; ConfigureRequest pass-through. Re-emits the request as a
; ConfigureWindow with the same value-mask + values, so unknown
; (untracked / transient / dialog) clients get the geometry they
; ask for. Reads the source event from x11_read_buf:
;   +8  window
;   +12 above-sibling
;   +16 x (INT16)        +20 width  (CARD16)   +24 border-w (CARD16)
;   +18 y (INT16)        +22 height (CARD16)   +26 value-mask (CARD16)
; Mask bits: 0x01 X, 0x02 Y, 0x04 W, 0x08 H, 0x10 BW, 0x20 Sib, 0x40 Stack.
; Without this, an untracked client whose ConfigureRequest we
; fullscreen would re-request its real size in a tight loop → flicker.
passthrough_configure_request:
    push rbx
    push r12
    push r13
    movzx r13d, word [x11_read_buf + 26]   ; value-mask
    and r13d, 0x7F                         ; sanitize
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_CONFIGURE_WINDOW
    mov byte [rdi+1], 0
    ; Length (in 4-byte units): 3 + popcount(mask).
    mov eax, r13d
    xor ecx, ecx
.pcr_pop:
    test eax, eax
    jz .pcr_pop_done
    mov edx, eax
    and edx, 1
    add ecx, edx
    shr eax, 1
    jmp .pcr_pop
.pcr_pop_done:
    add ecx, 3
    mov [rdi+2], cx                        ; length
    mov eax, [x11_read_buf + 8]            ; window
    mov [rdi+4], eax
    mov [rdi+8], r13w                      ; value-mask
    mov word [rdi+10], 0                   ; pad
    lea r12, [rdi + 12]                    ; payload cursor

    ; Bit 0x01 — X (sign-extend INT16 → INT32)
    test r13d, 0x01
    jz .pcr_no_x
    movsx eax, word [x11_read_buf + 16]
    mov [r12], eax
    add r12, 4
.pcr_no_x:
    ; Bit 0x02 — Y
    test r13d, 0x02
    jz .pcr_no_y
    movsx eax, word [x11_read_buf + 18]
    mov [r12], eax
    add r12, 4
.pcr_no_y:
    ; Bit 0x04 — Width (zero-extend CARD16)
    test r13d, 0x04
    jz .pcr_no_w
    movzx eax, word [x11_read_buf + 20]
    mov [r12], eax
    add r12, 4
.pcr_no_w:
    ; Bit 0x08 — Height
    test r13d, 0x08
    jz .pcr_no_h
    movzx eax, word [x11_read_buf + 22]
    mov [r12], eax
    add r12, 4
.pcr_no_h:
    ; Bit 0x10 — Border-Width
    test r13d, 0x10
    jz .pcr_no_bw
    movzx eax, word [x11_read_buf + 24]
    mov [r12], eax
    add r12, 4
.pcr_no_bw:
    ; Bit 0x20 — Sibling (CARD32)
    test r13d, 0x20
    jz .pcr_no_sib
    mov eax, [x11_read_buf + 12]
    mov [r12], eax
    add r12, 4
.pcr_no_sib:
    ; Bit 0x40 — Stack-Mode (only the byte at +1 of the event header is
    ; meaningful; pad to CARD32).
    test r13d, 0x40
    jz .pcr_no_stack
    movzx eax, byte [x11_read_buf + 1]
    mov [r12], eax
    add r12, 4
.pcr_no_stack:
    ; Send: rdx = total bytes = (3 + popcount) * 4
    lea rsi, [tmp_buf]
    mov rdx, r12
    sub rdx, rsi
    call x11_buffer
    inc dword [x11_seq]
    pop r13
    pop r12
    pop rbx
    ret

; eax = workspace number (1..WS_COUNT). Reapplies the workspace's
; layout: configures and maps every client that should be visible,
; unmaps any that shouldn't. No-op if the workspace isn't currently
; on any output. Safe to call repeatedly.
apply_workspace_layout:
    push rbx
    push r12
    push r13
    push r14
    push r15
    test eax, eax
    jz .awl_done
    cmp eax, WS_COUNT
    jg .awl_done
    mov r13d, eax                         ; r13 = ws number

    ; Find the output this workspace is pinned to and check whether
    ; the workspace is currently visible there.
    mov ecx, r13d
    dec ecx
    movzx r14d, byte [ws_pinned_output + rcx]
    cmp r14b, byte [output_count]
    jge .awl_done
    movzx eax, byte [output_current_ws + r14]
    cmp eax, r13d
    jne .awl_done                         ; not visible — nothing to do

    ; Compute the workspace area on its output: full output rect
    ; minus bar reservation (only on output 0) minus inner gap on
    ; all four sides.
    movzx esi, word [output_x + r14*2]    ; ax_x
    movzx edx, word [output_y + r14*2]    ; ax_y
    movzx ecx, word [output_w + r14*2]    ; ax_w
    movzx r12d, word [output_h + r14*2]   ; ax_h
    test r14d, r14d
    jnz .awl_no_bar
    movzx eax, word [bar_height]
    movzx edi, word [cfg_strip_height]
    add eax, edi                          ; reserve strip + bar
    add edx, eax
    sub r12d, eax
.awl_no_bar:
    movzx eax, word [cfg_gap_inner]
    add esi, eax
    add edx, eax
    mov edi, eax
    shl edi, 1
    sub ecx, edi
    sub r12d, edi
    ; r15 layout: pack into 4 dwords on stack — easier as locals via the registers above.
    ; Save: ws_x = esi, ws_y = edx, ws_w = ecx, ws_h = r12d.

    ; Branch on layout.
    movzx eax, byte [ws_layout + r13 - 1]
    cmp eax, LAYOUT_SPLIT_H
    je .awl_split_h
    cmp eax, LAYOUT_SPLIT_V
    je .awl_split_v
    cmp eax, LAYOUT_MASTER
    je .awl_master

    ; ----------- TABBED layout: single visible window ------------
    ; Walk all clients on ws. Configure & map the active one;
    ; unmap any others that are still mapped.
    push rsi                              ; ws_x
    push rdx                              ; ws_y
    push rcx                              ; ws_w
    push r12                              ; ws_h
    mov ecx, r13d
    dec ecx
    mov r15d, [ws_active_xid + rcx*4]     ; r15 = active XID (may be 0)
    ; Two-pass: configure+map the active client FIRST so its pixels
    ; cover the workspace before any non-active siblings get unmapped.
    ; Single x11_flush below sends both passes in one go, so X never
    ; releases the screen between them. Eliminates the wallpaper
    ; flicker on workspace switch / re-elect.
    xor ebx, ebx
.awl_t_loop_show:
    cmp ebx, [client_count]
    jge .awl_t_done_show
    movzx eax, byte [client_ws + rbx]
    cmp eax, r13d
    jne .awl_t_next_show
    mov eax, [client_xids + rbx*4]
    cmp eax, r15d
    jne .awl_t_next_show
    ; Active: route through configure_client_for_workspace for
    ; no-border + no-gap (configure_window_rect would re-add them).
    mov edi, eax
    mov esi, r13d
    call configure_client_for_workspace
    mov eax, [client_xids + rbx*4]
    call send_map_window
.awl_t_next_show:
    inc ebx
    jmp .awl_t_loop_show
.awl_t_done_show:
    ; Second pass: hide non-active clients on this ws.
    xor ebx, ebx
.awl_t_loop_hide:
    cmp ebx, [client_count]
    jge .awl_t_done
    movzx eax, byte [client_ws + rbx]
    cmp eax, r13d
    jne .awl_t_next_hide
    mov eax, [client_xids + rbx*4]
    cmp eax, r15d
    je .awl_t_next_hide
    mov byte [client_unmap_expected + rbx], 1
    call send_unmap_window
.awl_t_next_hide:
    inc ebx
    jmp .awl_t_loop_hide
.awl_t_done:
    pop r12
    pop rcx
    pop rdx
    pop rsi
    jmp .awl_render

    ; ----------- SPLIT_H layout: equal-width vertical strips ------------
.awl_split_h:
    push rbp                              ; rbp is callee-saved
    push rsi                              ; ws_x
    push rdx                              ; ws_y
    push rcx                              ; ws_w
    push r12                              ; ws_h
    movzx eax, byte [workspace_populated + r13 - 1]
    test eax, eax
    jz .awl_sh_done
    mov r15d, eax                         ; r15 = N
    xor ebx, ebx                          ; client iterator
    xor ebp, ebp                          ; visible-index in ws
.awl_sh_loop:
    cmp ebx, [client_count]
    jge .awl_sh_done
    movzx eax, byte [client_ws + rbx]
    cmp eax, r13d
    jne .awl_sh_next
    ; Compute strip rect: x = ws_x + idx * (ws_w / N); w = ws_w / N
    ; Round to keep strips uniform; final strip absorbs remainder.
    mov eax, [rsp + 8]                    ; ws_w
    xor edx, edx
    div r15d
    mov ecx, eax                          ; strip_w = ws_w / N
    mov eax, ebp
    imul eax, ecx                         ; idx * strip_w
    add eax, [rsp + 24]                   ; + ws_x
    mov esi, eax                          ; rect.x
    ; Last strip absorbs remainder (so right edge meets ws_x + ws_w).
    mov edi, ebp
    inc edi
    cmp edi, r15d
    jne .awl_sh_have_w
    ; Last: w = ws_x + ws_w - rect.x
    mov ecx, [rsp + 24]
    add ecx, [rsp + 8]
    sub ecx, esi
.awl_sh_have_w:
    mov edx, [rsp + 16]                   ; rect.y = ws_y
    mov r8d, [rsp + 0]                    ; rect.h = ws_h
    mov edi, [client_xids + rbx*4]
    call configure_window_rect
    mov eax, [client_xids + rbx*4]
    call send_map_window
    inc ebp
.awl_sh_next:
    inc ebx
    jmp .awl_sh_loop
.awl_sh_done:
    pop r12
    pop rcx
    pop rdx
    pop rsi
    pop rbp
    jmp .awl_render

    ; ----------- SPLIT_V layout: equal-height horizontal strips ----------
.awl_split_v:
    push rbp                              ; rbp is callee-saved
    push rsi                              ; ws_x
    push rdx                              ; ws_y
    push rcx                              ; ws_w
    push r12                              ; ws_h
    movzx eax, byte [workspace_populated + r13 - 1]
    test eax, eax
    jz .awl_sv_done
    mov r15d, eax                         ; N
    xor ebx, ebx
    xor ebp, ebp
.awl_sv_loop:
    cmp ebx, [client_count]
    jge .awl_sv_done
    movzx eax, byte [client_ws + rbx]
    cmp eax, r13d
    jne .awl_sv_next
    mov eax, [rsp + 0]                    ; ws_h
    xor edx, edx
    div r15d
    mov r8d, eax                          ; strip_h
    mov eax, ebp
    imul eax, r8d                         ; idx * strip_h
    add eax, [rsp + 16]                   ; + ws_y
    mov edx, eax                          ; rect.y
    mov edi, ebp
    inc edi
    cmp edi, r15d
    jne .awl_sv_have_h
    mov r8d, [rsp + 16]
    add r8d, [rsp + 0]
    sub r8d, edx
.awl_sv_have_h:
    mov esi, [rsp + 24]                   ; rect.x = ws_x
    mov ecx, [rsp + 8]                    ; rect.w = ws_w
    mov edi, [client_xids + rbx*4]
    call configure_window_rect
    mov eax, [client_xids + rbx*4]
    call send_map_window
    inc ebp
.awl_sv_next:
    inc ebx
    jmp .awl_sv_loop
.awl_sv_done:
    pop r12
    pop rcx
    pop rdx
    pop rsi
    pop rbp
    jmp .awl_render

    ; ----------- MASTER layout: master on left + vertical stack on right ---
    ; First ws-client in client_xids order is the master, takes
    ; cfg_master_ratio percent of ws_w on the left. Rest stack as
    ; equal-height strips on the right. With one client, master fills
    ; the whole workspace (no stack).
.awl_master:
    push rbp
    push rsi                              ; ws_x
    push rdx                              ; ws_y
    push rcx                              ; ws_w
    push r12                              ; ws_h
    movzx eax, byte [workspace_populated + r13 - 1]
    test eax, eax
    jz .awl_m_done
    mov r15d, eax                         ; r15 = N

    ; master_w = ws_w * ratio / 100. With N == 1, give master the
    ; whole ws (no stack to make room for).
    mov eax, [rsp + 8]                    ; ws_w
    cmp r15d, 1
    je .awl_m_master_full
    movzx ecx, byte [cfg_master_ratio]
    imul eax, ecx
    mov ecx, 100
    xor edx, edx
    div ecx
    jmp .awl_m_have_master_w
.awl_m_master_full:
    ; eax already = ws_w
.awl_m_have_master_w:
    mov ebp, eax                          ; ebp = master_w (also stack_x offset)

    xor ebx, ebx                          ; client iterator
    xor r14d, r14d                        ; visible-index in ws (0 = master)
.awl_m_loop:
    cmp ebx, [client_count]
    jge .awl_m_done
    movzx eax, byte [client_ws + rbx]
    cmp eax, r13d
    jne .awl_m_next
    test r14d, r14d
    jnz .awl_m_stack
    ; ----- master rect -----
    mov esi, [rsp + 24]                   ; ws_x
    mov edx, [rsp + 16]                   ; ws_y
    mov ecx, ebp                          ; master_w
    mov r8d, [rsp + 0]                    ; ws_h
    jmp .awl_m_emit
.awl_m_stack:
    ; ----- stack item rect -----
    ; stack_x = ws_x + master_w; stack_w = ws_w - master_w.
    ; stack_h slot = ws_h / (N - 1); idx within stack = r14 - 1.
    mov esi, [rsp + 24]
    add esi, ebp                          ; stack_x
    mov ecx, [rsp + 8]
    sub ecx, ebp                          ; stack_w
    mov eax, r15d
    dec eax                               ; (N - 1) stack items
    mov edi, eax                          ; save stack count for last-item check
    mov eax, [rsp + 0]                    ; ws_h
    xor edx, edx
    div edi                               ; eax = strip_h
    mov r8d, eax                          ; rect.h
    mov eax, r14d
    dec eax                               ; idx in stack (0-based)
    imul eax, r8d                         ; idx * strip_h
    add eax, [rsp + 16]                   ; + ws_y
    mov edx, eax                          ; rect.y
    ; Last stack item absorbs remainder so bottom edge meets ws_y + ws_h.
    mov eax, r14d
    cmp eax, r15d
    jne .awl_m_emit                       ; (r14 == N → last stack item)
    mov r8d, [rsp + 16]
    add r8d, [rsp + 0]
    sub r8d, edx
.awl_m_emit:
    mov edi, [client_xids + rbx*4]
    call configure_window_rect
    mov eax, [client_xids + rbx*4]
    call send_map_window
    inc r14d
.awl_m_next:
    inc ebx
    jmp .awl_m_loop
.awl_m_done:
    pop r12
    pop rcx
    pop rdx
    pop rsi
    pop rbp

.awl_render:
    call render_bar
    call x11_flush
.awl_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; edi = layout sentinel (LAY_SET_TABBED / SPLIT_H / SPLIT_V / TOGGLE).
; Sets the current workspace's layout and reapplies. TOGGLE cycles
; TABBED → SPLIT_H → SPLIT_V → TABBED.
action_layout:
    push rbx
    movzx eax, byte [current_ws]
    test eax, eax
    jz .al_done
    mov ebx, eax                          ; ws number

    cmp edi, LAY_TOGGLE
    jne .al_set
    movzx eax, byte [ws_layout + rbx - 1]
    inc eax
    cmp eax, 4
    jl .al_store
    xor eax, eax
    jmp .al_store
.al_set:
    cmp edi, LAY_SET_TABBED
    je .al_have
    cmp edi, LAY_SET_SPLIT_H
    je .al_have
    cmp edi, LAY_SET_SPLIT_V
    je .al_have
    cmp edi, LAY_SET_MASTER
    je .al_have
    jmp .al_done
.al_have:
    mov eax, edi
    dec eax                               ; sentinel - 1 → enum
.al_store:
    mov [ws_layout + rbx - 1], al
    mov eax, ebx
    call apply_workspace_layout
    ; If we just switched OUT of a split (back to tabbed), focus the
    ; active tab so the keyboard goes to the visible window.
    movzx eax, byte [ws_layout + rbx - 1]
    test eax, eax
    jnz .al_done
    mov ecx, ebx
    dec ecx
    mov eax, [ws_active_xid + rcx*4]
    test eax, eax
    jz .al_done
    call set_input_focus
    call x11_flush
.al_done:
    pop rbx
    ret

; edi = direction sentinel (SPAWN_RIGHT/LEFT/UP/DOWN)
; rsi = NUL-terminated command string (in arg_pool)
;
; Sets the workspace's layout (split-h for right/left, split-v for
; up/down), records the focused window as the spawn anchor and the
; insert direction, applies the new layout, then forks /bin/sh -c CMD.
; When the new client's MapRequest fires, track_client rotates it into
; place next to the anchor.
;
; If there's no focused client (empty workspace), the action still
; forks the command and switches the layout, but no reorder happens
; (the new client will simply become the workspace's only window).
action_spawn_split:
    push rbx
    push r12
    push r13
    mov r12d, edi                         ; direction
    mov r13, rsi                          ; cmd ptr

    movzx eax, byte [current_ws]
    test eax, eax
    jz .ass_done
    mov ebx, eax                          ; ws number

    ; Record anchor (focused) XID and after/before flag.
    mov ecx, ebx
    dec ecx
    mov eax, [ws_active_xid + rcx*4]
    mov [pending_spawn_xid], eax
    xor eax, eax
    cmp r12d, SPAWN_RIGHT
    je .ass_after
    cmp r12d, SPAWN_DOWN
    je .ass_after
    jmp .ass_set_after
.ass_after:
    mov eax, 1
.ass_set_after:
    mov [pending_spawn_after], al

    ; Choose target layout from direction.
    mov eax, LAYOUT_SPLIT_H
    cmp r12d, SPAWN_UP
    je .ass_lay_v
    cmp r12d, SPAWN_DOWN
    je .ass_lay_v
    jmp .ass_lay_set
.ass_lay_v:
    mov eax, LAYOUT_SPLIT_V
.ass_lay_set:
    mov [ws_layout + rbx - 1], al
    mov eax, ebx
    call apply_workspace_layout

    ; Fire the command.
    test r13, r13
    jz .ass_done
    mov rdi, r13
    call fork_exec_string
.ass_done:
    pop r13
    pop r12
    pop rbx
    ret

; rdi = NUL-terminated command line. Reads the focused window's
; _TILE_SHELL_PID property (set by glass), resolves the bare child's
; cwd via /proc/PID/cwd, then forks /bin/sh -c CMD with that cwd via
; chdir() in the child. Falls back to plain fork_exec_string (no cwd
; change) if the focused window has no shell-pid property or the
; readlink fails — so the action is always at least as useful as
; `exec`.
action_exec_here:
    push rbx
    push r12
    push r13
    mov r12, rdi                          ; cmd ptr

    movzx eax, byte [current_ws]
    test eax, eax
    jz .aeh_no_cwd
    dec eax
    mov r13d, [ws_active_xid + rax*4]
    test r13d, r13d
    jz .aeh_no_cwd
    mov eax, [tile_shell_pid_atom]
    test eax, eax
    jz .aeh_no_cwd

    ; Send GetProperty(window=r13, property=tile_shell_pid_atom,
    ; type=AnyPropertyType, long_offset=0, long_length=1, delete=0).
    call x11_flush
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_GET_PROPERTY
    mov byte [rdi+1], 0                   ; delete = false
    mov word [rdi+2], 6                   ; length = 6 words
    mov [rdi+4], r13d                     ; window
    mov [rdi+8], eax                      ; property
    mov dword [rdi+12], 0                 ; type = AnyPropertyType
    mov dword [rdi+16], 0                 ; long-offset
    mov dword [rdi+20], 1                 ; long-length (1 CARD32)
    mov rdx, 24
    lea rsi, [tmp_buf]
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    syscall
    inc dword [x11_seq]

    ; Read 32-byte reply header (events get queued for event_loop).
    lea rdi, [tmp_buf + 64]
    call read_reply_or_queue
    test eax, eax
    jz .aeh_no_cwd
    mov eax, [tmp_buf + 64 + 16]          ; value-length
    test eax, eax
    jz .aeh_no_cwd
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [tmp_buf + 96]
    mov rdx, 4
    syscall
    cmp rax, 4
    jl .aeh_no_cwd
    mov ebx, [tmp_buf + 96]               ; bare PID

    ; Resolve foreground process group via /proc/PID/stat field 8
    ; (tpgid). When bare's child (e.g. pointer) is running in the
    ; foreground, tpgid is that child's pgrp; otherwise it equals
    ; bare's own pgrp. Falls back to the bare PID on any parse failure.
    mov eax, ebx
    call read_tpgid
    test eax, eax
    jle .aeh_use_bare_pid
    mov ebx, eax
.aeh_use_bare_pid:

    ; Build "/proc/PID/cwd" into tmp_buf+128.
    lea rdi, [tmp_buf + 128]
    mov dword [rdi], "/pro"
    mov word [rdi+4], "c/"
    add rdi, 6
    mov eax, ebx
    call .aeh_itoa
    mov dword [rax], "/cwd"
    mov byte [rax+4], 0

    ; Resolve via readlink into tmp_buf+256.
    mov rax, 89                           ; SYS_READLINK
    lea rdi, [tmp_buf + 128]
    lea rsi, [tmp_buf + 256]
    mov rdx, 4096
    syscall
    test rax, rax
    jle .aeh_no_cwd
    cmp rax, 4096
    jge .aeh_no_cwd
    mov byte [tmp_buf + 256 + rax], 0     ; readlink doesn't NUL-terminate

    ; Fork; child chdir + exec /bin/sh -c CMD.
    mov rax, SYS_FORK
    syscall
    test rax, rax
    js .aeh_done
    jnz .aeh_done                          ; parent — done
    mov rax, 80                           ; SYS_CHDIR
    lea rdi, [tmp_buf + 256]
    syscall                               ; ignore failure
    sub rsp, 32
    lea rax, [.aeh_sh]
    mov [rsp], rax
    lea rax, [.aeh_dash_c]
    mov [rsp+8], rax
    mov [rsp+16], r12
    mov qword [rsp+24], 0
    lea rdi, [.aeh_sh]
    mov rsi, rsp
    mov rdx, [envp]
    mov rax, SYS_EXECVE
    syscall
    mov rax, SYS_EXIT
    mov edi, 1
    syscall
.aeh_no_cwd:
    test r12, r12
    jz .aeh_done
    mov rdi, r12
    call fork_exec_string
.aeh_done:
    pop r13
    pop r12
    pop rbx
    ret

; eax = number, rdi = output buffer. Writes decimal digits, returns
; rax = pointer past the last digit. (Local helper for action_exec_here
; only — keeps the global itoa untouched.)
.aeh_itoa:
    push rbx
    mov rbx, rdi
    mov ecx, 10
    xor r8d, r8d
.aeh_it_div:
    xor edx, edx
    div ecx
    add edx, '0'
    push rdx
    inc r8d
    test eax, eax
    jnz .aeh_it_div
.aeh_it_pop:
    pop rdx
    mov [rbx], dl
    inc rbx
    dec r8d
    jnz .aeh_it_pop
    mov rax, rbx
    pop rbx
    ret

.aeh_sh:     db "/bin/sh", 0
.aeh_dash_c: db "-c", 0

; eax = process PID. Reads /proc/PID/stat, parses field 8 (tpgid =
; foreground process group of the controlling terminal). Returns the
; tpgid in eax, or 0 on any failure (process gone, parse error,
; tpgid == -1 = no foreground). Uses tmp_buf+1024..+5120 as scratch.
read_tpgid:
    push rbx
    push r12
    push r13
    mov r12d, eax                         ; pid

    ; Build "/proc/PID/stat" into tmp_buf+1024.
    lea rdi, [tmp_buf + 1024]
    mov dword [rdi], "/pro"
    mov word [rdi+4], "c/"
    add rdi, 6
    mov eax, r12d
    call action_exec_here.aeh_itoa
    mov dword [rax], "/sta"
    mov word [rax+4], "t"
    mov byte [rax+5], 0

    ; Open + read the stat file.
    mov rax, SYS_OPEN
    lea rdi, [tmp_buf + 1024]
    xor esi, esi                          ; O_RDONLY
    xor edx, edx
    syscall
    test rax, rax
    js .rt_fail
    mov r13, rax                          ; fd
    mov rax, SYS_READ
    mov rdi, r13
    lea rsi, [tmp_buf + 2048]
    mov rdx, 4096
    syscall
    push rax                              ; bytes read
    mov rax, SYS_CLOSE
    mov rdi, r13
    syscall
    pop rax
    test rax, rax
    jle .rt_fail
    mov r13, rax                          ; bytes read

    ; Find the LAST ')' in [tmp_buf+2048 .. tmp_buf+2048+r13).
    ; The comm field is parenthesised and may itself contain '(' / ')'.
    lea rbx, [tmp_buf + 2048]
    mov rcx, r13
    xor rdi, rdi                          ; rdi = position of last ')' or 0
.rt_scan:
    test rcx, rcx
    jz .rt_after_scan
    dec rcx
    cmp byte [rbx + rcx], ')'
    jne .rt_scan
    lea rdi, [rbx + rcx]
    jmp .rt_after_scan                    ; first hit going right-to-left wins
.rt_after_scan:
    test rdi, rdi
    jz .rt_fail
    inc rdi                               ; skip ')'
    cmp byte [rdi], ' '
    jne .rt_fail
    inc rdi                               ; skip ' '

    ; Skip 5 space-separated tokens: state, ppid, pgrp, session, tty_nr.
    mov ecx, 5
.rt_skip_field:
    test ecx, ecx
    jz .rt_have_tpgid
.rt_eat_token:
    mov al, [rdi]
    test al, al
    jz .rt_fail
    cmp al, ' '
    je .rt_eat_space
    inc rdi
    jmp .rt_eat_token
.rt_eat_space:
    inc rdi                               ; skip the ' '
    dec ecx
    jmp .rt_skip_field
.rt_have_tpgid:
    ; Parse signed decimal at [rdi].
    xor eax, eax
    xor ebx, ebx                          ; sign flag (1 = negative)
    cmp byte [rdi], '-'
    jne .rt_parse
    mov ebx, 1
    inc rdi
.rt_parse:
    movzx ecx, byte [rdi]
    cmp cl, '0'
    jb .rt_parse_done
    cmp cl, '9'
    ja .rt_parse_done
    sub ecx, '0'
    imul eax, eax, 10
    add eax, ecx
    inc rdi
    jmp .rt_parse
.rt_parse_done:
    test ebx, ebx
    jz .rt_done
    neg eax
.rt_done:
    cmp eax, 0
    jle .rt_fail                          ; -1 means no foreground process
    pop r13
    pop r12
    pop rbx
    ret
.rt_fail:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

; eax = workspace number, edx = visual index within ws (0-based).
; Returns XID at that index in eax, or 0 if out of range. Walks
; client_xids in order, counting only clients on the requested ws.
xid_at_ws_index:
    push rbx
    push r12
    push r13
    mov r12d, eax                         ; ws
    mov r13d, edx                         ; target index
    xor ebx, ebx
    xor ecx, ecx                          ; running count
.xawi_loop:
    cmp ebx, [client_count]
    jge .xawi_none
    movzx eax, byte [client_ws + rbx]
    cmp eax, r12d
    jne .xawi_next
    cmp ecx, r13d
    je .xawi_hit
    inc ecx
.xawi_next:
    inc ebx
    jmp .xawi_loop
.xawi_hit:
    mov eax, [client_xids + rbx*4]
    pop r13
    pop r12
    pop rbx
    ret
.xawi_none:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

; eax = XID, edx = workspace number. Returns the visual index (0-based)
; of that XID within the workspace's clients in eax, or -1 if not on ws.
ws_index_of_xid:
    push rbx
    push r12
    push r13
    mov r12d, eax                         ; XID
    mov r13d, edx                         ; ws
    xor ebx, ebx
    xor ecx, ecx
.wiox_loop:
    cmp ebx, [client_count]
    jge .wiox_none
    movzx eax, byte [client_ws + rbx]
    cmp eax, r13d
    jne .wiox_next
    mov eax, [client_xids + rbx*4]
    cmp eax, r12d
    je .wiox_hit
    inc ecx
.wiox_next:
    inc ebx
    jmp .wiox_loop
.wiox_hit:
    mov eax, ecx
    pop r13
    pop r12
    pop rbx
    ret
.wiox_none:
    mov eax, -1
    pop r13
    pop r12
    pop rbx
    ret

; edi = direction sentinel (FOC_RIGHT/LEFT/UP/DOWN). Routes to
; focus_cycle_tab(±1) when the direction is meaningful for the current
; workspace's layout, no-op otherwise:
;   TABBED  : all 4 directions cycle (right/down = +1, left/up = -1)
;   SPLIT_H : right/left only act (up/down are no-ops)
;   SPLIT_V : up/down only act (left/right are no-ops)
;   MASTER  : from master, right → first stack item; from a stack item,
;             left → master, up/down walk the stack; off-axis = no-op
action_focus_dir:
    push rbx
    push r12
    movzx eax, byte [current_ws]
    test eax, eax
    jz .afd_done
    mov r12d, eax                       ; ws number
    dec eax
    movzx ebx, byte [ws_layout + rax]   ; layout enum

    cmp ebx, LAYOUT_SPLIT_H
    je .afd_split_h
    cmp ebx, LAYOUT_SPLIT_V
    je .afd_split_v
    cmp ebx, LAYOUT_MASTER
    je .afd_master
    jmp .afd_pick                       ; TABBED — all dirs cycle
.afd_split_h:
    cmp edi, FOC_UP
    je .afd_done
    cmp edi, FOC_DOWN
    je .afd_done
    jmp .afd_pick
.afd_split_v:
    cmp edi, FOC_LEFT
    je .afd_done
    cmp edi, FOC_RIGHT
    je .afd_done
    jmp .afd_pick
.afd_pick:
    ; Direction → step. right/down advance; left/up retreat.
    mov ecx, 1
    cmp edi, FOC_LEFT
    je .afd_neg
    cmp edi, FOC_UP
    je .afd_neg
    jmp .afd_have_step
.afd_neg:
    mov ecx, -1
.afd_have_step:
    mov edi, ecx
    call focus_cycle_tab
    jmp .afd_done

    ; ---- MASTER navigation ----
    ; Find focused window's ws-index. 0 = master, 1..N-1 = stack items.
    ;   right + master       → index 1 (first stack item)
    ;   left  + stack(any)   → 0       (master)
    ;   up    + stack(idx>1) → idx - 1
    ;   down  + stack(<last) → idx + 1
    ;   anything else        → no-op
.afd_master:
    push rdi                              ; preserve direction
    mov ecx, r12d
    dec ecx
    mov eax, [ws_active_xid + rcx*4]
    test eax, eax
    pop rdi
    jz .afd_done
    push rdi
    mov edx, r12d
    call ws_index_of_xid                  ; eax = focused index in ws
    pop rdi
    cmp eax, -1
    je .afd_done
    mov ebx, eax                          ; ebx = focused ws-index
    movzx ecx, byte [workspace_populated + r12 - 1]   ; ecx = N
    test ebx, ebx
    jnz .afd_m_in_stack
    ; Master: only "right" does anything (jump to first stack item).
    cmp edi, FOC_RIGHT
    jne .afd_done
    cmp ecx, 1
    jle .afd_done                         ; no stack
    mov eax, r12d
    mov edx, 1
    jmp .afd_m_focus
.afd_m_in_stack:
    cmp edi, FOC_LEFT
    je .afd_m_to_master
    cmp edi, FOC_UP
    je .afd_m_up
    cmp edi, FOC_DOWN
    je .afd_m_down
    jmp .afd_done                         ; right in stack = no-op
.afd_m_to_master:
    mov eax, r12d
    xor edx, edx
    jmp .afd_m_focus
.afd_m_up:
    cmp ebx, 1
    jle .afd_done                         ; already first stack item
    mov eax, r12d
    mov edx, ebx
    dec edx
    jmp .afd_m_focus
.afd_m_down:
    mov eax, ebx
    inc eax
    cmp eax, ecx
    jge .afd_done                         ; already last stack item
    mov edx, eax
    mov eax, r12d
.afd_m_focus:
    call xid_at_ws_index
    test eax, eax
    jz .afd_done
    push rax
    mov ecx, r12d
    dec ecx
    mov [ws_active_xid + rcx*4], eax
    call set_input_focus
    call x11_flush
    pop rax
.afd_done:
    pop r12
    pop rbx
    ret

; ══════════════════════════════════════════════════════════════════════
; Config file: ~/.tilerc
; ══════════════════════════════════════════════════════════════════════

; Build $HOME/.tilerc into config_path. Returns rax=ptr or NULL if
; HOME isn't set.
build_config_path:
    push rbx
    mov rdi, [envp]
.bcp_loop:
    mov rax, [rdi]
    test rax, rax
    jz .bcp_none
    cmp dword [rax], 'HOME'
    jne .bcp_next
    cmp byte [rax + 4], '='
    jne .bcp_next
    lea rsi, [rax + 5]
    lea rdi, [config_path]
.bcp_cp_home:
    mov al, [rsi]
    test al, al
    jz .bcp_append
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .bcp_cp_home
.bcp_append:
    lea rsi, [tilerc_suffix]
    mov ecx, tilerc_suffix_len + 1   ; include trailing NUL
.bcp_cp_suf:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz .bcp_cp_suf
    lea rax, [config_path]
    pop rbx
    ret
.bcp_next:
    add rdi, 8
    jmp .bcp_loop
.bcp_none:
    xor eax, eax
    pop rbx
    ret

; Read ~/.tilerc into config_buf, parse it. If file is missing or empty,
; install built-in defaults.
load_config:
    push rbx
    push r12
    mov dword [bind_count], 0
    mov dword [exec_count], 0
    mov dword [assign_count], 0
    mov dword [stash_class_count], 0
    mov qword [config_len], 0
    ; Reset arg_pool so repeated reloads don't leak. The bind_table and
    ; exec_list above are already empty, so no live offsets reference
    ; arg_pool. Keep arg_pool[0] = 0 as the "no arg" sentinel.
    mov dword [arg_pool_pos], 1
    mov byte [arg_pool], 0
    ; Reset pin overrides so a reload picks up removed `pin` lines.
    mov rax, 0xFFFFFFFFFFFFFFFF
    mov [ws_pin_override], rax
    mov word [ws_pin_override + 8], 0xFFFF

    call build_config_path
    test rax, rax
    jz .lc_defaults
    mov rdi, rax
    mov rax, SYS_OPEN
    xor esi, esi                 ; O_RDONLY
    xor edx, edx
    syscall
    test rax, rax
    js .lc_defaults
    mov rbx, rax                 ; fd

    xor r12, r12                 ; bytes read
.lc_read:
    mov rax, SYS_READ
    mov rdi, rbx
    lea rsi, [config_buf]
    add rsi, r12
    mov rdx, CFG_BUF_SIZE
    sub rdx, r12
    jle .lc_read_done
    syscall
    test rax, rax
    jle .lc_read_done
    add r12, rax
    jmp .lc_read
.lc_read_done:
    mov [config_len], r12
    mov rax, SYS_CLOSE
    mov rdi, rbx
    syscall

    test r12, r12
    jz .lc_defaults

    ; Parse line by line.
    lea rbx, [config_buf]        ; rbx = current pointer
    mov r12, rbx
    add r12, [config_len]        ; r12 = end
.lc_lineloop:
    cmp rbx, r12
    jge .lc_check_empty
    ; Find end of current line (LF or end of buffer).
    mov rsi, rbx
.lc_find_lf:
    cmp rsi, r12
    jge .lc_lf_found
    cmp byte [rsi], 10
    je .lc_lf_found
    inc rsi
    jmp .lc_find_lf
.lc_lf_found:
    ; Null-terminate this line in place (overwrite the LF).
    mov byte [rsi], 0
    push rsi                     ; save end-of-line ptr for advance
    mov rdi, rbx
    call parse_config_line
    pop rsi
    mov rbx, rsi
    inc rbx                      ; skip past the (now-NUL) terminator
    jmp .lc_lineloop
.lc_check_empty:
    cmp dword [bind_count], 0
    jne .lc_done
.lc_defaults:
    call install_default_binds
.lc_done:
    pop r12
    pop rbx
    ret

; Hardcoded fallback: Alt+Return → exec glass, Alt+q → kill, Alt+Shift+q → exit.
install_default_binds:
    push rbx
    lea rdi, [default_glass_arg]
    call arg_pool_dup
    mov ebx, eax                 ; arg_off
    mov dword [bind_count], 0
    mov edi, 0xff0d              ; XK_Return
    mov esi, MOD_MOD1
    mov edx, ACT_EXEC
    mov ecx, ebx
    xor r8b, r8b
    call add_bind
    mov edi, 0x71                ; XK_q
    mov esi, MOD_MOD1
    mov edx, ACT_KILL
    xor ecx, ecx
    xor r8b, r8b
    call add_bind
    mov edi, 0x71
    mov esi, MOD_MOD1 | MOD_SHIFT
    mov edx, ACT_EXIT
    xor ecx, ecx
    xor r8b, r8b
    call add_bind
    pop rbx
    ret

; rdi = keysym, esi = modifiers, edx = action_id, ecx = arg_off,
; r8b = arg_int. Appends a new bind entry. Silently drops if table is
; full.
add_bind:
    push rbx
    mov ebx, [bind_count]
    cmp ebx, MAX_BINDS
    jge .ab_full
    mov eax, ebx
    imul eax, BIND_STRIDE
    lea r9, [bind_table + rax]
    mov [r9], edi                ; keysym
    mov dword [r9 + 4], 0        ; keycode placeholder
    mov [r9 + 8], si             ; modifiers
    mov [r9 + 10], dl            ; action_id
    mov [r9 + 11], r8b           ; arg_int
    mov [r9 + 12], cx            ; arg_off
    mov word [r9 + 14], 0
    inc dword [bind_count]
.ab_full:
    pop rbx
    ret

; rdi = NUL-terminated string. Parse as integer. Returns workspace
; number in eax: 1..9 for "1".."9", 10 for "0" (matches i3-style
; numbering on the row of digit keys); 0 if not a valid digit.
; rdi = NUL-terminated string. Reads up to 2 leading decimal digits and
; returns the workspace number 1..10 in eax. Mapping:
;   "1".."9"  → 1..9
;   "0"       → 10  (i3-style — the digit row's "0" key sits after "9")
;   "10"      → 10
; Anything else (3+ digits, leading non-digit, value >10) → 0. Trailing
; whitespace / comment / NUL after the digits is ignored, so the line
; need not be tokenized before calling.
parse_workspace_number:
    movzx eax, byte [rdi]
    sub eax, '0'
    cmp eax, 9
    ja .pwn_no                   ; not a digit at all
    movzx ecx, byte [rdi + 1]
    sub ecx, '0'
    cmp ecx, 9
    ja .pwn_one_digit            ; second char isn't a digit → 1-digit value
    ; Two-digit value. Reject if a 3rd digit follows.
    movzx edx, byte [rdi + 2]
    sub edx, '0'
    cmp edx, 9
    jbe .pwn_no                  ; 3+ digits — reject
    imul eax, eax, 10
    add eax, ecx
    cmp eax, 10
    ja .pwn_no                   ; only 1..10 are valid workspaces
    test eax, eax
    jz .pwn_no                   ; "00" is nonsense
    ret
.pwn_one_digit:
    test eax, eax
    jnz .pwn_done                ; "1".."9" → 1..9
    mov eax, 10                  ; "0" → 10
.pwn_done:
    ret
.pwn_no:
    xor eax, eax
    ret

; rdi = NUL-terminated string. Lookup in ws_arg_table. Returns sentinel
; in eax (0xff/0xfe/0xfd) or 0 on miss.
lookup_ws_arg:
    lea rdx, [ws_arg_table]
    jmp lookup_packed_byte

; rdi = NUL-terminated string, rdx = pointer to a "name\0value\0pad"
; packed table (terminated with an empty name = single NUL byte).
; Returns the value byte in eax, or 0 if no match.
lookup_packed_byte:
    push rbx
    mov rsi, rdx
.lpb_loop:
    mov al, [rsi]
    test al, al
    jz .lpb_none
    push rsi
    push rdi
    mov rbx, rdi
.lpb_cmp:
    mov al, [rsi]
    mov dl, [rbx]
    cmp al, dl
    jne .lpb_neq
    test al, al
    je .lpb_match
    inc rsi
    inc rbx
    jmp .lpb_cmp
.lpb_neq:
    pop rdi
    pop rsi
.lpb_skip:
    mov al, [rsi]
    inc rsi
    test al, al
    jnz .lpb_skip
    add rsi, 2                   ; skip value byte + pad
    jmp .lpb_loop
.lpb_match:
    pop rdi
    pop rsi
.lpb_to_val:
    mov al, [rsi]
    inc rsi
    test al, al
    jnz .lpb_to_val
    movzx eax, byte [rsi]
    pop rbx
    ret
.lpb_none:
    xor eax, eax
    pop rbx
    ret

; rdi = source string. Copy into arg_pool, return offset in eax (0 on
; failure / empty). Includes trailing NUL.
arg_pool_dup:
    push rbx
    push r12
    mov r12, rdi
    mov ebx, [arg_pool_pos]
    mov rdi, r12
    call .apd_strlen             ; rax = length
    mov ecx, eax
    inc ecx                      ; include NUL
    mov edx, ebx
    add edx, ecx
    cmp edx, ARG_POOL_SIZE
    jg .apd_full
    lea rdi, [arg_pool + rbx]
    mov rsi, r12
.apd_copy:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    test al, al
    jnz .apd_copy
    mov eax, ebx                 ; return offset
    add [arg_pool_pos], ecx
    pop r12
    pop rbx
    ret
.apd_full:
    xor eax, eax
    pop r12
    pop rbx
    ret
.apd_strlen:
    xor eax, eax
.apd_sl:
    cmp byte [rdi + rax], 0
    je .apd_sl_done
    inc eax
    jmp .apd_sl
.apd_sl_done:
    ret

; rdi = NUL-terminated line (LF already stripped). Parses one config
; statement: "bind <chord> <action> [arg]" or "exec <cmd>" or "mod = X"
; or comment / blank.
; rdi = NUL-terminated original config line (held in cfg_line_buf, set
; by parse_config_line before tokenization). Writes
;   "tile: warning: ignoring config line: <line>\n"
; to stderr. Visible when tile is launched from a terminal; harmless
; (silently dropped) under xinit. Output errors are ignored — there's
; nothing useful we could do about a closed stderr.
warn_unknown_config_line:
    push rbx
    push r12
    mov r12, rdi
    mov rax, SYS_WRITE
    mov edi, 2
    lea rsi, [.wucl_pre]
    mov edx, .wucl_pre_len
    syscall
    ; Walk the line to its NUL or 255 cap.
    mov rdi, r12
    xor ecx, ecx
.wucl_len:
    cmp byte [rdi + rcx], 0
    je .wucl_len_done
    inc ecx
    cmp ecx, 255
    jl .wucl_len
.wucl_len_done:
    test ecx, ecx
    jz .wucl_lf_only
    mov rax, SYS_WRITE
    mov edi, 2
    mov rsi, r12
    mov edx, ecx
    syscall
.wucl_lf_only:
    mov rax, SYS_WRITE
    mov edi, 2
    lea rsi, [.wucl_lf]
    mov edx, 1
    syscall
    pop r12
    pop rbx
    ret
.wucl_pre: db "tile: warning: ignoring config line: "
.wucl_pre_len equ $ - .wucl_pre
.wucl_lf: db 10

parse_config_line:
    push rbx
    push r12
    push r13
    mov r12, rdi

    ; Snapshot the line into cfg_line_buf BEFORE tokenization NUL-
    ; terminates words inside it. The warning emitter reads this back
    ; so the user sees the original text in the diagnostic.
    push rdi
    mov rsi, rdi
    lea rdi, [cfg_line_buf]
    mov ecx, 255
.pcl_snap:
    test ecx, ecx
    jz .pcl_snap_done
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .pcl_snap_done
    inc rsi
    inc rdi
    dec ecx
    jmp .pcl_snap
.pcl_snap_done:
    mov byte [rdi], 0
    mov byte [cfg_line_recognized], 0
    pop rdi
    mov r12, rdi

    ; Strip trailing inline comments from the WORKING copy: a `#` that
    ; follows whitespace becomes a NUL terminator. The `#` in `#rrggbb`
    ; hex colours is preserved because nothing whitespacey precedes it
    ; (the value sits flush against `=`/the keyword + a space). The
    ; cfg_line_buf snapshot keeps the original for warning text.
    mov rsi, r12
.pcl_strip_inline:
    mov al, [rsi]
    test al, al
    je .pcl_strip_done
    cmp al, ' '
    je .pcl_strip_check_hash
    cmp al, 9
    je .pcl_strip_check_hash
    inc rsi
    jmp .pcl_strip_inline
.pcl_strip_check_hash:
    cmp byte [rsi + 1], '#'
    jne .pcl_strip_advance_ws
    ; A `#` after whitespace ONLY counts as a comment when it is itself
    ; followed by whitespace (or end-of-line). That distinguishes
    ;   bar_pad = 6   # comment        ← real comment
    ; from
    ;   bar_bg = #222222               ← hex colour, must not be eaten
    movzx eax, byte [rsi + 2]
    cmp al, 0
    je .pcl_strip_kill
    cmp al, ' '
    je .pcl_strip_kill
    cmp al, 9
    je .pcl_strip_kill
    jmp .pcl_strip_advance_ws            ; not whitespace after `#` → not a comment
.pcl_strip_kill:
    mov byte [rsi], 0
    jmp .pcl_strip_done
.pcl_strip_advance_ws:
    inc rsi
    jmp .pcl_strip_inline
.pcl_strip_done:

    ; Trim trailing whitespace. Some arg parsers (layout/focus/move-tab)
    ; do strict equality lookups against short words — a lingering
    ; space after `toggle` would turn "toggle" into "toggle " and miss.
    mov rsi, r12
.pcl_find_end:
    mov al, [rsi]
    test al, al
    jz .pcl_trim_back
    inc rsi
    jmp .pcl_find_end
.pcl_trim_back:
    cmp rsi, r12
    jbe .pcl_trim_done
    mov al, [rsi - 1]
    cmp al, ' '
    je .pcl_trim_kill
    cmp al, 9
    je .pcl_trim_kill
    jmp .pcl_trim_done
.pcl_trim_kill:
    dec rsi
    mov byte [rsi], 0
    jmp .pcl_trim_back
.pcl_trim_done:

    ; Skip leading whitespace
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_blank_or_comment     ; blank → don't warn
    cmp al, '#'
    je .pcl_blank_or_comment     ; comment → don't warn
    ; Tokenize: r13 = start of command word
    mov r13, r12
.pcl_cmd_end:
    mov al, [r12]
    test al, al
    je .pcl_cmd_done
    cmp al, ' '
    je .pcl_cmd_done
    cmp al, 9
    je .pcl_cmd_done
    inc r12
    jmp .pcl_cmd_end
.pcl_cmd_done:
    ; If we hit a space/tab, NUL-terminate it so we can compare.
    mov al, [r12]
    test al, al
    je .pcl_have_cmd
    mov byte [r12], 0
    inc r12
.pcl_have_cmd:
    ; Compare command against the recognised keywords.
    mov rdi, r13
    lea rsi, [.pcl_kw_bind]
    call .pcl_streq
    test eax, eax
    jnz .pcl_handle_bind
    mov rdi, r13
    lea rsi, [.pcl_kw_exec]
    call .pcl_streq
    test eax, eax
    jnz .pcl_handle_exec
    mov rdi, r13
    lea rsi, [.pcl_kw_pin]
    call .pcl_streq
    test eax, eax
    jnz .pcl_handle_pin
    mov rdi, r13
    lea rsi, [.pcl_kw_assign]
    call .pcl_streq
    test eax, eax
    jnz .pcl_handle_assign
    mov rdi, r13
    lea rsi, [.pcl_kw_stash_on_map]
    call .pcl_streq
    test eax, eax
    jnz .pcl_handle_stash_on_map
    ; bar / palette settings (key = value)
    call .pcl_skip_ws
    cmp byte [r12], '='
    jne .pcl_done                ; unknown command word — falls through to warn
    inc r12
    call .pcl_skip_ws
    mov rdi, r13
    call apply_setting
    test eax, eax
    jz .pcl_done                 ; unknown setting key — warn
    mov byte [cfg_line_recognized], 1
    jmp .pcl_done

.pcl_handle_bind:
    ; r12 points just past "bind\0". Skip ws.
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_done
    ; Parse chord (modifiers + key) terminated by ws or NUL.
    mov rdi, r12
    call parse_chord
    test eax, eax
    jz .pcl_done                 ; bad chord
    mov rbx, rax                 ; rbx = keysym
    push rdx                     ; modifiers
    mov r12, rcx                 ; advance past chord
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_pop_mod_done
    ; Read action keyword
    mov r13, r12
.pcl_act_end:
    mov al, [r12]
    test al, al
    je .pcl_act_done
    cmp al, ' '
    je .pcl_act_done
    cmp al, 9
    je .pcl_act_done
    inc r12
    jmp .pcl_act_end
.pcl_act_done:
    mov al, [r12]
    test al, al
    je .pcl_act_have
    mov byte [r12], 0
    inc r12
.pcl_act_have:
    ; Lookup action in action_table
    mov rdi, r13
    call lookup_action
    test eax, eax
    jz .pcl_pop_mod_done         ; unknown action
    mov ecx, eax                 ; action_id
    ; Per-action argument parsing. ecx = action_id at entry to each
    ; branch. We need to set:
    ;   edx = arg_off   (offset into arg_pool, or 0)
    ;   r8b = arg_int   (small numeric arg, or 0)
    ; before falling into .pcl_emit.
    cmp ecx, ACT_EXEC
    je .pcl_arg_exec
    cmp ecx, ACT_EXEC_HERE
    je .pcl_arg_exec
    cmp ecx, ACT_WORKSPACE
    je .pcl_arg_ws
    cmp ecx, ACT_MOVE_TO
    je .pcl_arg_mt
    cmp ecx, ACT_FOCUS
    je .pcl_arg_focus
    cmp ecx, ACT_MOVE_TAB
    je .pcl_arg_mtab
    cmp ecx, ACT_LAYOUT
    je .pcl_arg_layout
    cmp ecx, ACT_SPAWN_SPLIT
    je .pcl_arg_spawn_split
    ; kill / exit / unknown — no arg.
    xor edx, edx
    xor r8b, r8b
    jmp .pcl_emit
.pcl_arg_exec:
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_pop_mod_done
    push rcx                     ; save action_id across arg_pool_dup
    mov rdi, r12
    call arg_pool_dup
    pop rcx
    mov edx, eax                 ; arg_off
    xor r8b, r8b                 ; no arg_int
    jmp .pcl_emit
.pcl_arg_ws:
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_pop_mod_done
    push rcx                     ; save action_id across helper calls
    mov rdi, r12
    call lookup_ws_arg           ; handles next/prev/back-and-forth
    test eax, eax
    jnz .pcl_ws_have
    mov rdi, r12
    call parse_workspace_number
    test eax, eax
    jnz .pcl_ws_have
    pop rcx                      ; balance stack before bailing
    jmp .pcl_pop_mod_done
.pcl_ws_have:
    mov r8b, al                  ; arg_int
    xor edx, edx                 ; no arg_off
    pop rcx                      ; restore action_id
    jmp .pcl_emit
.pcl_arg_mt:
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_pop_mod_done
    push rcx                     ; save action_id across parse_workspace_number
    mov rdi, r12
    call parse_workspace_number
    test eax, eax
    jnz .pcl_mt_ok
    pop rcx
    jmp .pcl_pop_mod_done
.pcl_mt_ok:
    mov r8b, al
    xor edx, edx
    pop rcx
    jmp .pcl_emit
.pcl_arg_focus:
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_pop_mod_done
    push rcx                     ; save action_id across lookup_packed_byte
    mov rdi, r12
    lea rdx, [focus_arg_table]
    call lookup_packed_byte
    test eax, eax
    jnz .pcl_focus_ok
    pop rcx
    jmp .pcl_pop_mod_done
.pcl_focus_ok:
    mov r8b, al
    xor edx, edx
    pop rcx
    jmp .pcl_emit
.pcl_arg_mtab:
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_pop_mod_done
    push rcx
    mov rdi, r12
    lea rdx, [mtab_arg_table]
    call lookup_packed_byte
    test eax, eax
    jnz .pcl_mtab_ok
    pop rcx
    jmp .pcl_pop_mod_done
.pcl_mtab_ok:
    mov r8b, al
    xor edx, edx
    pop rcx
    jmp .pcl_emit
.pcl_arg_layout:
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_pop_mod_done
    push rcx
    mov rdi, r12
    lea rdx, [layout_arg_table]
    call lookup_packed_byte
    test eax, eax
    jnz .pcl_layout_ok
    pop rcx
    jmp .pcl_pop_mod_done
.pcl_layout_ok:
    mov r8b, al
    xor edx, edx
    pop rcx
    jmp .pcl_emit
.pcl_arg_spawn_split:
    ; "spawn-split <direction> <command...>"
    ; First read the direction word, NUL-terminate, look it up. Then
    ; the rest of the line (after ws skip) is the command for arg_pool.
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_pop_mod_done
    mov r13, r12                          ; start of direction word
.pcl_ssp_dir_end:
    mov al, [r12]
    test al, al
    je .pcl_ssp_dir_done
    cmp al, ' '
    je .pcl_ssp_dir_done
    cmp al, 9
    je .pcl_ssp_dir_done
    inc r12
    jmp .pcl_ssp_dir_end
.pcl_ssp_dir_done:
    mov al, [r12]
    test al, al
    je .pcl_pop_mod_done                  ; need a command after direction
    mov byte [r12], 0
    inc r12
    push rcx                              ; save action_id across lookups
    mov rdi, r13
    lea rdx, [spawn_split_arg_table]
    call lookup_packed_byte
    test eax, eax
    jz .pcl_ssp_bad
    push rax                              ; save direction sentinel
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_ssp_pop_bad
    mov rdi, r12
    call arg_pool_dup
    test eax, eax
    jz .pcl_ssp_pop_bad
    mov edx, eax                          ; arg_off = command
    pop r9                                ; direction sentinel
    pop rcx                               ; action_id
    mov r8b, r9b                          ; arg_int = direction
    jmp .pcl_emit
.pcl_ssp_pop_bad:
    add rsp, 8                            ; drop direction sentinel
.pcl_ssp_bad:
    pop rcx                               ; restore action_id (to keep stack balanced)
    jmp .pcl_pop_mod_done
.pcl_emit:
    pop r9                       ; modifiers (was push rdx earlier)
    push rcx                     ; preserve action_id
    push r8                      ; preserve arg_int
    mov edi, ebx                 ; keysym
    mov esi, r9d                 ; modifiers
    mov r9, rdx                  ; arg_off (param 5)
    pop rcx                      ; arg_int from stack into rcx temporarily
    mov r8b, cl                  ; restore arg_int into r8b for add_bind
    pop rcx                      ; action_id
    mov edx, ecx                 ; action_id (param 3)
    mov ecx, r9d                 ; arg_off (param 4)
    call add_bind
    mov byte [cfg_line_recognized], 1
    jmp .pcl_done
.pcl_pop_mod_done:
    pop rdx
    jmp .pcl_done

.pcl_handle_exec:
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_done
    mov rdi, r12
    call arg_pool_dup
    test eax, eax
    jz .pcl_done
    mov edx, [exec_count]
    cmp edx, MAX_EXECS
    jge .pcl_done
    mov [exec_list + rdx*2], ax
    inc dword [exec_count]
    mov byte [cfg_line_recognized], 1
    jmp .pcl_done

.pcl_handle_pin:
    ; "pin <ws> <output_index>"
    ; ws is 1..9 (digit) or 0 (= WS 10), output_index is decimal byte.
    call .pcl_skip_ws
    mov rdi, r12
    call parse_workspace_number
    test eax, eax
    jz .pcl_done
    mov ebx, eax                          ; ws number 1..10
    ; Skip past the digit (single-char in our parser).
    inc r12
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_done
    mov rdi, r12
    call parse_decimal_byte
    cmp eax, 0
    jl .pcl_done
    cmp eax, MAX_OUTPUTS
    jge .pcl_done
    mov [ws_pin_override + rbx - 1], al
    mov byte [cfg_line_recognized], 1
    jmp .pcl_done

.pcl_handle_assign:
    ; "assign <class> <ws>"  — class string copied into arg_pool; ws is
    ; 1..9 (digit) or 0 (= WS 10). Garbage drops the line.
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_done
    mov r13, r12                          ; class start
.pcl_assign_cls_end:
    mov al, [r12]
    test al, al
    je .pcl_done                          ; need ws after class
    cmp al, ' '
    je .pcl_assign_cls_done
    cmp al, 9
    je .pcl_assign_cls_done
    inc r12
    jmp .pcl_assign_cls_end
.pcl_assign_cls_done:
    mov byte [r12], 0
    inc r12
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_done
    mov rdi, r12
    call parse_workspace_number
    test eax, eax
    jz .pcl_done
    mov ebx, eax                          ; ws
    mov rdi, r13
    call arg_pool_dup
    test eax, eax
    jz .pcl_done
    mov ecx, [assign_count]
    cmp ecx, MAX_ASSIGNS
    jge .pcl_done
    mov [assign_class + rcx*2], ax
    mov [assign_ws + rcx], bl
    inc dword [assign_count]
    mov byte [cfg_line_recognized], 1
    jmp .pcl_done

.pcl_handle_stash_on_map:
    ; "stash-on-map <class>"  — class string copied into arg_pool.
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_done
    mov rdi, r12
    call arg_pool_dup
    test eax, eax
    jz .pcl_done
    mov ecx, [stash_class_count]
    cmp ecx, MAX_STASH_ON_MAP
    jge .pcl_done
    mov [stash_class + rcx*2], ax
    inc dword [stash_class_count]
    mov byte [cfg_line_recognized], 1
    jmp .pcl_done

.pcl_blank_or_comment:
    mov byte [cfg_line_recognized], 1
    ; fall through to .pcl_done

.pcl_done:
    cmp byte [cfg_line_recognized], 0
    jne .pcl_truly_done
    lea rdi, [cfg_line_buf]
    call warn_unknown_config_line
.pcl_truly_done:
    pop r13
    pop r12
    pop rbx
    ret

.pcl_skip_ws:
    mov al, [r12]
    cmp al, ' '
    je .pcl_sw_inc
    cmp al, 9
    je .pcl_sw_inc
    ret
.pcl_sw_inc:
    inc r12
    jmp .pcl_skip_ws

; rdi, rsi = NUL-terminated strings. Returns 1 in eax if equal, else 0.
.pcl_streq:
    push rbx
.pcl_se_loop:
    mov al, [rdi]
    mov bl, [rsi]
    cmp al, bl
    jne .pcl_se_no
    test al, al
    je .pcl_se_yes
    inc rdi
    inc rsi
    jmp .pcl_se_loop
.pcl_se_yes:
    mov eax, 1
    pop rbx
    ret
.pcl_se_no:
    xor eax, eax
    pop rbx
    ret

.pcl_kw_bind: db "bind", 0
.pcl_kw_exec: db "exec", 0
.pcl_kw_pin:  db "pin", 0
.pcl_kw_assign: db "assign", 0
.pcl_kw_stash_on_map: db "stash-on-map", 0

; rdi = chord string, e.g. "Mod4+Shift+Return".
; Tokens are split by '+'; the chord ends at the first whitespace or NUL.
; Each non-final token is a modifier name; the final token is a key name.
; Returns: rax = keysym (0 on failure)
;          rdx = modifier mask
;          rcx = pointer to char immediately after the chord
;                (the terminating space/tab/NUL itself is left at *rcx-1
;                 and turned into NUL)
; Modifies the input string in place (writes NULs at separators).
parse_chord:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi                 ; current token start
    xor r13, r13                 ; modifier accumulator
    mov r14, rdi                 ; scan pointer
.pc_scan:
    movzx eax, byte [r14]
    test eax, eax
    je .pc_final
    cmp al, ' '
    je .pc_final
    cmp al, 9
    je .pc_final
    cmp al, '+'
    je .pc_mod_token
    inc r14
    jmp .pc_scan
.pc_mod_token:
    mov byte [r14], 0
    mov rdi, r12
    call lookup_modifier
    test eax, eax
    jz .pc_fail
    or r13, rax
    inc r14
    mov r12, r14
    jmp .pc_scan
.pc_final:
    ; The terminator may be NUL, space, or tab. NUL-terminate the key
    ; token and remember the position just past it for the caller.
    movzx ebx, byte [r14]
    mov byte [r14], 0
    mov rdi, r12
    call lookup_key
    test eax, eax
    jz .pc_fail
    ; rcx = char after the chord. If the terminator was NUL, we stop
    ; right at the NUL; otherwise step one past the (now-NUL) byte.
    test ebx, ebx
    je .pc_pos_at_nul
    lea rcx, [r14 + 1]
    jmp .pc_done
.pc_pos_at_nul:
    mov rcx, r14
.pc_done:
    mov edx, r13d                ; modifiers
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.pc_fail:
    xor eax, eax
    xor edx, edx
    mov rcx, r14
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rdi = NUL-terminated name. Returns mask in eax (0 if not found).
lookup_modifier:
    push rbx
    lea rsi, [mod_table]
.lm_loop:
    mov al, [rsi]
    test al, al
    jz .lm_none
    push rsi
    push rdi
    mov rbx, rdi
.lm_cmp:
    mov al, [rsi]
    mov dl, [rbx]
    cmp al, dl
    jne .lm_neq
    test al, al
    je .lm_match
    inc rsi
    inc rbx
    jmp .lm_cmp
.lm_neq:
    pop rdi
    pop rsi
.lm_skip_name:
    mov al, [rsi]
    inc rsi
    test al, al
    jnz .lm_skip_name
    add rsi, 2                   ; skip 2-byte mask
    jmp .lm_loop
.lm_match:
    pop rdi
    pop rsi
.lm_skip_to_mask:
    mov al, [rsi]
    inc rsi
    test al, al
    jnz .lm_skip_to_mask
    movzx eax, word [rsi]
    pop rbx
    ret
.lm_none:
    xor eax, eax
    pop rbx
    ret

; rdi = NUL-terminated name. Returns keysym in eax (0 if not found).
; For single-character names a-z/A-Z/0-9, returns ASCII directly.
lookup_key:
    push rbx
    ; Single char shortcut
    mov al, [rdi]
    test al, al
    jz .lk_none
    cmp byte [rdi + 1], 0
    jne .lk_table                ; multi-char, search table
    ; Single char: a-z / A-Z / 0-9 / printable ASCII
    cmp al, 'a'
    jb .lk_check_upper
    cmp al, 'z'
    ja .lk_check_upper
    movzx eax, al
    pop rbx
    ret
.lk_check_upper:
    cmp al, 'A'
    jb .lk_check_digit
    cmp al, 'Z'
    ja .lk_check_digit
    movzx eax, al
    pop rbx
    ret
.lk_check_digit:
    cmp al, '0'
    jb .lk_other
    cmp al, '9'
    ja .lk_other
    movzx eax, al
    pop rbx
    ret
.lk_other:
    ; Other printable ASCII (! through ~) maps to its own keysym.
    cmp al, 0x20
    jb .lk_none
    cmp al, 0x7e
    ja .lk_none
    movzx eax, al
    pop rbx
    ret
.lk_table:
    lea rsi, [key_table]
.lk_t_loop:
    mov al, [rsi]
    test al, al
    jz .lk_none
    push rsi
    push rdi
    mov rbx, rdi
.lk_t_cmp:
    mov al, [rsi]
    mov dl, [rbx]
    cmp al, dl
    jne .lk_t_neq
    test al, al
    je .lk_t_match
    inc rsi
    inc rbx
    jmp .lk_t_cmp
.lk_t_neq:
    pop rdi
    pop rsi
.lk_t_skip:
    mov al, [rsi]
    inc rsi
    test al, al
    jnz .lk_t_skip
    add rsi, 4                   ; skip 4-byte keysym
    jmp .lk_t_loop
.lk_t_match:
    pop rdi
    pop rsi
.lk_t_to_ks:
    mov al, [rsi]
    inc rsi
    test al, al
    jnz .lk_t_to_ks
    mov eax, [rsi]
    pop rbx
    ret
.lk_none:
    xor eax, eax
    pop rbx
    ret

; rdi = NUL-terminated name. Returns action id in eax (0 if unknown).
lookup_action:
    push rbx
    lea rsi, [action_table]
.la_loop:
    mov al, [rsi]
    test al, al
    jz .la_none
    push rsi
    push rdi
    mov rbx, rdi
.la_cmp:
    mov al, [rsi]
    mov dl, [rbx]
    cmp al, dl
    jne .la_neq
    test al, al
    je .la_match
    inc rsi
    inc rbx
    jmp .la_cmp
.la_neq:
    pop rdi
    pop rsi
.la_skip:
    mov al, [rsi]
    inc rsi
    test al, al
    jnz .la_skip
    add rsi, 2                   ; skip 2-byte action_id+pad
    jmp .la_loop
.la_match:
    pop rdi
    pop rsi
.la_to_id:
    mov al, [rsi]
    inc rsi
    test al, al
    jnz .la_to_id
    movzx eax, byte [rsi]
    pop rbx
    ret
.la_none:
    xor eax, eax
    pop rbx
    ret

; ══════════════════════════════════════════════════════════════════════
; Bar — the row-of-squares strip across the top of the screen.
;
; Layout (left-to-right):
;   <ws-square>(<gap><ws-square>)*  <ws_tab_gap>  <tab-square>(<gap><tab-square>)*
;
; All squares are bar_height x bar_height pixels. Active squares draw
; in their full color; inactive squares are dimmed to
; cfg_tab_dim_factor / 100 of full intensity (per RGB channel).
;
; Workspace squares: cfg_ws_active for the current ws; cfg_ws_populated
; for any ws with at least one client; not drawn at all for empty
; workspaces (so the visible WS-square count = how many workspaces
; have something).
;
; Tab squares: each client carries client_color[i] which indexes the
; palette (0 = cfg_tab_default; 1..N = cfg_tab_palette[N-1]). The
; active tab is drawn at full intensity, others dimmed.
; ══════════════════════════════════════════════════════════════════════

; Apply a "key value" setting line. rdi = NUL-terminated key, r12 (the
; caller's parse_config_line scan ptr) points at the start of the value.
apply_setting:
    push rbx
    push r13
    mov r13, rdi                          ; r13 = key
    mov rdi, r13
    lea rsi, [.as_kw_bar_height]
    call .as_streq
    test eax, eax
    jnz .as_bar_height
    mov rdi, r13
    lea rsi, [.as_kw_bar_bg]
    call .as_streq
    test eax, eax
    jnz .as_bar_bg
    mov rdi, r13
    lea rsi, [.as_kw_tab_default]
    call .as_streq
    test eax, eax
    jnz .as_tab_default
    mov rdi, r13
    lea rsi, [.as_kw_tab_dim_factor]
    call .as_streq
    test eax, eax
    jnz .as_tab_dim_factor
    mov rdi, r13
    lea rsi, [.as_kw_tab_palette]
    call .as_streq
    test eax, eax
    jnz .as_tab_palette
    mov rdi, r13
    lea rsi, [.as_kw_ws_active]
    call .as_streq
    test eax, eax
    jnz .as_ws_active
    mov rdi, r13
    lea rsi, [.as_kw_ws_populated]
    call .as_streq
    test eax, eax
    jnz .as_ws_populated
    mov rdi, r13
    lea rsi, [.as_kw_gap_inner]
    call .as_streq
    test eax, eax
    jnz .as_gap_inner
    mov rdi, r13
    lea rsi, [.as_kw_border_width]
    call .as_streq
    test eax, eax
    jnz .as_border_width
    mov rdi, r13
    lea rsi, [.as_kw_border_focused]
    call .as_streq
    test eax, eax
    jnz .as_border_focused
    mov rdi, r13
    lea rsi, [.as_kw_border_unfocused]
    call .as_streq
    test eax, eax
    jnz .as_border_unfocused
    mov rdi, r13
    lea rsi, [.as_kw_master_ratio]
    call .as_streq
    test eax, eax
    jnz .as_master_ratio
    mov rdi, r13
    lea rsi, [.as_kw_strip_height]
    call .as_streq
    test eax, eax
    jnz .as_strip_height
    mov rdi, r13
    lea rsi, [.as_kw_bar_pad_bottom]
    call .as_streq
    test eax, eax
    jnz .as_bar_pad_bottom
    mov rdi, r13
    lea rsi, [.as_kw_bar_pad]
    call .as_streq
    test eax, eax
    jnz .as_bar_pad
    mov rdi, r13
    lea rsi, [.as_kw_ws_dim_factor]
    call .as_streq
    test eax, eax
    jnz .as_ws_dim_factor
    mov rdi, r13
    lea rsi, [.as_kw_layout_color]
    call .as_streq
    test eax, eax
    jnz .as_layout_color
    mov rdi, r13
    lea rsi, [.as_kw_active_frame]
    call .as_streq
    test eax, eax
    jnz .as_active_frame
    ; Per-workspace colour: ws_color_N where N is 1..10. Match the
    ; "ws_color_" prefix, then parse the digit suffix.
    mov rdi, r13
    lea rsi, [.as_kw_ws_color_pre]
    call .as_starts_with
    test eax, eax
    jnz .as_ws_color_pre
    ; No keyword matched. Return 0 so the caller can warn the user.
    xor eax, eax
    pop r13
    pop rbx
    ret

.as_ws_dim_factor:
    mov rdi, r12
    call parse_decimal_byte
    cmp eax, 100
    jle .as_ws_dim_ok
    mov eax, 100
.as_ws_dim_ok:
    mov [cfg_ws_dim_factor], al
    jmp .as_done

.as_ws_color_pre:
    ; r13 + 9 points just past "ws_color_" (9 chars). Parse the number.
    lea rdi, [r13 + 9]
    call parse_decimal_byte
    test eax, eax
    jz .as_ws_color_bad
    cmp eax, 10
    jg .as_ws_color_bad
    ; Save ws index, then parse the colour value.
    push rax
    mov rdi, r12
    call parse_hex_color
    pop rcx                                  ; rcx = ws (1..10)
    dec rcx
    mov [cfg_ws_colors + rcx*4], eax
    jmp .as_done
.as_ws_color_bad:
    xor eax, eax
    pop r13
    pop rbx
    ret

.as_bar_height:
    mov rdi, r12
    call parse_decimal_byte
    mov [bar_height], ax
    jmp .as_done
.as_bar_bg:
    mov rdi, r12
    call parse_hex_color
    mov [cfg_bar_bg], eax
    jmp .as_done
.as_tab_default:
    mov rdi, r12
    call parse_hex_color
    mov [cfg_tab_default], eax
    jmp .as_done
.as_tab_dim_factor:
    mov rdi, r12
    call parse_decimal_byte
    cmp eax, 100
    jle .as_dim_ok
    mov eax, 100
.as_dim_ok:
    mov [cfg_tab_dim_factor], al
    jmp .as_done
.as_tab_palette:
    mov rdi, r12
    call parse_palette
    jmp .as_done
.as_ws_active:
    mov rdi, r12
    call parse_hex_color
    mov [cfg_ws_active], eax
    jmp .as_done
.as_ws_populated:
    mov rdi, r12
    call parse_hex_color
    mov [cfg_ws_populated], eax
    jmp .as_done
.as_gap_inner:
    mov rdi, r12
    call parse_decimal_byte
    mov [cfg_gap_inner], ax
    jmp .as_done
.as_border_width:
    mov rdi, r12
    call parse_decimal_byte
    mov [cfg_border_width], al
    jmp .as_done
.as_border_focused:
    mov rdi, r12
    call parse_hex_color
    mov [cfg_border_focused], eax
    jmp .as_done
.as_border_unfocused:
    mov rdi, r12
    call parse_hex_color
    mov [cfg_border_unfocused], eax
    jmp .as_done
.as_master_ratio:
    mov rdi, r12
    call parse_decimal_byte
    cmp eax, 10
    jge .as_mr_check_hi
    mov eax, 10
.as_mr_check_hi:
    cmp eax, 90
    jle .as_mr_ok
    mov eax, 90
.as_mr_ok:
    mov [cfg_master_ratio], al
    jmp .as_done
.as_strip_height:
    mov rdi, r12
    call parse_decimal_byte
    mov [cfg_strip_height], ax
    jmp .as_done
.as_bar_pad:
    mov rdi, r12
    call parse_decimal_byte
    mov [cfg_bar_pad], ax
    jmp .as_done
.as_bar_pad_bottom:
    mov rdi, r12
    call parse_decimal_byte
    mov [cfg_bar_pad_bottom], ax
    jmp .as_done
.as_layout_color:
    mov rdi, r12
    call parse_hex_color
    mov [cfg_layout_color], eax
    jmp .as_done
.as_active_frame:
    mov rdi, r12
    call parse_hex_color
    mov [cfg_active_frame], eax
    jmp .as_done
.as_done:
    mov eax, 1                            ; matched + applied
    pop r13
    pop rbx
    ret

.as_streq:
    push rbx
.as_se_loop:
    mov al, [rdi]
    mov bl, [rsi]
    cmp al, bl
    jne .as_se_no
    test al, al
    je .as_se_yes
    inc rdi
    inc rsi
    jmp .as_se_loop
.as_se_yes:
    mov eax, 1
    pop rbx
    ret
.as_se_no:
    xor eax, eax
    pop rbx
    ret

.as_kw_bar_height:    db "bar_height", 0
.as_kw_bar_bg:        db "bar_bg", 0
.as_kw_tab_default:   db "tab_default", 0
.as_kw_tab_dim_factor:db "tab_dim_factor", 0
.as_kw_tab_palette:   db "tab_palette", 0
.as_kw_ws_active:     db "ws_active", 0
.as_kw_ws_populated:  db "ws_populated", 0
.as_kw_gap_inner:     db "gap_inner", 0
.as_kw_border_width:    db "border_width", 0
.as_kw_border_focused:  db "border_focused", 0
.as_kw_border_unfocused: db "border_unfocused", 0
.as_kw_master_ratio:    db "master_ratio", 0
.as_kw_strip_height:    db "strip_height", 0
.as_kw_bar_pad:         db "bar_pad", 0
.as_kw_bar_pad_bottom:  db "bar_pad_bottom", 0
.as_kw_ws_dim_factor:   db "ws_dim_factor", 0
.as_kw_ws_color_pre:    db "ws_color_", 0
.as_kw_layout_color:    db "layout_color", 0
.as_kw_active_frame:    db "active_frame", 0

; rdi = haystack, rsi = needle (NUL-terminated). Returns 1 in eax if
; needle is a prefix of haystack, 0 otherwise.
.as_starts_with:
    push rbx
.asw_loop:
    mov al, [rsi]
    test al, al
    jz .asw_yes                              ; needle exhausted = match
    mov bl, [rdi]
    cmp al, bl
    jne .asw_no
    inc rdi
    inc rsi
    jmp .asw_loop
.asw_yes:
    mov eax, 1
    pop rbx
    ret
.asw_no:
    xor eax, eax
    pop rbx
    ret

; rdi = NUL-terminated string starting with optional '#' then 6 hex
; digits. Returns CARD32 0x00RRGGBB in eax. Garbage in → 0 in eax.
parse_hex_color:
    push rbx
    push r12
    cmp byte [rdi], '#'
    jne .phc_start
    inc rdi
.phc_start:
    xor r12d, r12d                        ; accumulator
    mov ecx, 6                            ; expect exactly 6 hex digits
.phc_loop:
    movzx eax, byte [rdi]
    test eax, eax
    jz .phc_done
    cmp al, '0'
    jb .phc_done
    cmp al, '9'
    jbe .phc_dig
    or al, 0x20                           ; tolower
    cmp al, 'a'
    jb .phc_done
    cmp al, 'f'
    ja .phc_done
    sub al, 'a' - 10
    jmp .phc_acc
.phc_dig:
    sub al, '0'
.phc_acc:
    shl r12d, 4
    or r12d, eax
    inc rdi
    dec ecx
    jnz .phc_loop
.phc_done:
    mov eax, r12d
    or eax, 0xFF000000                    ; opaque alpha for depth-32 visuals
    pop r12
    pop rbx
    ret

; rdi = NUL-terminated decimal number (terminated by NUL or whitespace).
; Returns value in eax (clamped to 0..255 implicitly via the byte storage
; sites).
parse_decimal_byte:
    xor eax, eax
.pdb_loop:
    movzx ecx, byte [rdi]
    cmp cl, '0'
    jb .pdb_done
    cmp cl, '9'
    ja .pdb_done
    sub cl, '0'
    imul eax, 10
    add eax, ecx
    inc rdi
    jmp .pdb_loop
.pdb_done:
    ret

; rdi = NUL-terminated comma-separated list of hex colors, e.g.
;   #ff5555,#50fa7b,#bd93f9
; Stores each parsed color in cfg_tab_palette[] up to MAX_PALETTE
; entries; sets cfg_tab_palette_count.
parse_palette:
    push rbx
    push r12
    push r13
    mov r12, rdi                          ; current scan position
    xor r13d, r13d                        ; palette index
.pp_loop:
    cmp r13d, MAX_PALETTE
    jge .pp_done
    mov rdi, r12
    call parse_hex_color
    test eax, eax
    jz .pp_done                           ; bad/empty entry — stop here
    mov [cfg_tab_palette + r13*4], eax
    inc r13d
    ; Skip remaining hex digits until ',' / NUL / ws
    mov r12, rdi                          ; parse_hex_color advanced rdi
.pp_skip_to_sep:
    movzx eax, byte [r12]
    test eax, eax
    jz .pp_done
    cmp al, ','
    je .pp_at_comma
    cmp al, ' '
    je .pp_done
    cmp al, 9
    je .pp_done
    inc r12
    jmp .pp_skip_to_sep
.pp_at_comma:
    inc r12
    jmp .pp_loop
.pp_done:
    mov [cfg_tab_palette_count], r13b
    pop r13
    pop r12
    pop rbx
    ret

; eax = source CARD32 0x00RRGGBB, dl = factor (% 0..100). Multiplies
; each channel by factor/100 and returns the result in eax. Tab path
; uses cfg_tab_dim_factor; WS path uses cfg_ws_dim_factor.
dim_color_pct:
    push rbx
    push r12
    push r13
    push r14
    mov r14d, eax
    movzx r13d, dl
    jmp dim_color_apply

; Legacy entrypoint: dims by cfg_tab_dim_factor.
dim_color:
    push rbx
    push r12
    push r13
    push r14
    mov r14d, eax
    movzx r13d, byte [cfg_tab_dim_factor]
dim_color_apply:
    ; --- R channel ---
    mov eax, r14d
    shr eax, 16
    and eax, 0xff
    imul eax, r13d
    mov ecx, 100
    xor edx, edx
    div ecx
    mov ebx, eax
    shl ebx, 16
    ; --- G channel ---
    mov eax, r14d
    shr eax, 8
    and eax, 0xff
    imul eax, r13d
    xor edx, edx
    mov ecx, 100
    div ecx
    shl eax, 8
    or ebx, eax
    ; --- B channel ---
    mov eax, r14d
    and eax, 0xff
    imul eax, r13d
    xor edx, edx
    mov ecx, 100
    div ecx
    or ebx, eax
    mov eax, ebx
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Create the bar window (override-redirect, bar_height tall, full
; screen width, at y=0) and a GC for filling it. Subscribes to Expose
; so we can redraw when something covers and uncovers it.
create_bar:
    push rbx
    push r12
    call alloc_xid
    mov [bar_window_id], eax
    mov r12d, eax                         ; window XID

    ; CreateWindow(depth=root_depth, wid=r12, parent=root,
    ;              x=0, y=0, w=screen_w, h=bar_height,
    ;              border-width=0, class=InputOutput,
    ;              visual=CopyFromParent,
    ;              value-mask = CW_BACK_PIXEL | CW_OVERRIDE_REDIRECT
    ;                          | CW_EVENT_MASK,
    ;              values: bg=cfg_bar_bg, override=1,
    ;                      events=ExposureMask)
    lea rdi, [tmp_buf]
    movzx eax, byte [x11_root_depth]
    mov [rdi], al
    mov byte [rdi+1], al                  ; depth
    mov word [rdi+2], 11                  ; request length (8 hdr + 3 values = 11 words)
    mov [rdi+4], r12d                     ; wid
    mov eax, [x11_root_window]
    mov [rdi+8], eax                      ; parent
    ; Bar lives on output 0 (the primary / laptop), not across the
    ; whole root. With Xinerama in extended mode the root spans every
    ; output and a bar at (0, 0, screen_w) would smear across the
    ; external monitor too.
    movzx eax, word [output_x]
    mov [rdi+12], ax                      ; x = output_x[0]
    movzx eax, word [output_y]
    movzx ecx, word [cfg_strip_height]
    add eax, ecx                          ; tile bar lands below strip
    mov [rdi+14], ax                      ; y
    movzx eax, word [output_w]
    mov [rdi+16], ax                      ; width = output_w[0]
    movzx eax, word [bar_height]
    mov [rdi+18], ax                      ; height
    mov word [rdi+20], 0                  ; border-width
    mov word [rdi+22], 1                  ; class = InputOutput
    mov dword [rdi+24], 0                 ; visual = CopyFromParent
    mov dword [rdi+28], CW_BACK_PIXEL | CW_OVERRIDE_REDIRECT | CW_EVENT_MASK
    mov eax, [cfg_bar_bg]
    mov [rdi+32], eax                     ; back pixel
    mov dword [rdi+36], 1                 ; override-redirect = true
    mov dword [rdi+40], EXPOSURE_MASK     ; event mask
    ; Set the X11 opcode now (rdi[0] got clobbered by the depth write).
    mov byte [rdi], X11_CREATE_WINDOW
    lea rsi, [tmp_buf]
    mov rdx, 44
    call x11_buffer
    inc dword [x11_seq]

    ; CreateGC(cid, drawable=bar_window_id, value-mask=GC_FOREGROUND,
    ;          values: foreground=0)  — foreground is set per-square.
    call alloc_xid
    mov [bar_gc_id], eax
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_CREATE_GC
    mov byte [rdi+1], 0
    mov word [rdi+2], 5                   ; length (4 hdr + 1 value = 5 words)
    mov [rdi+4], eax                      ; cid
    mov [rdi+8], r12d                     ; drawable
    mov dword [rdi+12], GC_FOREGROUND
    mov dword [rdi+16], 0                 ; foreground = 0 (overwritten per draw)
    lea rsi, [tmp_buf]
    mov rdx, 20
    call x11_buffer
    inc dword [x11_seq]

    ; Map the bar window.
    mov eax, r12d
    call send_map_window
    pop r12
    pop rbx
    ret

; eax = layout id (LAYOUT_TABBED / LAYOUT_SPLIT_H / LAYOUT_SPLIT_V /
; LAYOUT_MASTER), edi = x position. Draws a bar_height × bar_height
; glyph using the GC's current foreground colour, depicting the
; layout's pane shape so the user knows where the next spawn lands.
;
;   TABBED   ☰          (three thin horizontal bars stacked, distinct
;                       from the filled-square app indicators)
;   SPLIT_H  ▌▐         (two thin vertical bars side by side)
;   SPLIT_V  ▀▄         (two thin horizontal bars stacked)
;   MASTER   ▌▘▖        (left half full + right half split top/bottom)
;
; All glyphs occupy the same edge length so positioning stays
; predictable. Bars are 2px thick on a typical bar_height=10.
draw_layout_glyph:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, edi                          ; glyph x
    movzx r13d, word [bar_height]          ; glyph edge
    mov r14d, eax                          ; layout id
    cmp r14d, LAYOUT_TABBED
    je .dlg_tabbed
    cmp r14d, LAYOUT_SPLIT_H
    je .dlg_split_h
    cmp r14d, LAYOUT_SPLIT_V
    je .dlg_split_v
    cmp r14d, LAYOUT_MASTER
    je .dlg_master
    jmp .dlg_done                          ; unknown layout — draw nothing

.dlg_tabbed:
    ; Three thin horizontal bars stacked (☰): visually distinct from the
    ; filled-square app indicators that follow. Bar thickness ≈ edge/5,
    ; gap ≈ edge/10 (both clamped to ≥1px so it stays visible at small
    ; bar_height).
    mov ebx, r13d
    mov rax, rbx
    xor edx, edx
    mov ecx, 5
    div rcx                                ; bar thickness = edge / 5
    test eax, eax
    jnz .dlg_tab_th_ok
    inc eax
.dlg_tab_th_ok:
    mov ecx, eax                           ; ecx = bar thickness
    mov ebx, r13d
    mov rax, rbx
    xor edx, edx
    mov esi, 10
    div rsi                                ; gap = edge / 10
    test eax, eax
    jnz .dlg_tab_gp_ok
    inc eax
.dlg_tab_gp_ok:
    mov ebx, eax                           ; ebx = gap between bars
    ; Total occupied = 3*thickness + 2*gap; vertical pad to centre.
    mov eax, ecx
    add eax, ecx
    add eax, ecx
    mov edx, ebx
    add edx, ebx
    add eax, edx                           ; eax = 3*th + 2*gap
    mov edx, r13d
    sub edx, eax
    shr edx, 1                             ; edx = top pad (signed half)
    test edx, edx
    jns .dlg_tab_pad_ok
    xor edx, edx                           ; clamp negative to 0
.dlg_tab_pad_ok:
    ; Bar 1 — top
    mov edi, r12d
    mov esi, edx
    push rdx
    mov edx, r13d                          ; width = full edge
    push rcx
    ; ecx already = thickness
    call fill_rect
    pop rcx
    pop rdx
    add edx, ecx                           ; y += thickness
    add edx, ebx                           ; y += gap
    ; Bar 2 — middle
    mov edi, r12d
    mov esi, edx
    push rdx
    mov edx, r13d
    push rcx
    call fill_rect
    pop rcx
    pop rdx
    add edx, ecx
    add edx, ebx
    ; Bar 3 — bottom
    mov edi, r12d
    mov esi, edx
    mov edx, r13d
    call fill_rect
    jmp .dlg_done

.dlg_split_h:
    ; Two thin vertical bars side by side: |‖|. Each bar = ~38% width,
    ; with a small visual gap in the middle.
    mov ebx, r13d
    shr ebx, 2                             ; bar width = edge / 4
    test ebx, ebx
    jnz .dlg_sh_w_ok
    mov ebx, 1
.dlg_sh_w_ok:
    ; Left bar
    mov edi, r12d
    xor esi, esi
    mov edx, ebx
    mov ecx, r13d
    call fill_rect
    ; Right bar
    mov eax, r13d
    sub eax, ebx
    add eax, r12d
    mov edi, eax
    xor esi, esi
    mov edx, ebx
    mov ecx, r13d
    call fill_rect
    jmp .dlg_done

.dlg_split_v:
    ; Two thin horizontal bars stacked.
    mov ebx, r13d
    shr ebx, 2
    test ebx, ebx
    jnz .dlg_sv_h_ok
    mov ebx, 1
.dlg_sv_h_ok:
    ; Top bar
    mov edi, r12d
    xor esi, esi
    mov edx, r13d
    mov ecx, ebx
    call fill_rect
    ; Bottom bar
    mov eax, r13d
    sub eax, ebx
    mov edi, r12d
    mov esi, eax
    mov edx, r13d
    mov ecx, ebx
    call fill_rect
    jmp .dlg_done

.dlg_master:
    ; Left half = single filled bar; right half = two stacked bars,
    ; with a 1px gap between left and right.
    ;   half_w  = edge / 2
    ;   half_h  = edge / 2
    ;   right_x = half_w + 1
    ;   right_w = edge - half_w - 1
    mov ebx, r13d
    shr ebx, 1                             ; ebx = half_w (also half_h)
    ; Left half (x=r12, y=0, w=half_w, h=edge)
    mov edi, r12d
    xor esi, esi
    mov edx, ebx
    mov ecx, r13d
    call fill_rect
    ; Right top quadrant (x=r12+half_w+1, y=0, w=edge-half_w-1, h=half_h)
    lea edi, [r12d + 1]
    add edi, ebx
    xor esi, esi
    mov edx, r13d
    sub edx, ebx
    sub edx, 1                             ; right_w
    mov ecx, ebx                           ; half_h
    call fill_rect
    ; Right bottom quadrant (x=r12+half_w+1, y=half_h, w=right_w, h=edge-half_h)
    lea edi, [r12d + 1]
    add edi, ebx
    mov esi, ebx                           ; y = half_h
    mov edx, r13d
    sub edx, ebx
    sub edx, 1                             ; right_w
    mov ecx, r13d
    sub ecx, ebx                           ; bottom_h = edge - half_h
    call fill_rect

.dlg_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ChangeGC(gc=bar_gc_id, mask=GC_FOREGROUND, value=eax).
set_bar_fg:
    push rax
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_CHANGE_GC
    mov byte [rdi+1], 0
    mov word [rdi+2], 4                   ; length (3 hdr + 1 value = 4 words)
    mov eax, [bar_gc_id]
    mov [rdi+4], eax
    mov dword [rdi+8], GC_FOREGROUND
    pop rax
    mov [rdi+12], eax
    lea rsi, [tmp_buf]
    mov rdx, 16
    call x11_buffer
    inc dword [x11_seq]
    ret

; PolyFillRectangle(drawable=bar_window_id, gc=bar_gc_id, one rect).
; di = x, si = y, dx = w, cx = h.
fill_rect:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov ebx, ecx
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_POLY_FILL_RECT
    mov byte [rdi+1], 0
    mov word [rdi+2], 5                   ; length (3 hdr + 2 rect words = 5)
    mov eax, [bar_window_id]
    mov [rdi+4], eax
    mov eax, [bar_gc_id]
    mov [rdi+8], eax
    mov [rdi+12], r12w                    ; x
    mov [rdi+14], r13w                    ; y
    mov [rdi+16], r14w                    ; w
    mov [rdi+18], bx                      ; h
    lea rsi, [tmp_buf]
    mov rdx, 20
    call x11_buffer
    inc dword [x11_seq]
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; PolyRectangle (outline only) — same wire format, different opcode.
; PolyRectangle draws the border using the GC's line-width; the X
; default line-width is 0 which servers render as a single-pixel-thick
; outline. Note: PolyRectangle's "w,h" describe the outer dimensions but
; the spec draws the rectangle with corners at (x,y)..(x+w,y+h), so a
; w x h request actually paints (w+1) x (h+1) pixels. We compensate by
; passing w-1, h-1 here so the visible rectangle matches fill_rect's
; bounding box exactly.
outline_rect:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    dec r14d
    mov ebx, ecx
    dec ebx
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_POLY_RECTANGLE
    mov byte [rdi+1], 0
    mov word [rdi+2], 5
    mov eax, [bar_window_id]
    mov [rdi+4], eax
    mov eax, [bar_gc_id]
    mov [rdi+8], eax
    mov [rdi+12], r12w
    mov [rdi+14], r13w
    mov [rdi+16], r14w
    mov [rdi+18], bx
    lea rsi, [tmp_buf]
    mov rdx, 20
    call x11_buffer
    inc dword [x11_seq]
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Resolve client_color[i] (palette index, 0 = default) to a CARD32
; pixel value. eax = palette index (0..N). Returns pixel in eax.
client_color_to_pixel:
    test eax, eax
    jnz .cctp_palette
    mov eax, [cfg_tab_default]
    ret
.cctp_palette:
    movzx ecx, byte [cfg_tab_palette_count]
    test ecx, ecx
    jz .cctp_default                      ; no palette configured
    dec eax                               ; palette is 1-indexed in client_color
    cmp eax, ecx
    jb .cctp_lookup
    xor edx, edx
    div ecx                               ; eax %= count
.cctp_lookup:
    mov eax, [cfg_tab_palette + rax*4]
    ret
.cctp_default:
    mov eax, [cfg_tab_default]
    ret

; Render the entire bar: clear, draw workspace squares, gap, tab squares.
render_bar:
    push rbx
    push r12
    push r13
    push r14
    push r15
    cmp dword [bar_window_id], 0
    je .rb_done                           ; bar not created yet

    ; Clear the whole bar with bar_bg.
    mov eax, [cfg_bar_bg]
    call set_bar_fg
    xor edi, edi
    xor esi, esi
    ; Bar lives on output 0, so coordinates are local to that output
    ; and width = output_w[0], not the full root width.
    movzx edx, word [output_w]
    movzx ecx, word [bar_height]
    call fill_rect

    ; Workspace squares: fixed 10 slots, LEFT-justified, in the order
    ;   [WS1 WS2 WS3] [WS4 WS5 WS6] [WS7 WS8 WS9] [WS10]
    ; (display positions 0..8 = WS 1..9; display 9 = the "0" key =
    ; internal WS 10 — special; will be the external-monitor pin once
    ; 1c lands). Non-current populated workspaces draw filled in
    ; cfg_ws_populated; the current workspace fills in cfg_ws_active.
    ; Empty workspaces draw as outlines in the same colour so the slot
    ; is always visible. A small WS_GROUP_GAP precedes display positions
    ; 3, 6, 9 to group the bar as [1 2 3] [4 5 6] [7 8 9] [0].
    movzx r14d, word [bar_height]         ; square edge
    movzx eax, word [cfg_bar_pad_bottom]   ; user-configurable bottom padding
    cmp eax, r14d
    jb .rb_pad_ok                          ; pad < height → safe
    test r14d, r14d
    jz .rb_no_bottom_pad
    lea eax, [r14d - 1]                    ; clamp pad ≤ height - 1
.rb_pad_ok:
    sub r14d, eax                          ; squares/tabs are pad-px shorter
                                           ; than the bar so the bottom strip
                                           ; stays in bg colour, giving the
                                           ; bar visual breathing room above
                                           ; the cell area below.
.rb_no_bottom_pad:
    movzx r12d, word [cfg_bar_pad]        ; cursor x — start at left padding
    xor r13d, r13d                        ; display position 0..9
.rb_ws_loop:
    cmp r13d, WS_COUNT
    jge .rb_ws_done
    cmp r13d, 3
    je .rb_ws_gap
    cmp r13d, 6
    je .rb_ws_gap
    cmp r13d, 9
    je .rb_ws_gap
    jmp .rb_ws_paint_slot
.rb_ws_gap:
    add r12d, WS_GROUP_GAP
.rb_ws_paint_slot:
    ; Map display position → internal ws number (1..10).
    cmp r13d, 9
    je .rb_ws_zero
    mov ebx, r13d
    inc ebx                               ; display 0..8 → WS 1..9
    jmp .rb_ws_have_ws
.rb_ws_zero:
    mov ebx, 10                           ; display 9 → internal WS 10
.rb_ws_have_ws:
    ; Pick colour. If a per-workspace override is set, use it for both
    ; active and populated states (active = full intensity, populated =
    ; dimmed by cfg_ws_dim_factor — separate from the tab dim so a
    ; bright WS colour stays readable when not active).
    mov eax, [cfg_ws_colors + rbx*4 - 4]
    cmp eax, 0xFFFFFFFF
    je .rb_ws_no_override
    movzx ecx, byte [current_ws]
    cmp ebx, ecx
    je .rb_ws_have_fg                         ; active: per-ws colour at full
    movzx edx, byte [cfg_ws_dim_factor]
    call dim_color_pct                        ; populated: dim per-ws colour
    jmp .rb_ws_have_fg
.rb_ws_no_override:
    movzx eax, byte [current_ws]
    cmp ebx, eax
    jne .rb_ws_use_pop
    mov eax, [cfg_ws_active]
    jmp .rb_ws_have_fg
.rb_ws_use_pop:
    mov eax, [cfg_ws_populated]
.rb_ws_have_fg:
    call set_bar_fg
    mov edi, r12d
    xor esi, esi
    mov edx, r14d
    mov ecx, r14d
    ; Fill if populated, outline if empty.
    movzx eax, byte [workspace_populated + rbx - 1]
    test eax, eax
    jz .rb_ws_outline
    call fill_rect
    jmp .rb_ws_maybe_frame
.rb_ws_outline:
    call outline_rect
.rb_ws_maybe_frame:
    ; If this is the active WS AND a frame colour is configured, paint
    ; a 1 px outline on top in the user's frame colour. Skipped when
    ; cfg_active_frame == 0 so existing configs see no visual change.
    movzx ecx, byte [current_ws]
    cmp ebx, ecx
    jne .rb_ws_advance
    mov eax, [cfg_active_frame]
    test eax, eax
    jz .rb_ws_advance
    call set_bar_fg
    mov edi, r12d
    xor esi, esi
    mov edx, r14d
    mov ecx, r14d
    call outline_rect
.rb_ws_advance:
    add r12d, r14d
    add r12d, WS_SQUARE_GAP
    inc r13d
    jmp .rb_ws_loop
.rb_ws_done:
    ; Strip the trailing WS_SQUARE_GAP we added after the last WS so the
    ; following separator gap is symmetric.
    sub r12d, WS_SQUARE_GAP

    ; Separator between WS strip and the layout indicator:
    ; [ BAR_SEP_GAP ] [ vertical bar BAR_SEP_WIDTH × bar_height ] [ BAR_SEP_GAP ]
    add r12d, BAR_SEP_GAP
    mov eax, [cfg_tab_default]
    call set_bar_fg
    mov edi, r12d
    xor esi, esi
    mov edx, BAR_SEP_WIDTH
    mov ecx, r14d                          ; height = bar_height
    call fill_rect
    add r12d, BAR_SEP_WIDTH
    add r12d, BAR_SEP_GAP

    ; Layout indicator (always drawn, regardless of whether the
    ; workspace has tabs): a single bar_height-square glyph that shows
    ; the current ws's layout mode, sitting between the WS strip and
    ; the tab strip. Colour: cfg_layout_color if set, else cfg_tab_default
    ; (back-compat for configs without the new key).
    mov eax, [cfg_layout_color]
    test eax, eax
    jnz .rb_layout_have_color
    mov eax, [cfg_tab_default]
.rb_layout_have_color:
    call set_bar_fg
    movzx eax, byte [current_ws]
    dec eax
    movzx eax, byte [ws_layout + rax]
    mov edi, r12d                          ; x for the glyph
    call draw_layout_glyph
    add r12d, r14d                         ; advance past the glyph (square width)
    add r12d, LAYOUT_GLYPH_GAP             ; group-sized visual separation from tabs

    ; Tabs are left-justified, starting after the layout indicator.
    movzx r15d, byte [current_ws]
    movzx eax, byte [workspace_populated + r15 - 1]
    test eax, eax
    jz .rb_done                           ; no tabs on this workspace
    ; Active tab XID for this workspace.
    movzx r13d, byte [current_ws]
    dec r13d
    mov r13d, [ws_active_xid + r13*4]
    xor ebx, ebx
.rb_tab_loop:
    cmp ebx, [client_count]
    jge .rb_done
    movzx eax, byte [client_ws + rbx]
    cmp eax, r15d
    jne .rb_tab_next
    movzx eax, byte [client_color + rbx]
    call client_color_to_pixel
    mov ecx, [client_xids + rbx*4]
    cmp ecx, r13d
    je .rb_tab_is_active
    call dim_color
    xor ecx, ecx                              ; not active: no frame this iter
    jmp .rb_tab_paint
.rb_tab_is_active:
    mov ecx, 1                                ; remember "draw frame after fill"
.rb_tab_paint:
    push rcx
    call set_bar_fg
    mov edi, r12d
    xor esi, esi
    mov edx, r14d
    mov ecx, r14d
    call fill_rect
    pop rcx
    test ecx, ecx
    jz .rb_tab_no_frame
    mov eax, [cfg_active_frame]
    test eax, eax
    jz .rb_tab_no_frame
    call set_bar_fg
    mov edi, r12d
    xor esi, esi
    mov edx, r14d
    mov ecx, r14d
    call outline_rect
.rb_tab_no_frame:
    add r12d, r14d
    add r12d, SQUARE_GAP
.rb_tab_next:
    inc ebx
    jmp .rb_tab_loop
.rb_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ══════════════════════════════════════════════════════════════════════
; Stash — replacement for i3's scratchpad.
;
; `stash` unmaps the focused tab and pushes its XID onto a small LIFO.
; Tile keeps the client tracked (its workspace, colour, etc. are
; preserved) but it's not visible anywhere. `unstash` pops the most-
; recent XID and routes it to the current workspace as the active tab.
; Used in the user's i3 setup for the ff-marionette window — instantly
; hide-and-recall.
; ══════════════════════════════════════════════════════════════════════
action_stash:
    push rbx
    movzx ecx, byte [current_ws]
    test ecx, ecx
    jz .as_done
    dec ecx
    mov ebx, [ws_active_xid + rcx*4]
    test ebx, ebx
    jz .as_done                  ; nothing focused
    mov eax, [stash_count]
    cmp eax, MAX_STASH
    jge .as_done                 ; stash full
    mov [stash_xids + rax*4], ebx
    inc dword [stash_count]
    ; Unmap the focused window from view, but keep it tracked. We mark
    ; it as "stashed" by stealing the highest workspace bit … no, we
    ; don't have that. Simpler: untrack it entirely. unstash will
    ; re-track on the current workspace.
    ;
    ; Find its index, mark expected unmap, send unmap.
    mov eax, ebx
    call find_client_index
    cmp eax, -1
    je .as_pop                   ; shouldn't happen
    mov byte [client_unmap_expected + rax], 1
    mov eax, ebx
    call send_unmap_window
    ; Clear ws_active_xid for current ws and elect a new top.
    movzx eax, byte [current_ws]
    dec eax
    mov dword [ws_active_xid + rax*4], 0
    ; Untrack the stashed XID so it doesn't keep the workspace
    ; populated counter inflated.
    mov eax, ebx
    call untrack_client
    ; Elect a new active tab on the current workspace, if any.
    movzx eax, byte [current_ws]
    call find_top_of_workspace
    movzx edx, byte [current_ws]
    dec edx
    mov [ws_active_xid + rdx*4], eax
    test eax, eax
    jz .as_render
    push rax
    call send_map_window
    pop rax
    call set_input_focus
.as_render:
    call render_bar
    call x11_flush
    pop rbx
    ret
.as_pop:
    dec dword [stash_count]
    pop rbx
    ret
.as_done:
    pop rbx
    ret

; Pop the most-recent XID from the stash and route it to the current
; workspace as the active tab. The popped client is re-tracked
; (workspace, colour reset to default — we don't preserve the previous
; colour because the client_color slot was reclaimed when stash called
; untrack).
action_unstash:
    push rbx
    mov eax, [stash_count]
    test eax, eax
    jz .au_done
    dec eax
    mov ebx, [stash_xids + rax*4]
    mov [stash_count], eax
    test ebx, ebx
    jz .au_done
    ; Re-track on current workspace.
    mov eax, ebx
    call track_client
    ; Configure to fullscreen on the current workspace's pinned output.
    mov edi, ebx
    movzx esi, byte [current_ws]
    call configure_client_for_workspace
    ; Make it the active tab (set_active_tab unmaps the old active and
    ; maps the new one).
    mov eax, ebx
    call set_active_tab
    ; render_bar already called inside set_active_tab.
.au_done:
    pop rbx
    ret

; Bump the focused tab's colour to the next palette index. Wraps around
; back to 0 (= default colour) after the last palette entry, so a tab
; cycles default → palette[0] → palette[1] → ... → default.
tab_color_cycle:
    push rbx
    movzx eax, byte [current_ws]
    test eax, eax
    jz .tcc_done
    dec eax
    mov ebx, [ws_active_xid + rax*4]
    test ebx, ebx
    jz .tcc_done
    mov eax, ebx
    call find_client_index
    cmp eax, -1
    je .tcc_done
    movzx ecx, byte [client_color + rax]
    inc ecx
    movzx edx, byte [cfg_tab_palette_count]
    cmp ecx, edx
    jbe .tcc_store
    xor ecx, ecx                          ; wrap to default
.tcc_store:
    mov [client_color + rax], cl
    call render_bar
    call x11_flush
.tcc_done:
    pop rbx
    ret

; ══════════════════════════════════════════════════════════════════════
; Utility: integer → ASCII. rax = unsigned value, rdi = buffer.
; On return: rdi is advanced past the last digit written, rax = digit count.
; Both zero and nonzero cases advance rdi by the number of digits written.
; ══════════════════════════════════════════════════════════════════════
itoa:
    push rbx
    push r12
    mov rbx, 10
    test rax, rax
    jnz .it_nz
    mov byte [rdi], '0'
    inc rdi
    mov rax, 1
    pop r12
    pop rbx
    ret
.it_nz:
    xor ecx, ecx
.it_loop:
    xor edx, edx
    div rbx
    add dl, '0'
    push rdx
    inc ecx
    test rax, rax
    jnz .it_loop
    mov r12, rcx                 ; preserve digit count through pop loop
.it_pop:
    pop rdx
    mov [rdi], dl
    inc rdi
    loop .it_pop
    mov rax, r12                 ; return digit count
    pop r12
    pop rbx
    ret
