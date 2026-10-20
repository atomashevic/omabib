// omabib-desktop: Omabib's UI as a standalone app.
//
//   omabib-desktop [--toggle] [--add | --query TEXT | --pdf REF_ID] [--background]
//   omabib-desktop ipc FUNCTION [ARG...]
//   omabib-desktop screenshot FILE
//   omabib-desktop --quit
//
// The first launch stays running; later ones hand their request to it.

#include "host.h"

#include <QCommandLineParser>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QIcon>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLocalSocket>
#include <QProcess>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QStandardPaths>
#include <QTimer>
#include <QWindow>
#include <QtQml/qqmlextensionplugin.h>
#include <cstdio>
#include <unistd.h>

Q_IMPORT_QML_PLUGIN(QuickshellPlugin)
Q_IMPORT_QML_PLUGIN(Quickshell_IoPlugin)
Q_IMPORT_QML_PLUGIN(qs_CommonsPlugin)

struct Request {
    QJsonObject message;
    bool background = false;
};

static Request parseRequest(const QStringList &arguments) {
    QCommandLineParser parser;
    parser.setApplicationDescription("Omabib bibliography manager");
    parser.addHelpOption();
    parser.addOptions({
        {"toggle", "Hide the window instead when it already has focus."},
        {"add", "Open the add box."},
        {"query", "Search for TEXT.", "TEXT"},
        {"pdf", "Open a reference's PDF in a reader tab.", "REF_ID"},
        {"background", "Start without showing the window."},
        {"quit", "Stop the running copy."},
    });
    parser.addPositionalArgument("command", "ipc FUNCTION [ARG...] or screenshot FILE", "[command]");
    parser.process(arguments);

    Request request;
    const QStringList positional = parser.positionalArguments();
    if (parser.isSet("quit")) {
        request.message = {{"cmd", "quit"}};
    } else if (positional.value(0) == "ipc" && positional.size() >= 2) {
        QJsonArray args;
        for (const QString &arg : positional.mid(2)) {
            // Numbers and JSON literals pass as themselves; anything else as a string.
            const QJsonDocument doc = QJsonDocument::fromJson("[" + arg.toUtf8() + "]");
            args.append(doc.isArray() && doc.array().size() == 1 ? doc.array().first() : QJsonValue(arg));
        }
        request.message = {{"cmd", "ipc"}, {"target", "omabib"}, {"function", positional.at(1)}, {"args", args}};
    } else if (positional.value(0) == "screenshot" && positional.size() == 2) {
        request.message = {{"cmd", "screenshot"}, {"path", QFileInfo(positional.at(1)).absoluteFilePath()}};
    } else if (!positional.isEmpty()) {
        parser.showHelp(2);
    } else {
        QJsonObject payload;
        if (parser.isSet("add")) payload["action"] = "add";
        if (parser.isSet("query")) payload["query"] = parser.value("query");
        if (parser.isSet("pdf")) payload = {{"action", "pdf"}, {"ref_id", parser.value("pdf")}};
        request.message = {{"cmd", parser.isSet("toggle") ? "toggle" : "open"},
                           {"payload", QString::fromUtf8(QJsonDocument(payload).toJson(QJsonDocument::Compact))},
                           {"activation_token", qEnvironmentVariable("XDG_ACTIVATION_TOKEN")}};
        request.background = parser.isSet("background");
    }
    return request;
}

// Where `omabib serve` listens, as src/transport.rs decides it.
static QString serviceSocket() {
    const QString overridden = qEnvironmentVariable("OMABIB_SOCKET");
    if (!overridden.isEmpty()) return overridden;
    const QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    const QString base = runtime.isEmpty() ? QString("/tmp/omabib-%1").arg(getuid()) : runtime;
    return base + "/omabib/socket";
}

// Starts the library service when nothing answers on its socket, preferring
// an `omabib` installed beside this binary. Any omabib command starts the
// service on demand, detached and logged; the window reconnects once it is up.
static void ensureService(const QString &socket) {
    QLocalSocket probe;
    probe.connectToServer(socket);
    if (probe.waitForConnected(300)) return;
    QString omabib = QCoreApplication::applicationDirPath() + "/omabib";
    if (!QFileInfo(omabib).isExecutable()) omabib = QStandardPaths::findExecutable("omabib");
    if (omabib.isEmpty()) {
        qWarning("The omabib service is not running and the omabib binary was not found");
        return;
    }
    QProcess status;
    status.setProgram(omabib);
    status.setArguments({"status"});
    status.setStandardOutputFile(QProcess::nullDevice());
    status.startDetached();
}

static int forward(const Request &request) {
    const std::optional<QJsonObject> reply = DesktopHost::send(request.message);
    if (!reply) return -1;
    if (reply->contains("error")) {
        fprintf(stderr, "%s\n", qPrintable(reply->value("error").toString()));
        return 1;
    }
    const QJsonValue result = reply->value("result");
    if (result.isObject()) printf("%s\n", QJsonDocument(result.toObject()).toJson(QJsonDocument::Compact).constData());
    else if (result.isArray()) printf("%s\n", QJsonDocument(result.toArray()).toJson(QJsonDocument::Compact).constData());
    else if (!result.isUndefined() && !result.isNull()) printf("%s\n", qPrintable(result.toVariant().toString()));
    return 0;
}

int main(int argc, char *argv[]) {
    Request request;
    {
        QCoreApplication probe(argc, argv);
        probe.setApplicationName("omabib-desktop");
        request = parseRequest(probe.arguments());
        const int forwarded = forward(request);
        if (forwarded >= 0) return forwarded;
        if (request.message["cmd"] != "open" && request.message["cmd"] != "toggle") {
            fprintf(stderr, "Omabib is not running\n");
            return 1;
        }
    }

#if defined(Q_OS_LINUX) || defined(Q_OS_FREEBSD)
    // Omabib draws its own dialogs, so it needs nothing from the GTK platform
    // theme many sessions set, which costs ~70 ms at start. The portal theme
    // still reports the light or dark preference; OMABIB_PLATFORM_THEME picks
    // another. Programs Omabib starts get the session's value back.
    const bool sessionHasTheme = qEnvironmentVariableIsSet("QT_QPA_PLATFORMTHEME");
    const QByteArray sessionTheme = qgetenv("QT_QPA_PLATFORMTHEME");
    qputenv("QT_QPA_PLATFORMTHEME", qEnvironmentVariableIsSet("OMABIB_PLATFORM_THEME")
                                        ? qgetenv("OMABIB_PLATFORM_THEME")
                                        : QByteArray("xdgdesktopportal"));
#endif
    QGuiApplication app(argc, argv);
#if defined(Q_OS_LINUX) || defined(Q_OS_FREEBSD)
    if (sessionHasTheme) qputenv("QT_QPA_PLATFORMTHEME", sessionTheme);
    else qunsetenv("QT_QPA_PLATFORMTHEME");
#endif
    app.setApplicationName("Omabib");
    app.setApplicationDisplayName("Omabib");
    app.setDesktopFileName("omabib");
#ifndef Q_OS_MACOS
    // The Dock already shows the bundle's icon; this one would replace it.
    app.setWindowIcon(QIcon(":/omabib.png"));
#endif
    // Closing the window hides it; the next launch shows it again at once.
    app.setQuitOnLastWindowClosed(false);
    // Fusion takes App.qml's custom controls on every platform; the native
    // macOS and Windows styles refuse them.
    if (qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_STYLE")) QQuickStyle::setStyle("Fusion");

    // The helper scripts and omabib, installed beside this binary, come first.
    const QByteArray appDir = QCoreApplication::applicationDirPath().toUtf8();
    qputenv("PATH", appDir + ":" + qgetenv("PATH"));
#ifdef Q_OS_MACOS
    // An app opened from Finder or the Dock gets a bare PATH, without
    // Homebrew or where agents like claude and codex install. The login
    // shell's PATH is read in the background, for the programs started later.
    auto *loginShell = new QProcess(&app);
    QObject::connect(loginShell, &QProcess::finished, loginShell, [loginShell, appDir] {
        const QString out = QString::fromUtf8(loginShell->readAllStandardOutput());
        const qsizetype at = out.lastIndexOf("OMABIB_PATH=");
        const QString path = at < 0 ? QString() : out.mid(at + 12).section('\n', 0, 0).trimmed();
        if (!path.isEmpty()) qputenv("PATH", appDir + ":" + path.toUtf8());
        loginShell->deleteLater();
    });
    loginShell->start(qEnvironmentVariable("SHELL", "/bin/zsh"), {"-ilc", "printf '\\nOMABIB_PATH=%s\\n' \"$PATH\""});
    QTimer::singleShot(10000, loginShell, [loginShell] { loginShell->kill(); });
#endif

    // App.qml and the helper scripts read the service socket from here.
    const QString socket = serviceSocket();
    qputenv("OMABIB_SOCKET", socket.toUtf8());
    ensureService(socket);

    DesktopHost *host = DesktopHost::instance();
    QString error;
    if (!host->listen(&error)) {
        fprintf(stderr, "Could not listen on %s: %s\n", qPrintable(DesktopHost::socketPath()), qPrintable(error));
        return 1;
    }
    // The compiled-in UI, or a plugin/ folder to work on it without rebuilding.
    const QString uiDir = qEnvironmentVariable("OMABIB_UI_DIR");
    host->setAppUrl(uiDir.isEmpty() ? QUrl("qrc:/ui/App.qml")
                                    : QUrl::fromLocalFile(QDir(uiDir).absoluteFilePath("App.qml")));

    QQmlApplicationEngine engine;
    // The stand-in Quickshell and qs.* modules are compiled in; listing them
    // first keeps an installed Quickshell from being picked instead.
    engine.addImportPath("qrc:/qt/qml");
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); },
                     Qt::QueuedConnection);
    engine.loadFromModule("Omabib.Desktop", "Main");
    if (engine.rootObjects().isEmpty()) return 1;

    if (!request.background) {
        QJsonObject open = request.message;
        open["cmd"] = "open";
        host->handle(open);
    }
#ifdef Q_OS_MACOS
    // Clicking the Dock icon while the window is hidden shows it again.
    QObject::connect(&app, &QGuiApplication::applicationStateChanged, host, [host](Qt::ApplicationState state) {
        if (state != Qt::ApplicationActive) return;
        for (const QWindow *window : QGuiApplication::topLevelWindows())
            if (window->isVisible()) return;
        host->handle({{"cmd", "open"}, {"payload", "{}"}});
    });
#endif
    return app.exec();
}
