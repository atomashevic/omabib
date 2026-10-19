qt_add_library(quickshell_io STATIC)
qt_add_qml_module(quickshell_io
    URI Quickshell.Io
    SOURCES io.h io.cpp
)
target_include_directories(quickshell_io PRIVATE ..)
target_link_libraries(quickshell_io PRIVATE Qt6::Network Qt6::Qml quickshell_compat)
