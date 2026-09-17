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
- A pan chord or a touchpad swipe starts a slide (below).
- `Meta+Space` opens the canvas.

**Slide.** A pan at 1:1. `slide(dx, dy)` opens the canvas *quiet*: `open(true)`
snapshots as usual but skips the opening view, and while `quiet` is set the
per-screen delegate is disabled for input and draws only the ground and the
thumbnails, with no frames, tags, borders or toolbar. At zoom 1 that is
pixel-identical to the real screen when the Canvas Ground wallpaper is in
use. A `ParallelAnimation` moves `viewX`/`viewY` to `slideTo` over
`PanDuration` with an ease-out; a second slide while one runs adds to the
destination and restarts. On arrival the entry targets are restored and
`shiftAll` moves this activity's windows by the distance travelled, while
the thumbnails still cover them, and the effect hides. A slide is
navigation: only the current activity's windows are drawn while quiet, and
no window changes activity, so what slides is what 1:1 shows before and
after. A slide that ends where it began cancels instead. Any action that
wants the real canvas while a slide runs (`toggle`, Home) finishes the slide
first. A pan chord while the canvas is open moves the camera by the same
step and nothing more.

**Pan mode** is a slide held open with input on. The chord's handler opens
quiet and sets `panMode`; the view is enabled while quiet only in that
mode, and `panOnly` (Space held or pan mode) stands every grip and button
down, so left and middle drags reach the pan handler and the wheel is off.
The wheel zooms at the pointer as in the open canvas, and below 1:1
(`quietPlane`) the frames and every activity's windows are drawn, tags and
toolbar still off. The chord's keys are parsed from `PanModeShortcut`;
releasing the main key or any of its modifiers settles: the view and the
zoom animate together to 1:1 with the canvas point under the pointer kept
(`settleTarget`), then `endSlide` shifts the windows. Escape animates back
to the entry view and cancels, apply settles. KWin re-fires a held chord on
key autorepeat, so a second activation is ignored: release is the exit.

**Pass-through** is the optional binary plugin under `plugin/`, a
`KWin::Plugin` that is also an `InputEventFilter` at the global-shortcut
weight, ahead of the effects filter. Pan mode probes it over D-Bus
(`org.kde.KWin`, `/KWinCanvas`, `org.kde.kwin.canvas.Passthrough`); when it
answers, the effect publishes the camera to it on every change (view, zoom,
current activity, the targets as JSON) and switches it on. The filter maps
each pointer event to the plane, finds the topmost window the quiet canvas
would draw there (this activity's at 1:1, every activity's below), and if
the window's input surface takes the point, delivers the event to the
Wayland seat with the window's own input transformation, so the client sees
the same surface coordinates it would at 1:1. A press inside a window raises
it and starts an implicit grab until the buttons are up; a press on the
ground leaves the gesture to the effect. Over the ground the pointer leaves
the surface and events fall through, so the effect pans and zooms as
before. With pass-through live the thumbnail grips come back in pan mode:
the plugin has taken the client areas, so they only ever see title bars and
edges, and a drag there moves the window on the plane. Keys are not
forwarded. Settling writes every entry once from its plane position.

`endSlide` writes each shown window once, from its entry's canvas position
and its activity's final target, because writing a geometry makes the entry
absorb the change as a delta; windows the canvas does not show are shifted
by the slide as under a commit.

`shiftAll` moves every managed window on the current activity, or on all
activities, whether shown or not: minimized windows and other desktops'
windows keep their place on the plane under a pan, as they do under a
commit.

A touchpad swipe drives the same machinery live: the first progress value
opens quiet and records the base view, each progress value places the view
at `base - direction * step * progress`, and activation or cancellation
becomes a slide to the full step or back to the base. The fingers move the
content, so the camera goes the other way. Four `SwipeGestureHandler`s are
instantiated for the configured finger count, and re-instantiated only when
that count changes.

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

Dragging a frame's name tag or edge band changes that activity's target.
With `FramesCarryWindows` (default on) every entry on that activity moves by
the same delta, snapped as one with the frames, so the group travels the
plane as a unit and its windows keep their frame geometry at commit; off,
the frames move over the windows and the windows' frame geometry changes.
The camera is never involved in what gets applied.

**Commit.** For every entry, the activity whose frame overlaps the entry the
most wins: the window's `activities` list is set to that one if it differs
(a window on every activity stays on every activity), and
`frameGeometry = entry - target(that activity)`. An entry in no frame keeps
its activity. Windows not shown (minimized, hidden, other desktops) are
shifted by how much their activity's target moved, so they stay put on the
plane. The camera is set to the current activity's target at zoom 1, the
ground offset is published, and the effect hides. `pick()` (double-click) picks the
window's activity, the one whose frame holds it, else the one it belongs
to, and places that activity's target by `FocusTarget`: `window` sets it to
`canvas(pointer) - pointer`, so the point clicked stays under the pointer at
1:1, as a zoom-in there would; `desktop` leaves the target alone for a
window inside a frame and centres the active-screen frame on a window
outside every frame. If the activity is not current, the switch is
requested and the focus is applied when KWin reports it. `cancel()` restores the targets and `entryView` and hides without
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
- Binary plugins (`plugin.h`) are `KWin::Plugin` subclasses from a
  `PluginFactory`, loaded from `kwin/plugins` for the exact KWin version in
  the factory's interface id. `InputEventFilter` (`input.h`) is exported with
  its weights (`InputFilterOrder`), and `installInputEventFilter` puts one in
  the chain. The seat (`wayland/seat.h`) takes `notifyPointerEnter` with a
  transformation matrix, `notifyPointerMotion`, `notifyPointerButton`,
  `notifyPointerAxis` and `notifyPointerFrame`; `Window::inputTransformation`
  is the global-to-surface matrix KWin itself uses, and
  `SurfaceInterface::mapToInputSurface` finds the subsurface that takes input
  at a point. `Workspace::activateWindow` raises and focuses. The scripting
  `Workspace` has no stacking-order signal; `windowActivated` serves.
- `SwipeGestureHandler` and `PinchGestureHandler` (`scripting/gesturehandler.h`)
  register touchpad or touchscreen gestures from QML: `direction`,
  `fingerCount`, `deviceType`, a live `progress` from 0 to 1, and `activated`
  and `cancelled` signals. Every gesture registered for a finger count and
  direction fires, KWin's own included, so a count KWin uses fires both.
  Pointer axis shortcuts (`Meta+wheel`) are registered from C++ only.
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
(`ToggleShortcut`, `HomeShortcut`, `PanModeShortcut`, and `PanLeftShortcut`
through `PanDownShortcut`; the pan chords default to nothing). The keys the open canvas listens for are
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

- **No interaction while zoomed** without the plugin. The canvas is a
  navigation mode. With the pass-through plugin, pan mode hands the pointer
  to the real windows; keys still wait for the settle, and a window's popups
  open at its real position, off screen if the window is.
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
- Pan on a screen edge push at 1:1: the edge handlers fire once per push, so
  each push would be one step.
- Auto-pan when dragging a window to the screen edge at 1:1. The move is
  KWin's; the effect can watch `Window.move` and shift the plane on a timer.
- Bookmarks, and a minimap while the canvas is open.
- Persist `view` in the effect's config on commit.
