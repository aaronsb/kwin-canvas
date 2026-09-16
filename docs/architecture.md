# Architecture

## The model

Three coordinate spaces:

| Space | Meaning |
|---|---|
| canvas | the plane windows live on; unbounded |
| global | KWin's coordinate space across all outputs |
| screen | one output's local pixels; `global - output.geometry.topLeft` |

One camera and one target per activity. `view` is the canvas point the
camera puts at global (0,0), and `zoom` is its scale. `target(a)` is the
canvas point at global (0,0) when activity `a` is shown; its monitor frames
are drawn at `target(a) + output.geometry` for every output, so each activity
is a rigid group of frames in KDE's layout, placed anywhere on the plane.
While the canvas is closed, `view == target(current activity)`.

```
global = (canvas - view) * zoom
canvas = view + global / zoom
frame geometry = canvas - target(activity of the window)
```

A window's canvas position is its KWin geometry plus its own activity's
target. Activities never placed are laid out in a row beside the current one
on first open, which moves nothing. Virtual desktops stay ordinary KWin
desktops: the canvas shows the current desktop's windows across every
activity, and a desktop switch changes the set of windows, not the view.

A frame can be switched off from its tag. `HiddenFrames` lists
`activityId|outputName` keys; a hidden frame is not drawn, is not a snap
candidate, is left out of fit, and never claims a window on apply. The
effect writes the key through its own `configuration` map and
`writeConfig()`, so the choice survives a restart.

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
targets, snapshots every canvas window of the current desktop, on every
activity, in stacking order into `entries[] = {window, activity, x, y, width,
height}` with `x = frame.x + target(activity).x` and so on, then moves the camera to the
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

Dragging a frame's name tag or edge band changes that activity's target. The
camera is never involved in what gets applied.

**Commit.** For every entry, the activity whose frame overlaps the entry the
most wins: the window's `activities` list is set to that one if it differs
(a window on every activity stays on every activity), and
`frameGeometry = entry - target(that activity)`. An entry in no frame keeps
its activity. Windows not shown (minimized, hidden, other desktops) are
shifted by how much their activity's target moved, so they stay put on the
plane. The camera is set to the current activity's target at zoom 1, the
ground offset is published, and the effect hides. `pick()` first centres the
current activity's active-screen frame on the window if no frame contains
it. `cancel()` restores the targets and `entryView` and hides without
writing anything.

**Activity switch at 1:1.** `currentActivityChanged` sets `view` to the new
activity's target and republishes the ground, so the wallpaper scrolls to
where that activity's viewport sits on the plane.

**Activities.** KWin's `Workspace` exposes `activities` (ids), a writable
`currentActivity`, and `activitiesChanged` for single additions and
removals; the bulk load from the activity manager after startup arrives with
no signal, so the effect re-reads the list on every open, change, and debug
command. Names are not in the scripting API: one `DBusCall` per id asks
`org.kde.ActivityManager` for `ActivityName`, and `AddActivity` and
`RemoveActivity` back the tag's plus and trash buttons. `AddActivity`
answers asynchronously with the id, so "new activity at a window" parks the
window until the reply, then places the target, moves the window, makes the
activity current and applies. Activating a window on another activity does
not switch KWin to it. With activities disabled the list is empty and one
unnamed activity stands in.

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
is a `DesktopBackground` item for its output, the current desktop and the
frame's activity, which is the real Plasma wallpaper. Plasmashell keeps one
desktop window per screen, on every activity, and swaps its containment on
an activity switch, so every frame shows the current activity's wallpaper;
the other activities' wallpapers appear only at 1:1 after switching. A faint
tint in the activity's colour sits over it so the frame reads as a sheet
even with no background window, as in the nest.

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

## Snapping

Drags keep unsnapped positions (`dragRaw`, `targetRaw`) and snap the moving
set's bounding box as one, so a drag can always pull away. Candidates are
every other window and every activity's frames that are not hidden. Edges snap per axis, corners
only when both axes meet the same candidate, the grid rounds left and top to
`SnapGridSize`; the nearest within `SnapDistance` screen pixels wins. Resize
grips snap the edge being dragged through `snapEdge1D`. The three toggles
start from config on each open and live in the toolbar.

## Send to

`sendTo(activity)` translates each selected window by the difference between
its current frame's target and the destination's, so it keeps its place on
screen in the new activity. `sendTo(null)` parks the set's bounding box at the
nearest of a few spots around the union of all frames, the origin first.
Activity colours come from `palettes[Palette]`; okabe-ito, tol and ibm are
published colour-blind safe sets, mono is luminance only, and tag text
picks black or white by luminance.

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
the separators hidden there. It shows the current activity and zoom, one swatch per activity, the camera
and apply actions, a help panel rendered from the binding config, and a menu that opens
the settings pages through `KCMLauncher.openSystemSettings`, as Overview does.

## Known limits

- **Frames are not editable.** They are the outputs in KDE's display
  arrangement, read from `Workspace.screens`; changing that layout is
  Display Configuration's job and the frames follow.
- **Frames share one wallpaper.** Plasmashell has one desktop window per
  screen, so every frame shows the current activity's wallpaper.
- **Activity changes are asynchronous.** Adding, removing or switching goes
  through the activity manager; the canvas follows when KWin reports it.

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
