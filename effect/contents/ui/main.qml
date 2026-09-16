/*
    SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
    SPDX-License-Identifier: GPL-2.0-or-later
*/
/*
    kwin-canvas: an infinite canvas for KWin, built on the public scripting API.

    At 1:1 there is no effect running. Windows are ordinary KWin windows at
    ordinary positions, some of them off-screen. The screen is a 1:1 viewport
    onto one shared plane.

    Every virtual desktop is a viewport onto that same plane: a rigid group of
    monitor frames, one per output in the layout KDE knows, placed somewhere on
    the canvas. Switching desktops is switching viewport. Dragging a window
    into another desktop's frame moves it to that desktop.

    Opening the canvas snapshots every window into canvas coordinates and shows
    them as live thumbnails on a ground grid, with the frames drawn over them.
    Pan, zoom, drag windows, drag frames. Apply writes positions back as plain
    window geometry relative to the frame they sit in.

    Coordinate spaces:
      canvas   the plane windows live on; unbounded
      global   KWin's coordinate space across all outputs
      view     (viewX, viewY) is the canvas point the camera puts at global (0,0)
      target   per desktop: the canvas point at global (0,0) when that desktop
               is shown. Its frames are drawn at target + output.geometry.

      global = (canvas - view) * zoom
      canvas = view + global / zoom
      frame geometry = canvas - target(desktop of the window)

    While the canvas is closed, view == target(current desktop).
*/
import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.kwin as KWin
import org.kde.plasma.components as PC3

KWin.SceneEffect {
    id: effect

    // ---- camera ------------------------------------------------------------
    property real viewX: 0
    property real viewY: 0
    property real zoom: 1.0
    property real entryViewX: 0
    property real entryViewY: 0

    // ---- targets: desktop id -> {x, y} -------------------------------------
    property var targets: ({})
    property var entryTargets: ({})

    // ---- model -------------------------------------------------------------
    // Each entry: { window, desktop, x, y, width, height } in canvas units, bottom to top.
    property var entries: []
    property int revision: 0
    property bool helpOpen: false
    // Selection: window internalId -> true. selectionRev bumps on every change.
    property var selected: ({})
    property int selectionRev: 0

    function isSelected(e) { return e && selected[e.window.internalId] === true; }
    function selectOnly(e) { selected = {}; if (e) selected[e.window.internalId] = true; selectionRev++; }
    function selectAdd(e) { if (e) selected[e.window.internalId] = true; selectionRev++; }
    function selectToggle(e) {
        if (!e) return;
        if (selected[e.window.internalId]) delete selected[e.window.internalId]; else selected[e.window.internalId] = true;
        selectionRev++;
    }
    function clearSelection() { selected = {}; selectionRev++; }
    function selectedCount() { let n = 0; for (const k in selected) n++; return n; }
    // Add every window whose canvas rect meets the rectangle.
    function selectInRect(x, y, w, h) {
        for (let i = 0; i < entries.length; ++i) {
            const e = entries[i];
            if (e.x < x + w && e.x + e.width > x && e.y < y + h && e.y + e.height > y) selected[e.window.internalId] = true;
        }
        selectionRev++;
    }
    function desktopColor(d) { return palette[desktopIndex(d) % palette.length]; }
    property int lastDebugSeq: 0

    // ---- key bindings, from config ------------------------------------------
    // Each entry is a list of Qt key codes parsed from a comma-separated list
    // of Qt key names without the Key_ prefix ("Return,Enter").
    property var bindings: ({})

    function keysFor(spec) {
        const out = [];
        const names = String(spec || "").split(",");
        for (let i = 0; i < names.length; ++i) {
            const n = names[i].trim();
            if (!n) continue;
            const code = Qt["Key_" + n];
            if (code === undefined) { console.warn("kwin-canvas: unknown key name", n); continue; }
            out.push(code);
        }
        return out;
    }

    function rebuildBindings() {
        bindings = {
            apply: keysFor(configuration.KeyApply),
            cancel: keysFor(configuration.KeyCancel),
            home: keysFor(configuration.KeyHome),
            origin: keysFor(configuration.KeyOrigin),
            fit: keysFor(configuration.KeyFit),
            zoomIn: keysFor(configuration.KeyZoomIn),
            zoomOut: keysFor(configuration.KeyZoomOut),
            pan: keysFor(configuration.KeyPan)
        };
    }

    function bound(action, key) {
        const list = bindings[action];
        if (!list) return false;
        for (let i = 0; i < list.length; ++i) if (list[i] === key) return true;
        return false;
    }

    // Mouse gestures: "Shift+DoubleClick" -> { count: 2, mods: Qt.ShiftModifier }.
    function gestureFor(spec) {
        let count = 0, mods = 0, button = Qt.LeftButton;
        const parts = String(spec || "").split("+");
        for (let i = 0; i < parts.length; ++i) {
            const p = parts[i].trim().toLowerCase();
            if (p === "click") count = 1;
            else if (p === "doubleclick") count = 2;
            else if (p === "rightclick") { count = 1; button = Qt.RightButton; }
            else if (p === "middleclick") { count = 1; button = Qt.MiddleButton; }
            else if (p === "shift") mods |= Qt.ShiftModifier;
            else if (p === "ctrl" || p === "control") mods |= Qt.ControlModifier;
            else if (p === "alt") mods |= Qt.AltModifier;
            else if (p === "meta") mods |= Qt.MetaModifier;
            else if (p) console.warn("kwin-canvas: unknown gesture part", p);
        }
        return { count: count, mods: mods, button: button };
    }

    function gestureMatches(spec, count, modifiers, button) {
        const g = gestureFor(spec);
        if (g.count === 0 || count !== g.count) return false;
        if ((button || Qt.LeftButton) !== g.button) return false;
        const mask = Qt.ShiftModifier | Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier;
        return (modifiers & mask) === g.mods;
    }

    function gestureLabel(spec) {
        return String(spec || "").replace(/DoubleClick/i, "double-click").replace(/RightClick/i, "right-click").replace(/MiddleClick/i, "middle-click").replace(/Click/, "click").toLowerCase();
    }

    // Legend text for an action: the configured names, lower-cased.
    function keyLabel(spec) {
        return String(spec || "").split(",").map(function (n) { return n.trim().toLowerCase(); }).join("/");
    }

    // The primary display: first in the order plasmashell set, else the first screen.
    readonly property var primaryScreen: KWin.Workspace.screenOrder.length > 0 ? KWin.Workspace.screenOrder[0] : KWin.Workspace.screens[0]

    readonly property real zoomMin: configuration.ZoomMin
    readonly property real zoomStep: configuration.ZoomStep
    readonly property var palette: ["#4fa3ff", "#ff9f43", "#2ecc71", "#e056fd", "#f9ca24", "#ff6b6b", "#48dbfb", "#c8d6e5"]

    // ---- window filter -----------------------------------------------------
    function isCanvasWindow(w, anyDesktop) {
        if (!w || w.deleted || !w.managed) return false;
        if (w.desktopWindow || w.dock || w.popupWindow || w.specialWindow) return false;
        if (w.minimized || w.hidden) return false;
        if (!anyDesktop && !w.onAllDesktops) {
            const cur = KWin.Workspace.currentDesktop;
            const ds = w.desktops;
            let on = false;
            for (let i = 0; i < ds.length; ++i) if (ds[i] === cur) on = true;
            if (!on) return false;
        }
        return true;
    }

    // ---- desktops and targets ----------------------------------------------
    function desktopOf(w) {
        if (w.onAllDesktops || w.desktops.length === 0) return KWin.Workspace.currentDesktop;
        return w.desktops[0];
    }

    function targetOf(d) {
        let t = targets[d.id];
        if (!t) {
            t = { x: viewX, y: viewY };
            targets[d.id] = t;
        }
        return t;
    }

    // Read-only lookup for bindings, so drawing a frame never fixes a
    // target before ensureTargets() has laid the desktop out.
    function peekTarget(d) {
        const t = targets[d.id];
        return t ? t : { x: viewX, y: viewY };
    }

    function desktopIndex(d) {
        const ds = KWin.Workspace.desktops;
        for (let i = 0; i < ds.length; ++i) if (ds[i] === d) return i;
        return 0;
    }

    // The current desktop's target is the camera. Desktops never placed get laid
    // out in a row beside it, which moves nothing: their windows' canvas
    // positions are derived from the target.
    function ensureTargets() {
        const ds = KWin.Workspace.desktops;
        const cur = KWin.Workspace.currentDesktop;
        const ci = desktopIndex(cur);
        const base = targetOf(cur);
        const vs = KWin.Workspace.virtualScreenGeometry;
        const step = vs.width + configuration.DesktopGap;
        // Rightmost placed target, so later additions never overlap.
        let right = -Infinity;
        for (let i = 0; i < ds.length; ++i) {
            const t = targets[ds[i].id];
            if (t) right = Math.max(right, t.x);
        }
        for (let i = 0; i < ds.length; ++i) {
            if (targets[ds[i].id]) continue;
            const x = right === -Infinity ? base.x + (i - ci) * step : right + step;
            targets[ds[i].id] = { x: x, y: base.y };
            right = Math.max(right, x);
        }
    }

    // A desktop was added or removed. KWin re-homes the windows of a removed
    // desktop; their geometry is unchanged, so they sit at the same screen
    // spot in the new desktop's viewport.
    function desktopsChanged() {
        ensureTargets();
        if (!visible) return;
        const ds = KWin.Workspace.desktops;
        for (let i = 0; i < entries.length; ++i) {
            const e = entries[i];
            if (e.window.deleted) continue;
            let alive = false;
            for (let j = 0; j < ds.length; ++j) if (ds[j] === e.desktop) alive = true;
            const d = desktopOf(e.window);
            if (alive && d === e.desktop) continue;
            const t = targetOf(d);
            e.desktop = d;
            e.x = e.frameX + t.x;
            e.y = e.frameY + t.y;
        }
        revision++;
    }

    function addDesktopAfter(d) {
        const n = KWin.Workspace.desktops.length;
        KWin.Workspace.createDesktop(desktopIndex(d) + 1, "Desktop " + (n + 1));
    }

    function removeDesktop(d) {
        if (desktopIndex(d) === 0) return;
        KWin.Workspace.removeDesktop(d);
    }

    function copyTargets(src) {
        const out = {};
        for (const k in src) out[k] = { x: src[k].x, y: src[k].y };
        return out;
    }

    // The desktop whose frames overlap a canvas rect the most, or null if none
    // touches it. A window straddling two frames goes to the larger share.
    function desktopAt(rect) {
        const ds = KWin.Workspace.desktops;
        const screens = KWin.Workspace.screens;
        let best = null, bestArea = 0;
        for (let i = 0; i < ds.length; ++i) {
            const t = peekTarget(ds[i]);
            for (let j = 0; j < screens.length; ++j) {
                const g = screens[j].geometry;
                const w = Math.min(rect.x + rect.width, t.x + g.x + g.width) - Math.max(rect.x, t.x + g.x);
                const h = Math.min(rect.y + rect.height, t.y + g.y + g.height) - Math.max(rect.y, t.y + g.y);
                if (w <= 0 || h <= 0) continue;
                if (w * h > bestArea) { bestArea = w * h; best = ds[i]; }
            }
        }
        return best;
    }

    function dragTarget(d, dx, dy) {
        const t = targetOf(d);
        t.x += dx / zoom;
        t.y += dy / zoom;
        revision++;
    }

    function makeEntry(w) {
        const d = desktopOf(w);
        const t = targetOf(d);
        const g = w.frameGeometry;
        return { window: w, desktop: d, x: g.x + t.x, y: g.y + t.y, width: g.width, height: g.height,
                 frameX: g.x, frameY: g.y, anchorRight: false, anchorBottom: false };
    }

    function snapshot() {
        const list = [];
        const stack = KWin.Workspace.stackingOrder;
        for (let i = 0; i < stack.length; ++i) {
            const w = stack[i];
            if (!isCanvasWindow(w, true)) continue;
            list.push(makeEntry(w));
        }
        entries = list;
        revision++;
    }

    // Follow the live state while the canvas is open: windows that appear,
    // close, restack, or change geometry on their own. Existing entries keep
    // their canvas position and absorb frame changes as deltas.
    function resync() {
        if (!visible) return;
        const byId = {};
        for (let i = 0; i < entries.length; ++i) byId[entries[i].window.internalId] = entries[i];
        const list = [];
        let changed = false;
        const stack = KWin.Workspace.stackingOrder;
        for (let i = 0; i < stack.length; ++i) {
            const w = stack[i];
            if (!isCanvasWindow(w, true)) continue;
            let e = byId[w.internalId];
            if (!e) { e = makeEntry(w); changed = true; }
            else if (syncEntry(e)) changed = true;
            list.push(e);
        }
        if (list.length !== entries.length) changed = true;
        else for (let i = 0; i < list.length; ++i) if (list[i] !== entries[i]) changed = true;
        if (changed) {
            entries = list;
            revision++;
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: effect.visible
        onTriggered: effect.resync()
    }

    // ---- camera ops --------------------------------------------------------
    function globalToCanvas(gx, gy) { return Qt.point(viewX + gx / zoom, viewY + gy / zoom); }

    // Zoom while holding the canvas point under `anchor` (global px) fixed on screen.
    function setZoom(z, anchor) {
        z = Math.max(zoomMin, Math.min(1.0, z));
        const c = globalToCanvas(anchor.x, anchor.y);
        zoom = z;
        viewX = c.x - anchor.x / zoom;
        viewY = c.y - anchor.y / zoom;
    }

    function panBy(dx, dy) {
        viewX -= dx / zoom;
        viewY -= dy / zoom;
    }

    // Look through the current desktop's frames.
    function home() {
        const t = targetOf(KWin.Workspace.currentDesktop);
        viewX = t.x;
        viewY = t.y;
        zoom = 1.0;
    }

    function origin() {
        viewX = 0;
        viewY = 0;
        zoom = 1.0;
    }

    // Fit every window and every frame into the active screen.
    function zoomExtents() {
        let l = Infinity, t = Infinity, r = -Infinity, b = -Infinity;
        for (let i = 0; i < entries.length; ++i) {
            const e = entries[i];
            l = Math.min(l, e.x); t = Math.min(t, e.y);
            r = Math.max(r, e.x + e.width); b = Math.max(b, e.y + e.height);
        }
        const vs = KWin.Workspace.virtualScreenGeometry;
        const ds = KWin.Workspace.desktops;
        for (let i = 0; i < ds.length; ++i) {
            const tg = peekTarget(ds[i]);
            l = Math.min(l, tg.x + vs.x); t = Math.min(t, tg.y + vs.y);
            r = Math.max(r, tg.x + vs.x + vs.width); b = Math.max(b, tg.y + vs.y + vs.height);
        }
        const sg = KWin.Workspace.activeScreen.geometry;
        const pad = 80;
        const z = Math.max(zoomMin, Math.min(1.0, Math.min((sg.width - 2 * pad) / (r - l), (sg.height - 2 * pad) / (b - t))));
        zoom = z;
        viewX = (l + r) / 2 - (sg.x + sg.width / 2) / zoom;
        viewY = (t + b) / 2 - (sg.y + sg.height / 2) / zoom;
    }

    // ---- open / close ------------------------------------------------------
    function open() {
        if (visible) return;
        entryViewX = viewX;
        entryViewY = viewY;
        zoom = 1.0;
        clearSelection();
        targets[KWin.Workspace.currentDesktop.id] = { x: viewX, y: viewY };
        ensureTargets();
        entryTargets = copyTargets(targets);
        snapshot();
        visible = true;
        openView();
    }

    // Where the camera starts: fit everything, stay at 1:1, or a zoom
    // anchored at the active screen's centre.
    function openView() {
        const spec = String(configuration.OpenZoom || "fit").trim().toLowerCase();
        if (spec === "fit") { zoomExtents(); return; }
        const z = Number(spec);
        if (!(z > 0) || z >= 1) return;
        const g = KWin.Workspace.activeScreen.geometry;
        setZoom(z, Qt.point(g.x + g.width / 2, g.y + g.height / 2));
    }

    // Write every window's geometry relative to the frame it sits in, move it to
    // that frame's desktop, put the camera on the current desktop's target, and
    // hand input back.
    function commit(activate) {
        for (const k in targets) {
            targets[k].x = Math.round(targets[k].x);
            targets[k].y = Math.round(targets[k].y);
        }
        const seen = {};
        for (let i = 0; i < entries.length; ++i) {
            const e = entries[i];
            if (e.window.deleted) continue;
            seen[e.window.internalId] = true;
            let d = desktopAt(e);
            if (!d) d = e.desktop;
            if (d !== e.desktop && !e.window.onAllDesktops) e.window.desktops = [d];
            e.desktop = d;
            const t = targetOf(d);
            e.window.frameGeometry = Qt.rect(Math.round(e.x - t.x), Math.round(e.y - t.y), e.width, e.height);
        }
        // Windows not shown (minimized, hidden) share the plane: keep them where
        // they were relative to their desktop's frames.
        const all = KWin.Workspace.stackingOrder;
        for (let i = 0; i < all.length; ++i) {
            const w = all[i];
            if (seen[w.internalId] || w.deleted || !w.managed) continue;
            if (w.desktopWindow || w.dock || w.popupWindow || w.specialWindow) continue;
            const d = desktopOf(w);
            const was = entryTargets[d.id], now = targetOf(d);
            if (!was) continue;
            const dx = was.x - now.x, dy = was.y - now.y;
            if (dx === 0 && dy === 0) continue;
            const g = w.frameGeometry;
            w.frameGeometry = Qt.rect(g.x + dx, g.y + dy, g.width, g.height);
        }
        const cur = targetOf(KWin.Workspace.currentDesktop);
        viewX = cur.x;
        viewY = cur.y;
        zoom = 1.0;
        publishGround();
        visible = false;
        if (activate && !activate.deleted) {
            KWin.Workspace.activeWindow = activate;
        }
    }

    function cancel() {
        targets = copyTargets(entryTargets);
        viewX = entryViewX;
        viewY = entryViewY;
        zoom = 1.0;
        visible = false;
    }

    function toggle() {
        if (visible) commit(null); else open();
    }

    // ---- named actions --------------------------------------------------------

    // focusWindow: apply with this window on screen and focused. A window that
    // overlaps a frame keeps that desktop's position; one outside every frame
    // gets the current desktop's active-screen frame centred on it.
    function focusWindow(entry) {
        if (!desktopAt(entry)) {
            const g = KWin.Workspace.activeScreen.geometry;
            const t = targetOf(KWin.Workspace.currentDesktop);
            t.x = entry.x + entry.width / 2 - (g.x + g.width / 2);
            t.y = entry.y + entry.height / 2 - (g.y + g.height / 2);
        }
        commit(entry.window);
    }

    // zoomToDesktop: camera fitted to that desktop's frames, canvas stays open.
    function zoomToDesktop(d) {
        const t = peekTarget(d);
        const vs = KWin.Workspace.virtualScreenGeometry;
        const l = t.x + vs.x, tp = t.y + vs.y, r = l + vs.width, b = tp + vs.height;
        const sg = KWin.Workspace.activeScreen.geometry;
        const pad = 60;
        const z = Math.max(zoomMin, Math.min(1.0, Math.min((sg.width - 2 * pad) / (r - l), (sg.height - 2 * pad) / (b - tp))));
        zoom = z;
        viewX = (l + r) / 2 - (sg.x + sg.width / 2) / zoom;
        viewY = (tp + b) / 2 - (sg.y + sg.height / 2) / zoom;
    }

    // gotoDesktop: apply with that desktop current, frames where they are.
    function gotoDesktop(d) {
        KWin.Workspace.currentDesktop = d;
        commit(null);
    }

    // newDesktopAt: a new desktop whose active-screen frame is centred on the
    // window, the window moved into it, applied and focused.
    function newDesktopAt(entry) {
        // Workspace.desktops is a live view, so remember ids, not the list.
        const before = {};
        const ds0 = KWin.Workspace.desktops;
        for (let i = 0; i < ds0.length; ++i) before[ds0[i].id] = true;
        KWin.Workspace.createDesktop(ds0.length, "Desktop " + (ds0.length + 1));
        const after = KWin.Workspace.desktops;
        let nd = null;
        for (let i = 0; i < after.length; ++i) if (!before[after[i].id]) nd = after[i];
        if (!nd) return;
        const g = KWin.Workspace.activeScreen.geometry;
        targets[nd.id] = { x: entry.x + entry.width / 2 - (g.x + g.width / 2),
                           y: entry.y + entry.height / 2 - (g.y + g.height / 2) };
        revision++;
        commit(entry.window);
    }

    // ---- arrange the selection ----------------------------------------------
    // Entries to arrange: the selection, or the one window the menu was opened on.
    property var contextEntry: null
    function arrangeTargets() {
        const out = [];
        for (let i = 0; i < entries.length; ++i) if (isSelected(entries[i])) out.push(entries[i]);
        if (out.length === 0 && contextEntry) out.push(contextEntry);
        out.sort(function (a, b) { return (a.y - b.y) || (a.x - b.x); });
        return out;
    }

    function bbox(list) {
        let l = Infinity, t = Infinity, r = -Infinity, b = -Infinity;
        for (let i = 0; i < list.length; ++i) {
            const e = list[i];
            l = Math.min(l, e.x); t = Math.min(t, e.y); r = Math.max(r, e.x + e.width); b = Math.max(b, e.y + e.height);
        }
        return { x: l, y: t, width: r - l, height: b - t };
    }

    // arrange MODE [ROWS COLS]: horizontal, vertical, cascade keep sizes;
    // tile and grid split the selection's bounding box into cells and
    // command each window to its cell.
    function arrange(mode, rows, cols) {
        const list = arrangeTargets();
        if (list.length === 0) return;
        const gap = configuration.ArrangeGap;
        const box = bbox(list);
        if (mode === "horizontal") {
            let x = box.x;
            for (let i = 0; i < list.length; ++i) { list[i].x = x; list[i].y = box.y; x += list[i].width + gap; }
        } else if (mode === "vertical") {
            let y = box.y;
            for (let i = 0; i < list.length; ++i) { list[i].x = box.x; list[i].y = y; y += list[i].height + gap; }
        } else if (mode === "cascade") {
            const step = 40;
            for (let i = 0; i < list.length; ++i) { list[i].x = box.x + i * step; list[i].y = box.y + i * step; }
        } else {
            if (mode === "tile" || !(rows > 0 && cols > 0)) {
                cols = Math.ceil(Math.sqrt(list.length));
                rows = Math.ceil(list.length / cols);
            }
            const cw = Math.max(50, Math.floor((box.width - gap * (cols - 1)) / cols));
            const ch = Math.max(50, Math.floor((box.height - gap * (rows - 1)) / rows));
            for (let i = 0; i < list.length; ++i) {
                const e = list[i];
                const r = Math.floor(i / cols), c = i % cols;
                e.x = box.x + c * (cw + gap);
                e.y = box.y + r * (ch + gap);
                const idx = entries.indexOf(e);
                if (idx >= 0) requestSize(idx, cw, ch, false, false);
            }
        }
        revision++;
    }

    // Dispatch a gesture on a window against the mouse bindings.
    signal contextRequested(var entry)

    function windowGesture(entry, count, modifiers, button) {
        if (gestureMatches(configuration.MouseContextMenu, count, modifiers, button)) {
            contextEntry = entry;
            if (!isSelected(entry)) selectOnly(entry);
            contextRequested(entry);
        } else if (gestureMatches(configuration.MouseNewDesktopAt, count, modifiers) && !desktopAt(entry)) {
            newDesktopAt(entry);
        } else if (gestureMatches(configuration.MouseFocusWindow, count, modifiers)) {
            focusWindow(entry);
        } else if (gestureMatches(configuration.MouseSelectToggle, count, modifiers)) {
            selectToggle(entry);
        } else if (gestureMatches(configuration.MouseSelectAdd, count, modifiers)) {
            selectAdd(entry);
        } else if (gestureMatches(configuration.MouseSelect, count, modifiers)) {
            selectOnly(entry);
        }
    }

    // The modifier of the add gesture is also the marquee modifier on the ground.
    function marqueeModifiers() { return gestureFor(configuration.MouseSelectAdd).mods; }

    function frameGesture(d, count, modifiers) {
        if (gestureMatches(configuration.MouseGotoDesktop, count, modifiers)) gotoDesktop(d);
        else if (gestureMatches(configuration.MouseZoomToDesktop, count, modifiers)) zoomToDesktop(d);
    }

    function pick(entry) { focusWindow(entry); }

    // Move a window on the canvas by a screen-space delta while the canvas is open.
    // Entries are addressed by index: the Repeater hands delegates a copy of the
    // element, so mutating modelData would never reach the committed table.
    // A selected window drags the whole selection; relative geometry is kept.
    function dragEntry(index, dx, dy) {
        const e = entries[index];
        if (!e) return;
        if (isSelected(e)) {
            for (let i = 0; i < entries.length; ++i) {
                if (!isSelected(entries[i])) continue;
                entries[i].x += dx / zoom;
                entries[i].y += dy / zoom;
            }
        } else {
            e.x += dx / zoom;
            e.y += dy / zoom;
        }
        revision++;
    }

    // Command the real window to a size while the canvas is open. Position is
    // untouched. The client answers with whatever size it accepts, and
    // syncSize() copies that back into the entry when the geometry changes.
    function requestSize(index, w, h, anchorRight, anchorBottom) {
        const e = entries[index];
        if (!e || e.window.deleted) return;
        e.anchorRight = anchorRight;
        e.anchorBottom = anchorBottom;
        const f = e.window.frameGeometry;
        e.window.frameGeometry = Qt.rect(f.x, f.y, Math.max(50, Math.round(w)), Math.max(50, Math.round(h)));
    }

    // Absorb a window's real frame change into its entry. Returns true if anything moved.
    function syncEntry(e) {
        if (!e || e.window.deleted) return false;
        const f = e.window.frameGeometry;
        let changed = false;
        if (f.x !== e.frameX || f.y !== e.frameY) {
            e.x += f.x - e.frameX;
            e.y += f.y - e.frameY;
            e.frameX = f.x;
            e.frameY = f.y;
            changed = true;
        }
        if (f.width !== e.width || f.height !== e.height) {
            if (e.anchorRight) e.x += e.width - f.width;
            if (e.anchorBottom) e.y += e.height - f.height;
            e.width = f.width;
            e.height = f.height;
            changed = true;
        }
        return changed;
    }

    function syncIndex(index) {
        if (syncEntry(entries[index])) revision++;
    }

    // ---- ground publication ------------------------------------------------
    KWin.DBusCall {
        id: groundCall
        service: "org.kde.plasmashell"
        path: "/PlasmaShell"
        dbusInterface: "org.kde.PlasmaShell"
        method: "evaluateScript"
    }

    function publishGround() {
        if (!configuration.PublishGround) return;
        const script =
            "const ds = desktops();" +
            "for (let i = 0; i < ds.length; ++i) {" +
            "  ds[i].currentConfigGroup = ['Wallpaper', 'kwin-canvas-ground', 'General'];" +
            "  ds[i].writeConfig('OffsetX', " + viewX + ");" +
            "  ds[i].writeConfig('OffsetY', " + viewY + ");" +
            "}";
        groundCall.arguments = [script];
        groundCall.call();
    }

    // ---- 1:1 behaviours (effect closed) ------------------------------------
    // Shift the current desktop's viewport: move its windows and its target.
    function shiftAll(dx, dy) {
        const all = KWin.Workspace.stackingOrder;
        for (let i = 0; i < all.length; ++i) {
            const w = all[i];
            if (!isCanvasWindow(w, false)) continue;
            const g = w.frameGeometry;
            w.frameGeometry = Qt.rect(g.x + dx, g.y + dy, g.width, g.height);
        }
        const t = targetOf(KWin.Workspace.currentDesktop);
        t.x -= dx;
        t.y -= dy;
        viewX = t.x;
        viewY = t.y;
        publishGround();
    }

    function intersects(a, b) {
        return a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y;
    }

    Connections {
        target: KWin.Workspace
        function onWindowActivated(w) {
            if (effect.visible || !effect.configuration.FollowActivation) return;
            if (!effect.isCanvasWindow(w, false)) return;
            const g = w.frameGeometry;
            if (effect.intersects(g, KWin.Workspace.virtualScreenGeometry)) return;
            const area = KWin.Workspace.clientArea(KWin.Workspace.PlacementArea, w);
            const dx = Math.round(area.x + (area.width - g.width) / 2 - g.x);
            const dy = Math.round(area.y + (area.height - g.height) / 2 - g.y);
            effect.shiftAll(dx, dy);
        }
        function onDesktopsChanged() { Qt.callLater(effect.desktopsChanged); }
        function onWindowAdded(w) { if (effect.visible) Qt.callLater(effect.resync); }
        function onWindowRemoved(w) { if (effect.visible) Qt.callLater(effect.resync); }
        // Switching desktops at 1:1 switches viewport: the ground follows.
        function onCurrentDesktopChanged() {
            if (effect.visible) return;
            const t = effect.targetOf(KWin.Workspace.currentDesktop);
            effect.viewX = t.x;
            effect.viewY = t.y;
            effect.publishGround();
        }
    }

    // ---- shortcuts ---------------------------------------------------------
    KWin.ShortcutHandler {
        name: "Toggle Canvas"
        text: "Canvas: open or close the canvas"
        sequence: effect.configuration.ToggleShortcut
        onActivated: effect.toggle()
    }
    KWin.ShortcutHandler {
        name: "Canvas Home"
        text: "Canvas: return this desktop to the origin"
        sequence: effect.configuration.HomeShortcut
        onActivated: {
            if (effect.visible) { effect.home(); return; }
            effect.open();
            const t = effect.targetOf(KWin.Workspace.currentDesktop);
            t.x = 0;
            t.y = 0;
            effect.commit(null);
        }
    }
    // The in-canvas actions as global shortcuts too, with no default chord,
    // so they can be bound in System Settings > Shortcuts > KWin. They act
    // only while the canvas is open.
    KWin.ShortcutHandler { name: "Canvas Apply";    text: "Canvas: apply and close";           sequence: ""; onActivated: if (effect.visible) effect.commit(null) }
    KWin.ShortcutHandler { name: "Canvas Cancel";   text: "Canvas: cancel";                    sequence: ""; onActivated: if (effect.visible) effect.cancel() }
    KWin.ShortcutHandler { name: "Canvas Fit";      text: "Canvas: zoom to fit";               sequence: ""; onActivated: if (effect.visible) effect.zoomExtents() }
    KWin.ShortcutHandler { name: "Canvas Origin";   text: "Canvas: camera to the origin";      sequence: ""; onActivated: if (effect.visible) effect.origin() }
    KWin.ShortcutHandler { name: "Canvas Zoom In";  text: "Canvas: zoom in";                   sequence: ""; onActivated: if (effect.visible) effect.setZoom(effect.zoom * effect.zoomStep, KWin.Workspace.cursorPos) }
    KWin.ShortcutHandler { name: "Canvas Zoom Out"; text: "Canvas: zoom out";                  sequence: ""; onActivated: if (effect.visible) effect.setZoom(effect.zoom / effect.zoomStep, KWin.Workspace.cursorPos) }

    // ---- screen edges ------------------------------------------------------
    // The Screen Edges settings page lists this effect (X-KWin-Border-Activate)
    // and writes the chosen corners into BorderActivate. One handler per edge;
    // pushing the pointer into it toggles the canvas, like Overview's hot corner.
    Instantiator {
        model: effect.configuration.BorderActivate
        delegate: KWin.ScreenEdgeHandler {
            required property int modelData
            enabled: true
            edge: modelData
            onActivated: effect.toggle()
        }
    }
    Instantiator {
        model: effect.configuration.TouchBorderActivate
        delegate: KWin.ScreenEdgeHandler {
            required property int modelData
            enabled: true
            mode: KWin.ScreenEdgeHandler.Touch
            edge: modelData
            onActivated: effect.toggle()
        }
    }

    // ---- nested test harness -----------------------------------------------
    // The harness writes DebugCommand + DebugSeq into kwinrc and calls reconfigure.
    function runDebug(cmd) {
        const a = cmd.trim().split(/\s+/);
        switch (a[0]) {
        case "open": open(); break;
        case "commit": commit(null); break;
        case "cancel": cancel(); break;
        case "toggle": toggle(); break;
        case "home": home(); break;
        case "origin": origin(); break;
        case "extents": zoomExtents(); break;
        case "pan": panBy(Number(a[1]), Number(a[2])); break;
        case "zoom": {
            const p = a.length >= 4 ? Qt.point(Number(a[2]), Number(a[3])) : KWin.Workspace.cursorPos;
            setZoom(Number(a[1]), p);
            break;
        }
        case "shift": shiftAll(Number(a[1]), Number(a[2])); break;
        case "drag": dragEntry(Number(a[1]), Number(a[2]), Number(a[3])); break;
        case "resize": requestSize(Number(a[1]), Number(a[2]), Number(a[3]), false, false); break;
        case "resetview": {
            // 1:1 only: forget the pan history so canvas == frame for this desktop.
            if (visible) break;
            viewX = 0; viewY = 0;
            targets[KWin.Workspace.currentDesktop.id] = { x: 0, y: 0 };
            break;
        }
        case "placeby": {
            // placeby CAPTION_SUBSTR X Y [W H]: position (and size) an entry by caption.
            for (let i = 0; i < entries.length; ++i) {
                const e = entries[i];
                if (e.window.caption.indexOf(a[1]) === -1) continue;
                e.x = Number(a[2]); e.y = Number(a[3]);
                if (a.length >= 6) requestSize(i, Number(a[4]), Number(a[5]), false, false);
                revision++;
                break;
            }
            break;
        }
        case "place": {
            const e = entries[Number(a[1])];
            if (e) { e.x = Number(a[2]); e.y = Number(a[3]); revision++; }
            break;
        }
        case "frames": {
            // frames DX DY [desktopIndex]
            const ds = KWin.Workspace.desktops;
            const d = a.length >= 4 ? ds[Number(a[3])] : KWin.Workspace.currentDesktop;
            dragTarget(d, Number(a[1]), Number(a[2]));
            break;
        }
        case "pick": pick(entries[Number(a[1])]); break;
        case "focus": focusWindow(entries[Number(a[1])]); break;
        case "goto": gotoDesktop(KWin.Workspace.desktops[Number(a[1])]); break;
        case "zoomto": zoomToDesktop(KWin.Workspace.desktops[Number(a[1])]); break;
        case "newdesktopat": newDesktopAt(entries[Number(a[1])]); break;
        case "activate": {
            const all = KWin.Workspace.stackingOrder;
            for (let i = 0; i < all.length; ++i) {
                if (all[i].caption.indexOf(a[1]) !== -1) { KWin.Workspace.activeWindow = all[i]; break; }
            }
            break;
        }
        case "desktop": KWin.Workspace.currentDesktop = KWin.Workspace.desktops[Number(a[1])]; break;
        case "adddesktop": addDesktopAfter(KWin.Workspace.desktops[Number(a[1])]); break;
        case "rmdesktop": removeDesktop(KWin.Workspace.desktops[Number(a[1])]); break;
        case "list": {
            const all = KWin.Workspace.stackingOrder;
            let s = "kwin-canvas windows:";
            for (let i = 0; i < all.length; ++i) {
                const w = all[i]; const g = w.frameGeometry;
                s += "\n  " + (isCanvasWindow(w, true) ? "*" : " ") + " " + w.caption + " frame=(" + g.x + "," + g.y + " " + g.width + "x" + g.height + ") desktop=" + (w.onAllDesktops ? "all" : desktopOf(w).name);
            }
            console.log(s);
            break;
        }
        case "help": helpOpen = !helpOpen; break;
        case "select": selectOnly(entries[Number(a[1])]); break;
        case "selectadd": selectAdd(entries[Number(a[1])]); break;
        case "selecttoggle": selectToggle(entries[Number(a[1])]); break;
        case "clearsel": clearSelection(); break;
        case "arrange": arrange(a[1], Number(a[2]), Number(a[3])); break;
        case "marquee": selectInRect(Number(a[1]), Number(a[2]), Number(a[3]), Number(a[4])); break;
        case "state": break;
        default: console.warn("kwin-canvas: unknown debug command", cmd);
        }
        logState();
    }

    function logState() {
        const cur = KWin.Workspace.currentDesktop;
        let s = "kwin-canvas state visible=" + visible + " zoom=" + zoom.toFixed(4) + " view=(" + viewX.toFixed(1) + "," + viewY.toFixed(1) + ") desktop=" + cur.name + " entries=" + entries.length;
        const ds = KWin.Workspace.desktops;
        for (let i = 0; i < ds.length; ++i) {
            const t = peekTarget(ds[i]);
            s += "\n  {" + i + "} " + ds[i].name + " target=(" + t.x.toFixed(0) + "," + t.y.toFixed(0) + ")";
        }
        for (let i = 0; i < entries.length; ++i) {
            const e = entries[i];
            const g = e.window.frameGeometry;
            s += "\n  [" + i + "] " + (isSelected(e) ? "*" : " ") + e.window.caption + " canvas=(" + e.x.toFixed(0) + "," + e.y.toFixed(0) + " " + e.width + "x" + e.height + ") frame=(" + g.x + "," + g.y + ") desktop=" + e.desktop.name;
        }
        console.log(s);
    }

    onConfigurationChanged: {
        rebuildBindings();
        const seq = configuration.DebugSeq;
        if (seq !== lastDebugSeq) {
            lastDebugSeq = seq;
            const cmd = configuration.DebugCommand;
            if (cmd && cmd.length > 0) runDebug(cmd);
        }
    }

    Component.onCompleted: {
        rebuildBindings();
        lastDebugSeq = configuration.DebugSeq;
        if (configuration.AutoActivate) {
            Qt.callLater(open);
        }
    }

    // ---- controls ----------------------------------------------------------
    // Every draggable thing on the canvas is a Grip and every clickable thing
    // is an IconButton. Both count themselves into the view's hoverCount so
    // the pan handler stands down while the pointer is over them, both set
    // their own cursor, and both are disabled while Space is held.

    component Grip : Item {
        id: grip
        required property Item viewItem
        property int cursor: Qt.ArrowCursor
        property bool tappable: false
        property alias buttons: gripDrag.acceptedButtons
        readonly property bool hovered: gripHover.hovered
        readonly property bool active: gripDrag.active
        readonly property point total: gripDrag.activeTranslation
        signal dragStarted()
        signal dragged(real dx, real dy)
        signal dragEnded()
        signal tapped(int count, int modifiers, int button)

        HoverHandler {
            id: gripHover
            enabled: !grip.viewItem.spaceHeld
            cursorShape: gripDrag.active && grip.cursor === Qt.ArrowCursor ? Qt.ClosedHandCursor : grip.cursor
            onHoveredChanged: grip.viewItem.hoverCount += hovered ? 1 : -1
            Component.onDestruction: if (hovered) grip.viewItem.hoverCount -= 1
        }
        DragHandler {
            id: gripDrag
            target: null
            enabled: !grip.viewItem.spaceHeld
            acceptedButtons: Qt.LeftButton
            property point last: Qt.point(0, 0)
            onActiveChanged: {
                last = Qt.point(0, 0);
                if (active) grip.dragStarted(); else grip.dragEnded();
            }
            onActiveTranslationChanged: {
                const t = activeTranslation;
                grip.dragged(t.x - last.x, t.y - last.y);
                last = t;
            }
        }
        TapHandler {
            id: gripTap
            enabled: grip.tappable && !grip.viewItem.spaceHeld
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            onTapped: (eventPoint, button) => grip.tapped(tapCount, point.modifiers, button)
        }
    }

    component IconButton : Rectangle {
        id: button
        required property Item viewItem
        property string icon: ""
        property color hoverColor: "#60ffffff"
        signal clicked()
        width: 18
        height: 18
        radius: 3
        color: buttonHover.hovered ? hoverColor : "#30ffffff"
        Kirigami.Icon {
            anchors.fill: parent
            anchors.margins: 2
            source: button.icon
            color: "#ffffff"
        }
        HoverHandler {
            id: buttonHover
            cursorShape: Qt.PointingHandCursor
            onHoveredChanged: button.viewItem.hoverCount += hovered ? 1 : -1
            Component.onDestruction: if (hovered) button.viewItem.hoverCount -= 1
        }
        TapHandler {
            acceptedButtons: Qt.LeftButton
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: button.clicked()
        }
    }

    // The desktop's name tag: a Grip for its frame group, plus the desktop
    // controls KDE's pager has: add after, remove.
    component FrameTag : Grip {
        id: tag
        required property var desktop
        required property int desktopIndex
        required property var screen
        readonly property bool current: desktop === KWin.Workspace.currentDesktop
        readonly property color accent: effect.palette[desktopIndex % effect.palette.length]
        cursor: Qt.SizeAllCursor
        width: tagRow.implicitWidth + 12
        height: tagRow.implicitHeight + 6
        onDragged: (dx, dy) => effect.dragTarget(desktop, dx, dy)

        Rectangle {
            anchors.fill: parent
            radius: 3
            color: tag.accent
            opacity: tag.current ? 1 : 0.8
        }
        Row {
            id: tagRow
            anchors.centerIn: parent
            spacing: 6
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: tag.desktop.name + " \u00b7 " + tag.screen.name + "  " + tag.screen.geometry.width + "x" + tag.screen.geometry.height
                color: "#ffffff"
                font.pixelSize: 12
                font.bold: true
            }
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                viewItem: tag.viewItem
                icon: "list-add"
                onClicked: effect.addDesktopAfter(tag.desktop)
            }
            IconButton {
                visible: tag.desktopIndex > 0
                anchors.verticalCenter: parent.verticalCenter
                viewItem: tag.viewItem
                icon: "edit-delete"
                hoverColor: "#80ff4040"
                onClicked: effect.removeDesktop(tag.desktop)
            }
        }
    }

    // ---- per-screen view ---------------------------------------------------
    delegate: Item {
        id: view
        readonly property var screen: KWin.SceneView.screen
        readonly property rect sg: KWin.SceneView.screen.geometry
        property bool spaceHeld: false
        // Modifiers, tracked from key events, for the ground handlers.
        property int heldModifiers: 0
        // Number of grips and buttons under the pointer. The pan handler
        // refuses a left press while this is non-zero, so a drag that starts
        // on one of them acts on it instead of racing the pan.
        property int hoverCount: 0
        readonly property bool overControl: hoverCount > 0
        focus: true
        Connections {
            target: effect
            function onVisibleChanged() { if (effect.visible) view.hoverCount = 0; }
        }

        Ground {
            anchors.fill: parent
            originX: -effect.viewX * effect.zoom - view.sg.x
            originY: -effect.viewY * effect.zoom - view.sg.y
            zoom: effect.zoom
            baseSpacing: effect.configuration.GridBase
            octaveFactor: effect.configuration.GridOctaveFactor
            octaves: effect.configuration.GridOctaves
            background: effect.configuration.Background
            lineColor: effect.configuration.LineColor
            tileImage: effect.configuration.TileImage
        }

        // Pan: left-drag on the ground, middle-drag anywhere, or hold Space and
        // left-drag anywhere (Space disables every Grip and IconButton).
        // Ground click: drop the selection.
        TapHandler {
            enabled: !view.spaceHeld && !view.overControl
            acceptedButtons: Qt.LeftButton
            onTapped: (eventPoint, button) => { if ((point.modifiers & effect.marqueeModifiers()) === 0) effect.clearSelection(); }
        }

        // Marquee: the add gesture's modifier plus a drag on the ground selects by rectangle.
        DragHandler {
            id: marquee
            target: null
            // Latched while active: crossing a window mid-drag must not end the gesture.
            enabled: active || (!view.spaceHeld && !view.overControl && effect.marqueeModifiers() !== 0 && (view.heldModifiers & effect.marqueeModifiers()) !== 0)
            acceptedButtons: Qt.LeftButton
            onActiveChanged: {
                if (active) {
                    marqueeBox.x0 = centroid.pressPosition.x; marqueeBox.y0 = centroid.pressPosition.y;
                    marqueeBox.x1 = marqueeBox.x0; marqueeBox.y1 = marqueeBox.y0;
                } else {
                    // The centroid resets on release; the box kept the last corner.
                    const r = marqueeBox.rect;
                    const c0 = effect.globalToCanvas(r.x + view.sg.x, r.y + view.sg.y);
                    effect.selectInRect(c0.x, c0.y, r.width / effect.zoom, r.height / effect.zoom);
                }
            }
            onActiveTranslationChanged: {
                marqueeBox.x1 = marqueeBox.x0 + activeTranslation.x;
                marqueeBox.y1 = marqueeBox.y0 + activeTranslation.y;
            }
        }
        Rectangle {
            id: marqueeBox
            property real x0: 0
            property real y0: 0
            property real x1: 0
            property real y1: 0
            readonly property rect rect: Qt.rect(Math.min(x0, x1), Math.min(y0, y1), Math.abs(x1 - x0), Math.abs(y1 - y0))
            visible: marquee.active
            z: 90000
            x: rect.x; y: rect.y; width: rect.width; height: rect.height
            color: Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g, Kirigami.Theme.highlightColor.b, 0.15)
            border.width: 1
            border.color: Kirigami.Theme.highlightColor
        }

        DragHandler {
            id: panDrag
            target: null
            enabled: active || !marquee.enabled
            acceptedButtons: (active || view.spaceHeld || !view.overControl) ? (Qt.LeftButton | Qt.MiddleButton) : Qt.MiddleButton
            cursorShape: active ? Qt.ClosedHandCursor : (view.spaceHeld ? Qt.OpenHandCursor : Qt.ArrowCursor)
            property point last: Qt.point(0, 0)
            onActiveChanged: last = Qt.point(0, 0)
            onActiveTranslationChanged: {
                const t = activeTranslation;
                effect.panBy(t.x - last.x, t.y - last.y);
                last = t;
            }
        }

        // Zoom at the cursor.
        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: (event) => {
                const steps = event.angleDelta.y / 120;
                if (steps === 0) return;
                const anchor = Qt.point(event.x + view.sg.x, event.y + view.sg.y);
                effect.setZoom(effect.zoom * Math.pow(effect.zoomStep, steps), anchor);
            }
        }

        // Z order, back to front: ground, monitor frames with their real
        // desktop background, windows in KWin's stacking order, frame tags, HUD.

        // Monitor frames: one per desktop per output. A desktop's frames are a
        // rigid group; dragging any edge band moves them all. The interior is
        // the Plasma desktop background for that output, so each frame reads
        // as a desk top.
        Repeater {
            model: KWin.Workspace.desktops
            delegate: Repeater {
                id: desktopFrames
                required property var modelData
                required property int index
                readonly property var desktop: modelData
                readonly property bool current: modelData === KWin.Workspace.currentDesktop
                readonly property color accent: effect.palette[index % effect.palette.length]
                model: KWin.Workspace.screens
                delegate: Item {
                    id: frame
                    required property var modelData
                    readonly property rect og: modelData.geometry
                    x: { effect.revision; return (effect.peekTarget(desktopFrames.desktop).x + og.x - effect.viewX) * effect.zoom - view.sg.x; }
                    y: { effect.revision; return (effect.peekTarget(desktopFrames.desktop).y + og.y - effect.viewY) * effect.zoom - view.sg.y; }
                    width: og.width * effect.zoom
                    height: og.height * effect.zoom
                    z: 1

                    // An empty activity makes KWin 6.7 dereference a null
                    // activities object when activities are disabled, so
                    // always pass a non-empty one.
                    KWin.DesktopBackground {
                        anchors.fill: parent
                        output: frame.modelData
                        desktop: desktopFrames.desktop
                        activity: KWin.Workspace.currentActivity || "default"
                    }

                    // Sheet tint: keeps the frame legible when no background window exists.
                    Rectangle {
                        anchors.fill: parent
                        color: desktopFrames.accent
                        opacity: desktopFrames.current ? 0.10 : 0.06
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.width: desktopFrames.current ? 2 : 1
                        border.color: desktopFrames.accent
                        opacity: desktopFrames.current ? 0.95 : 0.6
                    }

                    // A gesture on the frame's own area (windows sit above and
                    // take their own taps).
                    TapHandler {
                        enabled: !view.spaceHeld
                        acceptedButtons: Qt.LeftButton
                        onTapped: effect.frameGesture(desktopFrames.desktop, tapCount, point.modifiers)
                    }

                    // Edge bands: grips for the whole group.
                    Repeater {
                        model: 4
                        delegate: Grip {
                            required property int index
                            readonly property int band: 8
                            viewItem: view
                            cursor: Qt.SizeAllCursor
                            x: index === 1 ? frame.width - band : 0
                            y: index === 3 ? frame.height - band : 0
                            width: (index === 0 || index === 2) ? frame.width : band
                            height: (index === 1 || index === 3) ? frame.height : band
                            onDragged: (dx, dy) => effect.dragTarget(desktopFrames.desktop, dx, dy)
                        }
                    }
                }
            }
        }

        // Windows.
        Repeater {
            model: effect.entries.length
            delegate: Item {
                id: thumb
                required property int index
                // The entry object keeps its identity across drags, so the
                // geometry bindings read the table directly and depend on
                // revision to re-evaluate after dragEntry().
                readonly property var entry: effect.entries[index]
                x: { effect.revision; return (effect.entries[index].x - effect.viewX) * effect.zoom - view.sg.x; }
                y: { effect.revision; return (effect.entries[index].y - effect.viewY) * effect.zoom - view.sg.y; }
                width: { effect.revision; return effect.entries[index].width * effect.zoom; }
                height: { effect.revision; return effect.entries[index].height * effect.zoom; }
                z: 1000 + index

                KWin.WindowThumbnail {
                    anchors.fill: parent
                    client: thumb.entry.window
                }

                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    readonly property bool sel: { effect.selectionRev; return effect.isSelected(thumb.entry); }
                    border.width: sel ? 3 : (body.hovered || body.active ? 2 : 1)
                    border.color: sel ? Kirigami.Theme.highlightColor
                                : (body.hovered || body.active ? effect.desktopColor(thumb.entry.desktop) : "#40ffffff")
                }

                Text {
                    anchors.left: parent.left
                    anchors.bottom: parent.top
                    anchors.bottomMargin: 2
                    text: thumb.entry.window.caption
                    color: "#ffffff"
                    font.pixelSize: 12
                    visible: effect.zoom < 0.6 || body.hovered
                    style: Text.Outline
                    styleColor: "#000000"
                }

                // The client decides the size it ends up with. Follow it.
                Connections {
                    target: thumb.entry.window
                    function onFrameGeometryChanged() { effect.syncIndex(thumb.index); }
                }

                // Body: move on drag, pick on click.
                Grip {
                    id: body
                    anchors.fill: parent
                    viewItem: view
                    tappable: true
                    onDragged: (dx, dy) => effect.dragEntry(thumb.index, dx, dy)
                    onTapped: (count, modifiers, button) => effect.windowGesture(thumb.entry, count, modifiers, button)
                }

                // Resize grips: four edges, four corners, above the body. Each
                // drag step commands the real window to the new size.
                Repeater {
                    model: 8
                    delegate: Grip {
                        id: grip
                        required property int index
                        readonly property int b: 6
                        readonly property int c: 14
                        readonly property bool north: index === 0 || index === 4 || index === 5
                        readonly property bool south: index === 1 || index === 6 || index === 7
                        readonly property bool west: index === 2 || index === 4 || index === 6
                        readonly property bool east: index === 3 || index === 5 || index === 7
                        readonly property bool corner: index >= 4
                        property real startW: 0
                        property real startH: 0
                        viewItem: view
                        z: 10
                        x: corner ? (west ? 0 : thumb.width - c) : (west ? 0 : (east ? thumb.width - b : c))
                        y: corner ? (north ? 0 : thumb.height - c) : (north ? 0 : (south ? thumb.height - b : c))
                        width: corner ? c : ((west || east) ? b : Math.max(0, thumb.width - 2 * c))
                        height: corner ? c : ((north || south) ? b : Math.max(0, thumb.height - 2 * c))
                        cursor: corner
                            ? ((north && west) || (south && east) ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor)
                            : ((north || south) ? Qt.SizeVerCursor : Qt.SizeHorCursor)
                        onDragStarted: {
                            startW = thumb.entry.width;
                            startH = thumb.entry.height;
                        }
                        onDragged: {
                            const t = grip.total;
                            let rw = startW, rh = startH;
                            if (east) rw = startW + t.x / effect.zoom;
                            if (west) rw = startW - t.x / effect.zoom;
                            if (south) rh = startH + t.y / effect.zoom;
                            if (north) rh = startH - t.y / effect.zoom;
                            effect.requestSize(thumb.index, rw, rh, west, north);
                        }
                    }
                }
            }
        }

        // Frame tags, above the windows so they can always be grabbed.
        Repeater {
            model: KWin.Workspace.desktops
            delegate: Repeater {
                id: desktopTags
                required property var modelData
                required property int index
                model: KWin.Workspace.screens
                delegate: FrameTag {
                    required property var modelData
                    viewItem: view
                    desktop: desktopTags.modelData
                    desktopIndex: desktopTags.index
                    screen: modelData
                    x: { effect.revision; return (effect.peekTarget(desktop).x + screen.geometry.x - effect.viewX) * effect.zoom - view.sg.x; }
                    y: { effect.revision; return (effect.peekTarget(desktop).y + screen.geometry.y - effect.viewY) * effect.zoom - view.sg.y - height - 2; }
                    z: 60000
                }
            }
        }

        function modifierOf(key) {
            switch (key) {
            case Qt.Key_Shift: return Qt.ShiftModifier;
            case Qt.Key_Control: return Qt.ControlModifier;
            case Qt.Key_Alt: return Qt.AltModifier;
            case Qt.Key_Meta: return Qt.MetaModifier;
            }
            return 0;
        }

        Keys.onPressed: (event) => {
            const k = event.key;
            const m = view.modifierOf(k);
            if (m) { view.heldModifiers |= m; return; }
            if (effect.bound("pan", k)) {
                if (!event.isAutoRepeat) view.spaceHeld = true;
            } else if (effect.bound("cancel", k)) {
                effect.cancel();
            } else if (effect.bound("apply", k)) {
                effect.commit(null);
            } else if (effect.bound("home", k)) {
                effect.home();
            } else if (effect.bound("origin", k)) {
                effect.origin();
            } else if (effect.bound("fit", k)) {
                effect.zoomExtents();
            } else if (effect.bound("zoomIn", k)) {
                effect.setZoom(effect.zoom * effect.zoomStep, KWin.Workspace.cursorPos);
            } else if (effect.bound("zoomOut", k)) {
                effect.setZoom(effect.zoom / effect.zoomStep, KWin.Workspace.cursorPos);
            } else {
                return;
            }
            event.accepted = true;
        }

        Keys.onReleased: (event) => {
            const m = view.modifierOf(event.key);
            if (m) { view.heldModifiers &= ~m; return; }
            if (effect.bound("pan", event.key) && !event.isAutoRepeat) {
                view.spaceHeld = false;
                event.accepted = true;
            }
        }

        // Arrange menu for the selection, opened by the context gesture on a window.
        Connections {
            target: effect
            function onContextRequested(entry) {
                // Attached properties resolve against this Connections object, so go through the view.
                if (view.screen !== KWin.Workspace.activeScreen) return;
                const p = KWin.Workspace.cursorPos;
                arrangeMenu.x = p.x - view.sg.x;
                arrangeMenu.y = p.y - view.sg.y;
                arrangeMenu.open();
            }
        }
        PC3.Menu {
            id: arrangeMenu
            z: 100001
            title: "Arrange"
            PC3.MenuItem { text: "Arrange horizontally"; icon.name: "view-split-left-right"; onTriggered: effect.arrange("horizontal") }
            PC3.MenuItem { text: "Arrange vertically";   icon.name: "view-split-top-bottom"; onTriggered: effect.arrange("vertical") }
            PC3.MenuItem { text: "Tile";                 icon.name: "view-grid";             onTriggered: effect.arrange("tile") }
            PC3.Menu {
                title: "Grid"
                icon.name: "view-grid"
                Repeater {
                    model: ["1x2", "2x1", "2x2", "3x1", "1x3", "3x2", "2x3", "3x3", "4x2", "2x4"]
                    delegate: PC3.MenuItem {
                        required property string modelData
                        text: modelData.replace("x", " × ") + "  (rows × columns)"
                        onTriggered: { const p = modelData.split("x"); effect.arrange("grid", Number(p[0]), Number(p[1])); }
                    }
                }
            }
            PC3.MenuItem { text: "Cascade";              icon.name: "window-duplicate";      onTriggered: effect.arrange("cascade") }
            PC3.MenuSeparator {}
            PC3.MenuItem { text: "Clear selection";      icon.name: "edit-select-none";      onTriggered: effect.clearSelection() }
        }

        // HUD: a Plasma toolbar, top centre. Camera state, the actions, help
        // with the bindings, and the settings pages that own them.
        Rectangle {
            id: hud
            z: 100000
            visible: view.screen === effect.primaryScreen
            readonly property string pos: String(effect.configuration.HudPosition || "Top").toLowerCase()
            readonly property bool atTop: pos.indexOf("top") === 0 || pos === "left" || pos === "right" ? pos.indexOf("bottom") !== 0 : false
            readonly property bool atBottom: pos.indexOf("bottom") === 0
            readonly property bool atLeft: pos === "left" || pos === "topleft" || pos === "bottomleft"
            readonly property bool atRight: pos === "right" || pos === "topright" || pos === "bottomright"
            readonly property bool centredV: pos === "left" || pos === "right"
            readonly property bool inCorner: pos === "topleft" || pos === "topright" || pos === "bottomleft" || pos === "bottomright"
            // Shape: auto follows the position (square in a corner, vertical on
            // a side, horizontal on the top or bottom), or forced by config.
            readonly property string shape: {
                const want = String(effect.configuration.HudShape || "auto").toLowerCase();
                if (want === "horizontal" || want === "vertical" || want === "square") return want;
                return inCorner ? "square" : (centredV ? "vertical" : "horizontal");
            }
            readonly property bool vertical: shape === "vertical"
            readonly property bool square: shape === "square"
            readonly property int squareColumns: 4
            anchors.top: atBottom || centredV ? undefined : parent.top
            anchors.bottom: atBottom ? parent.bottom : undefined
            anchors.verticalCenter: centredV ? parent.verticalCenter : undefined
            anchors.left: atLeft ? parent.left : undefined
            anchors.right: atRight ? parent.right : undefined
            anchors.horizontalCenter: !atLeft && !atRight ? parent.horizontalCenter : undefined
            anchors.margins: Kirigami.Units.largeSpacing
            width: hudRow.implicitWidth + Kirigami.Units.largeSpacing * 2
            height: hudRow.implicitHeight + Kirigami.Units.smallSpacing * 2
            radius: Kirigami.Units.cornerRadius
            color: Qt.rgba(Kirigami.Theme.backgroundColor.r, Kirigami.Theme.backgroundColor.g, Kirigami.Theme.backgroundColor.b, 0.85)
            border.width: 1
            border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)
            Kirigami.Theme.inherit: false
            Kirigami.Theme.colorSet: Kirigami.Theme.Window

            HoverHandler {
                onHoveredChanged: view.hoverCount += hovered ? 1 : -1
                Component.onDestruction: if (hovered) view.hoverCount -= 1
            }

            GridLayout {
                id: hudRow
                anchors.centerIn: parent
                flow: hud.vertical ? GridLayout.TopToBottom : GridLayout.LeftToRight
                rows: hud.vertical ? -1 : (hud.square ? -1 : 1)
                columns: hud.vertical ? 1 : (hud.square ? hud.squareColumns : -1)
                rowSpacing: Kirigami.Units.smallSpacing
                columnSpacing: Kirigami.Units.smallSpacing

                // Separators only in the linear shapes; a square reads as rows.
                component Sep : Kirigami.Separator {
                    visible: !hud.square
                    Layout.fillHeight: !hud.vertical
                    Layout.fillWidth: hud.vertical
                    Layout.margins: Kirigami.Units.smallSpacing
                }

                Kirigami.Icon {
                    visible: !hud.square
                    source: "virtual-desktops"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    Layout.alignment: Qt.AlignCenter
                }
                PC3.Label {
                    text: hud.vertical ? KWin.Workspace.currentDesktop.name + "\n" + Math.round(effect.zoom * 100) + "%"
                                       : KWin.Workspace.currentDesktop.name + "   " + Math.round(effect.zoom * 100) + "%"
                    horizontalAlignment: Text.AlignHCenter
                    Layout.alignment: Qt.AlignCenter
                    Layout.columnSpan: hud.square ? hud.squareColumns : 1
                    Layout.rightMargin: hud.vertical || hud.square ? 0 : Kirigami.Units.smallSpacing
                }
                // One swatch per desktop in its frame colour; click to zoom to it.
                Repeater {
                    model: KWin.Workspace.desktops
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        readonly property bool current: modelData === KWin.Workspace.currentDesktop
                        width: Kirigami.Units.iconSizes.small
                        height: Kirigami.Units.iconSizes.small
                        radius: 3
                        color: effect.palette[index % effect.palette.length]
                        border.width: current ? 2 : 0
                        border.color: Kirigami.Theme.textColor
                        Layout.alignment: Qt.AlignCenter
                        PC3.ToolTip.text: modelData.name
                        PC3.ToolTip.visible: swatchHover.hovered
                        HoverHandler { id: swatchHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { acceptedButtons: Qt.LeftButton; onTapped: effect.zoomToDesktop(modelData) }
                    }
                }
                Sep {}
                PC3.ToolButton { icon.name: "zoom-fit-best";   text: "Fit";    display: PC3.AbstractButton.IconOnly; PC3.ToolTip.text: "Zoom to fit (" + effect.keyLabel(effect.configuration.KeyFit) + ")"; PC3.ToolTip.visible: hovered; onClicked: effect.zoomExtents() }
                PC3.ToolButton { icon.name: "go-home";         text: "Home";   display: PC3.AbstractButton.IconOnly; PC3.ToolTip.text: "Look through this desktop's frames (" + effect.keyLabel(effect.configuration.KeyHome) + ")"; PC3.ToolTip.visible: hovered; onClicked: effect.home() }
                PC3.ToolButton { icon.name: "zoom-in";         text: "In";     display: PC3.AbstractButton.IconOnly; PC3.ToolTip.text: "Zoom in (" + effect.keyLabel(effect.configuration.KeyZoomIn) + ")"; PC3.ToolTip.visible: hovered; onClicked: effect.setZoom(effect.zoom * effect.zoomStep, Qt.point(view.sg.x + view.sg.width / 2, view.sg.y + view.sg.height / 2)) }
                PC3.ToolButton { icon.name: "zoom-out";        text: "Out";    display: PC3.AbstractButton.IconOnly; PC3.ToolTip.text: "Zoom out (" + effect.keyLabel(effect.configuration.KeyZoomOut) + ")"; PC3.ToolTip.visible: hovered; onClicked: effect.setZoom(effect.zoom / effect.zoomStep, Qt.point(view.sg.x + view.sg.width / 2, view.sg.y + view.sg.height / 2)) }
                Sep {}
                PC3.ToolButton { icon.name: "dialog-ok-apply"; text: "Apply";  display: hud.vertical || hud.square ? PC3.AbstractButton.IconOnly : PC3.AbstractButton.TextBesideIcon; PC3.ToolTip.text: "Apply and close (" + effect.keyLabel(effect.configuration.KeyApply) + ")"; PC3.ToolTip.visible: hovered; onClicked: effect.commit(null) }
                PC3.ToolButton { icon.name: "dialog-cancel";   text: "Cancel"; display: hud.vertical || hud.square ? PC3.AbstractButton.IconOnly : PC3.AbstractButton.TextBesideIcon; PC3.ToolTip.text: "Close without changes (" + effect.keyLabel(effect.configuration.KeyCancel) + ")"; PC3.ToolTip.visible: hovered; onClicked: effect.cancel() }
                Sep {}
                PC3.ToolButton { id: helpButton; icon.name: "help-contextual"; text: "Help"; display: PC3.AbstractButton.IconOnly; checkable: true; checked: effect.helpOpen; onToggled: effect.helpOpen = checked; PC3.ToolTip.text: "Controls"; PC3.ToolTip.visible: hovered }
                PC3.ToolButton {
                    icon.name: "configure"; text: "Settings"; display: PC3.AbstractButton.IconOnly
                    PC3.ToolTip.text: "Settings"; PC3.ToolTip.visible: hovered
                    onClicked: settingsMenu.open()
                    PC3.Menu {
                        id: settingsMenu
                        x: hud.vertical ? (hud.atRight ? -width : parent.width) : 0
                        y: hud.vertical ? 0 : parent.height
                        PC3.MenuItem { text: "Effect settings…";  icon.name: "preferences-desktop-effects"; onTriggered: KCM.KCMLauncher.openSystemSettings("kcm_kwin_effects") }
                        PC3.MenuItem { text: "Shortcuts…";        icon.name: "preferences-desktop-keyboard"; onTriggered: KCM.KCMLauncher.openSystemSettings("kcm_keys") }
                        PC3.MenuItem { text: "Screen edges…";     icon.name: "preferences-desktop-screen-edges"; onTriggered: KCM.KCMLauncher.openSystemSettings("kcm_kwinscreenedges") }
                        PC3.MenuItem { text: "Virtual desktops…"; icon.name: "virtual-desktops"; onTriggered: KCM.KCMLauncher.openSystemSettings("kcm_kwin_virtualdesktops") }
                    }
                }
            }
        }

        // Help: the bindings, read from the same config the actions use.
        Rectangle {
            z: 100000
            visible: effect.helpOpen && hud.visible
            anchors.top: hud.vertical ? hud.top : (hud.atBottom ? undefined : hud.bottom)
            anchors.bottom: !hud.vertical && hud.atBottom ? hud.top : undefined
            anchors.left: hud.vertical ? (hud.atLeft ? hud.right : undefined) : (hud.atLeft ? hud.left : undefined)
            anchors.right: hud.vertical ? (hud.atRight ? hud.left : undefined) : (hud.atRight ? hud.right : undefined)
            anchors.horizontalCenter: !hud.vertical && !hud.atLeft && !hud.atRight ? hud.horizontalCenter : undefined
            anchors.margins: Kirigami.Units.smallSpacing
            width: helpGrid.implicitWidth + Kirigami.Units.largeSpacing * 2
            height: helpGrid.implicitHeight + Kirigami.Units.largeSpacing * 2
            radius: Kirigami.Units.cornerRadius
            color: Qt.rgba(Kirigami.Theme.backgroundColor.r, Kirigami.Theme.backgroundColor.g, Kirigami.Theme.backgroundColor.b, 0.92)
            border.width: 1
            border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)
            Kirigami.Theme.inherit: false
            Kirigami.Theme.colorSet: Kirigami.Theme.Window
            HoverHandler {
                onHoveredChanged: view.hoverCount += hovered ? 1 : -1
                Component.onDestruction: if (hovered) view.hoverCount -= 1
            }
            GridLayout {
                id: helpGrid
                anchors.centerIn: parent
                columns: 2
                columnSpacing: Kirigami.Units.largeSpacing
                rowSpacing: Kirigami.Units.smallSpacing
                component K : PC3.Label { font.family: "monospace"; opacity: 0.85 }
                component V : PC3.Label {}
                K { text: "drag ground / " + effect.keyLabel(effect.configuration.KeyPan) + "+drag / middle-drag" } V { text: "pan" }
                K { text: "wheel / " + effect.keyLabel(effect.configuration.KeyZoomIn) + " / " + effect.keyLabel(effect.configuration.KeyZoomOut) } V { text: "zoom at the cursor" }
                K { text: "drag window" }                                       V { text: "move it on the plane" }
                K { text: "drag window edge or corner" }                        V { text: "resize it" }
                K { text: "drag frame tag or edge" }                            V { text: "move that desktop's screens" }
                K { text: effect.gestureLabel(effect.configuration.MouseSelect) + " window" }        V { text: "select it" }
                K { text: effect.gestureLabel(effect.configuration.MouseSelectAdd) + " window, or +drag ground" } V { text: "add to the selection, or select by rectangle" }
                K { text: effect.gestureLabel(effect.configuration.MouseSelectToggle) + " window" }  V { text: "toggle its selection; a selected window drags the whole selection" }
                K { text: effect.gestureLabel(effect.configuration.MouseContextMenu) + " window" }   V { text: "arrange the selection: horizontal, vertical, tile, grid, cascade" }
                K { text: effect.gestureLabel(effect.configuration.MouseFocusWindow) + " window" }   V { text: "apply, focused on it" }
                K { text: effect.gestureLabel(effect.configuration.MouseZoomToDesktop) + " frame" }  V { text: "zoom to that desktop" }
                K { text: effect.gestureLabel(effect.configuration.MouseGotoDesktop) + " frame" }    V { text: "apply with that desktop current" }
                K { text: effect.gestureLabel(effect.configuration.MouseNewDesktopAt) + " window outside frames" } V { text: "new desktop centred on it" }
                K { text: effect.keyLabel(effect.configuration.KeyApply) }      V { text: "apply and close" }
                K { text: effect.keyLabel(effect.configuration.KeyCancel) }     V { text: "cancel" }
                K { text: effect.keyLabel(effect.configuration.KeyHome) }       V { text: "look through this desktop's frames" }
                K { text: effect.keyLabel(effect.configuration.KeyOrigin) }     V { text: "camera to the canvas origin" }
                K { text: effect.keyLabel(effect.configuration.KeyFit) }        V { text: "zoom to fit" }
            }
        }
    }
}
