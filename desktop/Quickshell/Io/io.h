#pragma once

#include <QByteArray>
#include <QLocalSocket>
#include <QObject>
#include <QPointer>
#include <QProcess>
#include <QQmlParserStatus>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

// Quickshell.Io as App.qml uses it, on QProcess, QLocalSocket and QSaveFile.

class DataStreamParser : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Use SplitParser or StdioCollector")

public:
    using QObject::QObject;
    virtual void feed(const QByteArray &data) = 0;
    // The stream ended.
    virtual void finish() = 0;
    // Drops buffered data, as when a socket reconnects.
    virtual void reset() = 0;
};

// Emits read() once per marker-terminated chunk.
class SplitParser : public DataStreamParser {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString splitMarker READ splitMarker WRITE setSplitMarker NOTIFY splitMarkerChanged)

public:
    using DataStreamParser::DataStreamParser;
    QString splitMarker() const { return m_marker; }
    void setSplitMarker(const QString &marker);
    void feed(const QByteArray &data) override;
    void finish() override;
    void reset() override { m_buffer.clear(); }

signals:
    void read(const QString &data);
    void splitMarkerChanged();

private:
    QString m_marker = "\n";
    QByteArray m_buffer;
};

// Keeps the whole stream and offers it as `text` when it ends.
class StdioCollector : public DataStreamParser {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString text READ text NOTIFY streamFinished)

public:
    using DataStreamParser::DataStreamParser;
    QString text() const { return QString::fromUtf8(m_data); }
    void feed(const QByteArray &data) override { m_data += data; }
    void finish() override { emit streamFinished(); }
    void reset() override { m_data.clear(); }

signals:
    void streamFinished();

private:
    QByteArray m_data;
};

class Process : public QObject {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QStringList command READ command WRITE setCommand NOTIFY commandChanged)
    // Merged over the inherited environment; a null value unsets a variable.
    Q_PROPERTY(QVariantMap environment READ environment WRITE setEnvironment NOTIFY environmentChanged)
    Q_PROPERTY(QString workingDirectory READ workingDirectory WRITE setWorkingDirectory NOTIFY workingDirectoryChanged)
    Q_PROPERTY(bool running READ running WRITE setRunning NOTIFY runningChanged)
    Q_PROPERTY(DataStreamParser *stdout READ stdoutParser WRITE setStdoutParser NOTIFY stdoutParserChanged)
    Q_PROPERTY(DataStreamParser *stderr READ stderrParser WRITE setStderrParser NOTIFY stderrParserChanged)

public:
    using QObject::QObject;
    ~Process() override;

    QStringList command() const { return m_command; }
    void setCommand(const QStringList &command);
    QVariantMap environment() const { return m_environment; }
    void setEnvironment(const QVariantMap &environment);
    QString workingDirectory() const { return m_workingDirectory; }
    void setWorkingDirectory(const QString &dir);
    bool running() const { return m_process != nullptr; }
    void setRunning(bool running);
    DataStreamParser *stdoutParser() const { return m_stdout; }
    void setStdoutParser(DataStreamParser *parser);
    DataStreamParser *stderrParser() const { return m_stderr; }
    void setStderrParser(DataStreamParser *parser);

    Q_INVOKABLE void signal(int signal);

signals:
    void started();
    void exited(int exitCode, int exitStatus);
    void commandChanged();
    void environmentChanged();
    void workingDirectoryChanged();
    void runningChanged();
    void stdoutParserChanged();
    void stderrParserChanged();

private:
    void start();
    void finished(int exitCode, int exitStatus);

    QStringList m_command;
    QVariantMap m_environment;
    QString m_workingDirectory;
    QProcess *m_process = nullptr;
    QPointer<DataStreamParser> m_stdout;
    QPointer<DataStreamParser> m_stderr;
};

// A line-oriented client for a Unix socket. `connected` follows the actual
// connection; setting it true starts connecting.
class Socket : public QObject, public QQmlParserStatus {
    Q_OBJECT
    QML_ELEMENT
    Q_INTERFACES(QQmlParserStatus)
    Q_PROPERTY(QString path READ path WRITE setPath NOTIFY pathChanged)
    Q_PROPERTY(bool connected READ connected WRITE setConnected NOTIFY connectedChanged)
    Q_PROPERTY(DataStreamParser *parser READ parser WRITE setParser NOTIFY parserChanged)

public:
    explicit Socket(QObject *parent = nullptr);

    QString path() const { return m_path; }
    void setPath(const QString &path);
    bool connected() const { return m_socket->state() == QLocalSocket::ConnectedState; }
    void setConnected(bool connected);
    DataStreamParser *parser() const { return m_parser; }
    void setParser(DataStreamParser *parser);

    Q_INVOKABLE void write(const QString &data);
    Q_INVOKABLE void flush();

    void classBegin() override {}
    void componentComplete() override;

signals:
    void pathChanged();
    void connectedChanged();
    void parserChanged();

private:
    QLocalSocket *m_socket;
    QString m_path;
    QPointer<DataStreamParser> m_parser;
    bool m_complete = false;
    bool m_wanted = false;
    bool m_was = false;
};

// A text file loaded when its path is set, written with setText.
class FileView : public QObject, public QQmlParserStatus {
    Q_OBJECT
    QML_ELEMENT
    Q_INTERFACES(QQmlParserStatus)
    Q_PROPERTY(QString path READ path WRITE setPath NOTIFY pathChanged)
    Q_PROPERTY(bool atomicWrites READ atomicWrites WRITE setAtomicWrites NOTIFY atomicWritesChanged)
    // Reloads when the file changes, including when its directory is replaced.
    Q_PROPERTY(bool watch READ watch WRITE setWatch NOTIFY watchChanged)

public:
    using QObject::QObject;

    QString path() const { return m_path; }
    void setPath(const QString &path);
    bool atomicWrites() const { return m_atomic; }
    void setAtomicWrites(bool atomic);
    bool watch() const { return m_watch; }
    void setWatch(bool watch);

    Q_INVOKABLE QString text() const { return m_text; }
    Q_INVOKABLE void setText(const QString &text);
    Q_INVOKABLE void reload();

    void classBegin() override {}
    void componentComplete() override;

signals:
    void loaded();
    void loadFailed(int error);
    void saved();
    void saveFailed(int error);
    void pathChanged();
    void atomicWritesChanged();
    void watchChanged();

private:
    void armWatch();
    void scheduleWatch();

    QString m_path;
    QString m_text;
    bool m_atomic = true;
    bool m_complete = false;
    bool m_watch = false;
    class QFileSystemWatcher *m_watcher = nullptr;
    class QTimer *m_watchTimer = nullptr;
};

// Exposes the functions declared on it in QML to `omabib-desktop ipc`.
class IpcHandler : public QObject, public QQmlParserStatus {
    Q_OBJECT
    QML_ELEMENT
    Q_INTERFACES(QQmlParserStatus)
    Q_PROPERTY(QString target READ target WRITE setTarget NOTIFY targetChanged)

public:
    using QObject::QObject;
    ~IpcHandler() override;

    QString target() const { return m_target; }
    void setTarget(const QString &target);

    void classBegin() override {}
    void componentComplete() override;

signals:
    void targetChanged();

private:
    QString m_target;
    bool m_complete = false;
};
