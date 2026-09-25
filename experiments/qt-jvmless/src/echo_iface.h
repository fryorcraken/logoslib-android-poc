// qt-jvmless: trivial plugin interface (stands in for a Logos module plugin).
#pragma once

#include <QObject>
#include <QString>
#include <QtPlugin>

class EchoInterface
{
public:
    virtual ~EchoInterface() = default;
    virtual QString hello() const = 0;
};

#define EchoInterface_iid "org.logos.test.EchoInterface/1.0"
Q_DECLARE_INTERFACE(EchoInterface, EchoInterface_iid)
