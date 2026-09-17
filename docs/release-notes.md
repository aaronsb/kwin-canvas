0.4.0 is the overworld: one chord out and back in, and the open canvas is
a live desktop.

- Two places. A location is an activity's screens at 1:1 with the canvas
  closed: stock Plasma, nothing of ours running, so games and fullscreen
  apps get KWin's native path. The overworld is the open canvas: every
  window live on the plane, the frames with their wallpaper, tags and the
  toolbar.
- One chord steps out and back in. Toggle Canvas now defaults to
  Meta+Ctrl+Alt+Space (was Meta+Space); KDE keeps an existing binding in
  kglobalshortcutsrc, so rebind by hand if you want the new one. Stepping
  out opens at the current viewport at 1:1 (`OpenZoom` default is now `1`;
  `fit` is still there). Stepping in enters the location under the screen
  centre, switching activity if that is another activity's frame, and
  writes the viewport where the camera is. Double-click a window's title
  bar or a frame to enter that location.
- Pass-through is live whenever the canvas is open, with the plugin loaded:
  pointer over a window's client area goes to the window, every key goes to
  the focused window, Esc included. Title bars, edges, frames, tags, ground
  and toolbar stay the canvas's; select windows from the title bar. Setting
  `Passthrough`, default on.
- Pan mode is gone. The slide stays: pan chords, the touchpad swipe,
  `PanStep`, `PanDuration` and activation-follow move the viewport within a
  location.
- Toolbar: Apply is now Enter; Cancel is back to where you were, nothing
  moved.
- `kwin-canvas`, a terminal CLI: `exit`, `cancel`, `open`, `toggle`,
  `status`. Works from a virtual terminal, the fallback when the chord does
  not reach the open canvas, and the way to toggle from a script or start
  in the overworld at login (`open` waits for the effect; an autostart
  entry is in docs/install.md, `AutoActivate` is the other route). `make
  install` puts it in `~/.local/bin`; the package in `/usr/bin`
  (`qt6-tools` is now a dependency).
- A Plasma applet, `kwin-canvas-toggle`: a panel button that fires the
  Toggle Canvas chord.

0.3.1 fixes where the pass-through plugin installs: Qt 6's plugin directory
(`/usr/lib/qt6/plugins/kwin/plugins`), which KWin searches; 0.3.0's package
put it under Qt 5's. Nothing else changed.

0.3.0 is about moving at 1:1 and reaching into windows from the canvas.

- Panning at 1:1 is a slide: the effect opens for a moment with no chrome,
  this activity's windows glide, their new positions are written once. Pan
  chords (Canvas Pan Left, Right, Up, Down; no default chord) step half a
  screen; a three-finger touchpad swipe follows the fingers.
- Pan mode: hold a chord (Canvas Pan Mode; no default chord) and drag the
  desktop with the mouse as often as you like, wheel to zoom out and see the
  whole plane, let go to settle with the point under the pointer kept, Esc
  to slide back.
- The pass-through plugin, `kwin-canvas-passthrough`, optional and built
  against your KWin: in pan mode, clicks, drags and the wheel reach the
  real windows, a click raises, title bars and edges move windows on the
  plane. Its own AUR package; rebuild it after a KWin upgrade.
- Double-click a window: the window's activity takes the viewport, and a
  window in another activity's frame takes you there. `FocusTarget` chooses
  between the point you clicked staying under the pointer (`window`) and a
  frame staying put (`desktop`).
- Dragging an activity's frames carries its windows along
  (`FramesCarryWindows`, on by default).
- Activation-follow moves minimized and other-desktop windows of the
  activity too, so the plane stays whole under a pan.
- The test nest renders to KWin's virtual backend, so the scenarios keep
  their timing when the nest is not on screen.

0.2.0 makes activities the frame axis and adds a short install path.

- Every activity is a group of monitor frames on the plane, in KDE's output
  layout. Drag windows into an activity's frames, drag frames over windows,
  apply. Switching activities at 1:1 switches viewport. Virtual desktops
  stay ordinary desktops; the canvas shows the current one.
- Frame tags: add an activity, remove one, and an eye that hides that frame
  for that activity and display. A hidden frame is not drawn and takes no
  windows.
- Selection (click, Shift+click, Ctrl+click, Shift+drag marquee), group
  drag with geometry kept, and an arrange menu on right-click: horizontal,
  vertical, tile, grid, cascade, send to an activity or to the plane.
- Snapping to edges, corners and the grid, with toolbar toggles.
- Colour-blind safe palettes for the frame colours.
- `configure.sh install | uninstall | enable | disable | status | try`, one
  Makefile target each, and `make install-system` with DESTDIR for distro
  packages. Enabling now loads the effect by name; KWin's plain reconfigure
  never did.

Install from a checkout with `./configure.sh install`, or:

```
kpackagetool6 --type KWin/Effect --install kwin-canvas-0.2.0.kwineffect.tar.gz
kpackagetool6 --type Plasma/Wallpaper --install kwin-canvas-ground-0.2.0.tar.gz
```

then enable "Canvas" in System Settings → Desktop Effects. KWin keeps the
effect it compiled at login, so after an upgrade log out and in once.
Tested on Plasma 6.7.5. Alpha: the effect moves real windows; try it in a
nested session first (`make play` from a checkout).
