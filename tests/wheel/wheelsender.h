#pragma once

#include <QObject>
#include <QWheelEvent>
#include <QtGui/QGuiApplication>
#include <QtQuick/QQuickItem>
#include <QtQuick/QQuickWindow>

// Sends a real QWheelEvent. mouseWheel() in Qt Quick Test can only set angleDelta.
class WheelSender : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool holdStamp READ holdStamp WRITE setHoldStamp)

public:
    bool holdStamp() const { return m_hold; }
    void setHoldStamp(bool hold) { m_hold = hold; }

    Q_INVOKABLE void send(QQuickItem *item, int angleX, int angleY, int pixelX, int pixelY)
    {
        if (!item || !item->window())
            return;
        const QPointF local = item->mapToScene(QPointF(item->width() / 2.0, item->height() / 2.0));
        const QPointF global = item->window()->mapToGlobal(local);
        const bool pixelsOnly = (pixelX != 0 || pixelY != 0) && angleX == 0 && angleY == 0;
        QWheelEvent event(local, global, QPoint(pixelX, pixelY), QPoint(angleX, angleY),
                          Qt::NoButton, Qt::NoModifier,
                          pixelsOnly ? Qt::ScrollUpdate : Qt::NoScrollPhase,
                          false,
                          pixelsOnly ? Qt::MouseEventSynthesizedBySystem : Qt::MouseEventNotSynthesized);
        event.setTimestamp(static_cast<ulong>(m_stamp));
        if (!m_hold)
            m_stamp += 40;
        QCoreApplication::sendEvent(item->window(), &event);
    }

private:
    int m_stamp = 1000;
    bool m_hold = false;
};
