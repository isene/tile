#!/bin/bash
# Tile's tests. Each check is a fault that was once reported, and it fails
# on the build from before its fix.
#
#   test/run.sh                       the tile and frame built beside this
#   TILE=/path/tile FRAME=/path/frame test/run.sh
#
# Everything runs on a scratch frame that draws to plain memory. Nothing
# here may reach a real desktop. A restarting tile starts snixembed and
# sends a notice, so both are dummies here, and the session bus address
# points nowhere. Unsetting it is not enough: programs then find the real
# bus through XDG_RUNTIME_DIR.

here=$(cd "$(dirname "$0")" && pwd)
TILE=${TILE:-$here/../tile}
FRAME=${FRAME:-$here/../../frame/frame}
unset DISPLAY WAYLAND_DISPLAY

T=$(mktemp -d)
mkdir "$T/home" "$T/stub" "$T/bin" "$T/run"
cp "$here/tilerc" "$T/home/.tilerc"
for dummy in notify-send snixembed; do
    printf '#!/bin/sh\necho "$@" >> "%s/%s.calls"\n' "$T" $dummy > "$T/stub/$dummy"
    chmod +x "$T/stub/$dummy"
done
export HOME=$T/home PATH=$T/stub:$PATH XDG_RUNTIME_DIR=$T/run
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent
gcc -O1 -o "$T/xwin" "$here/xwin.c" -lX11 || exit 1
cp "$TILE" "$T/bin/tile-under-test"
TILE=$T/bin/tile-under-test

D=41; while [ -e /tmp/.X11-unix/X$D ]; do D=$((D + 1)); done
"$FRAME" $D --fbtest --noinput 2> "$T/frame.log" &
pids=($!)
trap 'kill "${pids[@]}" $(cat "$T"/*.pid 2>/dev/null) 2>/dev/null; rm -rf "$T" /tmp/.X11-unix/X$D' EXIT
for _ in {1..25}; do [ -S /tmp/.X11-unix/X$D ] && break; sleep 0.2; done
export DISPLAY=:$D

fails=0
is() {                                  # is NAME GOT WANT
    if [ "$2" = "$3" ]; then echo "  ok    $1"
    else echo "  FAIL  $1: got '$2', want '$3'"; fails=$((fails + 1)); fi
}
win() {                                 # win NAME [PARENT]: prints the id
    "$T/xwin" "$@" > "$T/$1.id" &
    echo $! > "$T/$1.pid"
    for _ in {1..30}; do [ -s "$T/$1.id" ] && break; sleep 0.1; done
    sleep 0.3
    cat "$T/$1.id"
}
close() { for w; do kill "$(cat "$T/$w.pid")" 2>/dev/null; done; sleep 0.3; }
shown() { xwininfo -id "$1" 2>/dev/null | grep -q IsViewable && echo yes || echo no; }
cur()   { xprop -root _NET_CURRENT_DESKTOP 2>/dev/null | sed -n 's/.*= //p'; }
go()    { xdotool key "super+$(($1 % 10))"; sleep 0.3; }

echo "== v0.1.62: --version and --help print and exit"
out=$(timeout 3 "$TILE" --version 2>&1); rc=$?
is "--version prints the version and exits" "${out%% *} $rc" "tile 0"
out=$(timeout 3 "$TILE" --help 2>&1); rc=$?
is "--help prints the usage and exits" "${out%% *} $rc" "usage: 0"

echo "== v0.1.73: strip's clock follows summer time"
# strip's local_time, alone in a harness that exits with the UTC offset
# of the time in argv[1], in quarter hours plus 64.
{ cat <<'EOF'
%define SYS_OPEN 2
%define SYS_READ 0
%define SYS_CLOSE 3
%define TZ_BUF_SIZE 8192
section .data
tz_path: db "/etc/localtime", 0
section .bss
tz_buf:  resb TZ_BUF_SIZE
tz_len:  resq 1
tz_read: resb 1
section .text
global _start
_start:
    mov rsi, [rsp + 16]
    xor edi, edi
.digit:
    movzx eax, byte [rsi]
    sub eax, '0'
    jb .go
    cmp eax, 9
    ja .go
    imul rdi, rdi, 10
    add rdi, rax
    inc rsi
    jmp .digit
.go:
    mov rbx, rdi
    call local_time
    sub rax, rbx
    cqo
    mov rcx, 900
    idiv rcx
    lea rdi, [rax + 64]
    mov eax, 60
    syscall
EOF
sed -n '/^local_time:/,/^\.done:/p' "${STRIP_ASM:-$here/../strip.asm}"
echo "    ret"; } > "$T/clock.asm"
nasm -f elf64 -w-all "$T/clock.asm" -o "$T/clock.o" 2>/dev/null && ld "$T/clock.o" -o "$T/clock"
for when in "2026-03-29 00:59:59" "2026-03-29 01:00:00" "2026-10-25 00:59:59" "2026-10-25 01:00:00"; do
    t=$(date -u -d "$when" +%s)
    z=$(date -d "@$t" +%z)
    want=$(( ${z:0:1}1 * (10#${z:1:2} * 4 + 10#${z:3:2} / 15) + 64 ))
    "$T/clock" "$t" 2>/dev/null; got=$?
    is "the offset at $when UTC" "$got" "$want"
done

"$TILE" --no-autostart 2> "$T/tile.log" &
TPID=$!; pids+=($TPID)
for _ in {1..30}; do [ -n "$(cur)" ] && break; sleep 0.1; done

echo "== v0.1.61: other programs can see a window manager is running"
case $(xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null) in
    *"window id"*) got=yes ;; *) got=no ;;
esac
is "_NET_SUPPORTING_WM_CHECK is set on the root" "$got" yes

echo "== v0.1.59: a pager can switch the workspace"
xdotool set_desktop 3 2>/dev/null; sleep 0.3
is "set_desktop 3 moves tile to workspace 4" "$(cur)" 3

echo "== v0.1.70: a pager asking for the workspace in view stays there"
go 5; xdotool set_desktop 4 2>/dev/null; sleep 0.3
is "set_desktop for the current workspace does not jump back" "$(cur)" 4

echo "== v0.1.63: workspace 10 in the log"
go 10; go 3
grep -q 'ws= 3 (was 10)' "$T/tile.log" && got=yes || got=no
is "the log names workspace 10 by its number" "$got" yes

echo "== v0.1.68: a dialog follows its workspace"
go 2
parent=$(win parent)
dialog=$(win dialog "$parent")
is "the dialog shows on its own workspace" "$(shown "$dialog")" yes
go 3
is "the dialog is hidden on another workspace" "$(shown "$dialog")" no
go 2
is "the dialog is back with its workspace" "$(shown "$dialog")" yes

close dialog parent

echo "== v0.1.72: a moved window moves on screen"
# Two windows side by side. Moving one in the order changed the bar only;
# the windows stayed put until the next workspace switch.
go 7; left=$(win left); right=$(win right)
xdotool key super+Tab; sleep 0.3
xat() { xwininfo -id "$1" 2>/dev/null | sed -n 's/.*Absolute upper-left X: *//p'; }
before="$(xat "$left") $(xat "$right")"
xdotool key super+comma; sleep 0.3
is "the two windows are side by side" "$([ "${before% *}" != "${before#* }" ] && echo yes || echo no)" yes
is "moving a window left swaps the two on screen" "$(xat "$right") $(xat "$left")" "$before"
close left right

echo "== v0.1.64: windows keep their workspace when a new tile takes over"
go 1; one=$(win one)
go 5; five=$(win five)
go 10; ten=$(win ten)
# A new tile, not a restart: before v0.1.69 a restart ran the tile installed
# in one fixed home folder, so the build under test never did the adopting.
kill $TPID; wait $TPID 2>/dev/null
spare=$(win spare)                      # takes the slot below the next tile's
"$TILE" --no-autostart 2> "$T/tile2.log" &
TPID=$!; pids+=($TPID)
for _ in {1..30}; do grep -q 'adopt N=' "$T/tile2.log" && break; sleep 0.1; done
sleep 0.3
close spare                             # its slot stays free for the restarted tile
go 10
is "workspace 10 still has its window" "$(shown "$ten")" yes
go 1
is "workspace 1 still has its window" "$(shown "$one")" yes
is "and the window of workspace 10 is hidden there" "$(shown "$ten")" no
go 5
is "workspace 5 still has its window" "$(shown "$five")" yes

echo "== v0.1.66, v0.1.69, v0.1.71: a restart"
kill -USR2 $TPID
for _ in {1..30}; do [ -s "$T/notify-send.calls" ] && break; sleep 0.1; done
sleep 0.5
is "tile restarts from the file it was started from" "$(readlink /proc/$TPID/exe)" "$TILE"
grep -q 'tile restarted' "$T/notify-send.calls" 2>/dev/null && got=yes || got=no
is "the new tile sends the restart notice" "$got" yes
is "a restart lands on the workspace it came from" "$(cur)" 4
is "and that workspace still shows its window" "$(shown "$five")" yes
go 1
is "the windows are still there after the restart" "$(shown "$one")" yes
is "and the window of workspace 5 is hidden there" "$(shown "$five")" no

echo "== v0.1.75: tile still places windows after a restart"
# frame ignored the new tile's claim while the old tile still had it, so
# windows opened after the restart kept their own size. A race, but the
# window closed above makes the build before the fix fail here each run.
go 8; after=$(win after)
is "a window opened after the restart fills the screen" \
    "$(xwininfo -id "$after" 2>/dev/null | sed -n 's/.*Width: *//p')" 1920

echo "== v0.1.76: a bind on a key that needs Shift, like ?"
# On frame's US keymap "?" is Shift+slash. tile looked only at the plain
# symbol of each key, found no key for "?" and grabbed nothing.
go 1; xdotool key super+shift+slash; sleep 0.3
is "Mod4+? reaches its bind" "$(cur)" 5

echo "== v0.1.77: strip's LCARS look"
# blocks = 1 puts each text run on a block of colour. The first segment's
# block is orange, so a pixel above its letters is orange, not the black
# background. "fg" comes first: a key that half matched used to move the
# parser on, so a line after it could miss its own key.
printf '%s\n' 'height = 22' 'fg = #cccccc' 'bg = #000000' 'blocks = 1' \
    'colours = #ff9900, #ffcc99, #cc99cc, #00ff00' \
    'segment a #cccccc printf ABCDEF 0' 'segment b #cccccc printf GH 0' \
    "segment v #cccccc sh -c 'printf \" \"' 0" \
    "segment c #cccccc sh -c 'printf \" \\033[38;2;0;0;255mIJ\"' 0" > "$HOME/.striprc"
"${STRIP:-$here/../strip}" 2> "$T/strip.log" &
pids+=($!); sleep 1
rm -f /tmp/frame${D}_win_*.raw; kill -USR1 "${pids[0]}"; sleep 0.5
px=no; edge=no; tail=no
for f in /tmp/frame${D}_win_*.raw; do
    [ "$(stat -c %s "$f" 2>/dev/null)" = $((1920 * 22 * 4)) ] || continue
    px=$(od -An -tx1 -j $(((1920 + 4) * 4)) -N3 "$f" | tr -d ' ')
    edge=$(od -An -tx1 -j $(((1920 + 1) * 4)) -N3 "$f" | tr -d ' ')
    tail=$(od -An -tx1 -j $(((1920 + 1919) * 4)) -N3 "$f" | tr -d ' ')
    row=$(od -An -v -tx1 -w4 -j $((1920 * 4)) -N $((1920 * 4)) "$f" | tr -d ' ' | cut -c1-6 | sort -u | tr '\n' ' ')
done
rm -f /tmp/frame${D}_*.raw
is "the pixel above the first letters is orange (BGR)" "$px" 0099ff

echo "== v0.1.78: no black between LCARS segments"
# The margin left of the first segment takes its colour.
is "the left margin is orange too" "$edge" 0099ff

echo "== v0.1.79, v0.1.80: the segment before fills the gap after it"
# The last segment prints its letters in blue, and that blue, not its
# orange from the colours above, runs on to the right edge.
is "the right edge is the blue of the last letters" "$tail" ff0000

echo "== v0.1.80: a blank segment draws no block of its own"
# Segment v prints a space, like the vpn mark with no tunnel up, and c
# starts with one, like the mail counts. Neither lilac (v's turn in the
# colours) nor green (c's) may show: the bar above the letters is orange
# (a), peach (b) and the blue of c's letters alone.
is "the colours on the bar" "$row" "0099ff 99ccff ff0000 "

echo
if [ $fails -eq 0 ]; then echo "tile tests: all good"; else echo "tile tests: $fails failed"; fi
exit $((fails > 0))
