// qt-jvmless: QtRO client logic shared by qro_client (executable) and
// libqrotest_jni.so. Must run on the thread that owns the QCoreApplication.
#pragma once

#include "common.h"

#include <QElapsedTimer>
#include <QMetaObject>
#include <QRemoteObjectDynamicReplica>
#include <QRemoteObjectNode>
#include <QRemoteObjectPendingCall>
#include <QScopedPointer>
#include <QStringList>
#include <QTime>
#include <QUrl>
#include <QVariant>

namespace qjl {

// Returns a one-line summary; details go through out().
inline QString runClientOnce(const QString& url, int timeoutMs)
{
    QElapsedTimer t;
    t.start();
    out(QStringLiteral("client: connecting to %1 at %2").arg(url, QTime::currentTime().toString("hh:mm:ss.zzz")));

    QRemoteObjectNode node;
    const bool accepted = node.connectToNode(QUrl(url));
    out(QStringLiteral("client: connectToNode accepted=%1 lastError=%2").arg(accepted).arg(int(node.lastError())));
    if (!accepted)
        return QStringLiteral("FAIL connectToNode rejected url (lastError=%1)").arg(int(node.lastError()));

    QScopedPointer<QRemoteObjectDynamicReplica> rep(node.acquireDynamic(QStringLiteral("Echo")));
    if (!rep)
        return QStringLiteral("FAIL acquireDynamic returned null");
    const bool ready = rep->waitForSource(timeoutMs);
    out(QStringLiteral("client: waitForSource=%1 state=%2 after %3 ms").arg(ready).arg(int(rep->state())).arg(t.elapsed()));
    if (!ready)
        return QStringLiteral("FAIL replica never became valid within %1 ms (state=%2)").arg(timeoutMs).arg(int(rep->state()));

    QStringList results;

    {
        QRemoteObjectPendingCall call;
        const bool invoked = QMetaObject::invokeMethod(
            rep.data(), "echo", Qt::DirectConnection,
            Q_RETURN_ARG(QRemoteObjectPendingCall, call),
            Q_ARG(QString, QStringLiteral("hello-from-client-pid-%1").arg(int(::getpid()))));
        if (!invoked)
            return QStringLiteral("FAIL invokeMethod(echo) returned false");
        call.waitForFinished(timeoutMs);
        if (!call.isFinished() || call.error() != QRemoteObjectPendingCall::NoError)
            return QStringLiteral("FAIL echo call finished=%1 error=%2").arg(call.isFinished()).arg(int(call.error()));
        const QString r = call.returnValue().toString();
        out(QStringLiteral("client: echo -> %1").arg(r));
        results << r;
    }
    {
        QRemoteObjectPendingCall call;
        const bool invoked = QMetaObject::invokeMethod(
            rep.data(), "callRemoteMethod", Qt::DirectConnection,
            Q_RETURN_ARG(QRemoteObjectPendingCall, call),
            Q_ARG(QString, QStringLiteral("tok")),
            Q_ARG(QString, QStringLiteral("sum")),
            Q_ARG(QVariantList, (QVariantList{1, 2, 39})));
        if (!invoked)
            return QStringLiteral("FAIL invokeMethod(callRemoteMethod) returned false");
        call.waitForFinished(timeoutMs);
        if (!call.isFinished() || call.error() != QRemoteObjectPendingCall::NoError)
            return QStringLiteral("FAIL callRemoteMethod finished=%1 error=%2").arg(call.isFinished()).arg(int(call.error()));
        const QString r = call.returnValue().toString();
        out(QStringLiteral("client: callRemoteMethod(sum,[1,2,39]) -> %1").arg(r));
        results << QStringLiteral("sum=%1").arg(r);
    }

    return QStringLiteral("OK %1 | %2 | %3 ms").arg(results.value(0), results.value(1)).arg(t.elapsed());
}

} // namespace qjl
