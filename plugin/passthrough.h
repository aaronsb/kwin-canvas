/*
    SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
    SPDX-License-Identifier: GPL-2.0-or-later
*/
#pragma once

#include <input.h>
#include <input_event.h>
#include <plugin.h>

#include <QHash>
#include <QMatrix4x4>
#include <QPointF>
#include <QPointer>
#include <QString>

namespace KWin
{
class Window;
class SurfaceInterface;
}

/**
 * Pointer pass-through for the kwin-canvas effect's pan mode.
 *
 * While the canvas is open it holds every pointer event, and the windows on
 * screen are thumbnails. This filter sits ahead of the effects filter in
 * KWin's input chain. When the canvas tells it the camera (view, zoom, the
 * per-activity targets) and switches it on, it maps each pointer event from
 * the screen onto the plane, finds the topmost drawn window there, and hands
 * the event to that window's surface as if the pointer were over it at 1:1.
 * Events over the ground fall through to the canvas, which pans.
 *
 * A press inside a window's client area raises the window and starts an
 * implicit grab that lasts until every button is up. A press on the ground
 * leaves the whole gesture to the canvas. Hover and wheel go to the window
 * under the pointer. Keys are not touched: they stay the canvas's.
 *
 * The canvas talks to it over D-Bus on KWin's bus name, object /KWinCanvas,
 * interface org.kde.kwin.canvas.Passthrough.
 */
class CanvasPassthrough : public KWin::Plugin, public KWin::InputEventFilter
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.kde.kwin.canvas.Passthrough")

public:
    CanvasPassthrough();
    ~CanvasPassthrough() override;

public Q_SLOTS:
    /** Identity and the KWin this was built for: "kwin-canvas-passthrough VERSION kwin KWIN". */
    Q_SCRIPTABLE QString probe() const;
    /** Switch the filter on or off. Off drops any grab and leaves the hovered surface. */
    Q_SCRIPTABLE void setActive(bool active);
    /**
     * The canvas camera. targetsJson maps activity id to {"x":..,"y":..},
     * the canvas point each activity's frames put at global (0,0).
     */
    Q_SCRIPTABLE void setCamera(double viewX, double viewY, double zoom, const QString &currentActivity, const QString &targetsJson);
    /** One line of state for the nest harness: active, camera, grab, hover. */
    Q_SCRIPTABLE QString state() const;

public:
    bool pointerMotion(KWin::PointerMotionEvent *event) override;
    bool pointerButton(KWin::PointerButtonEvent *event) override;
    bool pointerAxis(KWin::PointerAxisEvent *event) override;

private:
    QPointF toCanvas(const QPointF &screen) const;
    QPointF targetOf(KWin::Window *window) const;
    bool drawn(KWin::Window *window) const;
    KWin::Window *windowAt(const QPointF &canvas) const;
    /** Enter (or stay on) the input surface of @p window under @p canvas. False if no surface takes input there. */
    bool enter(KWin::Window *window, const QPointF &canvas);
    void leave();
    void clearGrab();

    bool m_active = false;
    double m_viewX = 0;
    double m_viewY = 0;
    double m_zoom = 1;
    QString m_current;
    QHash<QString, QPointF> m_targets;

    QPointer<KWin::Window> m_grab;
    bool m_grabGround = false;
    Qt::MouseButtons m_buttons;
    QPointer<KWin::Window> m_hover;
    QPointer<KWin::SurfaceInterface> m_hoverSurface;
};
