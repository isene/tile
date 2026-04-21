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
%define X11_SET_INPUT_FOCUS     42
%define X11_SEND_EVENT          25

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

; Workspace count and special arg_int sentinels for ACT_WORKSPACE.
%define WS_COUNT        10
%define WS_NEXT_POP     0xff
%define WS_PREV_POP     0xfe
%define WS_BACK_FORTH   0xfd

; Focus and move-tab arg_int sentinels (single byte, also stored in arg_int).
%define FOC_NEXT_TAB    1
%define FOC_PREV_TAB    2
%define MTAB_LEFT       1
%define MTAB_RIGHT      2

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
    db 0                       ; terminator

; Focus arg keyword table for `focus <direction>`.
focus_arg_table:
    db "next-tab", 0
    db FOC_NEXT_TAB, 0
    db "prev-tab", 0
    db FOC_PREV_TAB, 0
    db 0

; move-tab arg keyword table.
mtab_arg_table:
    db "left", 0
    db MTAB_LEFT, 0
    db "right", 0
    db MTAB_RIGHT, 0
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

; Bar reservation (top of screen, in pixels). 0 in phase 1a.
bar_height:          resw 1

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
tmp_buf:             resb 4096
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
    call load_config

    ; Become the WM by selecting substructure-redirect on root.
    call select_substructure_redirect
    call x11_flush
    call check_redirect_ok
    test rax, rax
    jnz .die_redirect

    ; Resolve the ICCCM atoms used for WM_DELETE_WINDOW.
    call intern_wm_atoms

    ; Resolve every bind's keysym to a keycode and grab them on root.
    call resolve_and_grab_binds
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

    ; Read one 32-byte event (X11 always sends events as 32-byte units)
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [x11_read_buf]
    mov rdx, 32
    syscall
    cmp rax, 32
    jl event_loop                ; partial / interrupted — try again

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
    ; Ignore anything else (MapNotify, ConfigureNotify, errors, replies).
    jmp event_loop

.ev_map_request:
    ; Pre-size to fullscreen, then track, then make this the active
    ; tab on the current workspace (set_active_tab unmaps whatever
    ; was previously visible and maps the new client).
    mov eax, [x11_read_buf + 8]
    mov edi, eax
    call configure_client_fullscreen
    mov eax, [x11_read_buf + 8]
    call track_client
    mov eax, [x11_read_buf + 8]
    call set_active_tab
    jmp event_loop

.ev_configure_request:
    ; Honor the request but clamp width/height to screen.
    ; ConfigureRequest layout (32 bytes):
    ;   0: type (23)
    ;   1: stack-mode
    ;   2-3: sequence
    ;   4-7: parent
    ;   8-11: window
    ;   12-15: sibling
    ;   16-17: x
    ;   18-19: y
    ;   20-21: width
    ;   22-23: height
    ;   24-25: border-width
    ;   26-27: value-mask
    ; For phase 1a, we ignore the requested geometry and force fullscreen.
    mov eax, [x11_read_buf + 8]
    mov edi, eax
    call configure_client_fullscreen
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
configure_client_fullscreen:
    push rbx
    push r12
    mov r12d, edi
    movzx eax, word [bar_height]
    mov ebx, eax                 ; bar_height as int

    lea rdi, [tmp_buf]
    mov byte [rdi], X11_CONFIGURE_WINDOW
    mov byte [rdi+1], 0
    mov word [rdi+2], 7          ; length = 3 header + 4 values = 7 words
    mov [rdi+4], r12d            ; window
    mov word [rdi+8], CFG_X | CFG_Y | CFG_WIDTH | CFG_HEIGHT
    mov word [rdi+10], 0         ; pad
    mov dword [rdi+12], 0        ; x = 0
    mov dword [rdi+16], ebx      ; y = bar_height
    movzx eax, word [x11_screen_width]
    mov dword [rdi+20], eax
    movzx eax, word [x11_screen_height]
    sub eax, ebx
    mov dword [rdi+24], eax
    lea rsi, [tmp_buf]
    mov rdx, 28
    call x11_buffer
    inc dword [x11_seq]
    pop r12
    pop rbx
    ret

; eax = window XID
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
    call x11_buffer
    inc dword [x11_seq]
    ret

; eax = window XID. SetInputFocus(window, RevertToParent=2, time=0).
set_input_focus:
    push rax
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_SET_INPUT_FOCUS
    mov byte [rdi+1], 2          ; revert-to = Parent
    mov word [rdi+2], 3
    pop rax
    mov [rdi+4], eax
    mov dword [rdi+8], 0         ; time = CurrentTime
    lea rsi, [tmp_buf]
    mov rdx, 12
    call x11_buffer
    inc dword [x11_seq]
    ret

; eax = window XID. Append to client_xids on the current workspace.
track_client:
    push rbx
    mov ebx, [client_count]
    cmp ebx, MAX_CLIENTS
    jge .tc_full
    mov [client_xids + rbx*4], eax
    movzx ecx, byte [current_ws]
    mov [client_ws + rbx], cl
    mov byte [client_unmap_expected + rbx], 0
    inc dword [client_count]
    ; Bump populated count for the workspace this client lives on.
    movzx ecx, byte [current_ws]
    dec ecx
    inc byte [workspace_populated + rcx]
.tc_full:
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

; eax = window XID. UnmapWindow request.
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
    call x11_buffer
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

; eax = new XID. Make it the active (visible) tab on the current
; workspace. Unmaps whatever was previously active. Idempotent if eax
; is already the active tab.
set_active_tab:
    push rbx
    push r12
    mov r12d, eax                ; new active XID
    movzx ecx, byte [current_ws]
    dec ecx
    mov ebx, [ws_active_xid + rcx*4]
    cmp ebx, r12d
    je .sat_done
    test ebx, ebx
    jz .sat_skip_unmap
    mov eax, ebx
    call find_client_index
    cmp eax, -1
    je .sat_skip_unmap
    mov byte [client_unmap_expected + rax], 1
    mov eax, ebx
    call send_unmap_window
.sat_skip_unmap:
    movzx ecx, byte [current_ws]
    dec ecx
    mov [ws_active_xid + rcx*4], r12d
    mov eax, r12d
    call send_map_window
    mov eax, r12d
    call set_input_focus
    call x11_flush
.sat_done:
    pop r12
    pop rbx
    ret

; eax = XID that has been destroyed or unmapped client-initiated.
; Untracks it, then if it was the active tab on any workspace, re-elects
; a new top for that workspace and (if it's the current ws) makes it
; visible.
client_closed:
    push rbx
    push r12
    mov r12d, eax                ; the dying XID
    mov eax, r12d
    call untrack_client
    xor ebx, ebx                 ; ws index 0..9
.cc_loop:
    cmp ebx, WS_COUNT
    jge .cc_done
    cmp [ws_active_xid + rbx*4], r12d
    jne .cc_next
    ; Stale active tab — find a replacement on this workspace.
    mov eax, ebx
    inc eax                      ; ws number
    call find_top_of_workspace
    mov [ws_active_xid + rbx*4], eax
    test eax, eax
    jz .cc_next                  ; workspace now empty
    movzx edx, byte [current_ws]
    dec edx
    cmp edx, ebx
    jne .cc_next                 ; not the current ws — stays hidden
    push rax
    call send_map_window
    pop rax
    call set_input_focus
.cc_next:
    inc ebx
    jmp .cc_loop
.cc_done:
    call x11_flush
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
    jne .dk_done
    mov edi, -1
    call focus_cycle_tab
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
; map new active".
switch_workspace:
    push rbx
    test edi, edi
    jz .sw_done
    cmp edi, WS_COUNT
    jg .sw_done
    movzx eax, byte [current_ws]
    cmp edi, eax
    je .sw_done
    mov [prev_ws], al
    ; Unmap old workspace's active tab.
    mov ecx, eax
    dec ecx
    mov ebx, [ws_active_xid + rcx*4]
    test ebx, ebx
    jz .sw_no_old
    mov eax, ebx
    call find_client_index
    cmp eax, -1
    je .sw_no_old
    mov byte [client_unmap_expected + rax], 1
    mov eax, ebx
    call send_unmap_window
.sw_no_old:
    mov [current_ws], dil
    ; Map new workspace's active tab (if any).
    mov ecx, edi
    dec ecx
    mov ebx, [ws_active_xid + rcx*4]
    test ebx, ebx
    jz .sw_no_new
    mov eax, ebx
    call send_map_window
    mov eax, ebx
    call set_input_focus
.sw_no_new:
    call x11_flush
.sw_done:
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
; workspace to the target. The window becomes the active tab on the
; target workspace and is unmapped from the current view; the current
; workspace re-elects its next-most-recent client as the new active
; tab.
move_focused_to_workspace:
    push rbx
    push r12
    push r13
    test edi, edi
    jz .mtw_done
    cmp edi, WS_COUNT
    jg .mtw_done
    movzx eax, byte [current_ws]
    cmp edi, eax
    je .mtw_done                  ; same ws — no-op
    mov r13d, edi                 ; target ws
    movzx ecx, byte [current_ws]
    dec ecx
    mov ebx, [ws_active_xid + rcx*4]
    test ebx, ebx
    jz .mtw_done                  ; nothing to move
    mov eax, ebx
    call find_client_index
    cmp eax, -1
    je .mtw_done
    mov r12d, eax                 ; index of moving client
    ; Update populated counters.
    movzx eax, byte [client_ws + r12]
    dec eax
    dec byte [workspace_populated + rax]
    mov [client_ws + r12], r13b
    mov eax, r13d
    dec eax
    inc byte [workspace_populated + rax]
    ; Unmap from current view.
    mov byte [client_unmap_expected + r12], 1
    mov eax, ebx
    call send_unmap_window
    ; Make this client the active tab on the target workspace.
    movzx eax, r13b
    dec eax
    mov [ws_active_xid + rax*4], ebx
    ; Re-elect a new active tab on the source (current) workspace.
    movzx eax, byte [current_ws]
    call find_top_of_workspace    ; eax = new top XID or 0
    movzx edx, byte [current_ws]
    dec edx
    mov [ws_active_xid + rdx*4], eax
    test eax, eax
    jz .mtw_flush
    push rax
    call send_map_window
    pop rax
    call set_input_focus
.mtw_flush:
    call x11_flush
.mtw_done:
    pop r13
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
    ; Compare command against "bind", "exec", "mod"
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
    ; Unknown keyword — silently ignore for now.
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
    cmp ecx, ACT_WORKSPACE
    je .pcl_arg_ws
    cmp ecx, ACT_MOVE_TO
    je .pcl_arg_mt
    cmp ecx, ACT_FOCUS
    je .pcl_arg_focus
    cmp ecx, ACT_MOVE_TAB
    je .pcl_arg_mtab
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
