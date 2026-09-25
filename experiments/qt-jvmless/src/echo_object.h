// qt-jvmless: the object qro_server publishes over QtRO (mirrors the shape of
// logos-protocol's ModuleProxy: a Q_INVOKABLE callRemoteMethod returning QVariant).
#pragma once

#include <QObject>
#include <QString>
#include <QVariant>
#include <QVariantList>

#include <unistd.h>

class EchoObject : public QObject
{
    Q_OBJECT
public:
    explicit EchoObject(const QString& pluginHello, QObject* parent = nullptr)
        : QObject(parent), m_pluginHello(pluginHello) {}

    Q_INVOKABLE QString echo(const QString& s)
    {
        return QStringLiteral("echo:%1 (server pid %2, plugin says '%3')")
            .arg(s).arg(int(::getpid())).arg(m_pluginHello);
    }

    Q_INVOKABLE QVariant callRemoteMethod(const QString& authToken, const QString& methodName,
                                          const QVariantList& args = QVariantList())
    {
        if (methodName == QLatin1String("sum")) {
            qlonglong total = 0;
            for (const QVariant& v : args) total += v.toLongLong();
            return QVariant::fromValue(total);
        }
        return QStringLiteral("callRemoteMethod token=%1 method=%2 nargs=%3")
            .arg(authToken, methodName).arg(args.size());
    }

private:
    QString m_pluginHello;
};
