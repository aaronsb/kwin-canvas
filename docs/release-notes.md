First cut. An infinite canvas for KDE Plasma as a KWin QML effect, on the
public scripting API with no patches.

- Windows on one shared plane; the screen is a 1:1 viewport onto it.
- Every virtual desktop is a group of monitor frames on the plane, in KDE's
  output layout, showing the real desktop background. Drag windows into
  frames or frames over windows, apply.
- Move, resize, focus, go to desktop, new desktop at a window, add and
  remove desktops, all from the canvas. Live resync while open.
- Opens zoomed to fit. Every key, chord, gesture and screen edge is
  reassignable through System Settings or the effect's configure dialog.
- A Canvas Ground wallpaper plugin that scrolls with the plane at 1:1.

Install:

```
kpackagetool6 --type KWin/Effect --install kwin-canvas-0.1.0.kwineffect.tar.gz
kpackagetool6 --type Plasma/Wallpaper --install kwin-canvas-ground-0.1.0.tar.gz
```

then enable "Canvas" in System Settings → Desktop Effects. Tested on
Plasma 6.7.5. Alpha: the effect moves real windows; try it in a nested
session first (`make play` from a checkout).
