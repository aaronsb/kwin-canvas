# Testing

The effect moves windows and grabs input, so a bad build in the live session is
a session you cannot use. Everything runs in a nested KWin first.

## The nest

`make nest` (`dev/nest.sh up`) starts `kwin_wayland --width 1920 --height 1080`
as a window of the live session, under `dbus-run-session` so it has its own
`org.kde.KWin`, its own `kglobalaccel` and its own portals, with
`XDG_CONFIG_HOME` pointed at a seeded config that enables the effect, gives it
two virtual desktops and disables Zoom and Overview. The live kwinrc is never
touched. It then starts `plasmashell` inside the nest and shapes it through
`org.kde.PlasmaShell.evaluateScript`: no panels, the Canvas Ground wallpaper,
a folder view on an empty directory. That is the same scripting call the
effect uses to publish the ground offset, so the handoff runs on every nest.

`NEST_NAME=foo` gives an independent nest with its own socket, bus, config and
log. Tests use `test`, the demo uses `demo`, and the default is `kwincanvas`.
`NEST_SHELL=0` skips plasmashell.

```bash
make play                       # up, fixture apps arranged, canvas open and fitted
make play ARGS=--closed         # same, canvas closed at 1:1
make nest                       # up, empty
make nest-fixtures              # kcalc kwrite konsole dolphin gwenview on fixture files
make nest-clients               # or the plain trio: kcalc konsole kwrite
make nest-cmd CMD=open          # a debug command
make nest-shot                  # spectacle against the nested compositor
make nest-log
make nest-down
make nest-clean                 # leftovers of nests whose state is gone
```

`dev/nest.sh` is sourceable: `source dev/nest.sh` exposes `up`, `down`, `run`,
`cmd`, `shot`, `input`, `fixtures` and the rest without running anything,
which is how `tests/lib.sh` reuses it.

## Driving the effect

Two channels, both from the shell.

**Debug commands.** QML effects cannot export D-Bus, so the harness writes a
command and a sequence number into the nest's kwinrc and calls
`org.kde.kwin.Effects.reconfigureEffect`. The effect runs the command when the
sequence changes and logs its state.

```bash
make nest-cmd CMD=open
make nest-cmd CMD="pan -1500 -400"        # screen px
make nest-cmd CMD="zoom 0.4 960 540"      # zoom [anchorX anchorY], global px
make nest-cmd CMD=extents
make nest-cmd CMD=commit
make nest-cmd CMD="frames 300 0 1"        # move desktop index 1's frames by screen px
make nest-cmd CMD="place 2 2300 100"      # set entry 2's canvas position
make nest-cmd CMD="placeby KCalc 100 120 480 420"   # by caption, with optional size
make nest-cmd CMD="resize 0 1000 700"     # command entry 0's window to a size
make nest-cmd CMD="activate KCalc"        # by caption substring, at 1:1
make nest-cmd CMD="shift 2200 900"        # move the current desktop's viewport at 1:1
make nest-cmd CMD="desktop 1"             # switch to desktop index 1
make nest-cmd CMD="adddesktop 0"          # insert a desktop after index 0
make nest-cmd CMD="rmdesktop 1"
make nest-cmd CMD=resetview               # 1:1 only: forget the pan so canvas == frame
make nest-cmd CMD=list                    # every window with its frame and desktop
make nest-cmd CMD=cancel
```

Each command prints the effect state afterwards: `visible`, `zoom`, `view`,
the current desktop, every desktop's target, and every entry's canvas rect,
frame and desktop.

**Real input.** `make tools` builds `build/tools/fakeinput`, a small C client
for KWin's `org_kde_kwin_fake_input` protocol. `dev/nest.sh input` runs it
against the nest:

```bash
./dev/nest.sh input move 960 540
./dev/nest.sh input wheel -3                       # three notches out
printf 'drag 300 300 600 500\n' | ./dev/nest.sh input   # left-drag, 20 steps
./dev/nest.sh input key esc
```

Commands: `move X Y`, `rel DX DY`, `down|up|click [left|middle|right]`,
`drag X1 Y1 X2 Y2 [STEPS] [MS]`, `wheel N`, `key NAME [down|up]`, `sleep MS`.
KWin only advertises the protocol to registered executables, so the nest runs
with `KWIN_WAYLAND_NO_PERMISSION_CHECKS=1`. Against a live session you would
need `make -C tools desktop`, which registers the binary with a desktop file
in your home directory.

## Tests

```bash
make test                 # all scenarios
make test ARGS=60         # scenarios matching a pattern
make golden               # re-record the golden screenshots
```

`tests/run.sh` starts the `test` nest, launches the fixture apps, arranges
them at fixed canvas positions with `placeby`, then sources each
`tests/scenarios/NN-name.sh` and calls its `run_scenario`. Scenarios use
`tests/lib.sh`:

- `c "command"` sends a debug command and keeps the state it printed.
- `sget zoom|viewx|viewy|visible|desktop|entries|ndesktops` reads the state line.
- `eget CAPTION x|y|w|h|fx|fy|desktop|index` reads an entry by caption substring.
- `tget INDEX x|y|name` reads a desktop target.
- `assert_eq`, `assert_near NAME ACTUAL EXPECTED [TOL]`, `assert_true`.
- `snap NAME` screenshots the nest and compares against `tests/golden/NAME.png`
  by normalized RMSE, within `GOLDEN_TOLERANCE` (default 0.02). With
  `UPDATE_GOLDEN=1` it records instead. Diffs land in `build/test/NAME.diff.png`.
- `input ...` injects real events; `have_input` says whether the tool is built.
- `arrange` restores the fixed fixture layout.

The fixtures are procedural (`tests/fixtures/gen.py`): a wallpaper with
labelled quadrants, a seamless tile, and two text files. The fixture apps open
them so every run shows the same content. Konsole runs `cat` on a fixture
instead of a shell, so no prompt or clock changes between runs.

Golden images are captured on this machine's fonts and theme. Re-record them
with `make golden` after an intentional visual change, and expect to
re-record after a Plasma upgrade.

## Demo

`make demo` runs `demo/demo.sh` in the `demo` nest: fixtures, then a scripted
session driven by fake input while a background loop screenshots the nest,
with named stills at each stage. `ffmpeg` assembles `build/demo/demo.mp4` and
`demo.gif`. `make video` re-assembles from existing frames. For a real-time
recording, point OBS at the nest window while `DEMO_FRAMES=0 make demo` runs.

## Things that cost time

- **Output goes to journald**, not stderr, when stderr is not a TTY. The nest
  sets `QT_LOGGING_TO_CONSOLE=1` so `kwin.log` gets it.
- **The QML component cache.** `unloadEffect` and `loadEffect` reload the
  cached component, not the file. `make nest-reload` restarts the nest.
- **Socket name.** The Wayland socket lands in `$XDG_RUNTIME_DIR`, so it must
  not share a name with the harness state directory.
- **A JS exception mid-commit leaves the effect open.** Check the log for
  `TypeError` before trusting a `visible=true` in the state line.
- **Cursor-anchored zoom does not reset the camera.** `zoom 0.4 960 540` from
  an already zoomed view keeps the point under the anchor fixed. Use `home`
  first when a scenario needs a known camera.
- **Daemons outlive the bus.** Portals and kactivitymanagerd activated on a
  nest's private bus keep running after it dies. `down` kills everything on
  the nest's bus; `make nest-clean` sweeps the rest.
- **The nested window must keep its size.** KWin's nested backend scales its
  framebuffer to the window instead of changing the output mode, so resizing
  the nest window on the outer desktop distorts it. Leave it at the invoked
  size, or set `NEST_WIDTH` and `NEST_HEIGHT` before `make nest`.
