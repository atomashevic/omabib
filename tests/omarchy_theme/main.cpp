#include <QtQuickTest>
#include <QtQml/qqmlextensionplugin.h>

// The desktop modules are static libraries, so qmltestrunner cannot load them.
// This is the same Quick Test runner, linked to those modules.
Q_IMPORT_QML_PLUGIN(QuickshellPlugin)
Q_IMPORT_QML_PLUGIN(Quickshell_IoPlugin)
Q_IMPORT_QML_PLUGIN(qs_CommonsPlugin)

QUICK_TEST_MAIN(omarchytheme)
