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
import org.kde.kirigami as Kirigami
import org.kde.kwin as KWin

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
    property int lastDebugSeq: 0

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

    // The desktop whose frames contain the centre of a canvas rect, or null.
    function desktopAt(rect) {
        const cx = rect.x + rect.width / 2, cy = rect.y + rect.height / 2;
        const ds = KWin.Workspace.desktops;
        const screens = KWin.Workspace.screens;
        for (let i = 0; i < ds.length; ++i) {
            const t = peekTarget(ds[i]);
            for (let j = 0; j < screens.length; ++j) {
                const g = screens[j].geometry;
                if (cx >= t.x + g.x && cx < t.x + g.x + g.width && cy >= t.y + g.y && cy < t.y + g.y + g.height) return ds[i];
            }
        }
        return null;
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
        targets[KWin.Workspace.currentDesktop.id] = { x: viewX, y: viewY };
        ensureTargets();
        entryTargets = copyTargets(targets);
        snapshot();
        visible = true;
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

    // Apply with this window on screen. If it sits in no frame, centre the
    // current desktop's active-screen frame on it first.
    function pick(entry) {
        if (!desktopAt(entry)) {
            const g = KWin.Workspace.activeScreen.geometry;
            const t = targetOf(KWin.Workspace.currentDesktop);
            t.x = entry.x + entry.width / 2 - (g.x + g.width / 2);
            t.y = entry.y + entry.height / 2 - (g.y + g.height / 2);
        }
        commit(entry.window);
    }

    // Move a window on the canvas by a screen-space delta while the canvas is open.
    // Entries are addressed by index: the Repeater hands delegates a copy of the
    // element, so mutating modelData would never reach the committed table.
    function dragEntry(index, dx, dy) {
        const e = entries[index];
        if (!e) return;
        e.x += dx / zoom;
        e.y += dy / zoom;
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
            s += "\n  [" + i + "] " + e.window.caption + " canvas=(" + e.x.toFixed(0) + "," + e.y.toFixed(0) + " " + e.width + "x" + e.height + ") frame=(" + g.x + "," + g.y + ") desktop=" + e.desktop.name;
        }
        console.log(s);
    }

    onConfigurationChanged: {
        const seq = configuration.DebugSeq;
        if (seq !== lastDebugSeq) {
            lastDebugSeq = seq;
            const cmd = configuration.DebugCommand;
            if (cmd && cmd.length > 0) runDebug(cmd);
        }
    }

    Component.onCompleted: {
        lastDebugSeq = configuration.DebugSeq;
        if (configuration.AutoActivate) {
            Qt.callLater(open);
        }
    }

    // ---- per-screen view ---------------------------------------------------
    delegate: Item {
        id: view
        readonly property rect sg: KWin.SceneView.screen.geometry
        property bool spaceHeld: false
        // Number of grabbable things (windows, frame handles) under the pointer.
        // The pan handler refuses a left press while this is non-zero, so a drag
        // that starts on one of them moves it instead of racing the pan.
        property int hoverCount: 0
        readonly property bool overWindow: hoverCount > 0
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
        // left-drag anywhere (Space disables the other handlers).
        DragHandler {
            id: panDrag
            target: null
            acceptedButtons: (view.spaceHeld || !view.overWindow) ? (Qt.LeftButton | Qt.MiddleButton) : Qt.MiddleButton
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
                // Grips under the pointer. The move and pick handlers stand
                // down while this is non-zero so a press on a grip resizes.
                property int gripHover: 0
                x: { effect.revision; return (effect.entries[index].x - effect.viewX) * effect.zoom - view.sg.x; }
                y: { effect.revision; return (effect.entries[index].y - effect.viewY) * effect.zoom - view.sg.y; }
                width: { effect.revision; return effect.entries[index].width * effect.zoom; }
                height: { effect.revision; return effect.entries[index].height * effect.zoom; }
                z: index

                KWin.WindowThumbnail {
                    anchors.fill: parent
                    client: thumb.entry.window
                }

                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    border.width: hover.hovered || winDrag.active ? 2 : 1
                    border.color: hover.hovered || winDrag.active ? "#ffffff" : "#40ffffff"
                }

                Text {
                    anchors.left: parent.left
                    anchors.bottom: parent.top
                    anchors.bottomMargin: 2
                    text: thumb.entry.window.caption
                    color: "#ffffff"
                    font.pixelSize: 12
                    visible: effect.zoom < 0.6 || hover.hovered
                    style: Text.Outline
                    styleColor: "#000000"
                }

                HoverHandler {
                    id: hover
                    onHoveredChanged: view.hoverCount += hovered ? 1 : -1
                    Component.onDestruction: if (hovered) view.hoverCount -= 1
                }

                DragHandler {
                    id: winDrag
                    target: null
                    enabled: !view.spaceHeld && thumb.gripHover === 0
                    acceptedButtons: Qt.LeftButton
                    property point last: Qt.point(0, 0)
                    onActiveChanged: last = Qt.point(0, 0)
                    onActiveTranslationChanged: {
                        const t = activeTranslation;
                        effect.dragEntry(thumb.index, t.x - last.x, t.y - last.y);
                        last = t;
                    }
                }

                TapHandler {
                    enabled: !view.spaceHeld && thumb.gripHover === 0
                    acceptedButtons: Qt.LeftButton
                    onTapped: effect.pick(thumb.entry)
                }

                // The client decides the size it ends up with. Follow it.
                Connections {
                    target: thumb.entry.window
                    function onFrameGeometryChanged() { effect.syncIndex(thumb.index); }
                }

                // Resize handles: four edges, four corners. Each drag step
                // commands the real window to the new size.
                Repeater {
                    model: 8
                    delegate: Item {
                        id: grip
                        required property int index
                        readonly property int b: 6
                        readonly property int c: 14
                        readonly property bool north: index === 0 || index === 4 || index === 5
                        readonly property bool south: index === 1 || index === 6 || index === 7
                        readonly property bool west: index === 2 || index === 4 || index === 6
                        readonly property bool east: index === 3 || index === 5 || index === 7
                        readonly property bool corner: index >= 4
                        x: corner ? (west ? 0 : thumb.width - c) : (west ? 0 : (east ? thumb.width - b : c))
                        y: corner ? (north ? 0 : thumb.height - c) : (north ? 0 : (south ? thumb.height - b : c))
                        width: corner ? c : ((west || east) ? b : Math.max(0, thumb.width - 2 * c))
                        height: corner ? c : ((north || south) ? b : Math.max(0, thumb.height - 2 * c))
                        z: 10

                        HoverHandler {
                            enabled: !view.spaceHeld
                            cursorShape: grip.corner
                                ? ((grip.north && grip.west) || (grip.south && grip.east) ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor)
                                : ((grip.north || grip.south) ? Qt.SizeVerCursor : Qt.SizeHorCursor)
                            onHoveredChanged: {
                                view.hoverCount += hovered ? 1 : -1;
                                thumb.gripHover += hovered ? 1 : -1;
                            }
                            Component.onDestruction: if (hovered) { view.hoverCount -= 1; thumb.gripHover -= 1; }
                        }
                        DragHandler {
                            id: gripDrag
                            target: null
                            enabled: !view.spaceHeld
                            acceptedButtons: Qt.LeftButton
                            property real startW: 0
                            property real startH: 0
                            onActiveChanged: {
                                if (active) {
                                    startW = thumb.entry.width;
                                    startH = thumb.entry.height;
                                }
                            }
                            onActiveTranslationChanged: {
                                const t = activeTranslation;
                                let rw = startW, rh = startH;
                                if (grip.east) rw = startW + t.x / effect.zoom;
                                if (grip.west) rw = startW - t.x / effect.zoom;
                                if (grip.south) rh = startH + t.y / effect.zoom;
                                if (grip.north) rh = startH - t.y / effect.zoom;
                                effect.requestSize(thumb.index, rw, rh, grip.west, grip.north);
                            }
                        }
                    }
                }
            }
        }

        // Monitor frames: one per desktop per output. A desktop's frames are a
        // rigid group; dragging any tag or edge moves them all.
        Repeater {
            model: KWin.Workspace.desktops
            delegate: Repeater {
                id: desktopFrames
                required property var modelData
                required property int index
                readonly property var desktop: modelData
                readonly property int desktopIndex: index
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
                    z: 50000 + (desktopFrames.current ? 1 : 0)

                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.width: desktopFrames.current ? 2 : 1
                        border.color: desktopFrames.accent
                        opacity: desktopFrames.current ? 0.95 : 0.6
                    }

                    // Name tag: the drag handle, like a window caption, with
                    // the desktop controls KDE's pager has: add after, remove.
                    Rectangle {
                        id: tag
                        x: 0
                        y: -height - 2
                        width: tagRow.implicitWidth + 12
                        height: tagRow.implicitHeight + 6
                        radius: 3
                        color: desktopFrames.accent
                        opacity: desktopFrames.current ? 1 : 0.75
                        Row {
                            id: tagRow
                            anchors.centerIn: parent
                            spacing: 6
                            Text {
                                id: tagText
                                anchors.verticalCenter: parent.verticalCenter
                                text: desktopFrames.desktop.name + " · " + frame.modelData.name + "  " + frame.og.width + "x" + frame.og.height
                                color: "#ffffff"
                                font.pixelSize: 12
                                font.bold: true
                            }
                            Rectangle {
                                id: addButton
                                anchors.verticalCenter: parent.verticalCenter
                                width: 18; height: 18; radius: 3
                                color: addHover.hovered ? "#60ffffff" : "#30ffffff"
                                Kirigami.Icon {
                                    anchors.fill: parent
                                    anchors.margins: 2
                                    source: "list-add"
                                    color: "#ffffff"
                                }
                                HoverHandler {
                                    id: addHover
                                    onHoveredChanged: view.hoverCount += hovered ? 1 : -1
                                    Component.onDestruction: if (hovered) view.hoverCount -= 1
                                }
                                TapHandler {
                                    acceptedButtons: Qt.LeftButton
                                    gesturePolicy: TapHandler.ReleaseWithinBounds
                                    onTapped: effect.addDesktopAfter(desktopFrames.desktop)
                                }
                            }
                            Rectangle {
                                id: removeButton
                                visible: desktopFrames.desktopIndex > 0
                                anchors.verticalCenter: parent.verticalCenter
                                width: 18; height: 18; radius: 3
                                color: removeHover.hovered ? "#80ff4040" : "#30ffffff"
                                Kirigami.Icon {
                                    anchors.fill: parent
                                    anchors.margins: 2
                                    source: "edit-delete"
                                    color: "#ffffff"
                                }
                                HoverHandler {
                                    id: removeHover
                                    onHoveredChanged: view.hoverCount += hovered ? 1 : -1
                                    Component.onDestruction: if (hovered) view.hoverCount -= 1
                                }
                                TapHandler {
                                    acceptedButtons: Qt.LeftButton
                                    gesturePolicy: TapHandler.ReleaseWithinBounds
                                    onTapped: effect.removeDesktop(desktopFrames.desktop)
                                }
                            }
                        }
                        HoverHandler {
                            onHoveredChanged: view.hoverCount += hovered ? 1 : -1
                            Component.onDestruction: if (hovered) view.hoverCount -= 1
                        }
                        DragHandler {
                            target: null
                            enabled: !view.spaceHeld
                            acceptedButtons: Qt.LeftButton
                            cursorShape: Qt.SizeAllCursor
                            property point last: Qt.point(0, 0)
                            onActiveChanged: last = Qt.point(0, 0)
                            onActiveTranslationChanged: {
                                const t = activeTranslation;
                                effect.dragTarget(desktopFrames.desktop, t.x - last.x, t.y - last.y);
                                last = t;
                            }
                        }
                    }

                    // Edge bands: also drag handles.
                    Repeater {
                        model: 4
                        delegate: Item {
                            required property int index
                            readonly property int band: 8
                            x: index === 1 ? frame.width - band : 0
                            y: index === 3 ? frame.height - band : 0
                            width: (index === 0 || index === 2) ? frame.width : band
                            height: (index === 1 || index === 3) ? frame.height : band
                            HoverHandler {
                                onHoveredChanged: view.hoverCount += hovered ? 1 : -1
                                Component.onDestruction: if (hovered) view.hoverCount -= 1
                            }
                            DragHandler {
                                target: null
                                enabled: !view.spaceHeld
                                acceptedButtons: Qt.LeftButton
                                cursorShape: Qt.SizeAllCursor
                                property point last: Qt.point(0, 0)
                                onActiveChanged: last = Qt.point(0, 0)
                                onActiveTranslationChanged: {
                                    const t = activeTranslation;
                                    effect.dragTarget(desktopFrames.desktop, t.x - last.x, t.y - last.y);
                                    last = t;
                                }
                            }
                        }
                    }
                }
            }
        }

        Keys.onPressed: (event) => {
            switch (event.key) {
            case Qt.Key_Space:
                if (!event.isAutoRepeat) view.spaceHeld = true;
                event.accepted = true;
                break;
            case Qt.Key_Escape: effect.cancel(); event.accepted = true; break;
            case Qt.Key_Return:
            case Qt.Key_Enter: effect.commit(null); event.accepted = true; break;
            case Qt.Key_Home: effect.home(); event.accepted = true; break;
            case Qt.Key_0: effect.origin(); event.accepted = true; break;
            case Qt.Key_F:
            case Qt.Key_W: effect.zoomExtents(); event.accepted = true; break;
            case Qt.Key_Plus:
            case Qt.Key_Equal: effect.setZoom(effect.zoom * effect.zoomStep, KWin.Workspace.cursorPos); event.accepted = true; break;
            case Qt.Key_Minus: effect.setZoom(effect.zoom / effect.zoomStep, KWin.Workspace.cursorPos); event.accepted = true; break;
            }
        }

        Keys.onReleased: (event) => {
            if (event.key === Qt.Key_Space && !event.isAutoRepeat) {
                view.spaceHeld = false;
                event.accepted = true;
            }
        }

        // HUD
        Rectangle {
            z: 100000
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: 12
            width: hud.implicitWidth + 16
            height: hud.implicitHeight + 10
            radius: 6
            color: "#a0000000"
            Text {
                id: hud
                anchors.centerIn: parent
                color: "#ffffff"
                font.pixelSize: 13
                font.family: "monospace"
                text: "zoom " + effect.zoom.toFixed(2) + "   view " + Math.round(effect.viewX) + ", " + Math.round(effect.viewY)
                    + "   desktop " + KWin.Workspace.currentDesktop.name
                    + "\ndrag ground or space+drag: pan   wheel: zoom   drag window: move   drag window edge: resize   drag frame tag/edge: move that desktop's screens   click window: pick"
                    + "\nenter: apply   esc: cancel   home: look through frames   0: origin   f: fit"
            }
        }
    }
}
