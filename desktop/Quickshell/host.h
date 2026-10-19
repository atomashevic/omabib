#pragma once

#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QPointer>
#include <QUrl>
#include <QtQml/qqmlregistration.h>
#include <optional>

class QJSEngine;
class QLocalServer;
class QQmlEngine;
class QQuickWindow;

// What the Omarchy shell did for the plugin: one running copy, reached by
// later launches over a local socket. Each message is one line of JSON:
//   {"cmd":"open"|"toggle", "payload":"{...}", "activation_token":"..."}
//   {"cmd":"ipc", "target":"omabib", "function":"state", "args":[]}
//   {"cmd":"screenshot", "path":"/abs/file.png"}
//   {"cmd":"quit"}
// and is answered with {"ok":true[,"result":...]} or {"error":"..."}.
class DesktopHost : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QUrl appUrl READ appUrl CONSTANT)

public:
    static DesktopHost *instance();
    static DesktopHost *create(QQmlEngine *, QJSEngine *);
    static QString socketPath();
    // The running copy's reply, or nothing when no copy is running.
    static std::optional<QJsonObject> send(const QJsonObject &message, int timeoutMs = 30000);

    bool listen(QString *error);
    QJsonObject handle(const QJsonObject &message);

    QUrl appUrl() const { return m_appUrl; }
    void setAppUrl(const QUrl &url) { m_appUrl = url; }

    Q_INVOKABLE void trackWindow(QObject *window);
    Q_INVOKABLE void raiseWindows();
    Q_INVOKABLE bool windowActive() const;

    void setIpcTarget(QObject *handler, const QString &target);

signals:
    // Show the app with an App.open payload; `toggle` hides it instead when
    // it already has focus.
    void openRequested(const QString &payload, bool toggle);

private:
    explicit DesktopHost(QObject *parent = nullptr);
    void onConnection();
    QJsonObject invokeIpc(const QJsonObject &message);
    QJsonObject screenshot(const QString &path);

    QUrl m_appUrl;
    QLocalServer *m_server = nullptr;
    QList<QPointer<QQuickWindow>> m_windows;
    QHash<QString, QPointer<QObject>> m_ipc;
};
