// qt-jvmless: QtRO client executable. usage: qro_client [local:qro_t] [timeoutMs]
#include "client_core.h"

#include <QCoreApplication>

int main(int argc, char** argv)
{
    qjl::tag() = "qro_client";
    qInstallMessageHandler(qjl::qtMessageHandler);
    qjl::out(QStringLiteral("client: start TMPDIR=%1 %2").arg(qjl::envOr("TMPDIR"), qjl::jvmState()));
    qjl::applyJvmMode(qjl::jvmModeFromEnv());
    QCoreApplication app(argc, argv);
    const QString url = argc > 1 ? QString::fromLocal8Bit(argv[1]) : QStringLiteral("local:qro_t");
    const int timeoutMs = argc > 2 ? QString::fromLocal8Bit(argv[2]).toInt() : 10000;
    const QString result = qjl::runClientOnce(url, timeoutMs);
    qjl::out(QStringLiteral("client: RESULT %1").arg(result));
    return result.startsWith(QLatin1String("OK")) ? 0 : 1;
}
