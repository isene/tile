; strip - status bar binary, CHasm suite (phase 2a skeleton).
; x86_64 NASM, no libc, X11 wire protocol over Unix socket.
;
; Phase 2a (this file): X11 connect, override-redirect window across
; the bottom of output 0, core X font load + GC, render hardcoded
; placeholder text on Expose. Proves the foundation; subsequent phases
; add ~/.striprc parsing, segment refresh fork+pipe loop, ANSI SGR
; colour decoding (2b) and XEMBED tray (2c).
;
; Build: nasm -f elf64 strip.asm -o strip.o && ld strip.o -o strip
; Run:   DISPLAY=:9 ./strip   (under tile in Xephyr)

; ══════════════════════════════════════════════════════════════════════
; Syscalls
; ══════════════════════════════════════════════════════════════════════
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_POLL        7
%define SYS_SOCKET      41
%define SYS_CONNECT     42
%define SYS_EXIT        60

%define AF_UNIX         1
%define SOCK_STREAM     1

; ══════════════════════════════════════════════════════════════════════
; X11 opcodes
; ══════════════════════════════════════════════════════════════════════
%define X11_CREATE_WINDOW       1
%define X11_MAP_WINDOW          8
%define X11_OPEN_FONT           45
%define X11_CREATE_GC           55
%define X11_IMAGE_TEXT8         76

%define EV_EXPOSE               12

%define CW_BACK_PIXEL           0x00000002
%define CW_OVERRIDE_REDIRECT    0x00000200
%define CW_EVENT_MASK           0x00000800
%define EXPOSURE_MASK           0x00008000

%define GC_FOREGROUND           0x00000004
%define GC_BACKGROUND           0x00000008
%define GC_FONT                 0x00004000

; ══════════════════════════════════════════════════════════════════════
; Defaults
; ══════════════════════════════════════════════════════════════════════
%define DEFAULT_HEIGHT  22
%define DEFAULT_TOP_OFFSET 10        ; matches tile's default bar_height
%define DEFAULT_BG      0x000000
%define DEFAULT_FG      0xCCCCCC

; ══════════════════════════════════════════════════════════════════════
; Data
; ══════════════════════════════════════════════════════════════════════
section .data

x11_sock_pre:    db "/tmp/.X11-unix/X", 0
auth_name:       db "MIT-MAGIC-COOKIE-1"
auth_name_len    equ 18

; X core font name. "fixed" is the universal alias every X server
; resolves; for real deployment swap for an ISO10646 13px variant.
font_name:       db "fixed"
font_name_len    equ 5

; Placeholder render text — phase 2b replaces with segment output.
hello_text:      db "strip v0.1 (skeleton)"
hello_text_len   equ 21

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
x11_root_visual:     resd 1
x11_root_depth:      resb 1
x11_white_pixel:     resd 1
x11_black_pixel:     resd 1

window_id:           resd 1
gc_id:               resd 1
font_id:             resd 1
strip_height:        resw 1
strip_y:             resw 1

x11_write_buf:       resb 65536
x11_write_pos:       resq 1
x11_read_buf:        resb 4096
conn_setup_buf:      resb 16384
sockaddr_buf:        resb 112
xauth_buf:           resb 4096
xauth_data:          resb 16
xauth_len:           resq 1
tmp_buf:             resb 4096

; ══════════════════════════════════════════════════════════════════════
; Code
; ══════════════════════════════════════════════════════════════════════
section .text
global _start

_start:
    ; argv[0] = [rsp]; argc = ?; envp follows argv + NULL
    mov rdi, [rsp]                        ; argc (used as scratch)
    mov rsi, rsp
    mov rdi, [rsi]                        ; argc
    add rsi, 8                            ; argv
    lea rax, [rdi + 1]
    lea rcx, [rsi + rax*8]                ; envp
    mov [envp], rcx

    call parse_display
    call read_xauthority
    call x11_connect
    test rax, rax
    jnz .die_x11
    call x11_parse_setup

    ; Defaults — phase 2b will override via ~/.striprc.
    ; Strip sits at the very top of output 0; tile reserves the same
    ; height via its `strip_height` config so its own row-of-squares
    ; bar lands immediately below us.
    mov word [strip_height], DEFAULT_HEIGHT
    mov word [strip_y], 0

    call open_core_font
    call create_strip_window
    call create_gc
    call map_strip_window
    call x11_flush

    jmp event_loop

.die_x11:
    mov rax, SYS_EXIT
    mov edi, 1
    syscall

; ──────────────────────────────────────────────────────────────────────
; Event loop — Expose redraws; ignore everything else.
; ──────────────────────────────────────────────────────────────────────
event_loop:
    call x11_flush
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [x11_read_buf]
    mov rdx, 32
    syscall
    test rax, rax
    jle .el_dead
    cmp rax, 32
    jl event_loop
    movzx eax, byte [x11_read_buf]
    and al, 0x7F
    cmp al, EV_EXPOSE
    je .ev_expose
    jmp event_loop
.ev_expose:
    call render_strip
    jmp event_loop
.el_dead:
    mov rax, SYS_EXIT
    xor edi, edi
    syscall

; ──────────────────────────────────────────────────────────────────────
; Open the X core font ("fixed"), store fid in font_id.
; ──────────────────────────────────────────────────────────────────────
open_core_font:
    push rbx
    call alloc_xid
    mov [font_id], eax
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_OPEN_FONT
    mov byte [rdi+1], 0
    mov word [rdi+2], 3 + (font_name_len + 3) / 4
    mov [rdi+4], eax                      ; fid
    mov word [rdi+8], font_name_len
    mov word [rdi+10], 0
    lea rsi, [font_name]
    lea rbx, [tmp_buf + 12]
    mov ecx, font_name_len
.ocf_cp:
    test ecx, ecx
    jz .ocf_pad
    mov al, [rsi]
    mov [rbx], al
    inc rsi
    inc rbx
    dec ecx
    jmp .ocf_cp
.ocf_pad:
    ; Pad to 4-byte boundary.
    mov ecx, font_name_len
    and ecx, 3
    jz .ocf_send
    mov edx, 4
    sub edx, ecx
.ocf_pl:
    mov byte [rbx], 0
    inc rbx
    dec edx
    jnz .ocf_pl
.ocf_send:
    mov rdx, rbx
    lea rsi, [tmp_buf]
    sub rdx, rsi
    call x11_buffer
    inc dword [x11_seq]
    pop rbx
    ret

; ──────────────────────────────────────────────────────────────────────
; Create override-redirect window across the bottom of output 0.
; ──────────────────────────────────────────────────────────────────────
create_strip_window:
    push rbx
    push r12
    call alloc_xid
    mov [window_id], eax
    mov r12d, eax

    lea rdi, [tmp_buf]
    movzx eax, byte [x11_root_depth]
    mov [rdi], al                         ; depth
    mov byte [rdi+1], al                  ; (re-overwritten with opcode below)
    mov word [rdi+2], 11                  ; length: 8 hdr + 3 values
    mov [rdi+4], r12d                     ; wid
    mov eax, [x11_root_window]
    mov [rdi+8], eax                      ; parent
    mov word [rdi+12], 0                  ; x = 0
    movzx eax, word [strip_y]
    mov [rdi+14], ax                      ; y
    movzx eax, word [x11_screen_width]
    mov [rdi+16], ax                      ; w
    movzx eax, word [strip_height]
    mov [rdi+18], ax                      ; h
    mov word [rdi+20], 0                  ; border-width
    mov word [rdi+22], 1                  ; class = InputOutput
    mov dword [rdi+24], 0                 ; visual = CopyFromParent
    mov dword [rdi+28], CW_BACK_PIXEL | CW_OVERRIDE_REDIRECT | CW_EVENT_MASK
    mov dword [rdi+32], DEFAULT_BG        ; back pixel
    mov dword [rdi+36], 1                 ; override-redirect
    mov dword [rdi+40], EXPOSURE_MASK     ; events
    mov byte [rdi], X11_CREATE_WINDOW     ; opcode (was clobbered by depth write)

    lea rsi, [tmp_buf]
    mov rdx, 44
    call x11_buffer
    inc dword [x11_seq]
    pop r12
    pop rbx
    ret

; ──────────────────────────────────────────────────────────────────────
; CreateGC with foreground=DEFAULT_FG, background=DEFAULT_BG, font set.
; ──────────────────────────────────────────────────────────────────────
create_gc:
    push rbx
    call alloc_xid
    mov [gc_id], eax
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_CREATE_GC
    mov byte [rdi+1], 0
    mov word [rdi+2], 7                   ; 4 hdr + 3 values
    mov [rdi+4], eax                      ; cid
    mov ebx, [window_id]
    mov [rdi+8], ebx                      ; drawable
    mov dword [rdi+12], GC_FOREGROUND | GC_BACKGROUND | GC_FONT
    mov dword [rdi+16], DEFAULT_FG
    mov dword [rdi+20], DEFAULT_BG
    mov ebx, [font_id]
    mov [rdi+24], ebx
    lea rsi, [tmp_buf]
    mov rdx, 28
    call x11_buffer
    inc dword [x11_seq]
    pop rbx
    ret

; ──────────────────────────────────────────────────────────────────────
; MapWindow on the strip window so the server displays it.
; ──────────────────────────────────────────────────────────────────────
map_strip_window:
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_MAP_WINDOW
    mov byte [rdi+1], 0
    mov word [rdi+2], 2
    mov eax, [window_id]
    mov [rdi+4], eax
    lea rsi, [tmp_buf]
    mov rdx, 8
    call x11_buffer
    inc dword [x11_seq]
    ret

; ──────────────────────────────────────────────────────────────────────
; Render: ImageText8 at (x=4, y=14) with the placeholder string.
; phase 2b replaces this with iteration over segment output buffers.
; ──────────────────────────────────────────────────────────────────────
render_strip:
    push rbx
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_IMAGE_TEXT8
    mov byte [rdi+1], hello_text_len      ; string length (CARD8)
    mov word [rdi+2], 4 + (hello_text_len + 3) / 4
    mov eax, [window_id]
    mov [rdi+4], eax                      ; drawable
    mov eax, [gc_id]
    mov [rdi+8], eax                      ; gc
    mov word [rdi+12], 4                  ; x
    mov word [rdi+14], 14                 ; y (baseline)
    lea rsi, [hello_text]
    lea rbx, [tmp_buf + 16]
    mov ecx, hello_text_len
.rs_cp:
    test ecx, ecx
    jz .rs_pad
    mov al, [rsi]
    mov [rbx], al
    inc rsi
    inc rbx
    dec ecx
    jmp .rs_cp
.rs_pad:
    mov ecx, hello_text_len
    and ecx, 3
    jz .rs_send
    mov edx, 4
    sub edx, ecx
.rs_pl:
    mov byte [rbx], 0
    inc rbx
    dec edx
    jnz .rs_pl
.rs_send:
    mov rdx, rbx
    lea rsi, [tmp_buf]
    sub rdx, rsi
    call x11_buffer
    inc dword [x11_seq]
    call x11_flush
    pop rbx
    ret

; ══════════════════════════════════════════════════════════════════════
; X11 connect / setup boilerplate (cribbed from tile.asm)
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

    mov dword [x11_seq], 1
    pop r12
    pop rbx
    ret

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

; rax = number, rdi = buffer. Writes ASCII digits, returns rax = count.
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
    mov r12, rcx
.it_pop:
    pop rdx
    mov [rdi], dl
    inc rdi
    loop .it_pop
    mov rax, r12
    pop r12
    pop rbx
    ret
