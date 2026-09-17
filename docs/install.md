# Installing kwin-canvas

For KDE Plasma 6 on Wayland. Tested on Plasma 6.7.5. Nothing is compiled;
the effect, the wallpaper and the applet are QML packages, and the CLI is a
shell script.

## Try it without touching your desktop

From a checkout, a nested KWin opens as a window with the effect inside it:

```bash
git clone https://github.com/aaronsb/kwin-canvas.git
cd kwin-canvas
make deps      # lists anything missing and the pacman line to install it
make play      # nested KWin with five sample apps, canvas open
```

Inside that window: Ctrl+Alt+Space steps out to the overworld and back in,
Esc cancels, wheel over the ground zooms, drag the ground to pan, drag a
window's title bar to move it, double-click a title bar to enter that
window's location. `make nest-down` closes it.

## Install for real

### On Arch, from the AUR

```bash
yay -S kwin-canvas
```

The package puts the three QML packages under `/usr/share` and the
`kwin-canvas` CLI in `/usr/bin`. Then enable the
effect as in step 3 below, or tick **Canvas** in Desktop Effects. After an
upgrade, log out and in once: KWin keeps the version it compiled at login.

### From the release tarballs

1. Download `kwin-canvas-0.4.0.kwineffect.tar.gz` from
   https://github.com/aaronsb/kwin-canvas/releases/latest.
   The wallpaper and applet tarballs are optional; see "The ground
   wallpaper" and "The panel applet" below.
2. Install the effect as a user package:

   ```bash
   kpackagetool6 --type KWin/Effect --install kwin-canvas-0.4.0.kwineffect.tar.gz
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

4. Press **Meta+Ctrl+Alt+Space**. The overworld opens at 1:1 over your
   windows; wheel over the ground to zoom out. Press **Esc** to close it
   again without changing anything.

### From a checkout

```bash
./configure.sh install    # the packages into ~/.local/share, the CLI into ~/.local/bin, then step 3
./configure.sh status     # what is installed, enabled and loaded
```

`configure.sh` is a short front for the Makefile: `make install enable` is
the same thing, and `make` alone lists every target.

### As a distro package

`make install-system DESTDIR=...` copies the three packages into
`/usr/share/kwin/effects`, `/usr/share/plasma/wallpapers` and
`/usr/share/plasma/plasmoids` under that root, the same places
`kpackagetool6 --global` uses, and the CLI into `/usr/bin`, with no session
calls.
`make pkgbuild` writes `dist/PKGBUILD` for the AUR from
`packaging/PKGBUILD.in`, plus `dist/passthrough/PKGBUILD` for the plugin,
and `make aur` and `make aur-passthrough` publish them after `make release`
has put the tag on GitHub. Users then enable the effect
in Desktop Effects or with step 3's D-Bus call. KWin keeps the version it
compiled at login, so an upgrade takes effect at the next login; the package
says so after installing.

### The pass-through plugin

Optional. With it, the open canvas is a live desktop: the pointer over a
window's client area and every key reach the real windows. On Arch:

```bash
yay -S kwin-canvas-passthrough
```

From a checkout, with KWin's headers, cmake and extra-cmake-modules installed:

```bash
make plugin                              # build/plugin/bin/kwin/plugins/kwin_canvas_passthrough.so
sudo make plugin-install-system          # into /usr/lib/qt6/plugins/kwin/plugins
make plugin-status                       # built, installed, and whether the running KWin answers
```

KWin loads binary plugins at login and only when they were built for the running KWin version, so log out and in after installing, and rebuild the package after a KWin upgrade. The canvas asks the plugin over D-Bus each time it opens; when there is no answer, the open canvas is a navigation view and its own keys, Esc included, work. Nothing else changes.

## First use

There are two places to be. A **location** is your desktop as it is now: an
activity's screens at 1:1, the canvas closed, stock Plasma. The
**overworld** is the open canvas: every window live on the plane, each
activity as a group of monitor frames with its wallpaper inside.

- **Meta+Ctrl+Alt+Space** steps out to the overworld. It opens at 1:1 on
  your current viewport, so nothing looks different until you move; wheel
  over the ground to zoom out, drag the ground to pan. Nothing moves until
  you step in.
- **Meta+Ctrl+Alt+Space** again, or **Enter**, steps in: you enter the
  location under the screen centre. Every window goes where you put it on
  the plane, and the frames decide what each screen shows in each activity.
  If the screen centre is over another activity's frame, you switch to that
  activity. With one activity there is one group of frames; add more from a
  frame tag's plus button or in System Settings → Activities.
- **Esc** goes back to where you were and leaves every window where it was.
  With the pass-through plugin loaded, keys belong to the focused window,
  Esc included; use the chord, the toolbar's **Cancel**, or the CLI.
- Windows you drag outside every frame are off-screen in every location.
  Step out again to find them, or activate them from the task manager and
  the plane pans to them.
- **Fallback from a terminal**, even a virtual terminal (Ctrl+Alt+F3):
  `kwin-canvas exit` steps into the location under the screen centre and
  `kwin-canvas cancel` goes back; `kwin-canvas status` says whether the
  effect is loaded and the plugin answers.
- **The panel applet**: add the **Canvas** widget to a panel for a button
  that steps out and back in.
- **Toggle from a script**: `kwin-canvas toggle` steps out or in from
  anything that can run a command, a key daemon or a launcher included.

The toolbar at the top of the primary display has the same actions (**Enter**
and **Cancel** among them), a help button listing every control, and a
settings menu.

## Make it yours

All of it is reassignable in System Settings:

| What | Where |
|---|---|
| Meta+Ctrl+Alt+Space and the other chords | Shortcuts → KWin, the entries starting with "Canvas" |
| A hot corner or edge that opens it | Screen Edges → pick **Canvas** for a corner |
| Keys inside the canvas, mouse gestures, opening view, toolbar position and shape | Desktop Effects → Canvas → configure |

## Start in the overworld at login

Two ways, pick one:

1. The **AutoActivate** effect setting (Desktop Effects → Canvas →
   configure, or `kwriteconfig6 --file kwinrc --group Effect-kwin-canvas
   --key AutoActivate true`) opens the canvas as soon as the effect loads.
   That is at login, and also the moment the effect is turned on in a live
   session.
2. An autostart entry that runs the CLI. Save this as
   `~/.config/autostart/kwin-canvas.desktop`:

   ```ini
   [Desktop Entry]
   Type=Application
   Name=Canvas overworld
   Comment=Step out to the kwin-canvas overworld at login
   Exec=kwin-canvas open
   Icon=view-grid
   X-KDE-autostart-after=panel
   OnlyShowIn=KDE;
   ```

   Autostart entries can run before KWin has loaded the effect, so
   `kwin-canvas open` polls for the effect every half second for up to ten
   seconds and sends the command once it is there. The CLI must be on PATH:
   `/usr/bin` from the package, `~/.local/bin` from `make install`.

## The ground wallpaper

Optional. `kwin-canvas-ground` is a wallpaper plugin that draws the canvas
grid at 1:1 and scrolls it as you pan, so the desktop itself shows where you
are on the plane. Install it and pick **Canvas Ground** in Desktop Settings:

```bash
kpackagetool6 --type Plasma/Wallpaper --install kwin-canvas-ground-0.4.0.tar.gz
```

Without it, your normal wallpaper stays, and the frames in the canvas show
it.

## The panel applet

Optional. `kwin-canvas-toggle` is a Plasma applet: one panel button that
fires the Toggle Canvas chord, so a click steps out to the overworld and
another steps back in. Install it and add **Canvas** to a panel from Add
Widgets:

```bash
kpackagetool6 --type Plasma/Applet --install kwin-canvas-toggle-0.4.0.tar.gz
```

It invokes the chord by name through kglobalaccel, so it follows a
rebinding in System Settings.

## Known limits in 0.4.0

- The monitor frames reproduce KDE's display arrangement and the canvas
  never changes it. Rearrange or resize displays in System Settings →
  Display Configuration; the frames follow.
- Every frame shows the current activity's wallpaper; Plasma keeps one
  desktop window per screen.
- Without the pass-through plugin there is no interaction with windows in
  the overworld; it is for arranging and navigating, and work happens in a
  location. With the plugin the overworld is live, and a window's popups
  still open at its real position, off screen if the window is.
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
kpackagetool6 --type Plasma/Applet --remove org.kde.kwin.canvas.toggle
```

Windows that were off-screen when you disabled it stay off-screen. Bring
them back with the task manager, or Meta+drag them from the edge.
