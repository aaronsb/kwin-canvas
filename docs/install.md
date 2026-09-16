# Installing kwin-canvas

For KDE Plasma 6 on Wayland. Tested on Plasma 6.7.5. Nothing is compiled;
the effect and the wallpaper are QML packages.

## Try it without touching your desktop

From a checkout, a nested KWin opens as a window with the effect inside it:

```bash
git clone https://github.com/aaronsb/kwin-canvas.git
cd kwin-canvas
make deps      # lists anything missing and the pacman line to install it
make play      # nested KWin with five sample apps, canvas open
```

Inside that window: Ctrl+Alt+Space opens and applies, Esc cancels, wheel
zooms, drag the ground to pan, drag a window to move it, double-click a window
to focus it. `make nest-down` closes it.

## Install for real

### On Arch, from the AUR

```bash
yay -S kwin-canvas
```

The package puts both QML packages under `/usr/share`. Then enable the
effect as in step 3 below, or tick **Canvas** in Desktop Effects. After an
upgrade, log out and in once: KWin keeps the version it compiled at login.

### From the release tarballs

1. Download `kwin-canvas-0.2.0.kwineffect.tar.gz` from
   https://github.com/aaronsb/kwin-canvas/releases/latest.
   The wallpaper tarball is optional; see "The ground wallpaper" below.
2. Install the effect as a user package:

   ```bash
   kpackagetool6 --type KWin/Effect --install kwin-canvas-0.2.0.kwineffect.tar.gz
   ```

   To update later, replace `--install` with `--upgrade`.
3. Enable it: System Settings → Desktop Effects, search for **Canvas**, tick
   it, Apply. Or from a terminal:

   ```bash
   kwriteconfig6 --file kwinrc --group Plugins --key kwin-canvasEnabled true
   qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.loadEffect kwin-canvas
   ```

   The config line keeps it enabled across logins; the D-Bus call loads it
   into the running KWin. KWin's plain `reconfigure` does not load a newly
   enabled effect. Check with:

   ```bash
   qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.isEffectLoaded kwin-canvas
   ```

4. Press **Meta+Space**. The canvas opens zoomed out over your windows.
   Press **Esc** to close it again without changing anything.

### From a checkout

```bash
./configure.sh install    # both packages into ~/.local/share, then step 3
./configure.sh status     # what is installed, enabled and loaded
```

`configure.sh` is a short front for the Makefile: `make install enable` is
the same thing, and `make` alone lists every target.

### As a distro package

`make install-system DESTDIR=...` copies both packages into
`/usr/share/kwin/effects` and `/usr/share/plasma/wallpapers` under that
root, the same places `kpackagetool6 --global` uses, with no session calls.
`make pkgbuild` writes `dist/PKGBUILD` for the AUR from
`packaging/PKGBUILD.in`, and `make aur` publishes it after `make release`
has put the tag on GitHub. Users then enable the effect
in Desktop Effects or with step 3's D-Bus call. KWin keeps the version it
compiled at login, so an upgrade takes effect at the next login; the package
says so after installing.

## First use

- **Meta+Space** opens the canvas. It moves nothing until you apply.
- **Esc** closes it and leaves every window where it was.
- **Enter** applies: every window goes where you put it on the plane, and
  the frames decide what each screen shows in each activity. With one
  activity there is one group of frames; add more from a frame tag's plus
  button or in System Settings → Activities.
- Windows you drag outside every frame are off-screen at 1:1. Open the
  canvas again to find them, or activate them from the task manager and the
  plane pans to them.

The toolbar at the top of the primary display has the same actions, a help
button listing every control, and a settings menu.

## Make it yours

All of it is reassignable in System Settings:

| What | Where |
|---|---|
| Meta+Space and the other chords | Shortcuts → KWin, the entries starting with "Canvas" |
| A hot corner or edge that opens it | Screen Edges → pick **Canvas** for a corner |
| Keys inside the canvas, mouse gestures, opening view, toolbar position and shape | Desktop Effects → Canvas → configure |

## The ground wallpaper

Optional. `kwin-canvas-ground` is a wallpaper plugin that draws the canvas
grid at 1:1 and scrolls it as you pan, so the desktop itself shows where you
are on the plane. Install it and pick **Canvas Ground** in Desktop Settings:

```bash
kpackagetool6 --type Plasma/Wallpaper --install kwin-canvas-ground-0.2.0.tar.gz
```

Without it, your normal wallpaper stays, and the frames in the canvas show
it.

## Known limits in 0.2.0

- The monitor frames reproduce KDE's display arrangement and the canvas
  never changes it. Rearrange or resize displays in System Settings →
  Display Configuration; the frames follow.
- Every frame shows the current activity's wallpaper; Plasma keeps one
  desktop window per screen.
- No interaction with windows while zoomed out; the canvas is for arranging
  and navigating, work happens at 1:1.
- X11 (XWayland) windows cannot be placed beyond about ±32k pixels.
- An output change (plug or unplug a monitor, change resolution) can pull
  far-off windows back toward the screens.
- The pan position resets when KWin restarts; window positions survive.

## Turn it off or remove it

Untick **Canvas** in Desktop Effects, `./configure.sh uninstall` from a
checkout, or:

```bash
kwriteconfig6 --file kwinrc --group Plugins --key kwin-canvasEnabled false
qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.unloadEffect kwin-canvas
kpackagetool6 --type KWin/Effect --remove kwin-canvas
kpackagetool6 --type Plasma/Wallpaper --remove kwin-canvas-ground
```

Windows that were off-screen when you disabled it stay off-screen. Bring
them back with the task manager, or Meta+drag them from the edge.
