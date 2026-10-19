#pragma once

#include <QObject>
#include <QVariant>
#include <QtQml/qqmlregistration.h>

// The `Quickshell` singleton's members that App.qml uses: env, execDetached
// and clipboardText.
class QuickshellCompat : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(Quickshell)
    QML_SINGLETON
    Q_PROPERTY(QString clipboardText READ clipboardText WRITE setClipboardText NOTIFY clipboardTextChanged)

public:
    explicit QuickshellCompat(QObject *parent = nullptr);

    // The variable's value, or null when it is unset.
    Q_INVOKABLE QVariant env(const QString &name) const;
    // Starts a command without waiting for it. Omarchy's own helpers are
    // replaced by the platform's opener where they are not installed.
    Q_INVOKABLE void execDetached(const QVariant &command) const;

    QString clipboardText() const;
    void setClipboardText(const QString &text);

signals:
    void clipboardTextChanged();
};
