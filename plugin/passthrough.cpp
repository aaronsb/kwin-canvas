/*
    SPDX-FileCopyrightText: 2026 Aaron Bockelie <aaronsb@gmail.com>
    SPDX-License-Identifier: GPL-2.0-or-later
*/
#include "passthrough.h"

#include <config-kwin.h>
#include <wayland/seat.h>
#include <wayland/surface.h>
#include <wayland_server.h>
#include <window.h>
#include <workspace.h>

#include <QDBusConnection>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLoggingCategory>

Q_LOGGING_CATEGORY(KWIN_CANVAS, "kwin_canvas_passthrough", QtWarningMsg)

using namespace KWin;

static const QString s_path = QStringLiteral("/KWinCanvas");

CanvasPassthrough::CanvasPassthrough()
    : Plugin()
    , InputEventFilter(InputFilterOrder::GlobalShortcut)
{
    input()->installInputEventFilter(this);
    if (!QDBusConnection::sessionBus().registerObject(s_path, this, QDBusConnection::ExportScriptableSlots)) {
        qCWarning(KWIN_CANVAS) << "could not register" << s_path << "on the session bus";
    }
}

CanvasPassthrough::~CanvasPassthrough()
{
    QDBusConnection::sessionBus().unregisterObject(s_path);
    input()->uninstallInputEventFilter(this);
}

QString CanvasPassthrough::probe() const
{
    return QStringLiteral("kwin-canvas-passthrough %1 kwin %2").arg(QStringLiteral(CANVAS_VERSION), KWIN_VERSION_STRING);
}

void CanvasPassthrough::setActive(bool active)
{
    if (m_active == active) {
        return;
    }
    m_active = active;
    if (!active) {
        clearGrab();
        leave();
    }
}

void CanvasPassthrough::setCamera(double viewX, double viewY, double zoom, const QString &currentActivity, const QString &targetsJson)
{
    m_viewX = viewX;
    m_viewY = viewY;
    m_zoom = zoom > 0 ? zoom : 1;
    m_current = currentActivity;
    m_targets.clear();
    const QJsonObject all = QJsonDocument::fromJson(targetsJson.toUtf8()).object();
    for (auto it = all.begin(); it != all.end(); ++it) {
        const QJsonObject t = it->toObject();
        m_targets.insert(it.key(), QPointF(t.value(QStringLiteral("x")).toDouble(), t.value(QStringLiteral("y")).toDouble()));
    }
}

QString CanvasPassthrough::state() const
{
    return QStringLiteral("active=%1 view=(%2,%3) zoom=%4 grab=%5 ground=%6 hover=%7")
        .arg(m_active ? QStringLiteral("true") : QStringLiteral("false"))
        .arg(m_viewX)
        .arg(m_viewY)
        .arg(m_zoom)
        .arg(m_grab ? m_grab->caption() : QStringLiteral("-"))
        .arg(m_grabGround ? QStringLiteral("true") : QStringLiteral("false"))
        .arg(m_hover ? m_hover->caption() : QStringLiteral("-"));
}

// ---- the plane ---------------------------------------------------------------

QPointF CanvasPassthrough::toCanvas(const QPointF &screen) const
{
    return QPointF(m_viewX + screen.x() / m_zoom, m_viewY + screen.y() / m_zoom);
}

// The activity a window belongs to for placement: the current one when it is
// there or on every activity, else its first. Same rule as the effect.
QPointF CanvasPassthrough::targetOf(Window *window) const
{
    QString id = m_current;
    if (!window->isOnAllActivities() && !window->isOnActivity(m_current)) {
        const QStringList a = window->activities();
        if (!a.isEmpty()) {
            id = a.first();
        }
    }
    return m_targets.value(id, QPointF(m_viewX, m_viewY));
}

// What the quiet canvas draws: at 1:1 this activity's windows, zoomed out
// every activity's. Same filter as the effect's entries.
bool CanvasPassthrough::drawn(Window *window) const
{
    if (!window->isClient() || window->isDeleted() || window->isUnmanaged()) {
        return false;
    }
    if (window->isDesktop() || window->isDock() || window->isPopupWindow() || window->isSpecialWindow()) {
        return false;
    }
    if (window->isMinimized() || window->isHidden() || !window->isOnCurrentDesktop()) {
        return false;
    }
    if (m_zoom < 0.999) {
        return true;
    }
    return window->isOnAllActivities() || window->isOnActivity(m_current);
}

Window *CanvasPassthrough::windowAt(const QPointF &canvas) const
{
    const QList<Window *> &stack = workspace()->stackingOrder();
    for (auto it = stack.crbegin(); it != stack.crend(); ++it) {
        Window *w = *it;
        if (!drawn(w)) {
            continue;
        }
        const QRectF frame = QRectF(w->frameGeometry()).translated(targetOf(w));
        if (frame.contains(canvas)) {
            return w;
        }
    }
    return nullptr;
}

// ---- delivery ----------------------------------------------------------------

bool CanvasPassthrough::enter(Window *window, const QPointF &canvas)
{
    SurfaceInterface *root = window->surface();
    if (!root) {
        return false;
    }
    // The window's real global position is the canvas point minus its target;
    // its own input transformation takes that to surface coordinates.
    const QPointF global = canvas - targetOf(window);
    const QMatrix4x4 toSurface = window->inputTransformation();
    const QPointF local = toSurface.map(global);
    const auto [surface, childLocal] = root->mapToInputSurface(local);
    if (!surface) {
        return false;
    }
    SeatInterface *seat = waylandServer()->seat();
    if (m_hoverSurface != surface) {
        QMatrix4x4 toChild;
        toChild.translate(childLocal.x() - local.x(), childLocal.y() - local.y());
        seat->notifyPointerEnter(surface, global, toChild * toSurface);
        m_hoverSurface = surface;
        m_hover = window;
    } else {
        seat->notifyPointerMotion(global);
    }
    seat->notifyPointerFrame();
    return true;
}

void CanvasPassthrough::leave()
{
    if (m_hoverSurface) {
        SeatInterface *seat = waylandServer()->seat();
        seat->notifyPointerLeave();
        seat->notifyPointerFrame();
    }
    m_hoverSurface = nullptr;
    m_hover = nullptr;
}

void CanvasPassthrough::clearGrab()
{
    m_grab = nullptr;
    m_grabGround = false;
    m_buttons = Qt::NoButton;
}

// ---- the filter --------------------------------------------------------------

bool CanvasPassthrough::pointerMotion(PointerMotionEvent *event)
{
    if (!m_active) {
        return false;
    }
    if (m_grabGround) {
        return false;
    }
    const QPointF canvas = toCanvas(event->position);
    if (m_grab) {
        // Implicit grab: the window keeps the pointer until the buttons are up.
        if (!enter(m_grab, canvas)) {
            waylandServer()->seat()->notifyPointerMotion(canvas - targetOf(m_grab));
            waylandServer()->seat()->notifyPointerFrame();
        }
        return true;
    }
    Window *w = windowAt(canvas);
    if (w && enter(w, canvas)) {
        return true;
    }
    leave();
    return false;
}

bool CanvasPassthrough::pointerButton(PointerButtonEvent *event)
{
    if (!m_active) {
        return false;
    }
    const bool pressed = event->state == PointerButtonState::Pressed;
    const bool first = pressed && m_buttons == Qt::NoButton;
    if (pressed) {
        m_buttons |= event->button;
    } else {
        m_buttons &= ~event->button;
    }
    if (first) {
        // A new gesture: the window under the pointer takes it, or the ground does.
        const QPointF canvas = toCanvas(event->position);
        Window *w = windowAt(canvas);
        if (w && enter(w, canvas)) {
            m_grab = w;
            m_grabGround = false;
            workspace()->activateWindow(w);
        } else {
            leave();
            m_grab = nullptr;
            m_grabGround = true;
        }
    }
    bool consumed = false;
    if (m_grab) {
        SeatInterface *seat = waylandServer()->seat();
        seat->notifyPointerButton(event->button, event->state);
        seat->notifyPointerFrame();
        consumed = true;
    }
    if (m_buttons == Qt::NoButton) {
        m_grab = nullptr;
        m_grabGround = false;
    }
    return consumed;
}

bool CanvasPassthrough::pointerAxis(PointerAxisEvent *event)
{
    if (!m_active || m_grabGround) {
        return false;
    }
    const QPointF canvas = toCanvas(event->position);
    Window *w = m_grab ? m_grab.data() : windowAt(canvas);
    if (!w || !enter(w, canvas)) {
        return false;
    }
    SeatInterface *seat = waylandServer()->seat();
    seat->notifyPointerAxis(event->orientation, event->delta, event->deltaV120, event->source, event->inverted);
    seat->notifyPointerFrame();
    return true;
}
