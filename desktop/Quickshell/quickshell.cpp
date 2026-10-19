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

void QuickshellCompat::execDetached(const QVariant &command) const {
    const QStringList argv = command.toStringList();
    if (argv.isEmpty()) return;
    const QString program = argv.first();
    if (QStandardPaths::findExecutable(program).isEmpty()) {
        if ((program == "omarchy-launch-browser" || program == "xdg-open") && argv.size() == 2) {
            if (!openWithPlatform(argv.at(1))) qWarning("Could not open %s", qPrintable(argv.at(1)));
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
