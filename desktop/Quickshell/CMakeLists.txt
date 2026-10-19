qt_add_library(quickshell_compat STATIC)
qt_add_qml_module(quickshell_compat
    URI Quickshell
    SOURCES quickshell.h quickshell.cpp host.h host.cpp
    QML_FILES FloatingWindow.qml
)
target_link_libraries(quickshell_compat PRIVATE Qt6::Gui Qt6::Network Qt6::Quick)
