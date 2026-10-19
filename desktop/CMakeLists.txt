cmake_minimum_required(VERSION 3.21)
project(omabib-desktop VERSION 0.1.0 LANGUAGES CXX)

# Omabib as an ordinary desktop app: plugin/App.qml in a plain Qt window,
# with stand-ins for the Quickshell and Omarchy shell modules it imports.
find_package(Qt6 6.5 REQUIRED COMPONENTS Gui Network Qml Quick QuickControls2)
qt_standard_project_setup(REQUIRES 6.5)

add_subdirectory(Quickshell)
add_subdirectory(Quickshell/Io)
add_subdirectory(qs/Commons)
add_subdirectory(qs/Ui)

qt_add_executable(omabib-desktop main.cpp)
qt_add_qml_module(omabib-desktop
    URI Omabib.Desktop
    QML_FILES Main.qml
)
# Development builds load the UI straight from the source tree.
target_compile_definitions(omabib-desktop PRIVATE
    OMABIB_UI_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../plugin"
)
target_include_directories(omabib-desktop PRIVATE Quickshell)
target_link_libraries(omabib-desktop PRIVATE
    Qt6::Gui Qt6::Network Qt6::Quick Qt6::QuickControls2 quickshell_compat
    quickshell_compatplugin quickshell_ioplugin qs_commonsplugin qs_uiplugin
)
install(TARGETS omabib-desktop RUNTIME DESTINATION bin)
