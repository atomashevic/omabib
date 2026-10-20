cmake_minimum_required(VERSION 3.21)
project(omabib-desktop VERSION 0.1.1 LANGUAGES CXX)

# Omabib as an ordinary desktop app: plugin/App.qml in a plain Qt window,
# with stand-ins for the Quickshell and Omarchy shell modules it imports.
find_package(Qt6 6.5 REQUIRED COMPONENTS Gui Network Qml Quick QuickControls2)
qt_standard_project_setup(REQUIRES 6.5)

add_subdirectory(Quickshell)
add_subdirectory(Quickshell/Io)
add_subdirectory(qs/Commons)

qt_add_executable(omabib-desktop main.cpp)
qt_add_qml_module(omabib-desktop
    URI Omabib.Desktop
    QML_FILES Main.qml
)
# The UI the Omarchy plugin loads from disk, compiled in under qrc:/ui with
# its relative layout kept. OMABIB_UI_DIR loads a folder instead at runtime.
set(ui_dir "${CMAKE_CURRENT_SOURCE_DIR}/../plugin")
file(GLOB ui_relative CONFIGURE_DEPENDS RELATIVE "${ui_dir}"
    "${ui_dir}/App.qml" "${ui_dir}/components/*.qml" "${ui_dir}/components/*.js")
file(GLOB ui_resources_relative CONFIGURE_DEPENDS RELATIVE "${ui_dir}"
    "${ui_dir}/components/shaders/*.qsb" "${ui_dir}/components/fonts/*")
foreach(file IN LISTS ui_relative ui_resources_relative)
    set_source_files_properties("${ui_dir}/${file}" PROPERTIES QT_RESOURCE_ALIAS "${file}")
endforeach()
list(TRANSFORM ui_relative PREPEND "${ui_dir}/" OUTPUT_VARIABLE ui_qml)
list(TRANSFORM ui_resources_relative PREPEND "${ui_dir}/" OUTPUT_VARIABLE ui_resources)
# NO_QMLDIR_TYPES keeps these files out of Omabib.Desktop's types: App.qml
# reaches them through its relative `import "components"`, and listed as
# module types they would be looked for under the module's own prefix. It
# also turns off the extra qmldir files QTP0004 adds, so OLD and NEW build
# the same resources; NEW only avoids the deprecation warning.
qt_policy(SET QTP0004 NEW)
qt_target_qml_sources(omabib-desktop
    PREFIX /ui
    NO_QMLDIR_TYPES
    QML_FILES ${ui_qml}
    RESOURCES ${ui_resources}
)
# The window icon, for X11 taskbars and window switchers. Wayland compositors
# and the macOS Dock take it from the launcher entry and the bundle instead.
qt_add_resources(omabib-desktop "omabib_icon"
    PREFIX "/"
    BASE "${CMAKE_CURRENT_SOURCE_DIR}/../packaging/icons/hicolor/256x256/apps"
    FILES "${CMAKE_CURRENT_SOURCE_DIR}/../packaging/icons/hicolor/256x256/apps/omabib.png"
)
target_include_directories(omabib-desktop PRIVATE Quickshell)
target_link_libraries(omabib-desktop PRIVATE
    Qt6::Gui Qt6::Network Qt6::Quick Qt6::QuickControls2 quickshell_compat
    quickshell_compatplugin quickshell_ioplugin qs_commonsplugin
)
if(APPLE)
    # omabib-desktop.app; scripts/bundle-macos-app names it Omabib.app and
    # adds omabib, the helpers, the icon and Qt.
    set_target_properties(omabib-desktop PROPERTIES
        MACOSX_BUNDLE TRUE
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/../packaging/macos/Info.plist.in"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
        MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
    )
endif()
install(TARGETS omabib-desktop RUNTIME DESTINATION bin BUNDLE DESTINATION .)
