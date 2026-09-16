# kwin-canvas

An infinite canvas for KDE Plasma, built on KWin's public scripting API. No
patches, no forked compositor, no plugin against private headers.

Windows live on an unbounded plane. The screen is a 1:1 viewport onto it. At
1:1 nothing is running: every window is an ordinary KWin window at an ordinary
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
| Meta+Space (configurable) | open the canvas | apply and close |
| Meta+Ctrl+Space | jump home | jump home |
| drag on ground, Space+drag, or middle-drag | | pan |
| wheel | | zoom at the cursor |
| drag a window | | move it on the plane |
| click a window | | apply, close, focus it |
| Enter | | apply and close |
| Esc | | cancel, nothing moves |
| Home / 0 | | origin |
| F / W | | zoom to fit |

Activating an off-screen window from the task manager pans the plane so it
comes on screen.

## Develop

```bash
./dev/nest.sh up          # nested KWin, effect enabled, own D-Bus bus
./dev/nest.sh clients     # kcalc konsole kwrite inside it
./dev/nest.sh cmd open    # drive the effect without a mouse
./dev/nest.sh cmd "zoom 0.4 960 540"
./dev/nest.sh shot        # screenshot of the nested session
./dev/nest.sh reload      # reinstall, restart the nest, relaunch clients
```

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

MIT
