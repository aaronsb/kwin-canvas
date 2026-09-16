# Architecture

## The model

Three coordinate spaces:

| Space | Meaning |
|---|---|
| canvas | the plane windows live on; unbounded |
| global | KWin's coordinate space across all outputs |
| screen | one output's local pixels; `global - output.geometry.topLeft` |

One camera and one target per virtual desktop. `view` is the canvas point
the camera puts at global (0,0), and `zoom` is its scale. `target(d)` is the
canvas point at global (0,0) when desktop `d` is shown; its monitor frames are
drawn at `target(d) + output.geometry` for every output, so each desktop is a
rigid group of frames in KDE's layout, placed anywhere on the plane. While the
canvas is closed, `view == target(current desktop)`.

```
global = (canvas - view) * zoom
canvas = view + global / zoom
frame geometry = canvas - target(desktop of the window)
```

A window's canvas position is its KWin geometry plus its own desktop's
target. Desktops never placed are laid out in a row beside the current one on
first open, which moves nothing.

At 1:1, `zoom` is 1 and a window at canvas `c` has KWin frame geometry
`c - view`. That is the whole trick. KWin's geometry *is* the canvas table,
offset by one vector. Windows beyond the screen are simply at off-screen
positions, which KWin allows and stops sending frame callbacks for.

The effect holds only `view` between activations. Everything else is
re-derived from live geometry each time the canvas opens.

## Lifecycle

**Closed (1:1).** The effect is not running. No transform, no grab, no
per-frame work. Two things happen in this state:

- `windowActivated` on a window with no on-screen intersection shifts every
  canvas window by the same delta so it lands centred on its output, and
  adjusts `view` to match. The task manager becomes a way to travel.
- `Meta+Space` opens the canvas.

**Open.** `open()` sets `zoom = 1`, records `entryView` and a copy of the
targets, snapshots every canvas window on every desktop in stacking order
into `entries[] = {window, desktop, x, y, width, height}` with
`x = frame.x + target(desktop).x` and so on, then moves the camera to the
configured opening view (`OpenZoom`, default fit-everything). The per-screen delegate draws the ground and one live `WindowThumbnail`
per entry at `(entry - view) * zoom - screen.topLeft`. Pan changes `view`.
Zoom changes `zoom` and `view` together so the canvas point under the anchor
stays put:

```
c     = view + anchor / zoom
zoom  = z
view  = c - anchor / zoom
```

Dragging a thumbnail edits the entry in canvas units. Nothing touches KWin
geometry while the canvas is open.

Dragging a frame's name tag or edge band changes that desktop's target. The
camera is never involved in what gets applied.

**Commit.** For every entry, the desktop whose frame contains the entry's
centre wins: the window is moved to that desktop if it differs, and
`frameGeometry = entry - target(that desktop)`. An entry in no frame keeps
its desktop. Minimized and hidden windows are shifted by how much their
desktop's target moved, so they stay put on the plane. The camera is set to
the current desktop's target at zoom 1, the ground offset is published, and
the effect hides. `pick()` first centres the current desktop's active-screen
frame on the window if no frame contains it. `cancel()` restores the targets
and `entryView` and hides without writing anything.

**Desktop switch at 1:1.** `currentDesktopChanged` sets `view` to the new
desktop's target and republishes the ground, so the wallpaper scrolls to
where that desktop's viewport sits on the plane.

## Why the ground has to be drawn twice

The ground must scroll with the plane at 1:1 and scale with it when zoomed.
No layer-shell wallpaper can do the first, because the client that draws it
has no idea the plane exists. So the effect draws the ground while it is open,
and a Plasma wallpaper plugin draws the same ground while it is closed. Both
use `shared/Ground.qml` with the same inputs, so the switch at open and close
is pixel-identical.

The wallpaper needs `view`, and neither a KWin effect nor a wallpaper can
export D-Bus. The effect calls `org.kde.PlasmaShell.evaluateScript` with a
Plasma script that writes `OffsetX/OffsetY` into the wallpaper's config group
on every desktop containment. That is one config write per commit, and the
wallpaper QML reads `configuration.OffsetX` live.

The ground itself is procedural: grid octaves at `base * factor^k`, each fading
in as its screen spacing crosses 14px and fully drawn by 72px, so there is
always a legible spacing at any zoom. Coordinate labels at the intersections
of the coarser octaves make each region unique. The axes through canvas (0,0)
are the one landmark that never repeats. Alternatively a tile image, mipmapped
and scaled with the view.

## KWin API facts this rests on

Verified against the 6.7.5 source, in `src/`:

- A QML effect is a KPackage of type `KWin/Effect` with
  `X-Plasma-API: declarativescript`, loaded from
  `~/.local/share/kwin/effects/<id>/contents/ui/main.qml`
  (`effect/effectloader.cpp`). The root must be `SceneEffect` from
  `org.kde.kwin`.
- `SceneEffect.visible` starts and stops the effect. The delegate is
  instantiated once per screen with `SceneView.screen` attached
  (`scripting/scriptedquicksceneeffect.h`, `effect/quickeffect.h`).
- Pointer and wheel events are forwarded to the delegate's QML scene, so
  `DragHandler`, `WheelHandler`, `TapHandler` and `HoverHandler` work as
  normal. Keys arrive through `grabbedKeyboardEvent` and reach `Keys.onPressed`
  on the focused item.
- `Window.frameGeometry` is writable and calls `Window::moveResize`
  (`window.h`). A JS object with `x, y, width, height` converts to `RectF`
  (`scripting/scripting.cpp`). No clamping happens on that path.
  `checkWorkspacePosition` runs on desktop send, output layout change, and
  placement, so those are the moments off-screen windows can be pulled back.
- `WindowThumbnail` takes `client` and `refOffscreenRendering()`s it, so
  windows that are off-screen or minimized still render live
  (`scripting/windowthumbnailitem.cpp`).
- The QML `Workspace` singleton is `DeclarativeScriptWorkspaceWrapper`. It has
  `stackingOrder`, `windows`, `activeWindow`, `cursorPos`, `activeScreen`,
  `virtualScreenGeometry`, `clientArea()`, and the `windowActivated` signal.
  It does **not** have `windowList()`; that exists only on the JS-script
  wrapper.
- `ShortcutHandler` registers a global shortcut; global shortcuts fire even
  while the effect holds the keyboard.
- `DBusCall` from `org.kde.kwin` makes an async call with `arguments` and
  `call()`.
- `org.kde.KWin /Effects reconfigureEffect <id>` reparses kwinrc and calls the
  effect's `reconfigure()`. The plain `/KWin reconfigure` does not reach
  effects.
- The QML engine caches components by URL. An edited `main.qml` does not load
  on `unloadEffect` + `loadEffect`; restart KWin.

## Layers

Back to front inside each screen's view: the ground, the monitor frames, the
windows in KWin's stacking order, the frame tags, the HUD. A frame's interior
is a `DesktopBackground` item for its output, desktop and activity, which is
the real Plasma wallpaper. Wallpapers in Plasma are per screen and per
activity, so frames of different desktops show the same image unless
activities differ. A faint tint in the desktop's colour sits over it so the
frame reads as a sheet even with no background window, as in the nest.

`DesktopBackground` with an empty `activity` crashes KWin 6.7 when activities
are disabled (null dereference in `updateWindow`), so the effect always
passes a non-empty activity.

## Keys

All keys come from config. The global chords are `ShortcutHandler` sequences
(`ToggleShortcut`, `HomeShortcut`). The keys the open canvas listens for are
comma-separated Qt key names (`KeyApply` = `Return,Enter` and so on), parsed
into key codes at load and on every reconfigure by looking up `Qt["Key_" +
name]`, and the legend is rendered from the same entries. A misspelt name is
logged and skipped.

## Arranging a selection

`arrange(mode, rows, cols)` acts on the selection, or on the window the menu
was opened on: horizontal and vertical lay windows out from the selection's
bounding-box corner with `ArrangeGap` between them, cascade steps them by 40,
and tile or grid split the bounding box into cells and command each window to
its cell through `requestSize`. The menu is a `PC3.Menu` opened at the pointer
by the `MouseContextMenu` gesture, the first gesture spec to carry a button.
Attached properties inside a `Connections` handler resolve against the
`Connections` object, so the handler reads the screen through the view.

## Screen edges

`X-KWin-Border-Activate` in the metadata puts the effect into the Screen
Edges settings page, which writes the chosen edges into `BorderActivate` in
the effect's config group as ElectricBorder numbers (top is 0, clockwise to
top-left at 7, the same order as `ScreenEdgeHandler.Edge`). The effect
instantiates one `ScreenEdgeHandler` per number and toggles on activation.
`TouchBorderActivate` does the same for touch edges.

## HUD

A Plasma toolbar (`org.kde.plasma.components`, Kirigami theme colours) on
the primary display only, which is the first output in
`Workspace.screenOrder`, the order plasmashell sets. `HudPosition` picks an
edge or corner, and `HudShape` the flow: one `GridLayout` whose flow, rows
and columns follow the shape, with the label spanning the square's width and
the separators hidden there. It shows the current desktop and zoom, the camera and apply
actions, a help panel rendered from the binding config, and a menu that opens
the settings pages through `KCMLauncher.openSystemSettings`, as Overview does.

## Known limits

- **No interaction while zoomed.** The canvas is a navigation mode. This is
  the trade that makes the rest possible.
- **Output changes.** Hotplug or resolution change runs
  `checkWorkspacePosition` on every window and may pull far-off windows
  toward the new layout. The effect re-derives from geometry so nothing is
  lost, but positions can shift.
- **X11 windows** have 16-bit coordinates. Beyond about ±32k canvas pixels
  they cannot be placed.
- **Persistence.** `view` lives in the effect object and resets to (0,0) when
  KWin restarts. Window positions survive since they are real geometry, but
  the ground offset does not until the next commit.
- **Stock Zoom effect** binds Meta+wheel. Disable it or rebind.
- **Untested live.** The `evaluateScript` handoff and the wallpaper plugin have
  been rendered in isolation but not yet run inside a live plasmashell.

## Next

- Snap `zoom` to 1 with a short animation on commit.
- Drawing limits: a drawn sheet boundary that only grows, and `ZoomMin` from
  it rather than a constant.
- Auto-pan when dragging a window to the screen edge at 1:1. The move is
  KWin's; the effect can watch `Window.move` and shift the plane on a timer.
- Bookmarks, and a minimap while the canvas is open.
- Persist `view` in the effect's config on commit.
