# Future config keys (tile + strip)

Pragmatic hardcodes in `tile.asm` and `strip.asm` that work fine today
but could be exposed in `~/.tilerc` / `~/.striprc` later if anyone
wants to tune them.

## Bar layout spacing constants

**Where:** `tile.asm` near the top, the constant block:

```nasm
%define SQUARE_GAP              2     ; gap between adjacent tab squares
%define WS_SQUARE_GAP           4     ; gap between WS squares within a group
%define WS_GROUP_GAP            14    ; extra gap before WS positions 4, 7, 10
%define BAR_SEP_GAP             8     ; space on each side of the vertical separator
%define BAR_SEP_WIDTH           2     ; width of the vertical separator bar
%define LAYOUT_GLYPH_GAP        14    ; gap after the layout indicator before tabs
%define DEFAULT_BAR_PAD         4     ; left padding (cfg_bar_pad, already configurable)
```

**What they do:** Define the visual rhythm of the bar — square sizes,
inter-square gaps, group gaps, separator-bar dimensions, and the gap
between the layout indicator and the tabs strip.

**Why config-worthy:** This is the bar's entire visual personality.
A user with a wider/narrower screen, larger bar_height, or stronger
preference for tight-vs-airy might want to tune these without a
rebuild.

**Migration sketch:** Add `~/.tilerc` keys like:

```
bar_square_gap        = 2
bar_ws_square_gap     = 4
bar_ws_group_gap      = 14
bar_sep_gap           = 8
bar_sep_width         = 2
bar_layout_glyph_gap  = 14
```

Map each to a `cfg_bar_*` BSS variable; replace the `%define`
references in `render_bar` with `movzx eax, byte [cfg_bar_*]`. Cost:
~6 BSS bytes, ~6 lines of parser, ~6 instruction substitutions.

**Why not yet:** Single user, opinionated default. The current values
were tuned interactively against a 24" 1920×1080 display.

## Strip default gap and per-segment gap-overrides

**Where:** `strip.asm`, `cfg_gap` (default 8 px from `~/.striprc`)
and `SEG_OFF_GAP_OVR` (per-segment `+N` syntax).

**Status:** Already fully config-driven via `~/.striprc`. No hardcode
to expose.

## Default exec command for Alt+Return

**Where:** `tile.asm`, `default_glass_arg: db "glass", 0`.

**What it does:** Hardcoded fallback bind: when no `~/.tilerc` exists,
Alt+Return spawns `glass` (resolved via `/bin/sh -c` PATH search).

**Why config-worthy:** A user who prefers a different terminal
emulator gets `glass` as the no-config default. With a `~/.tilerc`
present they can override via the normal `bind` syntax.

**Migration sketch:** Could be a build-time `%define DEFAULT_TERM
"xterm"` so distributors building tile for non-glass setups can ship
an appropriate default. Cost: trivial.

**Why not yet:** Without `~/.tilerc` a fresh tile install is non-
functional anyway; the fallback bind is just a "you can at least
spawn ONE thing" safety net.

## Strip segment count cap

**Where:** `strip.asm`, `MAX_SEGMENTS` (compile-time constant,
typically 32). Records are 256 bytes each in BSS.

**Status:** Could become a `~/.striprc` `max_segments = N` if anyone
wants more, but adding more segments costs 256 B per slot in BSS so
the cap is mostly cost-control, not feature-limit.

**Why not yet:** Nobody runs > 16 segments today.
