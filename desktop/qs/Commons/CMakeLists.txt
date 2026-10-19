set_source_files_properties(Color.qml Style.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
qt_add_library(qs_commons STATIC)
qt_add_qml_module(qs_commons
    URI qs.Commons
    QML_FILES Color.qml Style.qml
)
