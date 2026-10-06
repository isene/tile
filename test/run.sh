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

echo "== v0.1.64: windows keep their workspace when a new tile takes over"
go 1; one=$(win one)
go 5; five=$(win five)
go 10; ten=$(win ten)
# A new tile, not a restart: before v0.1.69 a restart ran the tile installed
# in one fixed home folder, so the build under test never did the adopting.
kill $TPID; wait $TPID 2>/dev/null
"$TILE" --no-autostart 2> "$T/tile2.log" &
TPID=$!; pids+=($TPID)
for _ in {1..30}; do grep -q 'adopt N=' "$T/tile2.log" && break; sleep 0.1; done
sleep 0.3
go 10
is "workspace 10 still has its window" "$(shown "$ten")" yes
go 1
is "workspace 1 still has its window" "$(shown "$one")" yes
is "and the window of workspace 10 is hidden there" "$(shown "$ten")" no
go 5
is "workspace 5 still has its window" "$(shown "$five")" yes

echo "== v0.1.66, v0.1.69: a restart"
kill -USR2 $TPID
for _ in {1..30}; do [ -s "$T/notify-send.calls" ] && break; sleep 0.1; done
sleep 0.5
is "tile restarts from the file it was started from" "$(readlink /proc/$TPID/exe)" "$TILE"
grep -q 'tile restarted' "$T/notify-send.calls" 2>/dev/null && got=yes || got=no
is "the new tile sends the restart notice" "$got" yes
go 1
is "the windows are still there after the restart" "$(shown "$one")" yes

echo
if [ $fails -eq 0 ]; then echo "tile tests: all good"; else echo "tile tests: $fails failed"; fi
exit $((fails > 0))
