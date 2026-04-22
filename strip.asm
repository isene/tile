; strip - status bar binary, CHasm suite (phase 2b.1).
; x86_64 NASM, no libc, X11 wire protocol over Unix socket.
;
; Phase 2b.1 (this file): X11 connect + override-redirect window across
; the top of output 0, X core font, ~/.striprc parser, async segment
; refresh (fork+pipe+exec per segment on its interval), poll-driven
; main loop, render walk left-to-right with single-colour text.
;
; Deferred: ANSI SGR colour decoding (2b.2), XEMBED tray (2c),
; right-justified segments (2b.2 — for now `tray` is a no-op space).
;
; Build: nasm -f elf64 strip.asm -o strip.o && ld strip.o -o strip
; Run:   DISPLAY=:9 ./strip   (under tile in Xephyr)

; ══════════════════════════════════════════════════════════════════════
; Syscalls
; ══════════════════════════════════════════════════════════════════════
%define SYS_READ          0
%define SYS_WRITE         1
%define SYS_OPEN          2
%define SYS_CLOSE         3
%define SYS_POLL          7
%define SYS_PIPE          22
%define SYS_DUP2          33
%define SYS_SOCKET        41
%define SYS_CONNECT       42
%define SYS_FORK          57
%define SYS_EXECVE        59
%define SYS_EXIT          60
%define SYS_WAIT4         61
%define SYS_CLOCK_GETTIME 228

%define CLOCK_REALTIME    0
%define WNOHANG           1

%define AF_UNIX           1
%define SOCK_STREAM       1

%define POLLIN            0x0001
%define POLLERR           0x0008
%define POLLHUP           0x0010

; ══════════════════════════════════════════════════════════════════════
; X11 opcodes / constants
; ══════════════════════════════════════════════════════════════════════
%define X11_CREATE_WINDOW       1
%define X11_MAP_WINDOW          8
%define X11_CREATE_PIXMAP       53
%define X11_OPEN_FONT           45
%define X11_CREATE_GC           55
%define X11_COPY_AREA           62
%define X11_POLY_FILL_RECT      70
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
; Defaults / limits
; ══════════════════════════════════════════════════════════════════════
%define DEFAULT_HEIGHT      22
; Pixel values include the alpha byte (high 8 bits = 0xFF) so they
; render opaque on depth-32 ARGB visuals. On depth-24 the high byte is
; just padding — harmless.
%define DEFAULT_BG          0xFF000000
%define DEFAULT_FG          0xFFCCCCCC
%define DEFAULT_FONT_BASELINE 14
%define CHAR_WIDTH          7        ; "fixed" 6x13 char advance (rough)

%define MAX_SEGMENTS        32
%define SEG_STRIDE          128
%define SEG_NAME_LEN        16
%define SEG_OUT_LEN         96
%define ARG_POOL_SIZE       8192
%define CFG_BUF_SIZE        8192
%define MAX_POLL_FDS        (MAX_SEGMENTS + 1)

; Per-segment record (SEG_STRIDE = 128 bytes):
;   +  0  name[16]
;   + 16  output[96]
;   +112  output_len  (uint8)
;   +113  pad
;   +116  cmd_off     (uint32)   offset into arg_pool
;   +120  interval_s  (uint32)   0 = static (run once)
;   +120 wait, actually let me re-pack:
;   +  0  name[16]
;   + 16  output[SEG_OUT_LEN=96]
;   +112  cmd_off     (uint32)
;   +116  interval_s  (uint32)
;   +120  next_run    (uint32)   unix seconds (low 32 bits is plenty)
;   +124  pid         (int32)    live child pid; 0 = none
;   wait — I need pipe_fd too, can't fit in 128. Let me use SEG_STRIDE=144.
;   Recompute: 16 name + 96 output + 4 + 4 + 8 + 4 + 4 = 136. Round to 144.

; ══════════════════════════════════════════════════════════════════════
; Data
; ══════════════════════════════════════════════════════════════════════
section .data

x11_sock_pre:    db "/tmp/.X11-unix/X", 0
auth_name:       db "MIT-MAGIC-COOKIE-1"
auth_name_len    equ 18

font_name:       db "fixed"
font_name_len    equ 5

striprc_suffix:  db "/.striprc", 0

; Default exec arg vectors for fork_segment.
sh_path:         db "/bin/sh", 0
sh_dash_c:       db "-c", 0

; Empty placeholder for segments awaiting first run.
empty_str:       db " ", 0

; ══════════════════════════════════════════════════════════════════════
; BSS
; ══════════════════════════════════════════════════════════════════════
section .bss

%define SEG_OFF_NAME      0
%define SEG_OFF_OUTPUT    16
%define SEG_OFF_OUT_LEN   112      ; uint8
%define SEG_OFF_CMD_OFF   116      ; uint32
%define SEG_OFF_INTERVAL  120      ; uint32
%define SEG_OFF_NEXT_RUN  124      ; uint32 unix seconds
%define SEG_OFF_PID       128      ; int32 (0 = none)
%define SEG_OFF_PIPE_FD   132      ; int32 (-1 = none)
%define SEG_OFF_FLAGS     136      ; uint8 (bit 0: dirty since last render)
%define SEG_STRIDE_REAL   144

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
pixmap_id:           resd 1
gc_id:               resd 1            ; text GC: fg=cfg_fg, bg=cfg_bg
fill_gc_id:          resd 1            ; fill GC: fg=cfg_bg (used to clear)
font_id:             resd 1
strip_height:        resw 1
strip_y:             resw 1
cfg_bg:              resd 1
cfg_fg:              resd 1
strip_dirty:         resb 1            ; non-zero → re-render needed

; Segment storage.
segments:            resb MAX_SEGMENTS * SEG_STRIDE_REAL
segment_count:       resd 1

arg_pool:            resb ARG_POOL_SIZE
arg_pool_pos:        resd 1

config_buf:          resb CFG_BUF_SIZE
config_len:          resq 1
config_path:         resb 512

; Poll fd array: x11_fd at slot 0, then one slot per live segment child.
; struct pollfd { int fd; short events; short revents; } = 8 bytes.
poll_fds:            resb MAX_POLL_FDS * 8
poll_seg_idx:        resd MAX_POLL_FDS    ; segment index for each pollfd (-1 for x11)

; Read-from-pipe scratch.
pipe_scratch:        resb 256

; Wait4 status output.
wait_status:         resd 1

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
    mov rsi, rsp
    mov rdi, [rsi]
    add rsi, 8
    lea rax, [rdi + 1]
    lea rcx, [rsi + rax*8]
    mov [envp], rcx

    call parse_display
    call read_xauthority
    call x11_connect
    test rax, rax
    jnz .die
    call x11_parse_setup

    ; Defaults.
    mov word [strip_height], DEFAULT_HEIGHT
    mov word [strip_y], 0
    mov dword [cfg_bg], DEFAULT_BG
    mov dword [cfg_fg], DEFAULT_FG
    mov dword [arg_pool_pos], 1
    mov byte [arg_pool], 0
    mov dword [segment_count], 0

    call load_striprc

    call open_core_font
    call create_strip_window
    call create_pixmap
    call create_gc
    call map_strip_window
    mov byte [strip_dirty], 1
    call x11_flush

    ; Mark all segments due now.
    call seed_next_runs

    jmp main_loop

.die:
    mov rax, SYS_EXIT
    mov edi, 1
    syscall

; ══════════════════════════════════════════════════════════════════════
; Main loop: poll x11 + live segment pipes; on timeout, refresh-due
; segments. On any output change, redraw.
; ══════════════════════════════════════════════════════════════════════
main_loop:
    call x11_flush
    call build_poll_set                   ; returns rcx = nfds
    push rcx                              ; save across compute_timeout_ms
    call compute_timeout_ms               ; eax = timeout ms
    pop rcx
    mov edx, eax
    mov esi, ecx
    mov rax, SYS_POLL
    lea rdi, [poll_fds]
    syscall
    test rax, rax
    js main_loop                          ; EINTR — re-poll

    call drain_ready_fds
    call refresh_due_segments
    call render_strip
    jmp main_loop

; Build poll_fds[]: slot 0 = x11_fd, then one slot per segment with
; an open pipe. Returns rcx = number of fds.
build_poll_set:
    push rbx
    push r12
    push r13
    ; Slot 0: x11_fd, POLLIN.
    mov eax, [x11_fd]
    mov [poll_fds + 0], eax
    mov word [poll_fds + 4], POLLIN
    mov word [poll_fds + 6], 0
    mov dword [poll_seg_idx + 0], -1

    mov ecx, 1                            ; current nfds
    xor ebx, ebx                          ; segment iterator
.bps_loop:
    cmp ebx, [segment_count]
    jge .bps_done
    mov rax, rbx
    imul rax, SEG_STRIDE_REAL
    lea r12, [segments + rax]
    mov r13d, [r12 + SEG_OFF_PIPE_FD]
    cmp r13d, 0
    jl .bps_next                          ; -1 = no live child
    mov eax, ecx
    shl eax, 3                            ; nfds * 8
    mov [poll_fds + rax], r13d
    mov word [poll_fds + rax + 4], POLLIN
    mov word [poll_fds + rax + 6], 0
    mov [poll_seg_idx + rcx*4], ebx
    inc ecx
.bps_next:
    inc ebx
    jmp .bps_loop
.bps_done:
    pop r13
    pop r12
    pop rbx
    ret

; Compute the poll timeout in ms = max(0, min(1000, ms_until_earliest_due)).
compute_timeout_ms:
    push rbx
    push r12
    call now_seconds                      ; rax = unix seconds
    mov rbx, rax
    mov r12d, 0xFFFFFFFF                  ; sentinel: "no deadline"
    xor ecx, ecx
.cmt_loop:
    cmp ecx, [segment_count]
    jge .cmt_done
    mov rax, rcx
    imul rax, SEG_STRIDE_REAL
    lea rdi, [segments + rax]
    ; Skip static segments (interval == 0) once they have a pid history.
    cmp dword [rdi + SEG_OFF_INTERVAL], 0
    je .cmt_next
    ; Skip if a child is already in flight.
    cmp dword [rdi + SEG_OFF_PID], 0
    jne .cmt_next
    mov eax, [rdi + SEG_OFF_NEXT_RUN]
    cmp eax, ebx
    ja .cmt_have                          ; future
    xor eax, eax                          ; due now
    jmp .cmt_compare
.cmt_have:
    sub eax, ebx                          ; secs until due
.cmt_compare:
    cmp eax, r12d
    jae .cmt_next
    mov r12d, eax
.cmt_next:
    inc ecx
    jmp .cmt_loop
.cmt_done:
    cmp r12d, 0xFFFFFFFF
    jne .cmt_have_any
    mov eax, 1000                         ; nothing due — poll for 1s
    jmp .cmt_ret
.cmt_have_any:
    cmp r12d, 1
    jl .cmt_zero
    mov eax, r12d
    imul eax, 1000
    cmp eax, 1000
    jle .cmt_ret
    mov eax, 1000
    jmp .cmt_ret
.cmt_zero:
    xor eax, eax                          ; due now → poll wakes immediately
.cmt_ret:
    pop r12
    pop rbx
    ret

; Drain every pollfd slot with revents != 0. For x11_fd, dispatch one
; event. For segment pipes, read into segment output buffer; on EOF
; or HUP, finalize the child.
drain_ready_fds:
    push rbx
    push r12
    push r13
    xor ebx, ebx
.drf_loop:
    ; Only walk the poll set we built. We re-call build_poll_set indirectly
    ; by using nfds = the slot we wrote into during build (we don't store
    ; nfds; just iterate until poll_fds entry has fd=0 OR we exceed MAX).
    cmp ebx, MAX_POLL_FDS
    jge .drf_done
    mov rax, rbx
    shl rax, 3
    mov edi, [poll_fds + rax]
    test edi, edi
    jz .drf_done
    movzx ecx, word [poll_fds + rax + 6]  ; revents
    test ecx, ecx
    jz .drf_next
    mov r12d, [poll_seg_idx + rbx*4]
    cmp r12d, -1
    je .drf_x11
    ; Segment pipe.
    mov edi, r12d
    mov esi, ecx
    call drain_segment_pipe
    jmp .drf_next
.drf_x11:
    ; Read one X11 event (32 bytes).
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [x11_read_buf]
    mov rdx, 32
    syscall
    cmp rax, 32
    jl .drf_next
    movzx eax, byte [x11_read_buf]
    and al, 0x7F
    cmp al, EV_EXPOSE
    jne .drf_next
    mov byte [strip_dirty], 1
.drf_next:
    inc ebx
    jmp .drf_loop
.drf_done:
    ; Reap any zombies (children that closed their pipe).
    call reap_segment_children
    pop r13
    pop r12
    pop rbx
    ret

; edi = segment index, esi = revents bitmask. Reads available bytes
; from the segment's pipe into its output buffer; on POLLHUP/POLLERR
; or read==0, closes the pipe and waits for the child.
drain_segment_pipe:
    push rbx
    push r12
    push r13
    push r14
    mov r14d, esi                         ; revents
    mov rax, rdi
    imul rax, SEG_STRIDE_REAL
    lea r12, [segments + rax]
    mov r13d, [r12 + SEG_OFF_PIPE_FD]
    cmp r13d, 0
    jl .dsp_done

    ; Read up to 256 bytes into pipe_scratch.
    mov rax, SYS_READ
    mov rdi, r13
    lea rsi, [pipe_scratch]
    mov rdx, 256
    syscall

    cmp rax, 0
    jle .dsp_close                        ; 0 = EOF, <0 = error

    ; Append (truncating to SEG_OUT_LEN-1) into segment output.
    movzx ebx, byte [r12 + SEG_OFF_OUT_LEN]
    mov ecx, eax                          ; bytes read
    xor edi, edi
.dsp_copy:
    cmp edi, ecx
    jge .dsp_copied
    cmp ebx, SEG_OUT_LEN - 1
    jge .dsp_copied
    movzx edx, byte [pipe_scratch + rdi]
    ; Drop newlines / control chars (keep space..~).
    cmp dl, 32
    jb .dsp_skip_byte
    cmp dl, 126
    ja .dsp_skip_byte
    mov [r12 + SEG_OFF_OUTPUT + rbx], dl
    inc ebx
.dsp_skip_byte:
    inc edi
    jmp .dsp_copy
.dsp_copied:
    mov [r12 + SEG_OFF_OUT_LEN], bl
    mov byte [r12 + SEG_OFF_FLAGS], 1     ; dirty
    mov byte [strip_dirty], 1
    ; If revents indicated HUP/ERR alongside the data, close.
    test r14d, POLLHUP | POLLERR
    jnz .dsp_close
    jmp .dsp_done

.dsp_close:
    ; Close the pipe; child reaping happens in reap_segment_children.
    mov rax, SYS_CLOSE
    mov edi, r13d
    syscall
    mov dword [r12 + SEG_OFF_PIPE_FD], -1
    mov byte [r12 + SEG_OFF_FLAGS], 1     ; dirty regardless
    mov byte [strip_dirty], 1
.dsp_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Walk segments: any with pid != 0 and pipe_fd == -1 → wait4(WNOHANG)
; to reap. If WNOHANG returns 0 (still alive), leave for next tick.
reap_segment_children:
    push rbx
    push r12
    xor ebx, ebx
.rsc_loop:
    cmp ebx, [segment_count]
    jge .rsc_done
    mov rax, rbx
    imul rax, SEG_STRIDE_REAL
    lea r12, [segments + rax]
    cmp dword [r12 + SEG_OFF_PID], 0
    je .rsc_next
    cmp dword [r12 + SEG_OFF_PIPE_FD], -1
    jne .rsc_next                         ; pipe still open, child must still be live
    mov rax, SYS_WAIT4
    mov edi, [r12 + SEG_OFF_PID]
    lea rsi, [wait_status]
    mov edx, WNOHANG
    xor r10d, r10d
    syscall
    test rax, rax
    jle .rsc_next                         ; 0 = still alive, <0 = error
    mov dword [r12 + SEG_OFF_PID], 0
.rsc_next:
    inc ebx
    jmp .rsc_loop
.rsc_done:
    pop r12
    pop rbx
    ret

; Walk segments: for each with no live child whose next_run <= now,
; fork+pipe+exec and update next_run.
refresh_due_segments:
    push rbx
    push r12
    push r13
    call now_seconds
    mov r13, rax                          ; now (seconds, 64-bit but only low 32 used)
    xor ebx, ebx
.rds_loop:
    cmp ebx, [segment_count]
    jge .rds_done
    mov rax, rbx
    imul rax, SEG_STRIDE_REAL
    lea r12, [segments + rax]
    ; Skip if a child is in flight.
    cmp dword [r12 + SEG_OFF_PID], 0
    jne .rds_next
    ; Skip static segments that already ran.
    cmp dword [r12 + SEG_OFF_INTERVAL], 0
    jne .rds_check_due
    ; Static: only run if next_run = 0 (never ran).
    cmp dword [r12 + SEG_OFF_NEXT_RUN], 0
    jne .rds_next
    jmp .rds_fire
.rds_check_due:
    mov eax, [r12 + SEG_OFF_NEXT_RUN]
    cmp eax, r13d
    ja .rds_next                          ; future
.rds_fire:
    mov edi, ebx
    call fork_segment
    ; Schedule next_run.
    mov ecx, [r12 + SEG_OFF_INTERVAL]
    test ecx, ecx
    jnz .rds_set_interval
    mov dword [r12 + SEG_OFF_NEXT_RUN], 0xFFFFFFFF   ; static: never again
    jmp .rds_next
.rds_set_interval:
    mov eax, r13d
    add eax, ecx
    mov [r12 + SEG_OFF_NEXT_RUN], eax
.rds_next:
    inc ebx
    jmp .rds_loop
.rds_done:
    pop r13
    pop r12
    pop rbx
    ret

; edi = segment index. Allocate a pipe; fork. In child: dup write end
; over stdout, close everything else, exec /bin/sh -c <cmd>. In parent:
; close write end, store pid + read end on the segment record, reset
; output buffer.
fork_segment:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov rax, r12
    imul rax, SEG_STRIDE_REAL
    lea r13, [segments + rax]

    ; Reset output buffer for fresh capture.
    mov byte [r13 + SEG_OFF_OUT_LEN], 0

    ; pipe(int fds[2])
    sub rsp, 16
    mov rax, SYS_PIPE
    mov rdi, rsp
    syscall
    test rax, rax
    js .fs_pipe_err
    mov ebx, [rsp + 0]                    ; read end
    mov ecx, [rsp + 4]                    ; write end
    add rsp, 16
    push rcx                              ; save write end across fork

    mov rax, SYS_FORK
    syscall
    test rax, rax
    js .fs_fork_err
    jz .fs_child

    ; Parent.
    pop rcx                               ; write end
    mov [r13 + SEG_OFF_PID], eax
    mov [r13 + SEG_OFF_PIPE_FD], ebx      ; read end goes on segment
    mov rax, SYS_CLOSE                    ; close write end (only child needs it)
    mov edi, ecx
    syscall
    pop r13
    pop r12
    pop rbx
    ret

.fs_child:
    ; Child: dup write end → stdout (fd 1).
    pop rcx                               ; write end (saved across fork)
    mov rax, SYS_DUP2
    mov edi, ecx
    mov esi, 1
    syscall
    mov rax, SYS_CLOSE
    mov edi, ebx                          ; close read end
    syscall
    cmp ecx, 1
    je .fs_no_close_w
    mov rax, SYS_CLOSE
    mov edi, ecx
    syscall
.fs_no_close_w:
    ; Build argv = ["/bin/sh", "-c", cmd, NULL] on the stack.
    sub rsp, 32
    lea rax, [sh_path]
    mov [rsp + 0], rax
    lea rax, [sh_dash_c]
    mov [rsp + 8], rax
    mov eax, [r13 + SEG_OFF_CMD_OFF]
    lea rdi, [arg_pool]
    add rdi, rax
    mov [rsp + 16], rdi
    mov qword [rsp + 24], 0
    mov rax, SYS_EXECVE
    lea rdi, [sh_path]
    mov rsi, rsp
    mov rdx, [envp]
    syscall
    ; If we get here, exec failed.
    mov rax, SYS_EXIT
    mov edi, 127
    syscall

.fs_fork_err:
    pop rcx                               ; drop write end
    mov rax, SYS_CLOSE
    mov edi, ebx                          ; close read end
    syscall
    mov rax, SYS_CLOSE
    mov edi, ecx                          ; close write end
    syscall
    pop r13
    pop r12
    pop rbx
    ret
.fs_pipe_err:
    add rsp, 16
    pop r13
    pop r12
    pop rbx
    ret

; Mark every segment as due now.
seed_next_runs:
    push rbx
    xor ebx, ebx
.snr_loop:
    cmp ebx, [segment_count]
    jge .snr_done
    mov rax, rbx
    imul rax, SEG_STRIDE_REAL
    lea rdi, [segments + rax]
    mov dword [rdi + SEG_OFF_NEXT_RUN], 0
    mov dword [rdi + SEG_OFF_PID], 0
    mov dword [rdi + SEG_OFF_PIPE_FD], -1
    mov byte [rdi + SEG_OFF_OUT_LEN], 0
    mov byte [rdi + SEG_OFF_FLAGS], 0
    inc ebx
    jmp .snr_loop
.snr_done:
    pop rbx
    ret

; Returns rax = unix seconds (CLOCK_REALTIME).
now_seconds:
    sub rsp, 16
    mov rax, SYS_CLOCK_GETTIME
    mov rdi, CLOCK_REALTIME
    mov rsi, rsp
    syscall
    mov rax, [rsp]
    add rsp, 16
    ret

; CreatePixmap matching the strip window dimensions. All rendering
; happens to the pixmap; a single CopyArea at the end of render_strip
; blits it to the window — eliminates flicker from multi-request draws.
create_pixmap:
    push rbx
    call alloc_xid
    mov [pixmap_id], eax
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_CREATE_PIXMAP
    movzx ebx, byte [x11_root_depth]
    mov [rdi+1], bl                       ; depth
    mov word [rdi+2], 4                   ; length
    mov [rdi+4], eax                      ; pid
    mov eax, [window_id]
    mov [rdi+8], eax                      ; drawable (window)
    movzx eax, word [x11_screen_width]
    mov [rdi+12], ax                      ; width
    movzx eax, word [strip_height]
    mov [rdi+14], ax                      ; height
    lea rsi, [tmp_buf]
    mov rdx, 16
    call x11_buffer
    inc dword [x11_seq]
    pop rbx
    ret

; Helper used by render_strip: render one segment's text on the pixmap
; at (edi=x, esi=y), data at rdx (NUL-terminated, capped at SEG_OUT_LEN).
; Mirrors image_text8 but targets pixmap_id instead of window_id.
image_text8_pixmap:
    push rcx
    push rdx
    xor ecx, ecx
.it8p_len:
    cmp ecx, SEG_OUT_LEN
    jge .it8p_have
    cmp byte [rdx + rcx], 0
    je .it8p_have
    inc ecx
    jmp .it8p_len
.it8p_have:
    pop rdx
    push rdx
    cmp ecx, 255
    jle .it8p_ok
    mov ecx, 255
.it8p_ok:
    push rbx
    lea rbx, [tmp_buf]
    mov byte [rbx], X11_IMAGE_TEXT8
    mov byte [rbx+1], cl
    mov eax, ecx
    add eax, 3
    shr eax, 2
    add eax, 4
    mov [rbx+2], ax
    mov eax, [pixmap_id]
    mov [rbx+4], eax
    mov eax, [gc_id]
    mov [rbx+8], eax
    mov [rbx+12], di
    mov [rbx+14], si
    add rbx, 16
    mov rsi, rdx
    push rcx
    xor edx, edx
.it8p_cp:
    cmp edx, ecx
    jge .it8p_pad
    mov al, [rsi + rdx]
    mov [rbx], al
    inc rbx
    inc edx
    jmp .it8p_cp
.it8p_pad:
    pop rcx
    mov edx, ecx
    and edx, 3
    jz .it8p_send
    mov eax, 4
    sub eax, edx
.it8p_pl:
    mov byte [rbx], 0
    inc rbx
    dec eax
    jnz .it8p_pl
.it8p_send:
    mov rdx, rbx
    lea rsi, [tmp_buf]
    sub rdx, rsi
    call x11_buffer
    inc dword [x11_seq]
    pop rbx
    pop rdx
    pop rcx
    ret

; ══════════════════════════════════════════════════════════════════════
; Render: draw to off-screen Pixmap, then CopyArea Pixmap → Window in
; a single request. Skipped entirely when strip_dirty == 0.
;
; Any segment whose drain_segment_pipe flagged dirty also aggregates
; into strip_dirty; Expose events set it; segment fork does too.
; ══════════════════════════════════════════════════════════════════════
render_strip:
    cmp byte [strip_dirty], 0
    je .rs_skip
    push rbx
    push r12
    push r13

    ; PolyFillRectangle on pixmap to clear it (using bg-coloured GC).
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_POLY_FILL_RECT
    mov byte [rdi+1], 0
    mov word [rdi+2], 5
    mov eax, [pixmap_id]
    mov [rdi+4], eax
    mov eax, [fill_gc_id]
    mov [rdi+8], eax
    mov word [rdi+12], 0
    mov word [rdi+14], 0
    movzx eax, word [x11_screen_width]
    mov [rdi+16], ax
    movzx eax, word [strip_height]
    mov [rdi+18], ax
    lea rsi, [tmp_buf]
    mov rdx, 20
    call x11_buffer
    inc dword [x11_seq]

    ; Walk segments: render text concatenated with single-space separator.
    mov r12d, 4                           ; running x in pixels
    xor ebx, ebx
.rs_loop:
    cmp ebx, [segment_count]
    jge .rs_copy
    mov rax, rbx
    imul rax, SEG_STRIDE_REAL
    lea r13, [segments + rax]
    movzx ecx, byte [r13 + SEG_OFF_OUT_LEN]
    test ecx, ecx
    jz .rs_next
    mov edi, r12d
    mov esi, DEFAULT_FONT_BASELINE
    lea rdx, [r13 + SEG_OFF_OUTPUT]
    call image_text8_pixmap
    movzx eax, byte [r13 + SEG_OFF_OUT_LEN]
    inc eax
    imul eax, CHAR_WIDTH
    add r12d, eax
    ; Reset per-segment dirty bit (aggregate on strip_dirty already covers it).
    mov byte [r13 + SEG_OFF_FLAGS], 0
.rs_next:
    inc ebx
    jmp .rs_loop

.rs_copy:
    ; CopyArea(src=pixmap, dst=window, gc, src(0,0), dst(0,0), w, h).
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_COPY_AREA
    mov byte [rdi+1], 0
    mov word [rdi+2], 7
    mov eax, [pixmap_id]
    mov [rdi+4], eax
    mov eax, [window_id]
    mov [rdi+8], eax
    mov eax, [gc_id]
    mov [rdi+12], eax
    mov word [rdi+16], 0
    mov word [rdi+18], 0
    mov word [rdi+20], 0
    mov word [rdi+22], 0
    movzx eax, word [x11_screen_width]
    mov [rdi+24], ax
    movzx eax, word [strip_height]
    mov [rdi+26], ax
    lea rsi, [tmp_buf]
    mov rdx, 28
    call x11_buffer
    inc dword [x11_seq]
    call x11_flush
    mov byte [strip_dirty], 0

    pop r13
    pop r12
    pop rbx
.rs_skip:
    ret

; edi = x, esi = y, rdx = ptr to text; assumes text terminates at NUL
; OR caller separately knows length. Reads length from segment record
; via an alternative call. For simplicity here we re-receive length
; by scanning to NUL OR cap at SEG_OUT_LEN.
;
; Actually, simpler signature: edi=x, esi=y, rdx=ptr, rcx=length.
; Refactor to take len explicitly (we have it in caller).
image_text8:
    ; (refactored — see image_text8_n)
    push rcx
    push rdx
    ; Determine length: walk until NUL or SEG_OUT_LEN.
    xor ecx, ecx
.it8_len:
    cmp ecx, SEG_OUT_LEN
    jge .it8_have
    cmp byte [rdx + rcx], 0
    je .it8_have
    inc ecx
    jmp .it8_len
.it8_have:
    pop rdx
    push rdx
    ; ecx = len (CARD8). Build the request.
    cmp ecx, 255
    jle .it8_ok
    mov ecx, 255
.it8_ok:
    push rbx
    lea rbx, [tmp_buf]
    mov byte [rbx], X11_IMAGE_TEXT8
    mov byte [rbx+1], cl                  ; string len
    mov eax, ecx
    add eax, 3
    shr eax, 2
    add eax, 4
    mov [rbx+2], ax                       ; req length in 4-byte words
    mov eax, [window_id]
    mov [rbx+4], eax
    mov eax, [gc_id]
    mov [rbx+8], eax
    mov [rbx+12], di                      ; x
    mov [rbx+14], si                      ; y
    add rbx, 16
    mov rsi, rdx                          ; src text
    push rcx
    xor edx, edx
.it8_cp:
    cmp edx, ecx
    jge .it8_pad
    mov al, [rsi + rdx]
    mov [rbx], al
    inc rbx
    inc edx
    jmp .it8_cp
.it8_pad:
    pop rcx
    mov edx, ecx
    and edx, 3
    jz .it8_send
    mov eax, 4
    sub eax, edx
.it8_pl:
    mov byte [rbx], 0
    inc rbx
    dec eax
    jnz .it8_pl
.it8_send:
    mov rdx, rbx
    lea rsi, [tmp_buf]
    sub rdx, rsi
    call x11_buffer
    inc dword [x11_seq]
    pop rbx
    pop rdx
    pop rcx
    ret

; ══════════════════════════════════════════════════════════════════════
; ~/.striprc parsing
; ══════════════════════════════════════════════════════════════════════

; Build $HOME/.striprc into config_path; load file into config_buf.
load_striprc:
    push rbx
    push r12
    push r13
    ; HOME lookup.
    mov rdi, [envp]
.lsr_home_loop:
    mov rax, [rdi]
    test rax, rax
    jz .lsr_done                          ; no HOME
    cmp dword [rax], 'HOME'
    jne .lsr_home_next
    cmp byte [rax+4], '='
    jne .lsr_home_next
    lea rsi, [rax + 5]
    jmp .lsr_have_home
.lsr_home_next:
    add rdi, 8
    jmp .lsr_home_loop
.lsr_have_home:
    lea rdi, [config_path]
.lsr_cp_home:
    mov al, [rsi]
    test al, al
    jz .lsr_append
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .lsr_cp_home
.lsr_append:
    lea rsi, [striprc_suffix]
.lsr_cp_suf:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .lsr_open
    inc rsi
    inc rdi
    jmp .lsr_cp_suf
.lsr_open:
    mov rax, SYS_OPEN
    lea rdi, [config_path]
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .lsr_done
    mov rbx, rax
    mov rax, SYS_READ
    mov rdi, rbx
    lea rsi, [config_buf]
    mov rdx, CFG_BUF_SIZE - 1
    syscall
    test rax, rax
    jle .lsr_close
    mov [config_len], rax
    mov byte [config_buf + rax], 0
.lsr_close:
    mov rax, SYS_CLOSE
    mov rdi, rbx
    syscall
    ; Walk lines.
    lea r12, [config_buf]
    mov r13, [config_len]
    lea r13, [r12 + r13]                  ; end ptr
.lsr_line_start:
    cmp r12, r13
    jge .lsr_done
    mov rdi, r12
.lsr_find_lf:
    cmp r12, r13
    jge .lsr_terminate
    mov al, [r12]
    cmp al, 10
    je .lsr_terminate
    inc r12
    jmp .lsr_find_lf
.lsr_terminate:
    mov byte [r12], 0
    push r12
    push r13
    call parse_striprc_line               ; rdi already = line ptr
    pop r13
    pop r12
    inc r12
    jmp .lsr_line_start
.lsr_done:
    pop r13
    pop r12
    pop rbx
    ret

; rdi = NUL-terminated line. Recognise:
;   #...                      comment / blank → ignore
;   key = value               settings (height, bg, fg, top_offset)
;   segment NAME [CMD [INTERVAL]]   register a segment
parse_striprc_line:
    push rbx
    push r12
    push r13
    mov r12, rdi
    call .skip_ws
    mov al, [r12]
    test al, al
    jz .psl_done
    cmp al, '#'
    je .psl_done
    ; Token 1.
    mov r13, r12                          ; word start
.psl_w1_end:
    mov al, [r12]
    test al, al
    jz .psl_w1_done
    cmp al, ' '
    je .psl_w1_done
    cmp al, 9
    je .psl_w1_done
    cmp al, '='
    je .psl_w1_done
    inc r12
    jmp .psl_w1_end
.psl_w1_done:
    mov bl, [r12]
    cmp bl, 0
    je .psl_have_w1
    mov byte [r12], 0
    inc r12
.psl_have_w1:
    ; "segment <name> [cmd] [interval]"
    mov rdi, r13
    lea rsi, [.kw_segment]
    call .streq
    test eax, eax
    jnz .psl_segment
    ; key=value (height, bg, fg, top_offset).
    call .skip_ws
    cmp byte [r12], '='
    jne .psl_done
    inc r12
    call .skip_ws
    mov rdi, r13
    mov rsi, r12
    call apply_setting
    jmp .psl_done

.psl_segment:
    call .skip_ws
    ; Read NAME.
    mov rdi, r12
.psl_nm_end:
    mov al, [r12]
    test al, al
    jz .psl_nm_have
    cmp al, ' '
    je .psl_nm_have
    cmp al, 9
    je .psl_nm_have
    inc r12
    jmp .psl_nm_end
.psl_nm_have:
    mov bl, [r12]
    cmp bl, 0
    je .psl_register
    mov byte [r12], 0
    inc r12
.psl_register:
    ; rdi still points at NAME; r12 at remainder (or NUL).
    push rdi
    call .skip_ws
    pop rdi
    mov rsi, r12                          ; rest = command + maybe interval
    call register_segment
.psl_done:
    pop r13
    pop r12
    pop rbx
    ret

.skip_ws:
    mov al, [r12]
    cmp al, ' '
    je .sw_inc
    cmp al, 9
    je .sw_inc
    ret
.sw_inc:
    inc r12
    jmp .skip_ws

.streq:
    push rbx
.se_loop:
    mov al, [rdi]
    mov bl, [rsi]
    cmp al, bl
    jne .se_no
    test al, al
    je .se_yes
    inc rdi
    inc rsi
    jmp .se_loop
.se_yes:
    mov eax, 1
    pop rbx
    ret
.se_no:
    xor eax, eax
    pop rbx
    ret

.kw_segment: db "segment", 0

; rdi = name, rsi = remainder ("cmd...interval" or just "cmd..." or empty).
; Scans backward from end of remainder for an optional decimal integer
; preceded by whitespace; if found, that's the interval and the cmd is
; everything before it. Otherwise the entire remainder is the cmd
; with interval = 0 (static).
register_segment:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov ecx, [segment_count]
    cmp ecx, MAX_SEGMENTS
    jge .rseg_full
    mov r14d, ecx                         ; new index
    mov rax, r14
    imul rax, SEG_STRIDE_REAL
    lea r15, [segments + rax]
    ; Zero the record's metadata fields.
    mov byte [r15 + SEG_OFF_OUT_LEN], 0
    mov dword [r15 + SEG_OFF_CMD_OFF], 0
    mov dword [r15 + SEG_OFF_INTERVAL], 0
    mov dword [r15 + SEG_OFF_NEXT_RUN], 0
    mov dword [r15 + SEG_OFF_PID], 0
    mov dword [r15 + SEG_OFF_PIPE_FD], -1
    mov byte [r15 + SEG_OFF_FLAGS], 0
    ; Copy name (truncate at SEG_NAME_LEN-1).
    lea rdi, [r15 + SEG_OFF_NAME]
    mov ecx, SEG_NAME_LEN - 1
    mov rsi, r12
.rseg_cp_nm:
    test ecx, ecx
    jz .rseg_nm_done
    mov al, [rsi]
    test al, al
    jz .rseg_nm_done
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jmp .rseg_cp_nm
.rseg_nm_done:
    mov byte [rdi], 0

    ; If remainder is empty, this is a built-in (e.g. "tray") with no
    ; command — leave cmd_off=0, mark as static.
    test r13, r13
    jz .rseg_done
    mov al, [r13]
    test al, al
    jz .rseg_done

    ; Detect optional trailing interval. Find end of remainder.
    mov rdi, r13
.rseg_eol:
    mov al, [rdi]
    test al, al
    jz .rseg_eol_have
    inc rdi
    jmp .rseg_eol
.rseg_eol_have:
    ; rdi points to NUL. Scan back over digits.
    mov rsi, rdi
.rseg_back_digits:
    cmp rsi, r13
    jbe .rseg_no_interval
    mov al, [rsi - 1]
    cmp al, '0'
    jb .rseg_back_done
    cmp al, '9'
    ja .rseg_back_done
    dec rsi
    jmp .rseg_back_digits
.rseg_back_done:
    cmp rsi, rdi                          ; no digits at end
    je .rseg_no_interval
    cmp rsi, r13                          ; whole thing is digits → no cmd
    jbe .rseg_no_interval
    mov al, [rsi - 1]
    cmp al, ' '
    je .rseg_have_interval
    cmp al, 9
    je .rseg_have_interval
    jmp .rseg_no_interval
.rseg_have_interval:
    ; Parse interval at rsi → eax.
    mov rbx, rsi
    xor eax, eax
.rseg_pi:
    mov dl, [rbx]
    test dl, dl
    jz .rseg_pi_done
    sub dl, '0'
    imul eax, eax, 10
    movzx edx, dl
    add eax, edx
    inc rbx
    jmp .rseg_pi
.rseg_pi_done:
    mov [r15 + SEG_OFF_INTERVAL], eax
    ; Trim trailing spaces from cmd region.
    dec rsi
.rseg_trim:
    cmp rsi, r13
    jbe .rseg_no_cmd
    mov al, [rsi - 1]
    cmp al, ' '
    je .rseg_trim_one
    cmp al, 9
    je .rseg_trim_one
    jmp .rseg_intern
.rseg_trim_one:
    dec rsi
    jmp .rseg_trim
.rseg_no_interval:
    ; Whole r13 is the cmd, no interval → static.
.rseg_intern:
.rseg_no_cmd:
    ; Intern cmd into arg_pool. NUL-terminate before interning by
    ; storing 0 at rsi (the boundary).
    cmp rsi, r13
    jbe .rseg_done                        ; no command
    mov byte [rsi], 0
    mov rdi, r13
    call arg_pool_dup
    mov [r15 + SEG_OFF_CMD_OFF], eax
.rseg_done:
    inc dword [segment_count]
.rseg_full:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rdi = key string, rsi = value string. Recognised keys:
;   height        decimal pixels
;   top_offset    decimal pixels
;   bg            #RRGGBB
;   fg            #RRGGBB
apply_setting:
    push rbx
    mov rbx, rsi
    lea rsi, [.k_height]
    call .as_streq
    test eax, eax
    jnz .as_height
    mov rsi, rbx
    lea rsi, [.k_top]
    call .as_streq
    test eax, eax
    jnz .as_top
    mov rsi, rbx
    lea rsi, [.k_bg]
    call .as_streq
    test eax, eax
    jnz .as_bg
    mov rsi, rbx
    lea rsi, [.k_fg]
    call .as_streq
    test eax, eax
    jnz .as_fg
    pop rbx
    ret
.as_height:
    mov rdi, rbx
    call parse_dec
    mov [strip_height], ax
    pop rbx
    ret
.as_top:
    mov rdi, rbx
    call parse_dec
    mov [strip_y], ax
    pop rbx
    ret
.as_bg:
    mov rdi, rbx
    call parse_hex
    mov [cfg_bg], eax
    pop rbx
    ret
.as_fg:
    mov rdi, rbx
    call parse_hex
    mov [cfg_fg], eax
    pop rbx
    ret

.as_streq:
    push rbx
.ase_loop:
    mov al, [rdi]
    mov bl, [rsi]
    cmp al, bl
    jne .ase_no
    test al, al
    je .ase_yes
    inc rdi
    inc rsi
    jmp .ase_loop
.ase_yes:
    mov eax, 1
    pop rbx
    ret
.ase_no:
    xor eax, eax
    pop rbx
    ret

.k_height: db "height", 0
.k_top:    db "top_offset", 0
.k_bg:     db "bg", 0
.k_fg:     db "fg", 0

; rdi = source NUL-terminated string. Copy into arg_pool, return offset
; in eax (0 on failure / empty).
arg_pool_dup:
    push rbx
    push r12
    mov r12, rdi
    mov ebx, [arg_pool_pos]
    xor ecx, ecx
.apd_strlen:
    cmp byte [r12 + rcx], 0
    je .apd_have_len
    inc ecx
    jmp .apd_strlen
.apd_have_len:
    inc ecx                               ; include NUL
    mov edx, ebx
    add edx, ecx
    cmp edx, ARG_POOL_SIZE
    jg .apd_full
    lea rdi, [arg_pool + rbx]
    mov rsi, r12
    push rcx
.apd_copy:
    test ecx, ecx
    jz .apd_done
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jmp .apd_copy
.apd_done:
    pop rcx
    mov eax, ebx
    add [arg_pool_pos], ecx
    pop r12
    pop rbx
    ret
.apd_full:
    xor eax, eax
    pop r12
    pop rbx
    ret

; rdi = NUL-terminated decimal string → eax.
parse_dec:
    xor eax, eax
.pd_loop:
    movzx ecx, byte [rdi]
    cmp cl, '0'
    jb .pd_done
    cmp cl, '9'
    ja .pd_done
    sub ecx, '0'
    imul eax, eax, 10
    add eax, ecx
    inc rdi
    jmp .pd_loop
.pd_done:
    ret

; rdi = "#RRGGBB" or "RRGGBB" → eax = 0xFFRRGGBB (opaque alpha for
; depth-32 visuals; harmless padding on depth-24).
parse_hex:
    push rbx
    cmp byte [rdi], '#'
    jne .ph_start
    inc rdi
.ph_start:
    xor eax, eax
    mov ecx, 6
.ph_loop:
    test ecx, ecx
    jz .ph_done
    movzx edx, byte [rdi]
    cmp dl, '0'
    jb .ph_done
    cmp dl, '9'
    jbe .ph_dig
    or dl, 0x20
    cmp dl, 'a'
    jb .ph_done
    cmp dl, 'f'
    ja .ph_done
    sub dl, 'a' - 10
    jmp .ph_acc
.ph_dig:
    sub dl, '0'
.ph_acc:
    shl eax, 4
    movzx edx, dl
    or eax, edx
    inc rdi
    dec ecx
    jmp .ph_loop
.ph_done:
    or eax, 0xFF000000
    pop rbx
    ret

; ──────────────────────────────────────────────────────────────────────
; X11 setup (cribbed from tile.asm; window create + map + GC + font)
; ──────────────────────────────────────────────────────────────────────
open_core_font:
    push rbx
    call alloc_xid
    mov [font_id], eax
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_OPEN_FONT
    mov byte [rdi+1], 0
    mov word [rdi+2], 3 + (font_name_len + 3) / 4
    mov [rdi+4], eax
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

create_strip_window:
    push rbx
    push r12
    call alloc_xid
    mov [window_id], eax
    mov r12d, eax
    lea rdi, [tmp_buf]
    movzx eax, byte [x11_root_depth]
    mov [rdi], al
    mov byte [rdi+1], al
    mov word [rdi+2], 11
    mov [rdi+4], r12d
    mov eax, [x11_root_window]
    mov [rdi+8], eax
    mov word [rdi+12], 0
    movzx eax, word [strip_y]
    mov [rdi+14], ax
    movzx eax, word [x11_screen_width]
    mov [rdi+16], ax
    movzx eax, word [strip_height]
    mov [rdi+18], ax
    mov word [rdi+20], 0
    mov word [rdi+22], 1
    mov dword [rdi+24], 0
    mov dword [rdi+28], CW_BACK_PIXEL | CW_OVERRIDE_REDIRECT | CW_EVENT_MASK
    mov eax, [cfg_bg]
    mov [rdi+32], eax
    mov dword [rdi+36], 1
    mov dword [rdi+40], EXPOSURE_MASK
    mov byte [rdi], X11_CREATE_WINDOW
    lea rsi, [tmp_buf]
    mov rdx, 44
    call x11_buffer
    inc dword [x11_seq]
    pop r12
    pop rbx
    ret

create_gc:
    push rbx
    push r12
    ; Text GC: foreground = cfg_fg, background = cfg_bg, font = font_id.
    call alloc_xid
    mov [gc_id], eax
    mov r12d, eax
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_CREATE_GC
    mov byte [rdi+1], 0
    mov word [rdi+2], 7
    mov [rdi+4], r12d
    mov ebx, [window_id]
    mov [rdi+8], ebx
    mov dword [rdi+12], GC_FOREGROUND | GC_BACKGROUND | GC_FONT
    mov eax, [cfg_fg]
    mov [rdi+16], eax
    mov eax, [cfg_bg]
    mov [rdi+20], eax
    mov ebx, [font_id]
    mov [rdi+24], ebx
    lea rsi, [tmp_buf]
    mov rdx, 28
    call x11_buffer
    inc dword [x11_seq]

    ; Fill GC: foreground = cfg_bg (used by PolyFillRectangle to clear).
    call alloc_xid
    mov [fill_gc_id], eax
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_CREATE_GC
    mov byte [rdi+1], 0
    mov word [rdi+2], 5
    mov [rdi+4], eax
    mov ebx, [window_id]
    mov [rdi+8], ebx
    mov dword [rdi+12], GC_FOREGROUND
    mov eax, [cfg_bg]
    mov [rdi+16], eax
    lea rsi, [tmp_buf]
    mov rdx, 20
    call x11_buffer
    inc dword [x11_seq]
    pop r12
    pop rbx
    ret

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

; ══════════════════════════════════════════════════════════════════════
; X11 connect / setup boilerplate
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
    add rsi, 2
    movzx eax, byte [rsi]
    shl eax, 8
    movzx ecx, byte [rsi+1]
    or eax, ecx
    add rsi, 2
    add rsi, rax
    movzx eax, byte [rsi]
    shl eax, 8
    movzx ecx, byte [rsi+1]
    or eax, ecx
    add rsi, 2
    add rsi, rax
    movzx eax, byte [rsi]
    shl eax, 8
    movzx ecx, byte [rsi+1]
    or eax, ecx
    add rsi, 2
    mov rbx, rax
    add rsi, rbx
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
    mov byte [rdi], 0x6C
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
