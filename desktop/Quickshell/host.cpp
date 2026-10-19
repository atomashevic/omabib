#include "host.h"

#include <QCoreApplication>
#include <QDeadlineTimer>
#include <QDir>
#include <QFileInfo>
#include <QJSEngine>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLocalServer>
#include <QLocalSocket>
#include <QMetaMethod>
#include <QQuickWindow>
#include <QStandardPaths>
#include <QTimer>
#include <vector>

DesktopHost::DesktopHost(QObject *parent) : QObject(parent) {}

DesktopHost *DesktopHost::instance() {
    static DesktopHost *host = new DesktopHost(QCoreApplication::instance());
    return host;
}

DesktopHost *DesktopHost::create(QQmlEngine *, QJSEngine *) {
    QJSEngine::setObjectOwnership(instance(), QJSEngine::CppOwnership);
    return instance();
}

QString DesktopHost::socketPath() {
    const QString overridden = qEnvironmentVariable("OMABIB_DESKTOP_SOCKET");
    if (!overridden.isEmpty()) return overridden;
    QString dir = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
    if (dir.isEmpty()) dir = QDir::tempPath();
    return dir + "/omabib-desktop.sock";
}

std::optional<QJsonObject> DesktopHost::send(const QJsonObject &message, int timeoutMs) {
    QLocalSocket socket;
    socket.connectToServer(socketPath());
    if (!socket.waitForConnected(500)) return std::nullopt;
    socket.write(QJsonDocument(message).toJson(QJsonDocument::Compact) + '\n');
    socket.flush();
    QDeadlineTimer deadline(timeoutMs);
    while (!socket.canReadLine()) {
        if (deadline.hasExpired() || !socket.waitForReadyRead(int(deadline.remainingTime())))
            return QJsonObject{{"error", "No answer from the running Omabib"}};
    }
    return QJsonDocument::fromJson(socket.readLine()).object();
}

bool DesktopHost::listen(QString *error) {
    const QString path = socketPath();
    QDir().mkpath(QFileInfo(path).absolutePath());
    // Only reached when no running copy answered, so a leftover file is stale.
    QLocalServer::removeServer(path);
    m_server = new QLocalServer(this);
    m_server->setSocketOptions(QLocalServer::UserAccessOption);
    if (!m_server->listen(path)) {
        *error = m_server->errorString();
        return false;
    }
    connect(m_server, &QLocalServer::newConnection, this, &DesktopHost::onConnection);
    return true;
}

void DesktopHost::onConnection() {
    while (QLocalSocket *client = m_server->nextPendingConnection()) {
        connect(client, &QLocalSocket::disconnected, client, &QObject::deleteLater);
        connect(client, &QLocalSocket::readyRead, this, [this, client] {
            while (client->canReadLine()) {
                QJsonParseError parseError;
                const QJsonDocument doc = QJsonDocument::fromJson(client->readLine(), &parseError);
                const QJsonObject reply = doc.isObject() ? handle(doc.object())
                                                         : QJsonObject{{"error", parseError.errorString()}};
                client->write(QJsonDocument(reply).toJson(QJsonDocument::Compact) + '\n');
                client->flush();
            }
        });
    }
}

QJsonObject DesktopHost::handle(const QJsonObject &message) {
    const QString cmd = message["cmd"].toString();
    if (cmd == "open" || cmd == "toggle") {
        // Wayland only lets a window take focus with the launcher's token;
        // Qt hands this variable to the next requestActivate.
        const QString token = message["activation_token"].toString();
        if (!token.isEmpty()) qputenv("XDG_ACTIVATION_TOKEN", token.toUtf8());
        emit openRequested(message["payload"].toString("{}"), cmd == "toggle");
        return {{"ok", true}};
    }
    if (cmd == "ipc") return invokeIpc(message);
    if (cmd == "screenshot") return screenshot(message["path"].toString());
    if (cmd == "quit") {
        QTimer::singleShot(0, QCoreApplication::instance(), &QCoreApplication::quit);
        return {{"ok", true}};
    }
    return {{"error", "Unknown command: " + cmd}};
}

void DesktopHost::trackWindow(QObject *window) {
    if (auto *quickWindow = qobject_cast<QQuickWindow *>(window)) m_windows.append(quickWindow);
}

void DesktopHost::raiseWindows() {
    for (const auto &window : std::as_const(m_windows)) {
        if (!window || !window->isVisible()) continue;
        if (window->windowStates() & Qt::WindowMinimized) window->showNormal();
        window->raise();
        window->requestActivate();
    }
}

bool DesktopHost::windowActive() const {
    for (const auto &window : m_windows)
        if (window && window->isVisible() && window->isActive()) return true;
    return false;
}

void DesktopHost::setIpcTarget(QObject *handler, const QString &target) {
    for (auto it = m_ipc.begin(); it != m_ipc.end();) {
        if (it.value() == handler) it = m_ipc.erase(it);
        else ++it;
    }
    if (!target.isEmpty()) m_ipc.insert(target, handler);
}

// Calls a function an IpcHandler declares in QML, converting the JSON
// arguments to the types it was declared with.
QJsonObject DesktopHost::invokeIpc(const QJsonObject &message) {
    QObject *handler = m_ipc.value(message["target"].toString());
    if (!handler) return {{"error", "No IPC target " + message["target"].toString()}};
    const QByteArray name = message["function"].toString().toUtf8();
    const QVariantList args = message["args"].toArray().toVariantList();
    const QMetaObject *meta = handler->metaObject();
    for (int i = 0; i < meta->methodCount(); ++i) {
        const QMetaMethod method = meta->method(i);
        if (method.name() != name || method.parameterCount() != args.size()) continue;
        if (args.size() > 10) break;
        std::vector<QVariant> values(args.begin(), args.end());
        QGenericArgument generic[10];
        for (int j = 0; j < int(values.size()); ++j) {
            const QMetaType type = method.parameterMetaType(j);
            if (type != QMetaType::fromType<QVariant>() && !values[j].convert(type))
                return {{"error", QString("Argument %1 of %2 is not a %3").arg(j + 1).arg(name, type.name())}};
            generic[j] = type == QMetaType::fromType<QVariant>()
                             ? QGenericArgument("QVariant", &values[j])
                             : QGenericArgument(type.name(), values[j].constData());
        }
        const QMetaType returnType = method.returnMetaType();
        QVariant result;
        QGenericReturnArgument ret;
        if (returnType == QMetaType::fromType<QVariant>()) ret = QGenericReturnArgument("QVariant", &result);
        else if (returnType.isValid() && returnType.id() != QMetaType::Void) {
            result = QVariant(returnType);
            ret = QGenericReturnArgument(returnType.name(), result.data());
        }
        if (!method.invoke(handler, Qt::DirectConnection, ret, generic[0], generic[1], generic[2], generic[3],
                           generic[4], generic[5], generic[6], generic[7], generic[8], generic[9]))
            return {{"error", "Could not call " + QString::fromUtf8(name)}};
        return {{"ok", true}, {"result", QJsonValue::fromVariant(result)}};
    }
    return {{"error", QString("No IPC function %1 taking %2 arguments").arg(QString::fromUtf8(name)).arg(args.size())}};
}

QJsonObject DesktopHost::screenshot(const QString &path) {
    for (const auto &window : std::as_const(m_windows)) {
        if (!window || !window->isVisible()) continue;
        if (!window->grabWindow().save(path)) return {{"error", "Could not save " + path}};
        return {{"ok", true}};
    }
    return {{"error", "No window is showing"}};
}
