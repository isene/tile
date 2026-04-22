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
%define MAX_BINDS       64
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
%define DEFAULT_TAB_DIM_FACTOR  40    ; inactive tab brightness, 0..100
%define DEFAULT_BORDER_WIDTH    1     ; pixels of focus border around managed windows
%define DEFAULT_BORDER_FOCUSED   0xffffff
%define DEFAULT_BORDER_UNFOCUSED 0x222222
%define MAX_PALETTE             16
%define WS_TAB_GAP              8     ; pixels of gap between WS and tab squares (legacy; kept for clarity)
%define SQUARE_GAP              2     ; pixels of gap between adjacent squares
%define WS_GROUP_GAP            6     ; extra gap before WS positions 1, 4, 7
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

; Spawn fallback chain for Alt+Return: try glass, then xterm.
glass_path:      db "/usr/local/bin/glass", 0
glass_path_alt:  db "/home/geir/Main/G/GIT-isene/glass/glass", 0
xterm_path:      db "/usr/bin/xterm", 0

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

; XINERAMA extension name (uppercase per X11 convention).
xinerama_name:    db "XINERAMA"
xinerama_name_len equ 8

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

; Default exec command path for the built-in Alt+Return bind, used when
; no ~/.tilerc is found. Same fallback as the phase 1a action.
default_glass_arg:
    db "/home/geir/Main/G/GIT-isene/glass/glass", 0
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

; Inner gap: pixels of padding inside each managed window (so neighbouring
; windows / the bar get visual breathing room). Equivalent to i3's
; `gaps inner N`. Tabs already mean only one window is visible at a time
; in phase 1b.3a, so the gap manifests as a uniform border around the
; active client.
cfg_gap_inner:           resw 1

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
output_count:            resb 1
output_x:                resw MAX_OUTPUTS
output_y:                resw MAX_OUTPUTS
output_w:                resw MAX_OUTPUTS
output_h:                resw MAX_OUTPUTS
ws_pinned_output:        resb WS_COUNT

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
    mov dword [cfg_bar_bg], 0x000000
    mov dword [cfg_tab_default], 0x555555
    mov byte [cfg_tab_dim_factor], DEFAULT_TAB_DIM_FACTOR
    mov dword [cfg_ws_active], 0xffffff
    mov dword [cfg_ws_populated], 0x555555
    mov byte [cfg_tab_palette_count], 0
    mov word [cfg_gap_inner], 0
    mov byte [cfg_border_width], DEFAULT_BORDER_WIDTH
    mov dword [cfg_border_focused], DEFAULT_BORDER_FOCUSED
    mov dword [cfg_border_unfocused], DEFAULT_BORDER_UNFOCUSED
    mov dword [focused_xid], 0
    mov byte [cfg_master_ratio], DEFAULT_MASTER_RATIO
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

    ; Resolve every bind's keysym to a keycode and grab them on root.
    call resolve_and_grab_binds
    call x11_flush

    ; Create the row-of-squares bar window across the top of the screen.
    call create_bar
    call render_bar
    call x11_flush

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
    jle .x11_dead                ; 0 = EOF, negative = -errno (also fatal)
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
    ; Ignore anything else (MapNotify, ConfigureNotify, errors, replies).
    jmp event_loop

.ev_expose:
    ; Expose bytes 8-11 = window. Only redraw if it's our bar window.
    mov eax, [x11_read_buf + 8]
    cmp eax, [bar_window_id]
    jne event_loop
    call render_bar
    jmp event_loop

.x11_dead:
    ; X server connection lost (e.g. xephyr was killed, real X11 crashed).
    ; Exit cleanly rather than spin on a dead socket.
    mov rax, SYS_EXIT
    xor edi, edi
    syscall

.ev_map_request:
    ; New client lands on the current workspace; size it to that
    ; workspace's pinned output before mapping. set_active_tab then
    ; unmaps the previously-visible tab on the same workspace and
    ; maps this one.
    mov eax, [x11_read_buf + 8]
    mov edi, eax
    movzx esi, byte [current_ws]
    call configure_client_for_workspace
    mov eax, [x11_read_buf + 8]
    call track_client
    mov eax, [x11_read_buf + 8]
    call set_active_tab
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
    pop rax
    mov edi, eax
    movzx esi, byte [current_ws]
    call configure_client_for_workspace
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
    call dispatch_keypress
    jmp event_loop

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

    ; Reserve bar height only on the bar's home output (output 0).
    ; Other outputs use their full height. This keeps the bar from
    ; eating pixels out of the external monitor's geometry.
    movzx eax, word [bar_height]
    test r13d, r13d
    jnz .ccfw_no_bar
    add r15d, eax                          ; oy += bar
    sub edx, eax                           ; oh -= bar
.ccfw_no_bar:

    ; Apply inner gap on all four sides.
    movzx eax, word [cfg_gap_inner]
    add r14d, eax                          ; ox += gap
    add r15d, eax                          ; oy += gap
    mov edi, eax
    shl edi, 1                             ; 2*gap
    sub ecx, edi                           ; ow -= 2*gap
    sub edx, edi                           ; oh -= 2*gap

    ; Build ConfigureWindow request: x, y, w, h.
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_CONFIGURE_WINDOW
    mov byte [rdi+1], 0
    mov word [rdi+2], 7                    ; 3 header + 4 values = 7 words
    mov [rdi+4], r12d                      ; window
    mov word [rdi+8], CFG_X | CFG_Y | CFG_WIDTH | CFG_HEIGHT
    mov word [rdi+10], 0
    mov dword [rdi+12], r14d               ; x
    mov dword [rdi+16], r15d               ; y
    mov dword [rdi+20], ecx                ; w
    mov dword [rdi+24], edx                ; h
    lea rsi, [tmp_buf]
    mov rdx, 28
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
    jz .sif_done                          ; nothing to focus
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
.sif_done:
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
    movzx ecx, byte [current_ws]
    mov [client_ws + rbx], cl
    mov byte [client_unmap_expected + rbx], 0
    mov byte [client_color + rbx], 0      ; tab_default colour
    inc dword [client_count]
    ; Bump populated count for the workspace this client lives on.
    movzx ecx, byte [current_ws]
    dec ecx
    inc byte [workspace_populated + rcx]

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
.rrq_loop:
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

; eax = new XID. Make it the active tab on the current workspace.
; In TABBED layout only the active is visible, so we unmap the
; previous active and map the new one (only if the workspace is
; currently shown on its output). In SPLIT layouts every client on
; the workspace is mapped simultaneously, so we just update state
; and re-apply the layout to slot the (possibly-new) client into
; the side-by-side strip arrangement.
;
; Idempotent if eax already equals the workspace's active XID.
set_active_tab:
    push rbx
    push r12
    push r13
    mov r12d, eax                ; new active XID
    movzx r13d, byte [current_ws]
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
    ; ----- TABBED: unmap old, map new, focus new -----
    test ebx, ebx
    jz .sat_t_map
    mov eax, ebx
    call find_client_index
    cmp eax, -1
    je .sat_t_map
    mov byte [client_unmap_expected + rax], 1
    mov eax, ebx
    call send_unmap_window
.sat_t_map:
    mov eax, r12d
    call send_map_window
    mov eax, r12d
    call set_input_focus
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
    movzx ecx, byte [current_ws]
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

    ; Hide everything on the workspace currently visible on this
    ; output (could be a tabbed single window or a split-mode set).
    movzx eax, byte [output_current_ws + r14]
    test eax, eax
    jz .sw_no_old_hide
    call hide_workspace_clients
.sw_no_old_hide:

    ; Make the target workspace visible: update output state then
    ; apply the target's layout (which configures and maps every
    ; client that should be on screen).
    mov [output_current_ws + r14], r12b
    mov eax, r12d
    call apply_workspace_layout
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
    xor ebx, ebx
.awl_t_loop:
    cmp ebx, [client_count]
    jge .awl_t_done
    movzx eax, byte [client_ws + rbx]
    cmp eax, r13d
    jne .awl_t_next
    mov eax, [client_xids + rbx*4]
    cmp eax, r15d
    je .awl_t_show
    ; Hide non-active client (it might have been visible if we just
    ; switched out of split mode).
    mov byte [client_unmap_expected + rbx], 1
    call send_unmap_window
    jmp .awl_t_next
.awl_t_show:
    mov rdi, rax
    mov esi, [rsp + 24]                   ; ws_x  (after 4 pushes)
    mov edx, [rsp + 16]                   ; ws_y
    mov ecx, [rsp + 8]                    ; ws_w
    mov r8d, [rsp + 0]                    ; ws_h
    call configure_window_rect
    ; Re-fetch the XID from memory before send_map_window — both
    ; configure_window_rect and x11_buffer (which it calls) clobber
    ; eax. Same pattern as the SPLIT_H/SPLIT_V branches below.
    mov eax, [client_xids + rbx*4]
    call send_map_window
.awl_t_next:
    inc ebx
    jmp .awl_t_loop
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
    mov qword [config_len], 0

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
parse_workspace_number:
    mov al, [rdi]
    cmp al, '1'
    jb .pwn_check_zero
    cmp al, '9'
    ja .pwn_no
    cmp byte [rdi + 1], 0
    jne .pwn_no                  ; multi-char like "10" not supported here
    sub al, '0'
    movzx eax, al
    ret
.pwn_check_zero:
    cmp al, '0'
    jne .pwn_no
    cmp byte [rdi + 1], 0
    jne .pwn_no
    mov eax, 10
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
parse_config_line:
    push rbx
    push r12
    push r13
    mov r12, rdi
    ; Skip leading whitespace
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_done                 ; blank
    cmp al, '#'
    je .pcl_done                 ; comment
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
    ; bar / palette settings (key = value)
    call .pcl_skip_ws
    cmp byte [r12], '='
    jne .pcl_done                ; not a key=value line, ignore
    inc r12
    call .pcl_skip_ws
    mov rdi, r13
    call apply_setting
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
    mov rdi, r12
    call lookup_ws_arg           ; handles next/prev/back-and-forth
    test eax, eax
    jnz .pcl_ws_have
    mov rdi, r12
    call parse_workspace_number
    test eax, eax
    jz .pcl_pop_mod_done         ; not a number, not a name
.pcl_ws_have:
    mov r8b, al                  ; arg_int
    xor edx, edx                 ; no arg_off
    jmp .pcl_emit
.pcl_arg_mt:
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_pop_mod_done
    mov rdi, r12
    call parse_workspace_number
    test eax, eax
    jz .pcl_pop_mod_done
    mov r8b, al
    xor edx, edx
    jmp .pcl_emit
.pcl_arg_focus:
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_pop_mod_done
    mov rdi, r12
    lea rdx, [focus_arg_table]
    call lookup_packed_byte
    test eax, eax
    jz .pcl_pop_mod_done
    mov r8b, al
    xor edx, edx
    jmp .pcl_emit
.pcl_arg_mtab:
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_pop_mod_done
    mov rdi, r12
    lea rdx, [mtab_arg_table]
    call lookup_packed_byte
    test eax, eax
    jz .pcl_pop_mod_done
    mov r8b, al
    xor edx, edx
    jmp .pcl_emit
.pcl_arg_layout:
    call .pcl_skip_ws
    mov al, [r12]
    test al, al
    je .pcl_pop_mod_done
    mov rdi, r12
    lea rdx, [layout_arg_table]
    call lookup_packed_byte
    test eax, eax
    jz .pcl_pop_mod_done
    mov r8b, al
    xor edx, edx
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
    jmp .pcl_done

.pcl_done:
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
    jmp .as_done

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
.as_done:
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

; eax = source CARD32 0x00RRGGBB. Multiplies each channel by
; cfg_tab_dim_factor / 100 and returns the result in eax. Used to draw
; inactive tab squares dimly while keeping their hue recognisable.
dim_color:
    push rbx
    push r12
    push r13
    push r14
    mov r14d, eax                         ; original 0x00RRGGBB
    movzx r13d, byte [cfg_tab_dim_factor]
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
    mov [rdi+14], ax                      ; y = output_y[0]
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

    ; Workspace squares: fixed 10 slots, right-justified, in the order
    ;   [WS1 WS2 WS3] [WS4 WS5 WS6] [WS7 WS8 WS9] [WS10]
    ; (display positions 0..8 = WS 1..9; display 9 = the "0" key =
    ; internal WS 10 — special; will be the external-monitor pin once
    ; 1c lands). Non-current populated workspaces draw filled in
    ; cfg_ws_populated; the current workspace fills in cfg_ws_active.
    ; Empty workspaces draw as outlines in the same colour so the slot
    ; is always visible. A small WS_GROUP_GAP precedes display positions
    ; 3, 6, 9 to group the bar as [1 2 3] [4 5 6] [7 8 9] [0].
    movzx r14d, word [bar_height]         ; square edge
    ; Compute total WS-strip width: 10 squares + 9 inter-square gaps +
    ; 3 group gaps (one each before slots 3, 6, 9).
    mov eax, r14d
    imul eax, WS_COUNT                    ; 10 * square
    mov ecx, WS_COUNT - 1
    imul ecx, SQUARE_GAP                  ; 9 inter-square gaps
    add eax, ecx
    add eax, 3 * WS_GROUP_GAP             ; 3 group gaps
    movzx ecx, word [output_w]            ; bar lives on output 0
    sub ecx, eax
    test ecx, ecx
    jns .rb_ws_have_x
    xor ecx, ecx                          ; clamp if it doesn't fit
.rb_ws_have_x:
    mov r12d, ecx                         ; cursor x
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
    ; Pick colour: active if this is the current ws, else populated.
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
    jmp .rb_ws_advance
.rb_ws_outline:
    call outline_rect
.rb_ws_advance:
    add r12d, r14d
    add r12d, SQUARE_GAP
    inc r13d
    jmp .rb_ws_loop
.rb_ws_done:

    ; Tabs are left-justified at x=0 so they have their own anchor
    ; (look top-left for tabs, top-right for workspaces).
    movzx r15d, byte [current_ws]
    movzx eax, byte [workspace_populated + r15 - 1]
    test eax, eax
    jz .rb_done                           ; no tabs on this workspace
    xor r12d, r12d                        ; cursor x = 0
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
    je .rb_tab_active
    call dim_color
.rb_tab_active:
    call set_bar_fg
    mov edi, r12d
    xor esi, esi
    mov edx, r14d
    mov ecx, r14d
    call fill_rect
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
