#include <QtQml/qqml.h>
#include <QtQuickTest/quicktest.h>

#include "wheelsender.h"

int main(int argc, char **argv)
{
    qmlRegisterType<WheelSender>("WheelSend", 1, 0, "WheelSender");
    return quick_test_main(argc, argv, "wheel", SOURCE_DIR);
}

#include "wheelsender.moc"
