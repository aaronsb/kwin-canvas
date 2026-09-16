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
