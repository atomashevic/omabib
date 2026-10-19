#include "io.h"

#include "host.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSaveFile>
#include <csignal>

void SplitParser::setSplitMarker(const QString &marker) {
    if (marker == m_marker) return;
    m_marker = marker;
    emit splitMarkerChanged();
}

void SplitParser::feed(const QByteArray &data) {
    m_buffer += data;
    const QByteArray marker = m_marker.toUtf8();
    if (marker.isEmpty()) return;
    qsizetype end;
    while ((end = m_buffer.indexOf(marker)) >= 0) {
        const QByteArray chunk = m_buffer.left(end);
        m_buffer.remove(0, end + marker.size());
        emit read(QString::fromUtf8(chunk));
    }
}

void SplitParser::finish() {
    if (m_buffer.isEmpty()) return;
    const QByteArray rest = std::exchange(m_buffer, {});
    emit read(QString::fromUtf8(rest));
}

Process::~Process() {
    if (!m_process) return;
    m_process->disconnect(this);
    m_process->kill();
    m_process->waitForFinished(1000);
}

void Process::setCommand(const QStringList &command) {
    if (command == m_command) return;
    m_command = command;
    emit commandChanged();
}

void Process::setEnvironment(const QVariantMap &environment) {
    if (environment == m_environment) return;
    m_environment = environment;
    emit environmentChanged();
}

void Process::setWorkingDirectory(const QString &dir) {
    if (dir == m_workingDirectory) return;
    m_workingDirectory = dir;
    emit workingDirectoryChanged();
}

void Process::setRunning(bool running) {
    if (running && !m_process) start();
    else if (!running && m_process) m_process->terminate();
}

void Process::setStdoutParser(DataStreamParser *parser) {
    if (parser == m_stdout) return;
    m_stdout = parser;
    emit stdoutParserChanged();
}

void Process::setStderrParser(DataStreamParser *parser) {
    if (parser == m_stderr) return;
    m_stderr = parser;
    emit stderrParserChanged();
}

void Process::signal(int signal) {
    if (m_process && m_process->processId() > 0) ::kill(pid_t(m_process->processId()), signal);
}

void Process::start() {
    if (m_command.isEmpty()) {
        qWarning("Process started without a command");
        return;
    }
    auto *process = new QProcess(this);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    for (auto it = m_environment.cbegin(); it != m_environment.cend(); ++it) {
        if (it.value().isNull()) env.remove(it.key());
        else env.insert(it.key(), it.value().toString());
    }
    process->setProcessEnvironment(env);
    if (!m_workingDirectory.isEmpty()) process->setWorkingDirectory(m_workingDirectory);
    connect(process, &QProcess::readyReadStandardOutput, this, [this, process] {
        const QByteArray data = process->readAllStandardOutput();
        if (m_stdout) m_stdout->feed(data);
    });
    connect(process, &QProcess::readyReadStandardError, this, [this, process] {
        const QByteArray data = process->readAllStandardError();
        if (m_stderr) m_stderr->feed(data);
    });
    connect(process, &QProcess::started, this, &Process::started);
    connect(process, &QProcess::finished, this, [this](int code, QProcess::ExitStatus status) { finished(code, status); });
    connect(process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) finished(127, QProcess::CrashExit);
    });
    if (m_stdout) m_stdout->reset();
    if (m_stderr) m_stderr->reset();
    m_process = process;
    emit runningChanged();
    process->start(m_command.first(), m_command.mid(1));
}

// `running` is already false when exited() fires, so a handler can start
// the next command right away.
void Process::finished(int exitCode, int exitStatus) {
    QProcess *process = std::exchange(m_process, nullptr);
    if (!process) return;
    if (m_stdout) m_stdout->feed(process->readAllStandardOutput());
    if (m_stderr) m_stderr->feed(process->readAllStandardError());
    process->disconnect(this);
    process->deleteLater();
    if (m_stdout) m_stdout->finish();
    if (m_stderr) m_stderr->finish();
    emit runningChanged();
    emit exited(exitCode, exitStatus);
}

Socket::Socket(QObject *parent) : QObject(parent), m_socket(new QLocalSocket(this)) {
    connect(m_socket, &QLocalSocket::stateChanged, this, [this] {
        const bool now = connected();
        if (now == m_was) return;
        m_was = now;
        if (!now && m_parser) m_parser->reset();
        emit connectedChanged();
    });
    connect(m_socket, &QLocalSocket::readyRead, this, [this] {
        const QByteArray data = m_socket->readAll();
        if (m_parser) m_parser->feed(data);
    });
}

void Socket::setPath(const QString &path) {
    if (path == m_path) return;
    m_path = path;
    emit pathChanged();
}

void Socket::setConnected(bool connected) {
    m_wanted = connected;
    if (!m_complete) return;
    if (connected && m_socket->state() == QLocalSocket::UnconnectedState && !m_path.isEmpty())
        m_socket->connectToServer(m_path);
    else if (!connected && m_socket->state() != QLocalSocket::UnconnectedState)
        m_socket->abort();
}

void Socket::setParser(DataStreamParser *parser) {
    if (parser == m_parser) return;
    m_parser = parser;
    emit parserChanged();
}

void Socket::write(const QString &data) {
    m_socket->write(data.toUtf8());
}

void Socket::flush() {
    m_socket->flush();
}

void Socket::componentComplete() {
    m_complete = true;
    setConnected(m_wanted);
}

void FileView::setPath(const QString &path) {
    if (path == m_path) return;
    m_path = path;
    emit pathChanged();
    if (m_complete) reload();
}

void FileView::setAtomicWrites(bool atomic) {
    if (atomic == m_atomic) return;
    m_atomic = atomic;
    emit atomicWritesChanged();
}

// Loads after the current handler returns, as Quickshell's threaded load does.
void FileView::reload() {
    if (m_path.isEmpty()) return;
    QMetaObject::invokeMethod(this, [this, path = m_path] {
        if (path != m_path) return;
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly)) {
            m_text.clear();
            emit loadFailed(int(file.error()));
            return;
        }
        m_text = QString::fromUtf8(file.readAll());
        emit loaded();
    }, Qt::QueuedConnection);
}

void FileView::setText(const QString &text) {
    m_text = text;
    if (m_path.isEmpty()) return;
    QDir().mkpath(QFileInfo(m_path).absolutePath());
    const QByteArray data = text.toUtf8();
    bool ok;
    if (m_atomic) {
        QSaveFile file(m_path);
        ok = file.open(QIODevice::WriteOnly) && file.write(data) == data.size() && file.commit();
    } else {
        QFile file(m_path);
        ok = file.open(QIODevice::WriteOnly | QIODevice::Truncate) && file.write(data) == data.size();
    }
    if (ok) emit saved();
    else emit saveFailed(1);
}

void FileView::componentComplete() {
    m_complete = true;
    reload();
}

IpcHandler::~IpcHandler() {
    DesktopHost::instance()->setIpcTarget(this, {});
}

void IpcHandler::setTarget(const QString &target) {
    if (target == m_target) return;
    m_target = target;
    emit targetChanged();
    if (m_complete) DesktopHost::instance()->setIpcTarget(this, m_target);
}

void IpcHandler::componentComplete() {
    m_complete = true;
    DesktopHost::instance()->setIpcTarget(this, m_target);
}
