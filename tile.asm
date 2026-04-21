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

; X11 keysyms we care about
%define XK_q            0x71
%define XK_Q            0x51
%define XK_Return       0xff0d

; Limits
%define MAX_CLIENTS     128

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

; Spawn fallback chain for Mod4+Return: try glass, then xterm.
glass_path:      db "/usr/local/bin/glass", 0
glass_path_alt:  db "/home/geir/Main/G/GIT-isene/glass/glass", 0
xterm_path:      db "/usr/bin/xterm", 0

env_display:     db "DISPLAY=", 0  ; placeholder; tile inherits envp directly

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

; Resolved keycodes for our hardcoded grabs (looked up after GetKeyboardMapping).
key_q_kc:            resb 1
key_return_kc:       resb 1

; Bar reservation (top of screen, in pixels). 0 in phase 1a.
bar_height:          resw 1

; Tracked top-level clients (most recent at the end). Used by Mod4+q to
; kill "the latest" until we have proper focus tracking.
client_xids:         resd MAX_CLIENTS
client_count:        resd 1

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
    call resolve_keycodes

    ; Become the WM by selecting substructure-redirect on root.
    call select_substructure_redirect
    call x11_flush
    ; Read back any error reply for the SelectInput (we should see only
    ; replies — if a BadAccess error arrives, it means another WM holds
    ; the redirect already).
    call check_redirect_ok
    test rax, rax
    jnz .die_redirect

    ; Grab our hardcoded keybinds on the root window.
    call grab_hardcoded_keys
    call x11_flush

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

resolve_keycodes:
    mov eax, XK_q
    call find_keycode_for_keysym
    mov [key_q_kc], al
    mov eax, XK_Return
    call find_keycode_for_keysym
    mov [key_return_kc], al
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

grab_hardcoded_keys:
    ; Phase 1a uses Mod1 (Alt) instead of Mod4 (Win) for dev binds.
    ; Reason: when developing inside windowed Xephyr, the host WM's
    ; passive grabs (e.g. i3's bindsym Mod4+...) fire BEFORE the
    ; Xephyr window can pass the key inward, so tile would never see
    ; Mod4+anything. Real Mod4 binds land in phase 1b alongside the
    ; config parser; until then Alt+ is conflict-free with i3.
    ;
    ;   Alt+Return  -> exec glass (or fallback)
    ;   Alt+q       -> kill latest mapped client
    ;   Alt+Shift+q -> exit tile
    movzx eax, byte [key_return_kc]
    test eax, eax
    jz .ghk_skip_return
    mov edi, eax
    mov esi, MOD_MOD1
    call grab_one_key
.ghk_skip_return:
    movzx eax, byte [key_q_kc]
    test eax, eax
    jz .ghk_skip_q
    mov edi, eax
    mov esi, MOD_MOD1
    call grab_one_key
    movzx eax, byte [key_q_kc]
    mov edi, eax
    mov esi, MOD_MOD1 | MOD_SHIFT
    call grab_one_key
.ghk_skip_q:
    ret

; edi = keycode (8-bit), esi = modifier mask (16-bit)
grab_one_key:
    push rbx
    mov ebx, edi
    mov ecx, esi

    ; X11 GrabKey: opcode=33, owner_events=1, length=4
    ; window=root, modifiers, key, pointer-mode=Async, keyboard-mode=Async, pad(3)
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_GRAB_KEY
    mov byte [rdi+1], 1         ; owner_events
    mov word [rdi+2], 4
    mov eax, [x11_root_window]
    mov [rdi+4], eax
    mov word [rdi+8], cx        ; modifiers
    mov [rdi+10], bl            ; keycode
    mov byte [rdi+11], 1        ; pointer mode = Async
    mov byte [rdi+12], 1        ; keyboard mode = Async
    mov byte [rdi+13], 0
    mov byte [rdi+14], 0
    mov byte [rdi+15], 0
    lea rsi, [tmp_buf]
    mov rdx, 16
    call x11_buffer
    inc dword [x11_seq]

    ; Also grab with NumLock (Mod2) so the binding works when NumLock is on.
    or ecx, MOD_MOD2
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_GRAB_KEY
    mov byte [rdi+1], 1
    mov word [rdi+2], 4
    mov eax, [x11_root_window]
    mov [rdi+4], eax
    mov word [rdi+8], cx
    mov [rdi+10], bl
    mov byte [rdi+11], 1
    mov byte [rdi+12], 1
    mov byte [rdi+13], 0
    mov byte [rdi+14], 0
    mov byte [rdi+15], 0
    lea rsi, [tmp_buf]
    mov rdx, 16
    call x11_buffer
    inc dword [x11_seq]

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
    ; Bytes 4-7: parent window (root); Bytes 8-11: window XID.
    mov eax, [x11_read_buf + 8]
    push rax
    call track_client
    pop rax
    ; Configure to full screen first, then Map.
    mov edi, eax
    call configure_client_fullscreen
    mov eax, [x11_read_buf + 8]
    call send_map_window
    mov eax, [x11_read_buf + 8]
    call set_input_focus
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
    ; Bytes 8-11: window
    mov eax, [x11_read_buf + 8]
    call untrack_client
    jmp event_loop

.ev_destroy_notify:
    mov eax, [x11_read_buf + 8]
    call untrack_client
    jmp event_loop

.ev_key_press:
    ; KeyPress layout: byte 1 = keycode, bytes 28-29 = state (modifiers),
    ; bytes 4-7 = root window, bytes 8-11 = event window.
    movzx eax, byte [x11_read_buf + 1]
    movzx edx, word [x11_read_buf + 28]
    ; Strip locks (NumLock=Mod2, CapsLock=Lock) so binds work either way.
    and edx, ~(MOD_LOCK | MOD_MOD2)
    ; Alt+Return -> exec glass/xterm
    movzx ecx, byte [key_return_kc]
    cmp eax, ecx
    jne .kp_not_return
    cmp edx, MOD_MOD1
    jne .kp_done
    call action_exec_terminal
    jmp .kp_done
.kp_not_return:
    movzx ecx, byte [key_q_kc]
    cmp eax, ecx
    jne .kp_done
    cmp edx, MOD_MOD1 | MOD_SHIFT
    je .kp_exit
    cmp edx, MOD_MOD1
    jne .kp_done
    call action_kill_latest
.kp_done:
    jmp event_loop
.kp_exit:
    mov rax, SYS_EXIT
    xor edi, edi
    syscall

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

; eax = window XID. Append to client_xids if there's room.
track_client:
    push rbx
    mov ebx, [client_count]
    cmp ebx, MAX_CLIENTS
    jge .tc_full
    mov [client_xids + rbx*4], eax
    inc dword [client_count]
.tc_full:
    pop rbx
    ret

; eax = window XID. Remove from client_xids (no-op if not present).
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
    ; Shift down
.uc_shift:
    mov eax, [client_count]
    dec eax
    cmp ebx, eax
    jge .uc_dec
    mov ecx, ebx
    inc ecx
    mov edx, [client_xids + rcx*4]
    mov [client_xids + rbx*4], edx
    inc ebx
    jmp .uc_shift
.uc_dec:
    dec dword [client_count]
.uc_done:
    pop r12
    pop rbx
    ret

action_kill_latest:
    mov eax, [client_count]
    test eax, eax
    jz .akl_none
    dec eax
    mov eax, [client_xids + rax*4]
    ; KillClient(window)
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_KILL_CLIENT
    mov byte [rdi+1], 0
    mov word [rdi+2], 2
    mov [rdi+4], eax
    lea rsi, [tmp_buf]
    mov rdx, 8
    call x11_buffer
    inc dword [x11_seq]
.akl_none:
    ret

; Try glass (system, then dev path), then xterm.
action_exec_terminal:
    mov rax, SYS_FORK
    syscall
    test rax, rax
    jnz .aet_parent             ; child: rax = 0
    ; child
    sub rsp, 16
    lea rax, [glass_path]
    mov [rsp], rax
    mov qword [rsp + 8], 0
    mov rax, SYS_EXECVE
    lea rdi, [glass_path]
    mov rsi, rsp
    mov rdx, [envp]
    syscall
    ; Try alt glass path
    lea rax, [glass_path_alt]
    mov [rsp], rax
    mov rax, SYS_EXECVE
    lea rdi, [glass_path_alt]
    mov rsi, rsp
    mov rdx, [envp]
    syscall
    ; Fallback xterm
    lea rax, [xterm_path]
    mov [rsp], rax
    mov rax, SYS_EXECVE
    lea rdi, [xterm_path]
    mov rsi, rsp
    mov rdx, [envp]
    syscall
    ; All failed
    mov rax, SYS_EXIT
    mov edi, 127
    syscall
.aet_parent:
    ret

; ══════════════════════════════════════════════════════════════════════
; Utility: integer to ASCII (rax = number, rdi = buffer; returns rax = digits)
; ══════════════════════════════════════════════════════════════════════
itoa:
    push rbx
    push r12
    mov r12, rdi
    mov rbx, 10
    test rax, rax
    jnz .it_nz
    mov byte [rdi], '0'
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
    mov rax, rcx
.it_pop:
    pop rdx
    mov [rdi], dl
    inc rdi
    loop .it_pop
    pop r12
    pop rbx
    ret
