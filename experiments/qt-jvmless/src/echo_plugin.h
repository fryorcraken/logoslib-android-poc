// qt-jvmless: trivial Qt plugin loaded by qro_server via QPluginLoader.
#pragma once

#include "echo_iface.h"

class EchoPlugin : public QObject, public EchoInterface
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID EchoInterface_iid FILE "echo_plugin.json")
    Q_INTERFACES(EchoInterface)

public:
    QString hello() const override { return QStringLiteral("hello from echoplugin"); }
};
