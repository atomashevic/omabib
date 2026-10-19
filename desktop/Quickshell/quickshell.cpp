#include "quickshell.h"

#include <QClipboard>
#include <QDesktopServices>
#include <QFileInfo>
#include <QGuiApplication>
#include <QProcess>
#include <QStandardPaths>
#include <QUrl>

QuickshellCompat::QuickshellCompat(QObject *parent) : QObject(parent) {
    connect(QGuiApplication::clipboard(), &QClipboard::dataChanged, this, &QuickshellCompat::clipboardTextChanged);
}

QVariant QuickshellCompat::env(const QString &name) const {
    const QByteArray key = name.toLocal8Bit();
    if (!qEnvironmentVariableIsSet(key.constData())) return QVariant::fromValue(nullptr);
    return qEnvironmentVariable(key.constData());
}

static bool openWithPlatform(const QString &target) {
    const QUrl url = QFileInfo(target).isAbsolute() ? QUrl::fromLocalFile(target) : QUrl::fromUserInput(target);
    return QDesktopServices::openUrl(url);
}

// A command in a terminal window where xdg-terminal-exec is missing: Terminal
// on macOS, otherwise the first common terminal installed. Takes
// xdg-terminal-exec's arguments, [--dir=DIR] [--title=TITLE] COMMAND...
static bool runInTerminal(QStringList args) {
    QString dir;
    while (!args.isEmpty() && args.first().startsWith("--")) {
        const QString option = args.takeFirst();
        if (option.startsWith("--dir=")) dir = option.mid(6);
    }
    if (args.isEmpty()) return false;
#ifdef Q_OS_MACOS
    auto quote = [](QString s) { return "'" + s.replace("'", "'\\''") + "'"; };
    QStringList words;
    for (const QString &arg : args) words << quote(arg);
    QString line = words.join(' ');
    if (!dir.isEmpty()) line = "cd " + quote(dir) + " && " + line;
    // Inside an AppleScript string, backslashes and quotes are escaped.
    line.replace("\\", "\\\\").replace("\"", "\\\"");
    return QProcess::startDetached("osascript", {"-e", "tell application \"Terminal\"", "-e", "activate", "-e",
                                                 "do script \"" + line + "\"", "-e", "end tell"});
#else
    // Each with the option that runs the rest of the line as the command.
    static const QList<QStringList> terminals = {
        {"gnome-terminal", "--"}, {"ptyxis", "--"}, {"kgx", "--"}, {"konsole", "-e"}, {"xfce4-terminal", "-x"},
        {"kitty"}, {"alacritty", "-e"}, {"foot"}, {"wezterm", "start", "--"}, {"x-terminal-emulator", "-e"},
        {"xterm", "-e"},
    };
    for (const QStringList &terminal : terminals) {
        if (QStandardPaths::findExecutable(terminal.first()).isEmpty()) continue;
        return QProcess::startDetached(terminal.first(), terminal.mid(1) + args, dir);
    }
    return false;
#endif
}

void QuickshellCompat::execDetached(const QVariant &command) const {
    const QStringList argv = command.toStringList();
    if (argv.isEmpty()) return;
    const QString program = argv.first();
    if (QStandardPaths::findExecutable(program).isEmpty()) {
        if ((program == "omarchy-launch-browser" || program == "xdg-open") && argv.size() == 2) {
            if (!openWithPlatform(argv.at(1))) qWarning("Could not open %s", qPrintable(argv.at(1)));
            return;
        }
        if (program == "xdg-terminal-exec") {
            if (!runInTerminal(argv.mid(1))) qWarning("No terminal found to run %s", qPrintable(argv.mid(1).join(' ')));
            return;
        }
        qWarning("%s is not installed", qPrintable(program));
        return;
    }
    QProcess::startDetached(program, argv.mid(1));
}

QString QuickshellCompat::clipboardText() const {
    return QGuiApplication::clipboard()->text();
}

void QuickshellCompat::setClipboardText(const QString &text) {
    QGuiApplication::clipboard()->setText(text);
}
