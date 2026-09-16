# kwin-canvas

An infinite canvas for KDE Plasma, built on KWin's public scripting API. No
patches, no forked compositor, no plugin against private headers.

Windows live on one unbounded plane. Every virtual desktop is a viewport onto
that plane, drawn while the canvas is open as a group of **monitor frames**:
outlined rectangles, one per output in the layout KDE knows, tagged with the
desktop and output names. Drag windows into a frame or drag a desktop's frames
over a cluster of windows, press Enter, and that is what the real screens show
on that desktop. Switching desktops at 1:1 switches viewport, and dragging a
window into another desktop's frame moves it to that desktop. At 1:1 nothing
is running: every window is an ordinary KWin window at an ordinary
position, some of them off-screen, and KWin handles input, popups, XWayland and
focus exactly as it always does. Open the canvas to zoom out, pan, rearrange
and pick; close it and the new layout is written back as plain window geometry.

The ground plane is the reference for all of this. A grid with coordinate
labels scrolls under the windows when you pan at 1:1 and scales with them when
you zoom out, so the plane has landmarks and the zoom has something to anchor.

> Alpha. Tested in a nested KWin 6.7.5 session. The wallpaper offset handoff to
> plasmashell has not yet been exercised in a live Plasma session.

## Parts

| Package | Type | What it does |
|---|---|---|
| `effect/` | KWin/Effect (QML) | The canvas: snapshot, ground, thumbnails, pan, zoom, pick, commit |
| `wallpaper/` | Plasma/Wallpaper | The ground at 1:1, offset by the last committed pan |
| `shared/Ground.qml` | copied into both | One renderer for the ground so both views match |
| `dev/nest.sh` | harness | Nested KWin with its own D-Bus and config, driven from the shell |

## Install

```bash
make install    # kpackagetool6 into ~/.local/share
make enable     # turn the effect on in the running session
```

Then pick **Canvas Ground** as the desktop wallpaper in Desktop Settings, and
disable the stock **Zoom** effect if it owns Meta+wheel.

## Use

| Key | At 1:1 | Canvas open |
|---|---|---|
| Meta+Space | open the canvas, zoomed to fit | apply and close |
| Meta+Ctrl+Space | jump home | jump home |
| drag on ground, Space+drag, or middle-drag | | pan |
| wheel | | zoom at the cursor |
| drag a window | | move it on the plane |
| drag a frame's tag or edge | | move that desktop's frames (all together) |
| drag a window's edge or corner | | resize it, live |
| + on a frame tag | | add a desktop after that one |
| trash on a frame tag | | remove that desktop (never the first) |
| click a window | | apply with it on screen, focus it |
| Enter | | apply and close |
| Esc | | cancel, nothing moves |
| Home | | look through the current desktop's frames |
| 0 | | canvas origin |
| F / W | | zoom to fit |

Activating an off-screen window from the task manager pans the plane so it
comes on screen.

Every key above is a config entry in the `[Effect-kwin-canvas]` group of
`kwinrc` (`KeyApply`, `KeyCancel`, `KeyHome`, `KeyOrigin`, `KeyFit`,
`KeyZoomIn`, `KeyZoomOut`, `KeyPan`, comma-separated Qt key names without the
`Key_` prefix), as are the two global chords (`ToggleShortcut`, `HomeShortcut`)
and the opening view (`OpenZoom`: `fit`, `1`, or a zoom such as `0.5`). The
legend inside the canvas is built from the same entries.

## Develop

`make` alone lists every target. The important ones:

```bash
make deps             # check tools; make deps-install fetches what is missing
make play             # nest with the five fixture apps arranged and the canvas open
make nest             # the bare nest: KWin with the effect and plasmashell inside, own D-Bus bus
make nest-fixtures    # kcalc, kwrite, konsole, dolphin, gwenview on fixture files
make nest-cmd CMD=open           # drive the effect without a mouse
make nest-cmd CMD="zoom 0.4 960 540"
make nest-shot        # screenshot of the nest
make nest-reload      # reinstall, restart the nest, relaunch clients
make test             # scenarios against a dedicated test nest, with golden screenshots
make golden           # re-record the golden screenshots
make demo             # scripted session driven by real input; stills, frames, mp4 and gif in build/demo
```

The nest is a second `kwin_wayland` as a window of your session, with its own
D-Bus bus, config and plasmashell, so nothing touches the real desktop. Inside
it the canvas chords are Ctrl+Alt+Space and Ctrl+Alt+Home, because the outer
desktop sees Meta chords first. `build/tools/fakeinput` injects pointer and
keyboard events into it through KWin's fake-input protocol, which is how the
tests and the demo drive it.

See [docs/architecture.md](docs/architecture.md) for the model and the KWin
API facts this rests on, and [docs/testing.md](docs/testing.md) for the harness.

## Prior attempts

- **kwin-map** (March 2026): a KWin effect plus two source patches, aiming at
  live input while zoomed. Hit the effect API's limit on input routing.
- **hypr-canvas**: a Hyprland plugin with twelve function hooks. Worked, then
  broke across a Hyprland release when two hooked symbols disappeared.

Both wanted to interact with windows while the view was transformed. This
attempt drops that requirement: interaction happens at 1:1, and the transformed
view is for navigation. That single change is what lets it live entirely on the
public API.

## License

GPL-2.0-or-later, KDE's licence for effects and plugins, so this can be
contributed upstream without relicensing. `tools/protocols/fake-input.xml` is
KDE's fake-input protocol definition, LGPL-2.1-or-later. Full texts in
`LICENSES/`.
