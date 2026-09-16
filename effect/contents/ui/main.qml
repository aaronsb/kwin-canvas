/*
    kwin-canvas: an infinite canvas for KWin, built on the public scripting API.

    At 1:1 there is no effect running. Windows are ordinary KWin windows at
    ordinary positions, some of them off-screen. The screen is a 1:1 viewport
    onto that plane.

    Opening the canvas (Meta+Space) snapshots every window's position into
    canvas coordinates and shows them as live thumbnails on a ground grid.
    Pan, zoom, drag windows around, pick one. Closing the canvas writes the
    new positions back as plain window geometry and hands input back to KWin.

    Coordinate spaces:
      canvas   the plane windows live on; unbounded
      global   KWin's coordinate space across all outputs
      view     (viewX, viewY) is the canvas point at global (0,0)

      global = (canvas - view) * zoom
      canvas = view + global / zoom
*/
import QtQuick
import org.kde.kwin as KWin

KWin.SceneEffect {
    id: effect

    // ---- camera ------------------------------------------------------------
    property real viewX: 0
    property real viewY: 0
    property real zoom: 1.0
    property real entryViewX: 0
    property real entryViewY: 0

    // ---- model -------------------------------------------------------------
    // Each entry: { window, x, y, width, height } in canvas units, bottom to top.
    property var entries: []
    property int revision: 0
    property int lastDebugSeq: 0

    readonly property real zoomMin: configuration.ZoomMin
    readonly property real zoomStep: configuration.ZoomStep

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

    function snapshot() {
        const list = [];
        const stack = KWin.Workspace.stackingOrder;
        for (let i = 0; i < stack.length; ++i) {
            const w = stack[i];
            if (!isCanvasWindow(w, false)) continue;
            const g = w.frameGeometry;
            list.push({ window: w, x: g.x + viewX, y: g.y + viewY, width: g.width, height: g.height });
        }
        entries = list;
        revision++;
    }

    // ---- camera ops --------------------------------------------------------
    function globalToCanvas(gx, gy) { return Qt.point(viewX + gx / zoom, viewY + gy / zoom); }
    function canvasToGlobal(cx, cy) { return Qt.point((cx - viewX) * zoom, (cy - viewY) * zoom); }

    // Zoom while holding the canvas point under `anchor` (global px) fixed on screen.
    function setZoom(z, anchor) {
        z = Math.max(zoomMin, Math.min(1.0, z));
        const c = globalToCanvas(anchor.x, anchor.y);
        zoom = z;
        viewX = c.x - anchor.x / zoom;
        viewY = c.y - anchor.y / zoom;
    }

    // Pan by a screen-space delta.
    function panBy(dx, dy) {
        viewX -= dx / zoom;
        viewY -= dy / zoom;
    }

    function home() {
        viewX = 0;
        viewY = 0;
        zoom = 1.0;
    }

    // Fit every window into the active screen.
    function zoomExtents() {
        if (entries.length === 0) { home(); return; }
        let l = Infinity, t = Infinity, r = -Infinity, b = -Infinity;
        for (let i = 0; i < entries.length; ++i) {
            const e = entries[i];
            l = Math.min(l, e.x); t = Math.min(t, e.y);
            r = Math.max(r, e.x + e.width); b = Math.max(b, e.y + e.height);
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
        snapshot();
        visible = true;
    }

    // Snap to 1:1 around the cursor, write canvas positions back as geometry, hand input back.
    function commit(activate) {
        setZoom(1.0, KWin.Workspace.cursorPos);
        const seen = {};
        for (let i = 0; i < entries.length; ++i) {
            const e = entries[i];
            if (e.window.deleted) continue;
            seen[e.window.internalId] = true;
            e.window.frameGeometry = Qt.rect(e.x - viewX, e.y - viewY, e.width, e.height);
        }
        // Windows not shown (other desktops) still share the plane: shift them by the pan.
        const dx = entryViewX - viewX, dy = entryViewY - viewY;
        if (dx !== 0 || dy !== 0) {
            const all = KWin.Workspace.stackingOrder;
            for (let i = 0; i < all.length; ++i) {
                const w = all[i];
                if (seen[w.internalId] || !isCanvasWindow(w, true)) continue;
                const g = w.frameGeometry;
                w.frameGeometry = Qt.rect(g.x + dx, g.y + dy, g.width, g.height);
            }
        }
        publishGround();
        visible = false;
        if (activate && !activate.deleted) {
            KWin.Workspace.activeWindow = activate;
        }
    }

    function cancel() {
        viewX = entryViewX;
        viewY = entryViewY;
        zoom = 1.0;
        visible = false;
    }

    function toggle() {
        if (visible) commit(null); else open();
    }

    function pick(entry) {
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
    // Shift the whole plane so the screen shows a different region, at 1:1.
    function shiftAll(dx, dy) {
        const all = KWin.Workspace.stackingOrder;
        for (let i = 0; i < all.length; ++i) {
            const w = all[i];
            if (!isCanvasWindow(w, true)) continue;
            const g = w.frameGeometry;
            w.frameGeometry = Qt.rect(g.x + dx, g.y + dy, g.width, g.height);
        }
        viewX -= dx;
        viewY -= dy;
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
        text: "Canvas: return to the origin"
        sequence: effect.configuration.HomeShortcut
        onActivated: {
            if (effect.visible) { effect.home(); return; }
            effect.open();
            effect.home();
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
        case "extents": zoomExtents(); break;
        case "pan": panBy(Number(a[1]), Number(a[2])); break;
        case "zoom": {
            const p = a.length >= 4 ? Qt.point(Number(a[2]), Number(a[3])) : KWin.Workspace.cursorPos;
            setZoom(Number(a[1]), p);
            break;
        }
        case "shift": shiftAll(Number(a[1]), Number(a[2])); break;
        case "drag": dragEntry(Number(a[1]), Number(a[2]), Number(a[3])); break;
        case "activate": {
            const all = KWin.Workspace.stackingOrder;
            for (let i = 0; i < all.length; ++i) {
                if (all[i].caption.indexOf(a[1]) !== -1) { KWin.Workspace.activeWindow = all[i]; break; }
            }
            break;
        }
        case "list": {
            const all = KWin.Workspace.stackingOrder;
            let s = "kwin-canvas windows:";
            for (let i = 0; i < all.length; ++i) {
                const w = all[i]; const g = w.frameGeometry;
                s += "\n  " + (isCanvasWindow(w, true) ? "*" : " ") + " " + w.caption + " frame=(" + g.x + "," + g.y + " " + g.width + "x" + g.height + ")";
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
        let s = "kwin-canvas state visible=" + visible + " zoom=" + zoom.toFixed(4) + " view=(" + viewX.toFixed(1) + "," + viewY.toFixed(1) + ") entries=" + entries.length;
        for (let i = 0; i < entries.length; ++i) {
            const e = entries[i];
            const g = e.window.frameGeometry;
            s += "\n  [" + i + "] " + e.window.caption + " canvas=(" + e.x.toFixed(0) + "," + e.y.toFixed(0) + " " + e.width + "x" + e.height + ") frame=(" + g.x + "," + g.y + ")";
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
        focus: true

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

        // Pan: middle-drag anywhere, or hold Space and left-drag (the hand tool).
        DragHandler {
            id: panDrag
            target: null
            acceptedButtons: view.spaceHeld ? (Qt.LeftButton | Qt.MiddleButton) : Qt.MiddleButton
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

                HoverHandler { id: hover }

                DragHandler {
                    id: winDrag
                    target: null
                    enabled: !view.spaceHeld
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
                    enabled: !view.spaceHeld
                    acceptedButtons: Qt.LeftButton
                    onTapped: effect.pick(thumb.entry)
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
            case Qt.Key_Home:
            case Qt.Key_0: effect.home(); event.accepted = true; break;
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
                    + "\nspace+drag or middle-drag: pan   wheel: zoom   click: pick   drag window: move\nenter: apply   esc: cancel   home: origin   f: fit"
            }
        }
    }
}
