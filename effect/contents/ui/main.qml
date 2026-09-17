/*
    SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
    SPDX-License-Identifier: GPL-2.0-or-later
*/
/*
    kwin-canvas: an infinite canvas for KWin, built on the public scripting API.

    At 1:1 there is no effect running. Windows are ordinary KWin windows at
    ordinary positions, some of them off-screen. The screen is a 1:1 viewport
    onto one shared plane.

    Every activity is a viewport onto that same plane: a rigid group of
    monitor frames, one per output in the layout KDE knows, placed somewhere on
    the canvas. Switching activities is switching viewport. Dragging a window
    into another activity's frame moves it to that activity. Virtual desktops
    stay ordinary KWin desktops; the canvas shows the current one.

    Opening the canvas snapshots every window into canvas coordinates and shows
    them as live thumbnails on a ground grid, with the frames drawn over them.
    Pan, zoom, drag windows, drag frames. Apply writes positions back as plain
    window geometry relative to the frame they sit in.

    Coordinate spaces:
      canvas   the plane windows live on; unbounded
      global   KWin's coordinate space across all outputs
      view     (viewX, viewY) is the canvas point the camera puts at global (0,0)
      target   per activity: the canvas point at global (0,0) when that
               activity is shown. Its frames are drawn at target + output.geometry.

      global = (canvas - view) * zoom
      canvas = view + global / zoom
      frame geometry = canvas - target(activity of the window)

    While the canvas is closed, view == target(current activity).
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

    // ---- targets: activity id -> {x, y} ------------------------------------
    property var targets: ({})
    property var entryTargets: ({})

    // ---- model -------------------------------------------------------------
    // Each entry: { window, activity, x, y, width, height } in canvas units, bottom to top.
    property var entries: []
    property int revision: 0
    property bool helpOpen: false
    // Quiet: open at 1:1 for a slide, with no frames, tags, toolbar or input.
    property bool quiet: false
    readonly property bool canvasOpen: visible && !quiet
    // Pan mode: quiet, with the pointer live. Held chord, drag the desktop.
    property bool panMode: false
    property int panModeKey: 0
    property int panModeMods: 0
    // Zoomed out while quiet (the wheel in pan mode): the whole plane shows,
    // frames and every activity's windows, still with no tags or toolbar.
    readonly property bool quietPlane: quiet && zoom < 0.999
    // Pass-through: the optional binary plugin hands pointer events over
    // windows to the real windows while pan mode is on. Live once it has
    // answered the probe for this pan mode; the camera is published to it.
    readonly property bool passthroughWanted: configuration.PanModePassthrough !== false
    property bool passthroughLive: false
    property string passthroughVersion: ""
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
    function activityColor(id) { return palette[activityIndex(id) % palette.length]; }
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

    // The pan-mode chord's own keys: releasing any of them ends the mode.
    function readPanModeChord() {
        let key = 0, mods = 0;
        const parts = String(configuration.PanModeShortcut || "").split("+");
        for (let i = 0; i < parts.length; ++i) {
            const p = parts[i].trim();
            if (!p) continue;
            const l = p.toLowerCase();
            if (l === "meta") mods |= Qt.MetaModifier;
            else if (l === "ctrl" || l === "control") mods |= Qt.ControlModifier;
            else if (l === "alt") mods |= Qt.AltModifier;
            else if (l === "shift") mods |= Qt.ShiftModifier;
            else {
                const code = Qt["Key_" + p];
                if (code === undefined) console.warn("kwin-canvas: unknown key in PanModeShortcut", p); else key = code;
            }
        }
        panModeKey = key;
        panModeMods = mods;
    }

    function rebuildBindings() {
        readPanModeChord();
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
    // Activity colour schemes. The colour-blind safe ones are published sets:
    // Okabe & Ito (2008), Paul Tol's bright set, IBM's Carbon set. mono
    // differs by luminance only.
    readonly property var palettes: ({
        "default":   ["#4fa3ff", "#ff9f43", "#2ecc71", "#e056fd", "#f9ca24", "#ff6b6b", "#48dbfb", "#c8d6e5"],
        "okabe-ito": ["#0072B2", "#E69F00", "#009E73", "#CC79A7", "#56B4E9", "#D55E00", "#F0E442", "#999999"],
        "tol":       ["#4477AA", "#EE6677", "#228833", "#CCBB44", "#66CCEE", "#AA3377", "#BBBBBB"],
        "ibm":       ["#648FFF", "#FE6100", "#785EF0", "#FFB000", "#DC267F"],
        "mono":      ["#f2f2f2", "#b8b8b8", "#8a8a8a", "#5e5e5e", "#3a3a3a"]
    })
    readonly property var palette: palettes[String(configuration.Palette || "").toLowerCase()] || palettes["default"]

    // Text that reads on a swatch of the given colour.
    function textOn(c) {
        const col = Qt.color(c);
        return (0.299 * col.r + 0.587 * col.g + 0.114 * col.b) > 0.6 ? "#1a1a1a" : "#ffffff";
    }

    // ---- window filter -----------------------------------------------------
    // Windows of the current virtual desktop. anyActivity takes every
    // activity's windows (the canvas); otherwise the current activity's (1:1).
    function isCanvasWindow(w, anyActivity) {
        if (!w || w.deleted || !w.managed) return false;
        if (w.desktopWindow || w.dock || w.popupWindow || w.specialWindow) return false;
        if (w.minimized || w.hidden) return false;
        if (!w.onAllDesktops) {
            const cur = KWin.Workspace.currentDesktop;
            const ds = w.desktops;
            let on = false;
            for (let i = 0; i < ds.length; ++i) if (ds[i] === cur) on = true;
            if (!on) return false;
        }
        if (!anyActivity && !onActivity(w, currentActivity)) return false;
        return true;
    }

    // ---- activities and targets --------------------------------------------
    // KWin hands out activity ids only. With activities disabled the list is
    // empty and the current id is "", so one unnamed activity stands in.
    // The list is read explicitly: KWin announces single additions and
    // removals, and the bulk load from the activity manager after startup
    // arrives with no signal at all.
    property var activityIds: [""]
    readonly property string currentActivity: KWin.Workspace.currentActivity || ""
    function refreshActivities() {
        const a = KWin.Workspace.activities;
        const list = a && a.length > 0 ? Array.prototype.slice.call(a) : [""];
        if (list.join("\n") === activityIds.join("\n")) return false;
        activityIds = list;
        return true;
    }

    // Names come from the activity manager over D-Bus, one call per id,
    // refreshed on every open and whenever the list changes: bumping
    // namesReq re-instantiates the callers, and each calls once on creation.
    property var activityNames: ({})
    property int namesRev: 0
    property int namesReq: 0
    function refreshNames() { namesReq++; }
    function setActivityName(id, name) {
        if (activityNames[id] === name) return;
        activityNames[id] = name;
        namesRev++;
    }
    function labelOf(id) {
        namesRev;
        const n = activityNames[id];
        if (n) return n;
        return id ? "Activity " + (activityIndex(id) + 1) : "Activity";
    }

    Instantiator {
        model: { effect.namesReq; return effect.activityIds; }
        delegate: KWin.DBusCall {
            required property string modelData
            service: "org.kde.ActivityManager"
            path: "/ActivityManager/Activities"
            dbusInterface: "org.kde.ActivityManager.Activities"
            method: "ActivityName"
            arguments: [modelData]
            onFinished: (ret) => effect.setActivityName(modelData, String(ret[0]))
            Component.onCompleted: call()
        }
    }

    KWin.DBusCall {
        id: addActivityCall
        service: "org.kde.ActivityManager"
        path: "/ActivityManager/Activities"
        dbusInterface: "org.kde.ActivityManager.Activities"
        method: "AddActivity"
        onFinished: (ret) => effect.activityAdded(String(ret[0]))
    }
    KWin.DBusCall {
        id: removeActivityCall
        service: "org.kde.ActivityManager"
        path: "/ActivityManager/Activities"
        dbusInterface: "org.kde.ActivityManager.Activities"
        method: "RemoveActivity"
    }

    function onActivity(w, id) {
        const a = w.activities;
        if (!a || a.length === 0) return true;
        for (let i = 0; i < a.length; ++i) if (a[i] === id) return true;
        return false;
    }

    // The activity a window belongs to: the current one when it is there or
    // on every activity, else its first.
    function activityOf(w) {
        const a = w.activities;
        if (!a || a.length === 0 || onActivity(w, currentActivity)) return currentActivity;
        return a[0];
    }

    function targetOf(id) {
        let t = targets[id];
        if (!t) {
            t = { x: viewX, y: viewY };
            targets[id] = t;
        }
        return t;
    }

    // Read-only lookup for bindings, so drawing a frame never fixes a
    // target before ensureTargets() has laid the activity out.
    function peekTarget(id) {
        const t = targets[id];
        return t ? t : { x: viewX, y: viewY };
    }

    function activityIndex(id) {
        const ids = activityIds;
        for (let i = 0; i < ids.length; ++i) if (ids[i] === id) return i;
        return 0;
    }

    // ---- hidden frames -----------------------------------------------------
    // An activity used on one monitor need not carry frames for the others.
    // Keys are "activityId|outputName"; the set lives in HiddenFrames.
    property var hiddenFrames: ({})
    property int hiddenRev: 0
    function frameKey(id, screen) { return id + "|" + screen.name; }
    function isHidden(id, screen) { hiddenRev; return hiddenFrames[frameKey(id, screen)] === true; }
    function setHidden(id, screen, on) {
        const k = frameKey(id, screen);
        if (on) hiddenFrames[k] = true; else delete hiddenFrames[k];
        hiddenRev++;
        const list = [];
        for (const key in hiddenFrames) list.push(key);
        configuration.HiddenFrames = list;
        configuration.writeConfig();
        revision++;
    }
    function loadHiddenFrames() {
        const list = configuration.HiddenFrames || [];
        const set = {};
        for (let i = 0; i < list.length; ++i) if (list[i]) set[list[i]] = true;
        hiddenFrames = set;
        hiddenRev++;
    }
    // Every frame drawn: { id, screen, x, y, width, height } in canvas units.
    function frames() {
        const out = [];
        const ids = activityIds, screens = KWin.Workspace.screens;
        for (let i = 0; i < ids.length; ++i) {
            const t = peekTarget(ids[i]);
            for (let j = 0; j < screens.length; ++j) {
                if (isHidden(ids[i], screens[j])) continue;
                const g = screens[j].geometry;
                out.push({ id: ids[i], screen: screens[j], x: t.x + g.x, y: t.y + g.y, width: g.width, height: g.height });
            }
        }
        return out;
    }

    // The current activity's target is the camera. Activities never placed get
    // laid out in a row beside it, which moves nothing: their windows' canvas
    // positions are derived from the target.
    function ensureTargets() {
        const ids = activityIds;
        const cur = currentActivity;
        const ci = activityIndex(cur);
        const base = targetOf(cur);
        const vs = KWin.Workspace.virtualScreenGeometry;
        const step = vs.width + configuration.ActivityGap;
        // Rightmost placed target, so later additions never overlap.
        let right = -Infinity;
        for (let i = 0; i < ids.length; ++i) {
            const t = targets[ids[i]];
            if (t) right = Math.max(right, t.x);
        }
        for (let i = 0; i < ids.length; ++i) {
            if (targets[ids[i]]) continue;
            const x = right === -Infinity ? base.x + (i - ci) * step : right + step;
            targets[ids[i]] = { x: x, y: base.y };
            right = Math.max(right, x);
        }
    }

    // An activity was added or removed. KWin re-homes the windows of a removed
    // activity; their geometry is unchanged, so they sit at the same screen
    // spot in their new activity's viewport.
    function activitiesChanged() {
        refreshActivities();
        ensureTargets();
        refreshNames();
        if (!visible) return;
        const ids = activityIds;
        for (let i = 0; i < entries.length; ++i) {
            const e = entries[i];
            if (e.window.deleted) continue;
            const alive = ids.indexOf(e.activity) !== -1;
            const a = activityOf(e.window);
            if (alive && a === e.activity) continue;
            const t = targetOf(a);
            e.activity = a;
            e.x = e.frameX + t.x;
            e.y = e.frameY + t.y;
        }
        revision++;
    }

    // addActivity: a new activity named after its count; the manager answers
    // with the id, and the Workspace list follows. newActivityAt() parks the
    // window it should be centred on until then.
    property var pendingNewAt: null
    function addActivity() {
        addActivityCall.arguments = ["Activity " + (activityIds.length + 1)];
        addActivityCall.call();
    }

    function activityAdded(id) {
        if (!id) return;
        const entry = pendingNewAt;
        pendingNewAt = null;
        if (!entry) return;
        const g = KWin.Workspace.activeScreen.geometry;
        targets[id] = { x: entry.x + entry.width / 2 - (g.x + g.width / 2),
                        y: entry.y + entry.height / 2 - (g.y + g.height / 2) };
        if (!entry.window.deleted) entry.window.activities = [id];
        entry.activity = id;
        revision++;
        // Activating a window on another activity does not switch to it.
        KWin.Workspace.currentActivity = id;
        commit(entry.window);
    }

    function removeActivity(id) {
        if (activityIds.length <= 1 || !id) return;
        removeActivityCall.arguments = [id];
        removeActivityCall.call();
    }

    function copyTargets(src) {
        const out = {};
        for (const k in src) out[k] = { x: src[k].x, y: src[k].y };
        return out;
    }

    // The activity whose frames overlap a canvas rect the most, or null if none
    // touches it. A window straddling two frames goes to the larger share.
    function activityAt(rect) {
        const fs = frames();
        let best = null, bestArea = 0;
        for (let i = 0; i < fs.length; ++i) {
            const f = fs[i];
            const w = Math.min(rect.x + rect.width, f.x + f.width) - Math.max(rect.x, f.x);
            const h = Math.min(rect.y + rect.height, f.y + f.height) - Math.max(rect.y, f.y);
            if (w <= 0 || h <= 0) continue;
            if (w * h > bestArea) { bestArea = w * h; best = f.id; }
        }
        return best;
    }

    property var targetRaw: null
    // Drag an activity's frame group. With FramesCarryWindows the activity's
    // windows ride along, so the group moves on the plane as one and nothing
    // changes on screen at 1:1; off, the frames move over the windows.
    function dragTarget(id, dx, dy) {
        const t = targetOf(id);
        if (!targetRaw || targetRaw.id !== id) targetRaw = { id: id, x: t.x, y: t.y };
        targetRaw.x += dx / zoom; targetRaw.y += dy / zoom;
        const carry = configuration.FramesCarryWindows !== false;
        let riding = null;
        if (carry) {
            riding = {};
            for (let i = 0; i < entries.length; ++i) if (entries[i].activity === id) riding[entries[i].window.internalId] = true;
        }
        const vs = KWin.Workspace.virtualScreenGeometry;
        const box = { x: targetRaw.x + vs.x, y: targetRaw.y + vs.y, width: vs.width, height: vs.height };
        const s = snapDelta(box, snapCandidates(riding, id));
        const nx = targetRaw.x + s.dx, ny = targetRaw.y + s.dy;
        if (carry) {
            const ddx = nx - t.x, ddy = ny - t.y;
            for (let i = 0; i < entries.length; ++i) {
                const e = entries[i];
                if (e.activity !== id) continue;
                e.x += ddx;
                e.y += ddy;
            }
        }
        t.x = nx;
        t.y = ny;
        revision++;
    }

    function makeEntry(w) {
        const a = activityOf(w);
        const t = targetOf(a);
        const g = w.frameGeometry;
        return { window: w, activity: a, x: g.x + t.x, y: g.y + t.y, width: g.width, height: g.height,
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

    // Look through the current activity's frames.
    function home() {
        const t = targetOf(currentActivity);
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
        const fs = frames();
        for (let i = 0; i < fs.length; ++i) {
            const f = fs[i];
            l = Math.min(l, f.x); t = Math.min(t, f.y);
            r = Math.max(r, f.x + f.width); b = Math.max(b, f.y + f.height);
        }
        if (l === Infinity) { l = 0; t = 0; r = 1; b = 1; }
        const sg = KWin.Workspace.activeScreen.geometry;
        const pad = 80;
        const z = Math.max(zoomMin, Math.min(1.0, Math.min((sg.width - 2 * pad) / (r - l), (sg.height - 2 * pad) / (b - t))));
        zoom = z;
        viewX = (l + r) / 2 - (sg.x + sg.width / 2) / zoom;
        viewY = (t + b) / 2 - (sg.y + sg.height / 2) / zoom;
    }

    // ---- open / close ------------------------------------------------------
    function open(quietMode) {
        if (visible) return;
        quiet = !!quietMode;
        entryViewX = viewX;
        entryViewY = viewY;
        zoom = 1.0;
        clearSelection();
        snapEdges = configuration.SnapEdges;
        snapCorners = configuration.SnapCorners;
        snapGrid = configuration.SnapGrid;
        dragRaw = {};
        targetRaw = null;
        pendingNewAt = null;
        loadHiddenFrames();
        refreshActivities();
        refreshNames();
        targets[currentActivity] = { x: viewX, y: viewY };
        ensureTargets();
        entryTargets = copyTargets(targets);
        snapshot();
        visible = true;
        if (!quiet) openView();
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
    // that frame's activity, put the camera on the current activity's target,
    // and hand input back.
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
            let a = activityAt(e);
            if (a === null) a = e.activity;
            // A window on every activity stays on every activity.
            if (a !== e.activity && a && e.window.activities.length > 0) e.window.activities = [a];
            e.activity = a;
            const t = targetOf(a);
            e.window.frameGeometry = Qt.rect(Math.round(e.x - t.x), Math.round(e.y - t.y), e.width, e.height);
        }
        // Windows not shown (minimized, hidden, other desktops) share the
        // plane: keep them where they were relative to their activity's frames.
        const all = KWin.Workspace.stackingOrder;
        for (let i = 0; i < all.length; ++i) {
            const w = all[i];
            if (seen[w.internalId] || w.deleted || !w.managed) continue;
            if (w.desktopWindow || w.dock || w.popupWindow || w.specialWindow) continue;
            const a = activityOf(w);
            const was = entryTargets[a], now = targetOf(a);
            if (!was) continue;
            const dx = was.x - now.x, dy = was.y - now.y;
            if (dx === 0 && dy === 0) continue;
            const g = w.frameGeometry;
            w.frameGeometry = Qt.rect(g.x + dx, g.y + dy, g.width, g.height);
        }
        const cur = targetOf(currentActivity);
        viewX = cur.x;
        viewY = cur.y;
        zoom = 1.0;
        publishGround();
        visible = false;
        quiet = false;
        panMode = false;
        swiping = false;
        dropPassthrough();
        if (activate && !activate.deleted) {
            KWin.Workspace.activeWindow = activate;
        }
    }

    function cancel() {
        if (!visible) return;
        targets = copyTargets(entryTargets);
        viewX = entryViewX;
        viewY = entryViewY;
        zoom = 1.0;
        visible = false;
        quiet = false;
        panMode = false;
        swiping = false;
        dropPassthrough();
    }

    function toggle() {
        if (quiet) { finishSlide(); return; }
        if (visible) commit(null); else open();
    }

    // ---- named actions --------------------------------------------------------

    // focusWindow: apply with this window focused. The window's activity is
    // the one whose frame it sits in, else the one it belongs to; the canvas
    // switches to it if it is not current, and the focus waits for the
    // switch, since KWin reports it asynchronously. Where its viewport goes
    // is FocusTarget:
    //   window   the canvas point under the pointer stays under it at 1:1,
    //            as if the camera zoomed in there; the frames move as one.
    //   desktop  a window inside a frame leaves the frame where it is; one
    //            outside every frame gets its activity's active-screen
    //            frame centred on it.
    property var pendingFocus: null
    function focusWindow(entry, gx, gy) {
        if (gx === undefined) { const p = KWin.Workspace.cursorPos; gx = p.x; gy = p.y; }
        const inFrame = activityAt(entry);
        const a = inFrame !== null ? inFrame : entry.activity;
        const t = targetOf(a);
        const desktop = String(configuration.FocusTarget || "window").trim().toLowerCase() === "desktop";
        if (!desktop) {
            const c = globalToCanvas(gx, gy);
            t.x = Math.round(c.x - gx);
            t.y = Math.round(c.y - gy);
        } else if (inFrame === null) {
            const g = KWin.Workspace.activeScreen.geometry;
            t.x = Math.round(entry.x + entry.width / 2 - (g.x + g.width / 2));
            t.y = Math.round(entry.y + entry.height / 2 - (g.y + g.height / 2));
        }
        if (a && a !== currentActivity) {
            pendingFocus = entry.window;
            KWin.Workspace.currentActivity = a;
            commit(null);
            return;
        }
        commit(entry.window);
    }

    // zoomToActivity: camera fitted to that activity's frames, canvas stays open.
    function zoomToActivity(id) {
        const t = peekTarget(id);
        const vs = KWin.Workspace.virtualScreenGeometry;
        const l = t.x + vs.x, tp = t.y + vs.y, r = l + vs.width, b = tp + vs.height;
        const sg = KWin.Workspace.activeScreen.geometry;
        const pad = 60;
        const z = Math.max(zoomMin, Math.min(1.0, Math.min((sg.width - 2 * pad) / (r - l), (sg.height - 2 * pad) / (b - tp))));
        zoom = z;
        viewX = (l + r) / 2 - (sg.x + sg.width / 2) / zoom;
        viewY = (tp + b) / 2 - (sg.y + sg.height / 2) / zoom;
    }

    // gotoActivity: apply with that activity current, frames where they are.
    function gotoActivity(id) {
        if (id && id !== currentActivity) KWin.Workspace.currentActivity = id;
        commit(null);
    }

    // newActivityAt: a new activity whose active-screen frame is centred on
    // the window, the window moved into it, applied and focused. The manager
    // answers asynchronously; activityAdded() finishes the job.
    function newActivityAt(entry) {
        if (!activityIds[0]) return;   // activities disabled
        pendingNewAt = entry;
        addActivity();
    }

    // ---- snapping --------------------------------------------------------------
    // Toggles start from config each time the canvas opens; the toolbar flips them.
    property bool snapEdges: true
    property bool snapCorners: true
    property bool snapGrid: false

    // Rects other than the moving set: windows and every activity's frames.
    function snapCandidates(movingIds, movingActivity) {
        const out = [];
        for (let i = 0; i < entries.length; ++i) {
            const e = entries[i];
            if (movingIds && movingIds[e.window.internalId]) continue;
            out.push({ x: e.x, y: e.y, width: e.width, height: e.height });
        }
        const fs = frames();
        for (let i = 0; i < fs.length; ++i) {
            if (movingActivity !== null && movingActivity !== undefined && fs[i].id === movingActivity) continue;
            out.push({ x: fs[i].x, y: fs[i].y, width: fs[i].width, height: fs[i].height });
        }
        return out;
    }

    // Offset that snaps `rect` (canvas units): per-axis edge snap, corner snap
    // when both axes meet the same candidate, grid on left/top. The nearest
    // within SnapDistance screen pixels wins; 0 when nothing is near.
    function snapDelta(rect, cands) {
        const th = configuration.SnapDistance / zoom;
        let bx = 0, by = 0, bax = th + 1, bay = th + 1;
        const rx = [rect.x, rect.x + rect.width], ry = [rect.y, rect.y + rect.height];
        if (snapEdges || snapCorners) {
            for (let i = 0; i < cands.length; ++i) {
                const c = cands[i];
                const cx = [c.x, c.x + c.width], cy = [c.y, c.y + c.height];
                let ex = 0, ey = 0, eax = th + 1, eay = th + 1;
                for (let a = 0; a < 2; ++a) for (let b = 0; b < 2; ++b) {
                    const dx = cx[b] - rx[a], dy = cy[b] - ry[a];
                    if (Math.abs(dx) < eax) { eax = Math.abs(dx); ex = dx; }
                    if (Math.abs(dy) < eay) { eay = Math.abs(dy); ey = dy; }
                }
                if (snapEdges) {
                    if (eax < bax) { bax = eax; bx = ex; }
                    if (eay < bay) { bay = eay; by = ey; }
                } else if (eax <= th && eay <= th && eax + eay < bax + bay) {
                    bax = eax; bay = eay; bx = ex; by = ey;
                }
            }
        }
        if (snapGrid) {
            const g = Math.max(1, configuration.SnapGridSize);
            const gx = Math.round(rect.x / g) * g - rect.x, gy = Math.round(rect.y / g) * g - rect.y;
            if (Math.abs(gx) < bax) { bax = Math.abs(gx); bx = gx; }
            if (Math.abs(gy) < bay) { bay = Math.abs(gy); by = gy; }
        }
        return { dx: bax <= th ? bx : 0, dy: bay <= th ? by : 0 };
    }

    // Snap one moving edge value (1-D) against candidate edges and the grid.
    function snapEdge1D(value, horizontal, cands) {
        const th = configuration.SnapDistance / zoom;
        let best = 0, ba = th + 1;
        if (snapEdges || snapCorners) {
            for (let i = 0; i < cands.length; ++i) {
                const c = cands[i];
                const es = horizontal ? [c.x, c.x + c.width] : [c.y, c.y + c.height];
                for (let k = 0; k < 2; ++k) { const d = es[k] - value; if (Math.abs(d) < ba) { ba = Math.abs(d); best = d; } }
            }
        }
        if (snapGrid) {
            const g = Math.max(1, configuration.SnapGridSize);
            const d = Math.round(value / g) * g - value;
            if (Math.abs(d) < ba) { ba = Math.abs(d); best = d; }
        }
        return ba <= th ? best : 0;
    }

    // Raw, unsnapped positions of the set being dragged, keyed by window id.
    property var dragRaw: ({})
    function beginDrag(index) {
        const e = entries[index];
        if (!e) return;
        dragRaw = {};
        const set = isSelected(e) ? entries.filter(isSelected) : [e];
        for (let i = 0; i < set.length; ++i) dragRaw[set[i].window.internalId] = { x: set[i].x, y: set[i].y };
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

    // sendTo(activity): move the selection so each window keeps its place
    // within a frame, now in that activity's frame. sendTo(null): park the
    // set near the origin at the nearest spot outside every frame.
    function sendTo(id) {
        const list = arrangeTargets();
        if (list.length === 0) return;
        if (id !== null && id !== undefined) {
            for (let i = 0; i < list.length; ++i) {
                const e = list[i];
                let from = activityAt(e);
                if (from === null) from = e.activity;
                const a = peekTarget(from), b = peekTarget(id);
                e.x += b.x - a.x;
                e.y += b.y - a.y;
            }
        } else {
            const box = bbox(list);
            const gap = configuration.ArrangeGap;
            const fs = frames();
            // Candidate spots: the origin, then just outside the union of all frames on each side.
            let l = Infinity, t = Infinity, r = -Infinity, b = -Infinity;
            for (let i = 0; i < fs.length; ++i) {
                const f = fs[i];
                l = Math.min(l, f.x); t = Math.min(t, f.y);
                r = Math.max(r, f.x + f.width); b = Math.max(b, f.y + f.height);
            }
            if (l === Infinity) { l = 0; t = 0; r = 0; b = 0; }
            const spots = [{ x: 0, y: 0 }, { x: l - box.width - gap, y: 0 }, { x: 0, y: t - box.height - gap },
                           { x: r + gap, y: 0 }, { x: 0, y: b + gap }];
            const clear = function (sx, sy) {
                for (let i = 0; i < fs.length; ++i) {
                    const f = fs[i];
                    if (sx < f.x + f.width && sx + box.width > f.x && sy < f.y + f.height && sy + box.height > f.y) return false;
                }
                return true;
            };
            let best = null, bd = Infinity;
            for (let i = 0; i < spots.length; ++i) {
                if (!clear(spots[i].x, spots[i].y)) continue;
                const dist = Math.hypot(spots[i].x, spots[i].y);
                if (dist < bd) { bd = dist; best = spots[i]; }
            }
            if (!best) best = { x: l - box.width - gap, y: t - box.height - gap };
            for (let i = 0; i < list.length; ++i) { list[i].x += best.x - box.x; list[i].y += best.y - box.y; }
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
        } else if (gestureMatches(configuration.MouseNewActivityAt, count, modifiers) && activityAt(entry) === null) {
            newActivityAt(entry);
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

    function frameGesture(id, count, modifiers) {
        if (gestureMatches(configuration.MouseGotoActivity, count, modifiers)) gotoActivity(id);
        else if (gestureMatches(configuration.MouseZoomToActivity, count, modifiers)) zoomToActivity(id);
    }

    function pick(entry) { focusWindow(entry); }

    // Move a window on the canvas by a screen-space delta while the canvas is open.
    // Entries are addressed by index: the Repeater hands delegates a copy of the
    // element, so mutating modelData would never reach the committed table.
    // A selected window drags the whole selection; relative geometry is kept.
    // Positions accumulate unsnapped in dragRaw, then the set's bounding box
    // is snapped as one, so a drag can always pull away from a snap.
    function dragEntry(index, dx, dy) {
        const e = entries[index];
        if (!e) return;
        if (!dragRaw[e.window.internalId]) beginDrag(index);
        const set = [];
        for (let i = 0; i < entries.length; ++i) if (dragRaw[entries[i].window.internalId]) set.push(entries[i]);
        for (let i = 0; i < set.length; ++i) {
            const r = dragRaw[set[i].window.internalId];
            r.x += dx / zoom; r.y += dy / zoom;
            set[i].x = r.x; set[i].y = r.y;
        }
        const box = bbox(set);
        const d = snapDelta(box, snapCandidates(dragRaw, null));
        for (let i = 0; i < set.length; ++i) { set[i].x += d.dx; set[i].y += d.dy; }
        revision++;
    }

    // Command the real window to a size while the canvas is open. Position is
    // untouched. The client answers with whatever size it accepts, and
    // syncSize() copies that back into the entry when the geometry changes.
    function requestSize(index, w, h, anchorRight, anchorBottom) {
        const e = entries[index];
        if (!e || e.window.deleted) return;
        // Snap the edge being dragged. Left/top anchors keep the far edge fixed.
        const ids = {}; ids[e.window.internalId] = true;
        const cands = snapCandidates(ids, null);
        const right = e.x + e.width, bottom = e.y + e.height;
        w += snapEdge1D(anchorRight ? right - w : e.x + w, true, cands) * (anchorRight ? -1 : 1);
        h += snapEdge1D(anchorBottom ? bottom - h : e.y + h, false, cands) * (anchorBottom ? -1 : 1);
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

    // ---- pass-through plugin -------------------------------------------------
    KWin.DBusCall {
        id: probeCall
        service: "org.kde.KWin"
        path: "/KWinCanvas"
        dbusInterface: "org.kde.kwin.canvas.Passthrough"
        method: "probe"
        onFinished: (ret) => effect.passthroughProbed(String(ret[0]))
    }
    KWin.DBusCall {
        id: activeCall
        service: "org.kde.KWin"
        path: "/KWinCanvas"
        dbusInterface: "org.kde.kwin.canvas.Passthrough"
        method: "setActive"
    }
    KWin.DBusCall {
        id: cameraCall
        service: "org.kde.KWin"
        path: "/KWinCanvas"
        dbusInterface: "org.kde.kwin.canvas.Passthrough"
        method: "setCamera"
    }
    // The plugin answered: if pan mode is still on, switch it on and give it the camera.
    function passthroughProbed(version) {
        passthroughVersion = version;
        if (!panMode || passthroughLive) return;
        passthroughLive = true;
        publishCamera();
        activeCall.arguments = [true];
        activeCall.call();
    }
    function publishCamera() {
        if (!passthroughLive) return;
        cameraCall.arguments = [viewX, viewY, zoom, currentActivity, JSON.stringify(targets)];
        cameraCall.call();
    }
    function dropPassthrough() {
        if (!passthroughLive) return;
        passthroughLive = false;
        activeCall.arguments = [false];
        activeCall.call();
    }
    onViewXChanged: if (passthroughLive) Qt.callLater(publishCamera)
    onViewYChanged: if (passthroughLive) Qt.callLater(publishCamera)
    onZoomChanged: if (passthroughLive) Qt.callLater(publishCamera)

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
    // A window that rides with this activity's viewport: managed, not part of
    // the shell, on this activity or on every activity. Minimized windows and
    // other desktops' windows count, so the plane stays whole under a pan.
    function isViewportWindow(w) {
        if (!w || w.deleted || !w.managed) return false;
        if (w.desktopWindow || w.dock || w.popupWindow || w.specialWindow) return false;
        return onActivity(w, currentActivity);
    }

    // Shift the current activity's viewport: move its windows and its target.
    function shiftAll(dx, dy) {
        const all = KWin.Workspace.stackingOrder;
        for (let i = 0; i < all.length; ++i) {
            const w = all[i];
            if (!isViewportWindow(w)) continue;
            const g = w.frameGeometry;
            w.frameGeometry = Qt.rect(g.x + dx, g.y + dy, g.width, g.height);
        }
        const t = targetOf(currentActivity);
        t.x -= dx;
        t.y -= dy;
        viewX = t.x;
        viewY = t.y;
        publishGround();
    }

    // ---- the slide: an animated pan at 1:1 ---------------------------------
    // Open quietly at 1:1, where the thumbnails and the ground are pixel-
    // identical to the real screen, move the camera, and end with shiftAll:
    // the desktop slides, and this activity's windows are written once at the
    // end. Nothing changes activity, and only this activity's windows are
    // drawn, so what slides is what 1:1 shows. A slide that arrives mid-slide
    // extends the destination. dx, dy are canvas pixels the camera moves by;
    // the windows move the other way.
    property real slideToX: 0
    property real slideToY: 0
    readonly property int panDuration: Math.max(0, Number(configuration.PanDuration) || 0)

    // One pan step in screen pixels: a fraction of the active screen.
    function panStep() {
        const f = Math.max(0.05, Math.min(1, Number(configuration.PanStep) || 0.5));
        const g = KWin.Workspace.activeScreen.geometry;
        return Qt.point(Math.round(g.width * f), Math.round(g.height * f));
    }

    function slide(dx, dy) {
        if (!beginSlide()) return;
        if (!slideAnim.running) { slideToX = viewX; slideToY = viewY; }
        slideToX += dx;
        slideToY += dy;
        slideAnim.restart();
    }

    // Open quietly if closed. False while the real canvas is open.
    function beginSlide() {
        if (visible && !quiet) return false;
        if (!visible) {
            open(true);
            slideToX = viewX;
            slideToY = viewY;
        }
        return true;
    }

    // The animation has arrived: the destination becomes this activity's
    // viewport. Every shown window is written once, where it sits on the
    // plane relative to its activity's frames, which covers both the ride and
    // any drag on the plane while quiet (pan mode with pass-through leaves
    // the title bars to the canvas). Writing a geometry makes its entry absorb
    // the move as a delta, so nothing may read an entry after writing it.
    // Windows the canvas does not show ride with the viewport as under a
    // commit. All of it happens while the thumbnails still cover the screen.
    function endSlide() {
        if (!quiet) return;
        swiping = false;
        panMode = false;
        dropPassthrough();
        zoom = 1.0;
        const dx = Math.round(slideToX - entryViewX), dy = Math.round(slideToY - entryViewY);
        targets = copyTargets(entryTargets);
        const cur = targetOf(currentActivity);
        cur.x += dx;
        cur.y += dy;
        const seen = {};
        for (let i = 0; i < entries.length; ++i) {
            const e = entries[i];
            if (e.window.deleted) continue;
            seen[e.window.internalId] = true;
            const t = targetOf(e.activity);
            const fx = Math.round(e.x - t.x), fy = Math.round(e.y - t.y);
            const g = e.window.frameGeometry;
            if (g.x !== fx || g.y !== fy) e.window.frameGeometry = Qt.rect(fx, fy, g.width, g.height);
        }
        if (dx !== 0 || dy !== 0) {
            const all = KWin.Workspace.stackingOrder;
            for (let i = 0; i < all.length; ++i) {
                const w = all[i];
                if (seen[w.internalId] || !isViewportWindow(w)) continue;
                const g = w.frameGeometry;
                w.frameGeometry = Qt.rect(g.x - dx, g.y - dy, g.width, g.height);
            }
        }
        viewX = cur.x;
        viewY = cur.y;
        publishGround();
        visible = false;
        quiet = false;
    }

    // Jump to the destination and settle now (another action wants the canvas).
    function finishSlide() {
        if (!quiet) return;
        slideAnim.stop();
        settleAnim.stop();
        if (panMode) settleTarget();
        endSlide();
    }

    ParallelAnimation {
        id: slideAnim
        NumberAnimation { target: effect; property: "viewX"; to: effect.slideToX; duration: effect.panDuration; easing.type: Easing.OutCubic }
        NumberAnimation { target: effect; property: "viewY"; to: effect.slideToY; duration: effect.panDuration; easing.type: Easing.OutCubic }
        onFinished: effect.endSlide()
    }
    // Pan mode settles with the zoom: view and zoom animate to 1:1 together.
    ParallelAnimation {
        id: settleAnim
        NumberAnimation { target: effect; property: "viewX"; to: effect.slideToX; duration: effect.panDuration; easing.type: Easing.OutCubic }
        NumberAnimation { target: effect; property: "viewY"; to: effect.slideToY; duration: effect.panDuration; easing.type: Easing.OutCubic }
        NumberAnimation { target: effect; property: "zoom";  to: 1;               duration: effect.panDuration; easing.type: Easing.OutCubic }
        onFinished: effect.endSlide()
    }

    // Pan by one step in a direction (dx, dy in {-1, 0, 1}): the camera moves
    // that way. Closed, it is a slide; open, the camera just moves.
    function panStepBy(dx, dy) {
        const st = panStep();
        if (canvasOpen) { panBy(-dx * st.x, -dy * st.y); return; }
        slide(dx * st.x, dy * st.y);
    }

    // Touchpad swipe: the desktop follows the fingers, then settles one step
    // in the swipe's direction, or slides back if the swipe is cancelled.
    // The fingers move the content, so the camera goes the other way.
    property real swipeBaseX: 0
    property real swipeBaseY: 0
    property bool swiping: false
    function swipeProgress(dx, dy, p) {
        if (!swiping) {
            if (p <= 0) return;
            if (!beginSlide()) return;
            slideAnim.stop();
            swipeBaseX = viewX;
            swipeBaseY = viewY;
            swiping = true;
        }
        const st = panStep();
        p = Math.max(0, Math.min(1, p));
        viewX = swipeBaseX - dx * st.x * p;
        viewY = swipeBaseY - dy * st.y * p;
    }
    function swipeEnd(dx, dy, ok) {
        if (!swiping) return;
        swiping = false;
        const st = panStep();
        slideToX = ok ? swipeBaseX - dx * st.x : swipeBaseX;
        slideToY = ok ? swipeBaseY - dy * st.y : swipeBaseY;
        slideAnim.restart();
    }

    // The finger count is copied out of the configuration so the handlers
    // are re-registered only when it changes, not on every reconfigure.
    property int swipeFingers: 0
    function readSwipeFingers() {
        const n = Number(configuration.PanSwipeFingers) || 0;
        if (n !== swipeFingers) swipeFingers = n;
    }
    Instantiator {
        // Four handlers, one per direction, for the configured finger count.
        model: {
            const n = effect.swipeFingers;
            if (n < 3) return [];
            return [{ f: n, d: KWin.SwipeGestureHandler.Left,  dx: -1, dy: 0 },
                    { f: n, d: KWin.SwipeGestureHandler.Right, dx: 1,  dy: 0 },
                    { f: n, d: KWin.SwipeGestureHandler.Up,    dx: 0,  dy: -1 },
                    { f: n, d: KWin.SwipeGestureHandler.Down,  dx: 0,  dy: 1 }];
        }
        delegate: KWin.SwipeGestureHandler {
            required property var modelData
            direction: modelData.d
            fingerCount: modelData.f
            deviceType: KWin.SwipeGestureHandler.Touchpad
            onProgressChanged: effect.swipeProgress(modelData.dx, modelData.dy, progress)
            onActivated: effect.swipeEnd(modelData.dx, modelData.dy, true)
            onCancelled: effect.swipeEnd(modelData.dx, modelData.dy, false)
        }
    }

    // ---- pan mode: hold the chord, drag the desktop ------------------------
    // The chord opens quiet with input on; every left or middle drag pulls
    // the view; releasing any key of the chord settles where it landed.
    // Escape slides back and writes nothing. The chord re-fires on key
    // autorepeat while it is held, so a second activation is ignored.
    function enterPanMode() {
        if (panMode || settleAnim.running) return;
        if (!beginSlide()) return;
        slideAnim.stop();
        panMode = true;
        if (passthroughWanted) probeCall.call();
    }
    // Where 1:1 lands when pan mode settles: the canvas point under the
    // anchor (the pointer) stays under it, as a zoom back to 1 there would.
    function settleTarget(ax, ay) {
        if (ax === undefined) { const p = KWin.Workspace.cursorPos; ax = p.x; ay = p.y; }
        const c = globalToCanvas(ax, ay);
        slideToX = c.x - ax;
        slideToY = c.y - ay;
    }
    function endPanMode(ax, ay) {
        if (!panMode) return;
        slideAnim.stop();
        settleTarget(ax, ay);
        settleAnim.restart();
    }
    function cancelPanMode() {
        if (!panMode) return;
        panMode = false;
        dropPassthrough();
        slideToX = entryViewX;
        slideToY = entryViewY;
        settleAnim.restart();
    }
    // A key release while in pan mode: true if it belongs to the chord.
    function panModeReleased(key, mod) {
        if (!panMode) return false;
        if (panModeKey && key === panModeKey) return true;
        return mod !== 0 && (mod & panModeMods) !== 0;
    }

    function intersects(a, b) {
        return a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y;
    }

    Connections {
        target: KWin.Workspace
        function onWindowActivated(w) {
            // Open: a raise (pass-through clicks) restacks the thumbnails.
            if (effect.visible) { Qt.callLater(effect.resync); return; }
            if (!effect.configuration.FollowActivation) return;
            if (!effect.isCanvasWindow(w, false)) return;
            const g = w.frameGeometry;
            if (effect.intersects(g, KWin.Workspace.virtualScreenGeometry)) return;
            const area = KWin.Workspace.clientArea(KWin.Workspace.PlacementArea, w);
            const dx = Math.round(area.x + (area.width - g.width) / 2 - g.x);
            const dy = Math.round(area.y + (area.height - g.height) / 2 - g.y);
            effect.shiftAll(dx, dy);
        }
        function onActivitiesChanged(id) { Qt.callLater(effect.activitiesChanged); }
        function onWindowAdded(w) { if (effect.visible) Qt.callLater(effect.resync); }
        function onWindowRemoved(w) { if (effect.visible) Qt.callLater(effect.resync); }
        // Switching activities at 1:1 switches viewport: the ground follows.
        function onCurrentActivityChanged(id) {
            if (effect.refreshActivities()) effect.ensureTargets();
            if (effect.visible) return;
            const t = effect.targetOf(KWin.Workspace.currentActivity || "");
            effect.viewX = t.x;
            effect.viewY = t.y;
            effect.publishGround();
            const w = effect.pendingFocus;
            effect.pendingFocus = null;
            if (w && !w.deleted) KWin.Workspace.activeWindow = w;
        }
        // Another desktop's windows are a different set on the same plane.
        function onCurrentDesktopChanged() { if (effect.visible) Qt.callLater(effect.resync); }
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
        text: "Canvas: return this activity to the origin"
        sequence: effect.configuration.HomeShortcut
        onActivated: {
            if (effect.quiet) effect.finishSlide();
            if (effect.visible) { effect.home(); return; }
            effect.open();
            const t = effect.targetOf(effect.currentActivity);
            t.x = 0;
            t.y = 0;
            effect.commit(null);
        }
    }
    // The in-canvas actions as global shortcuts too, with no default chord,
    // so they can be bound in System Settings > Shortcuts > KWin. They act
    // only while the canvas is open.
    KWin.ShortcutHandler { name: "Canvas Apply";    text: "Canvas: apply and close";           sequence: ""; onActivated: if (effect.canvasOpen) effect.commit(null) }
    KWin.ShortcutHandler { name: "Canvas Cancel";   text: "Canvas: cancel";                    sequence: ""; onActivated: if (effect.canvasOpen) effect.cancel() }
    KWin.ShortcutHandler { name: "Canvas Fit";      text: "Canvas: zoom to fit";               sequence: ""; onActivated: if (effect.canvasOpen) effect.zoomExtents() }
    KWin.ShortcutHandler { name: "Canvas Origin";   text: "Canvas: camera to the origin";      sequence: ""; onActivated: if (effect.canvasOpen) effect.origin() }
    KWin.ShortcutHandler { name: "Canvas Zoom In";  text: "Canvas: zoom in";                   sequence: ""; onActivated: if (effect.canvasOpen) effect.setZoom(effect.zoom * effect.zoomStep, KWin.Workspace.cursorPos) }
    KWin.ShortcutHandler { name: "Canvas Zoom Out"; text: "Canvas: zoom out";                  sequence: ""; onActivated: if (effect.canvasOpen) effect.setZoom(effect.zoom / effect.zoomStep, KWin.Workspace.cursorPos) }
    KWin.ShortcutHandler {
        name: "Canvas Pan Mode"
        text: "Canvas: hold to pan the desktop with the mouse"
        sequence: effect.configuration.PanModeShortcut
        onActivated: effect.enterPanMode()
    }
    // Pan at 1:1 by one step (a slide), or move the open canvas's camera.
    KWin.ShortcutHandler { name: "Canvas Pan Left";  text: "Canvas: pan left";  sequence: effect.configuration.PanLeftShortcut;  onActivated: effect.panStepBy(-1, 0) }
    KWin.ShortcutHandler { name: "Canvas Pan Right"; text: "Canvas: pan right"; sequence: effect.configuration.PanRightShortcut; onActivated: effect.panStepBy(1, 0) }
    KWin.ShortcutHandler { name: "Canvas Pan Up";    text: "Canvas: pan up";    sequence: effect.configuration.PanUpShortcut;    onActivated: effect.panStepBy(0, -1) }
    KWin.ShortcutHandler { name: "Canvas Pan Down";  text: "Canvas: pan down";  sequence: effect.configuration.PanDownShortcut;  onActivated: effect.panStepBy(0, 1) }

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
        refreshActivities();
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
        case "slide": slide(Number(a[1]), Number(a[2])); break;
        case "panmode": {
            // panmode | panmode end [X Y] | panmode cancel
            if (a[1] === "end") endPanMode(a.length >= 4 ? Number(a[2]) : undefined, a.length >= 4 ? Number(a[3]) : undefined);
            else if (a[1] === "cancel") cancelPanMode();
            else enterPanMode();
            break;
        }
        case "panstep": panStepBy(Number(a[1]), Number(a[2])); break;
        case "swipe": {
            // swipe DX DY PROGRESS | swipe DX DY end | swipe DX DY cancel
            if (a[3] === "end") swipeEnd(Number(a[1]), Number(a[2]), true);
            else if (a[3] === "cancel") swipeEnd(Number(a[1]), Number(a[2]), false);
            else swipeProgress(Number(a[1]), Number(a[2]), Number(a[3]));
            break;
        }
        case "drag": beginDrag(Number(a[1])); dragEntry(Number(a[1]), Number(a[2]), Number(a[3])); break;
        case "resize": requestSize(Number(a[1]), Number(a[2]), Number(a[3]), false, false); break;
        case "resetview": {
            // 1:1 only: forget the pan history so canvas == frame for this activity.
            if (visible) break;
            viewX = 0; viewY = 0;
            targets[currentActivity] = { x: 0, y: 0 };
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
            // frames DX DY [activityIndex]
            const id = a.length >= 4 ? activityIds[Number(a[3])] : currentActivity;
            dragTarget(id, Number(a[1]), Number(a[2]));
            break;
        }
        case "pick": pick(entries[Number(a[1])]); break;
        case "focus": focusWindow(entries[Number(a[1])]); break;
        case "goto": gotoActivity(activityIds[Number(a[1])]); break;
        case "zoomto": zoomToActivity(activityIds[Number(a[1])]); break;
        case "newactivityat": newActivityAt(entries[Number(a[1])]); break;
        case "activate": {
            const all = KWin.Workspace.stackingOrder;
            for (let i = 0; i < all.length; ++i) {
                if (all[i].caption.indexOf(a[1]) !== -1) { KWin.Workspace.activeWindow = all[i]; break; }
            }
            break;
        }
        case "activity": KWin.Workspace.currentActivity = activityIds[Number(a[1])]; break;
        case "addactivity": addActivity(); break;
        case "rmactivity": removeActivity(activityIds[Number(a[1])]); break;
        case "hide": case "show": {
            // hide|show ACTIVITY_INDEX [SCREEN_INDEX]
            const screens = KWin.Workspace.screens;
            const s = a.length >= 3 ? screens[Number(a[2])] : KWin.Workspace.activeScreen;
            setHidden(activityIds[Number(a[1])], s, a[0] === "hide");
            break;
        }
        case "activities": {
            // Raw ids as KWin reports them, and each window's list.
            let s = "kwin-canvas activities: current=" + JSON.stringify(KWin.Workspace.currentActivity) + " all=" + JSON.stringify(Array.prototype.slice.call(KWin.Workspace.activities));
            const all = KWin.Workspace.stackingOrder;
            for (let i = 0; i < all.length; ++i) s += "\n  " + all[i].caption + " " + JSON.stringify(Array.prototype.slice.call(all[i].activities));
            console.log(s);
            break;
        }
        case "list": {
            const all = KWin.Workspace.stackingOrder;
            let s = "kwin-canvas windows:";
            for (let i = 0; i < all.length; ++i) {
                const w = all[i]; const g = w.frameGeometry;
                s += "\n  " + (isCanvasWindow(w, true) ? "*" : " ") + " " + w.caption + " frame=(" + g.x + "," + g.y + " " + g.width + "x" + g.height + ") activity=" + (w.activities.length === 0 ? "all" : labelOf(activityOf(w)));
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
        case "snap": {
            const on = a[2] === "on";
            if (a[1] === "edges") snapEdges = on; else if (a[1] === "corners") snapCorners = on; else if (a[1] === "grid") snapGrid = on;
            break;
        }
        case "begindrag": beginDrag(Number(a[1])); break;
        case "sendto": sendTo(a[1] === "none" ? null : activityIds[Number(a[1])]); break;
        case "marquee": selectInRect(Number(a[1]), Number(a[2]), Number(a[3]), Number(a[4])); break;
        case "state": break;
        default: console.warn("kwin-canvas: unknown debug command", cmd);
        }
        logState();
    }

    function logState() {
        let s = "kwin-canvas state visible=" + visible + (quiet ? (panMode ? " panmode" : " quiet") : "") + (passthroughLive ? " passthrough" : "") + " zoom=" + zoom.toFixed(4) + " view=(" + viewX.toFixed(1) + "," + viewY.toFixed(1) + ") activity=" + labelOf(currentActivity) + " entries=" + entries.length
            + " snap=" + (snapEdges ? "E" : "-") + (snapCorners ? "C" : "-") + (snapGrid ? "G" : "-")
            + " active=" + (KWin.Workspace.activeWindow ? JSON.stringify(KWin.Workspace.activeWindow.caption) : "none");
        const ids = activityIds, screens = KWin.Workspace.screens;
        for (let i = 0; i < ids.length; ++i) {
            const t = peekTarget(ids[i]);
            let hidden = "";
            for (let j = 0; j < screens.length; ++j) if (isHidden(ids[i], screens[j])) hidden += (hidden ? "," : "") + screens[j].name;
            s += "\n  {" + i + "} " + labelOf(ids[i]) + " target=(" + t.x.toFixed(0) + "," + t.y.toFixed(0) + ")" + (hidden ? " hidden=" + hidden : "");
        }
        for (let i = 0; i < entries.length; ++i) {
            const e = entries[i];
            const g = e.window.frameGeometry;
            s += "\n  [" + i + "] " + (isSelected(e) ? "*" : " ") + e.window.caption + " canvas=(" + e.x.toFixed(0) + "," + e.y.toFixed(0) + " " + e.width + "x" + e.height + ") frame=(" + g.x + "," + g.y + ") activity=" + labelOf(e.activity);
        }
        console.log(s);
    }

    onConfigurationChanged: {
        rebuildBindings();
        readSwipeFingers();
        const seq = configuration.DebugSeq;
        if (seq !== lastDebugSeq) {
            lastDebugSeq = seq;
            const cmd = configuration.DebugCommand;
            if (cmd && cmd.length > 0) runDebug(cmd);
        }
    }

    Component.onCompleted: {
        rebuildBindings();
        readSwipeFingers();
        loadHiddenFrames();
        refreshActivities();
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
            enabled: !grip.viewItem.panOnly
            cursorShape: gripDrag.active && grip.cursor === Qt.ArrowCursor ? Qt.ClosedHandCursor : grip.cursor
            onHoveredChanged: grip.viewItem.hoverCount += hovered ? 1 : -1
            Component.onDestruction: if (hovered) grip.viewItem.hoverCount -= 1
        }
        DragHandler {
            id: gripDrag
            target: null
            enabled: !grip.viewItem.panOnly
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
            enabled: grip.tappable && !grip.viewItem.panOnly
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

    // The activity's name tag: a Grip for its frame group, plus the activity
    // controls: hide or show this frame, add an activity, remove this one.
    component FrameTag : Grip {
        id: tag
        required property string activity
        required property int activityIndex
        required property var screen
        readonly property bool current: activity === effect.currentActivity
        readonly property bool hidden: effect.isHidden(activity, screen)
        readonly property color accent: effect.palette[activityIndex % effect.palette.length]
        cursor: Qt.SizeAllCursor
        width: tagRow.implicitWidth + 12
        height: tagRow.implicitHeight + 6
        onDragStarted: effect.targetRaw = null
        onDragged: (dx, dy) => effect.dragTarget(activity, dx, dy)

        Rectangle {
            anchors.fill: parent
            radius: 3
            color: tag.accent
            opacity: tag.hidden ? 0.45 : (tag.current ? 1 : 0.8)
        }
        Row {
            id: tagRow
            anchors.centerIn: parent
            spacing: 6
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: effect.labelOf(tag.activity) + " \u00b7 " + tag.screen.name + "  " + tag.screen.geometry.width + "x" + tag.screen.geometry.height
                color: effect.textOn(tag.accent)
                font.pixelSize: 12
                font.bold: true
            }
            IconButton {
                anchors.verticalCenter: parent.verticalCenter
                viewItem: tag.viewItem
                icon: tag.hidden ? "view-hidden" : "view-visible"
                onClicked: effect.setHidden(tag.activity, tag.screen, !tag.hidden)
            }
            IconButton {
                visible: tag.activity !== ""
                anchors.verticalCenter: parent.verticalCenter
                viewItem: tag.viewItem
                icon: "list-add"
                onClicked: effect.addActivity()
            }
            IconButton {
                visible: effect.activityIds.length > 1
                anchors.verticalCenter: parent.verticalCenter
                viewItem: tag.viewItem
                icon: "edit-delete"
                hoverColor: "#80ff4040"
                onClicked: effect.removeActivity(tag.activity)
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
        // Space held, or pan mode without pass-through: every grip and button
        // stands down and drags pan. With pass-through live the plugin takes
        // the client areas, so the grips see only title bars and edges.
        readonly property bool panOnly: spaceHeld || (effect.panMode && !effect.passthroughLive)
        enabled: !effect.quiet || effect.panMode
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
            enabled: !view.panOnly && !view.overControl
            acceptedButtons: Qt.LeftButton
            onTapped: (eventPoint, button) => { if ((point.modifiers & effect.marqueeModifiers()) === 0) effect.clearSelection(); }
        }

        // Marquee: the add gesture's modifier plus a drag on the ground selects by rectangle.
        DragHandler {
            id: marquee
            target: null
            // Latched while active: crossing a window mid-drag must not end the gesture.
            enabled: active || (!view.panOnly && !view.overControl && effect.marqueeModifiers() !== 0 && (view.heldModifiers & effect.marqueeModifiers()) !== 0)
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
            acceptedButtons: (active || view.panOnly || !view.overControl) ? (Qt.LeftButton | Qt.MiddleButton) : Qt.MiddleButton
            cursorShape: active ? Qt.ClosedHandCursor : (view.panOnly ? Qt.OpenHandCursor : Qt.ArrowCursor)
            property point last: Qt.point(0, 0)
            onActiveChanged: {
                last = Qt.point(0, 0);
                if (active && effect.panMode) slideAnim.stop();
            }
            onActiveTranslationChanged: {
                const t = activeTranslation;
                effect.panBy(t.x - last.x, t.y - last.y);
                last = t;
            }
        }

        // Zoom at the cursor. In pan mode too: release settles back to 1:1.
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

        // Monitor frames: one per activity per output. An activity's frames
        // are a rigid group; dragging any edge band moves them all. The
        // interior is the Plasma desktop background for that output, so each
        // frame reads as a desk top. A hidden frame is not drawn; its tag stays.
        Repeater {
            model: effect.activityIds
            delegate: Repeater {
                id: activityFrames
                required property string modelData
                required property int index
                readonly property string activity: modelData
                readonly property bool current: modelData === effect.currentActivity
                readonly property color accent: effect.palette[index % effect.palette.length]
                model: KWin.Workspace.screens
                delegate: Item {
                    id: frame
                    required property var modelData
                    readonly property rect og: modelData.geometry
                    visible: (!effect.quiet || effect.quietPlane) && !effect.isHidden(activityFrames.activity, modelData)
                    x: { effect.revision; return (effect.peekTarget(activityFrames.activity).x + og.x - effect.viewX) * effect.zoom - view.sg.x; }
                    y: { effect.revision; return (effect.peekTarget(activityFrames.activity).y + og.y - effect.viewY) * effect.zoom - view.sg.y; }
                    width: og.width * effect.zoom
                    height: og.height * effect.zoom
                    z: 1

                    // An empty activity makes KWin 6.7 dereference a null
                    // activities object when activities are disabled, so
                    // always pass a non-empty one.
                    KWin.DesktopBackground {
                        anchors.fill: parent
                        output: frame.modelData
                        desktop: KWin.Workspace.currentDesktop
                        activity: activityFrames.activity || "default"
                    }

                    // Sheet tint: keeps the frame legible when no background window exists.
                    Rectangle {
                        anchors.fill: parent
                        color: activityFrames.accent
                        opacity: activityFrames.current ? 0.10 : 0.06
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.width: activityFrames.current ? 2 : 1
                        border.color: activityFrames.accent
                        opacity: activityFrames.current ? 0.95 : 0.6
                    }

                    // A gesture on the frame's own area (windows sit above and
                    // take their own taps).
                    TapHandler {
                        enabled: !view.panOnly
                        acceptedButtons: Qt.LeftButton
                        onTapped: effect.frameGesture(activityFrames.activity, tapCount, point.modifiers)
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
                            onDragStarted: effect.targetRaw = null
                            onDragged: (dx, dy) => effect.dragTarget(activityFrames.activity, dx, dy)
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
                visible: !effect.quiet || effect.quietPlane || entry.activity === effect.currentActivity
                z: 1000 + index

                KWin.WindowThumbnail {
                    anchors.fill: parent
                    client: thumb.entry.window
                }

                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    visible: !effect.quiet
                    readonly property bool sel: { effect.selectionRev; return effect.isSelected(thumb.entry); }
                    border.width: sel ? 3 : (body.hovered || body.active ? 2 : 1)
                    border.color: sel ? Kirigami.Theme.highlightColor
                                : (body.hovered || body.active ? effect.activityColor(thumb.entry.activity) : "#40ffffff")
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
                    onDragStarted: effect.beginDrag(thumb.index)
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
            model: effect.activityIds
            delegate: Repeater {
                id: activityTags
                required property string modelData
                required property int index
                model: KWin.Workspace.screens
                delegate: FrameTag {
                    required property var modelData
                    visible: !effect.quiet
                    viewItem: view
                    activity: activityTags.modelData
                    activityIndex: activityTags.index
                    screen: modelData
                    x: { effect.revision; return (effect.peekTarget(activity).x + screen.geometry.x - effect.viewX) * effect.zoom - view.sg.x; }
                    y: { effect.revision; return (effect.peekTarget(activity).y + screen.geometry.y - effect.viewY) * effect.zoom - view.sg.y - height - 2; }
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
            if (effect.panMode) {
                // Escape slides back, apply settles, the rest is swallowed.
                if (effect.bound("cancel", k)) effect.cancelPanMode();
                else if (effect.bound("apply", k)) effect.endPanMode();
                event.accepted = true;
                return;
            }
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
            if (!event.isAutoRepeat && effect.panModeReleased(event.key, m)) {
                if (m) view.heldModifiers &= ~m;
                effect.endPanMode();
                event.accepted = true;
                return;
            }
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
            PC3.Menu {
                title: "Send to"
                icon.name: "activities"
                Repeater {
                    model: effect.activityIds
                    delegate: PC3.MenuItem {
                        required property string modelData
                        required property int index
                        text: effect.labelOf(modelData)
                        onTriggered: effect.sendTo(modelData)
                        Rectangle { anchors.verticalCenter: parent.verticalCenter; anchors.right: parent.right; anchors.rightMargin: Kirigami.Units.smallSpacing; width: 12; height: 12; radius: 3; color: effect.palette[index % effect.palette.length] }
                    }
                }
                PC3.MenuSeparator {}
                PC3.MenuItem { text: "Plane, outside every activity"; icon.name: "edit-none"; onTriggered: effect.sendTo(null) }
            }
            PC3.MenuSeparator {}
            PC3.MenuItem { text: "Clear selection";      icon.name: "edit-select-none";      onTriggered: effect.clearSelection() }
        }

        // HUD: a Plasma toolbar, top centre. Camera state, the actions, help
        // with the bindings, and the settings pages that own them.
        Rectangle {
            id: hud
            z: 100000
            visible: view.screen === effect.primaryScreen && !effect.quiet
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
                    source: "activities"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    Layout.alignment: Qt.AlignCenter
                }
                PC3.Label {
                    text: hud.vertical ? effect.labelOf(effect.currentActivity) + "\n" + Math.round(effect.zoom * 100) + "%"
                                       : effect.labelOf(effect.currentActivity) + "   " + Math.round(effect.zoom * 100) + "%"
                    horizontalAlignment: Text.AlignHCenter
                    Layout.alignment: Qt.AlignCenter
                    Layout.columnSpan: hud.square ? hud.squareColumns : 1
                    Layout.rightMargin: hud.vertical || hud.square ? 0 : Kirigami.Units.smallSpacing
                }
                // One swatch per activity in its frame colour; click to zoom to it.
                Repeater {
                    model: effect.activityIds
                    delegate: Rectangle {
                        required property string modelData
                        required property int index
                        readonly property bool current: modelData === effect.currentActivity
                        width: Kirigami.Units.iconSizes.small
                        height: Kirigami.Units.iconSizes.small
                        radius: 3
                        color: effect.palette[index % effect.palette.length]
                        border.width: current ? 2 : 0
                        border.color: Kirigami.Theme.textColor
                        Layout.alignment: Qt.AlignCenter
                        PC3.ToolTip.text: effect.labelOf(modelData)
                        PC3.ToolTip.visible: swatchHover.hovered
                        HoverHandler { id: swatchHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { acceptedButtons: Qt.LeftButton; onTapped: effect.zoomToActivity(modelData) }
                    }
                }
                Sep {}
                PC3.ToolButton { icon.name: "zoom-fit-best";   text: "Fit";    display: PC3.AbstractButton.IconOnly; PC3.ToolTip.text: "Zoom to fit (" + effect.keyLabel(effect.configuration.KeyFit) + ")"; PC3.ToolTip.visible: hovered; onClicked: effect.zoomExtents() }
                PC3.ToolButton { icon.name: "go-home";         text: "Home";   display: PC3.AbstractButton.IconOnly; PC3.ToolTip.text: "Look through this activity's frames (" + effect.keyLabel(effect.configuration.KeyHome) + ")"; PC3.ToolTip.visible: hovered; onClicked: effect.home() }
                PC3.ToolButton { icon.name: "zoom-in";         text: "In";     display: PC3.AbstractButton.IconOnly; PC3.ToolTip.text: "Zoom in (" + effect.keyLabel(effect.configuration.KeyZoomIn) + ")"; PC3.ToolTip.visible: hovered; onClicked: effect.setZoom(effect.zoom * effect.zoomStep, Qt.point(view.sg.x + view.sg.width / 2, view.sg.y + view.sg.height / 2)) }
                PC3.ToolButton { icon.name: "zoom-out";        text: "Out";    display: PC3.AbstractButton.IconOnly; PC3.ToolTip.text: "Zoom out (" + effect.keyLabel(effect.configuration.KeyZoomOut) + ")"; PC3.ToolTip.visible: hovered; onClicked: effect.setZoom(effect.zoom / effect.zoomStep, Qt.point(view.sg.x + view.sg.width / 2, view.sg.y + view.sg.height / 2)) }
                Sep {}
                PC3.ToolButton { icon.name: "snap-bounding-box-edges";   text: "Edges";   display: PC3.AbstractButton.IconOnly; checkable: true; checked: effect.snapEdges;   onToggled: effect.snapEdges = checked;   PC3.ToolTip.text: "Snap to edges";   PC3.ToolTip.visible: hovered }
                PC3.ToolButton { icon.name: "snap-bounding-box-corners"; text: "Corners"; display: PC3.AbstractButton.IconOnly; checkable: true; checked: effect.snapCorners; onToggled: effect.snapCorners = checked; PC3.ToolTip.text: "Snap to corners"; PC3.ToolTip.visible: hovered }
                PC3.ToolButton { icon.name: "snap-grid";                 text: "Grid";    display: PC3.AbstractButton.IconOnly; checkable: true; checked: effect.snapGrid;    onToggled: effect.snapGrid = checked;    PC3.ToolTip.text: "Snap to grid (" + effect.configuration.SnapGridSize + " px)"; PC3.ToolTip.visible: hovered }
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
                        PC3.MenuItem { text: "Activities…";       icon.name: "activities"; onTriggered: KCM.KCMLauncher.openSystemSettings("kcm_activities") }
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
                K { text: "drag frame tag or edge" }                            V { text: "move that activity's screens" }
                K { text: "eye on a frame tag" }                                V { text: "hide or show that frame; a hidden frame takes no windows" }
                K { text: effect.gestureLabel(effect.configuration.MouseSelect) + " window" }        V { text: "select it" }
                K { text: effect.gestureLabel(effect.configuration.MouseSelectAdd) + " window, or +drag ground" } V { text: "add to the selection, or select by rectangle" }
                K { text: effect.gestureLabel(effect.configuration.MouseSelectToggle) + " window" }  V { text: "toggle its selection; a selected window drags the whole selection" }
                K { text: effect.gestureLabel(effect.configuration.MouseContextMenu) + " window" }   V { text: "arrange the selection: horizontal, vertical, tile, grid, cascade" }
                K { text: effect.gestureLabel(effect.configuration.MouseFocusWindow) + " window" }   V { text: effect.configuration.FocusTarget === "desktop" ? "apply, focused on it; in another activity's frame, go there" : "apply with that point under the pointer, focused on it; in another activity's frame, go there" }
                K { text: effect.gestureLabel(effect.configuration.MouseZoomToActivity) + " frame" }  V { text: "zoom to that activity" }
                K { text: effect.gestureLabel(effect.configuration.MouseGotoActivity) + " frame" }    V { text: "apply with that activity current" }
                K { text: effect.gestureLabel(effect.configuration.MouseNewActivityAt) + " window outside frames" } V { text: "new activity centred on it" }
                K { text: effect.keyLabel(effect.configuration.KeyApply) }      V { text: "apply and close" }
                K { text: effect.keyLabel(effect.configuration.KeyCancel) }     V { text: "cancel" }
                K { text: effect.keyLabel(effect.configuration.KeyHome) }       V { text: "look through this activity's frames" }
                K { text: effect.keyLabel(effect.configuration.KeyOrigin) }     V { text: "camera to the canvas origin" }
                K { text: effect.keyLabel(effect.configuration.KeyFit) }        V { text: "zoom to fit" }
            }
        }
    }
}
