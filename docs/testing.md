# Testing

The effect moves windows and grabs input, so a bad build in the live session is
a session you cannot use. Everything runs in a nested KWin first.

## The nest

`dev/nest.sh up` starts `kwin_wayland --width 1920 --height 1080` as a window
of the live session, under `dbus-run-session` so it has its own `org.kde.KWin`
and its own `kglobalaccel`, and with `XDG_CONFIG_HOME` pointed at a seeded
config that enables the effect and disables Zoom and Overview. The live kwinrc
is never touched.

```bash
./dev/nest.sh up
./dev/nest.sh clients            # kcalc konsole kwrite; NEST_CLIENTS overrides
./dev/nest.sh run firefox        # any client
./dev/nest.sh toggle             # the toggle shortcut via the nest's kglobalaccel
# Inside the nest the chords are Ctrl+Alt+Space and Ctrl+Alt+Home, because the
# outer desktop sees Meta chords first.
./dev/nest.sh shot [file]        # spectacle against the nested compositor
./dev/nest.sh log [n]
./dev/nest.sh down
```

## Driving the effect without a mouse

QML effects cannot export D-Bus, so the harness writes a command and a
sequence number into the nest's kwinrc and calls
`org.kde.kwin.Effects.reconfigureEffect`. The effect runs the command when the
sequence changes and logs its state.

```bash
./dev/nest.sh cmd open
./dev/nest.sh cmd "pan -1500 -400"        # screen px
./dev/nest.sh cmd "zoom 0.4 960 540"      # zoom [anchorX anchorY], global px
./dev/nest.sh cmd extents
./dev/nest.sh cmd commit
./dev/nest.sh cmd "activate KCalc"        # by caption substring, at 1:1
./dev/nest.sh cmd "shift 2200 900"        # move the current desktop's viewport at 1:1
./dev/nest.sh cmd "place 2 2300 100"      # set entry 2's canvas position
./dev/nest.sh cmd "frames 300 0 1"        # drag desktop 1's frames by screen px
./dev/nest.sh cmd "desktop 1"             # switch to desktop index 1 (nest has two)
./dev/nest.sh cmd "pick 0"                # apply with entry 0 on screen
./dev/nest.sh cmd "resize 0 1000 700"     # command entry 0's window to a size
./dev/nest.sh cmd "adddesktop 0"          # insert a desktop after index 0
./dev/nest.sh cmd "rmdesktop 1"           # remove desktop index 1
./dev/nest.sh cmd list                    # every window with its frame
./dev/nest.sh cmd cancel
```

Each command prints the effect state afterwards: `visible`, `zoom`, `view`,
and every entry's canvas rect and frame.

## Things that cost time

- **Output goes to journald**, not stderr, when stderr is not a TTY. The nest
  sets `QT_LOGGING_TO_CONSOLE=1` so `kwin.log` gets it.
- **The QML component cache.** `unloadEffect` and `loadEffect` reload the
  cached component, not the file. `nest.sh reload` restarts the nest.
- **Socket name.** The Wayland socket lands in `$XDG_RUNTIME_DIR`, so it must
  not share a name with the harness state directory.
- **A JS exception mid-commit leaves the effect open.** Check the log for
  `TypeError` before trusting a `visible=true` in the state line.

## What has been verified in the nest

- Effect loads with no QML errors.
- Open at zoom 1 is pixel-identical to the desktop.
- Cursor-anchored zoom out, ground grid with octaves, labels, axes, HUD.
- Pan then commit writes `frame = canvas - view` for every window; windows
  land partly and fully off-screen and stay there.
- Activating a fully off-screen window shifts the plane so it is centred and
  returns `view` to match.
- Zoom to fit, including every desktop's frames.
- Two desktops draw as two frame groups. Placing a window inside Desktop 2's
  frame and applying moves it to Desktop 2 at the matching geometry, and
  switching to Desktop 2 at 1:1 moves the view to that desktop's target.
- The wallpaper plugin renders the same ground at the same offset, headless
  against a stub `WallpaperItem`.
