// qt-jvmless: stand-in for logos_host_qt. QCoreApplication + QPluginLoader +
// QRemoteObjectRegistryHost on a local: socket, in a native executable with no JavaVM.
//
// usage: qro_server [--url=local:qro_t] [--plugin=/abs/libechoplugin.so]
//                   [--exit-after-ms=N] [--probe=NAME]
#include "common.h"
#include "echo_iface.h"
#include "echo_object.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJniObject>
#include <QLocale>
#include <QtCore/qcoreapplication_platform.h>
#include <QPluginLoader>
#include <QRemoteObjectRegistryHost>
#include <QSocketNotifier>
#include <QStandardPaths>
#include <QSysInfo>
#include <QTime>
#include <QTimeZone>
#include <QTimer>
#include <QUrl>

#include <cerrno>
#include <csignal>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>

namespace {

int s_sigPipe[2] = {-1, -1};

extern "C" void onTerm(int)
{
    const int saved = errno;
    const char b = 1;
    ssize_t rc = ::write(s_sigPipe[1], &b, 1);
    (void)rc;
    errno = saved;
}

// Same self-pipe pattern as logos-module-loader-qt/src/host/qt/qt_app.cpp.
void installSignalHandlers(QCoreApplication* app)
{
    if (::pipe(s_sigPipe) != 0) return;
    for (int fd : s_sigPipe) {
        ::fcntl(fd, F_SETFD, ::fcntl(fd, F_GETFD) | FD_CLOEXEC);
        ::fcntl(fd, F_SETFL, ::fcntl(fd, F_GETFL) | O_NONBLOCK);
    }
    auto* n = new QSocketNotifier(s_sigPipe[0], QSocketNotifier::Read, app);
    QObject::connect(n, &QSocketNotifier::activated, app, []() {
        char buf[16];
        while (::read(s_sigPipe[0], buf, sizeof(buf)) > 0) {}
        qjl::out(QStringLiteral("server: SIGTERM/SIGINT -> quit"));
        QCoreApplication::quit();
    });
    struct sigaction sa {};
    sa.sa_handler = &onTerm;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    ::sigaction(SIGTERM, &sa, nullptr);
    ::sigaction(SIGINT, &sa, nullptr);
}

QString argValue(int argc, char** argv, const char* key, const QString& def)
{
    const QByteArray k = QByteArray(key) + '=';
    for (int i = 1; i < argc; ++i)
        if (std::strncmp(argv[i], k.constData(), size_t(k.size())) == 0)
            return QString::fromLocal8Bit(argv[i] + k.size());
    return def;
}

// Qt Core APIs that are JNI-backed on Android (or suspected to be). Each runs in
// its own process invocation so a crash identifies exactly one API.
int runProbe(const QString& probe)
{
    qjl::out(QStringLiteral("probe %1: start").arg(probe));
    if (probe == QLatin1String("stdpaths")) {
        qjl::out(QStringLiteral("probe stdpaths: TempLocation=%1").arg(QStandardPaths::writableLocation(QStandardPaths::TempLocation)));
        qjl::out(QStringLiteral("probe stdpaths: CacheLocation=%1").arg(QStandardPaths::writableLocation(QStandardPaths::CacheLocation)));
        qjl::out(QStringLiteral("probe stdpaths: AppDataLocation=%1").arg(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)));
        qjl::out(QStringLiteral("probe stdpaths: HomeLocation=%1").arg(QStandardPaths::writableLocation(QStandardPaths::HomeLocation)));
    } else if (probe == QLatin1String("timezone")) {
        qjl::out(QStringLiteral("probe timezone: currentDateTime=%1").arg(QDateTime::currentDateTime().toString(Qt::ISODate)));
        qjl::out(QStringLiteral("probe timezone: systemTimeZoneId=%1").arg(QString::fromUtf8(QTimeZone::systemTimeZoneId())));
        qjl::out(QStringLiteral("probe timezone: systemTimeZone valid=%1").arg(QTimeZone::systemTimeZone().isValid()));
        qjl::out(QStringLiteral("probe timezone: Europe/Paris valid=%1").arg(QTimeZone("Europe/Paris").isValid()));
    } else if (probe == QLatin1String("locale")) {
        qjl::out(QStringLiteral("probe locale: system=%1").arg(QLocale::system().name()));
        qjl::out(QStringLiteral("probe locale: toString(1234.5)=%1").arg(QLocale::system().toString(1234.5)));
    } else if (probe == QLatin1String("sysinfo")) {
        qjl::out(QStringLiteral("probe sysinfo: productType=%1 version=%2").arg(QSysInfo::productType(), QSysInfo::productVersion()));
        qjl::out(QStringLiteral("probe sysinfo: pretty=%1").arg(QSysInfo::prettyProductName()));
        qjl::out(QStringLiteral("probe sysinfo: host=%1").arg(QSysInfo::machineHostName()));
    } else if (probe == QLatin1String("androidctx")) {
        qjl::out(QStringLiteral("probe androidctx: sdkVersion=%1").arg(QNativeInterface::QAndroidApplication::sdkVersion()));
        qjl::out(QStringLiteral("probe androidctx: context valid=%1").arg(QJniObject(QNativeInterface::QAndroidApplication::context()).isValid()));
        qjl::out(QStringLiteral("probe androidctx: applicationVersion='%1'").arg(QCoreApplication::applicationVersion()));
    } else {
        qjl::out(QStringLiteral("probe %1: unknown").arg(probe));
        return 2;
    }
    qjl::out(QStringLiteral("probe %1: DONE (no crash)").arg(probe));
    return 0;
}

} // namespace

int main(int argc, char** argv)
{
    qjl::tag() = "qro_server";
    qInstallMessageHandler(qjl::qtMessageHandler);
    qjl::out(QStringLiteral("server: start ppid=%1 uid=%2 exe-arg0=%3").arg(int(::getppid())).arg(int(::getuid())).arg(QString::fromLocal8Bit(argv[0])));
    qjl::out(QStringLiteral("server: env TMPDIR=%1 LD_LIBRARY_PATH=%2 HOME=%3").arg(qjl::envOr("TMPDIR"), qjl::envOr("LD_LIBRARY_PATH"), qjl::envOr("HOME")));
    qjl::out(QStringLiteral("server: %1").arg(qjl::jvmState()));
    qjl::applyJvmMode(argValue(argc, argv, "--jvm-mode", qjl::jvmModeFromEnv()));

    QCoreApplication app(argc, argv);
    qjl::out(QStringLiteral("server: QCoreApplication constructed, Qt %1").arg(QString::fromLatin1(qVersion())));
    qjl::out(QStringLiteral("server: applicationFilePath=%1").arg(QCoreApplication::applicationFilePath()));
    qjl::out(QStringLiteral("server: applicationDirPath=%1").arg(QCoreApplication::applicationDirPath()));
    qjl::out(QStringLiteral("server: QDir::tempPath=%1").arg(QDir::tempPath()));
    qjl::out(QStringLiteral("server: libraryPaths=%1").arg(QCoreApplication::libraryPaths().join(QLatin1Char(':'))));
    qjl::out(QStringLiteral("server: QTime::currentTime=%1").arg(QTime::currentTime().toString("hh:mm:ss.zzz")));

    const QString probe = argValue(argc, argv, "--probe", QString());
    if (!probe.isEmpty())
        return runProbe(probe);

    installSignalHandlers(&app);

    // --- QPluginLoader ---
    const QString pluginPath = argValue(argc, argv, "--plugin",
        QCoreApplication::applicationDirPath() + QStringLiteral("/libechoplugin.so"));
    QPluginLoader loader;
    loader.setFileName(pluginPath);
    const QJsonObject md = loader.metaData();
    qjl::out(QStringLiteral("server: QPluginLoader file=%1 IID=%2 MetaData=%3")
        .arg(loader.fileName(), md.value(QStringLiteral("IID")).toString(),
             QString::fromUtf8(QJsonDocument(md.value(QStringLiteral("MetaData")).toObject()).toJson(QJsonDocument::Compact))));
    QString pluginHello = QStringLiteral("<no plugin>");
    QObject* inst = loader.instance();
    if (!inst) {
        qjl::out(QStringLiteral("server: PLUGIN FAIL instance()=null error=%1").arg(loader.errorString()));
    } else if (auto* e = qobject_cast<EchoInterface*>(inst)) {
        pluginHello = e->hello();
        qjl::out(QStringLiteral("server: PLUGIN OK instance=%1 hello()=%2").arg(QString::fromLatin1(inst->metaObject()->className()), pluginHello));
    } else {
        qjl::out(QStringLiteral("server: PLUGIN FAIL qobject_cast<EchoInterface*> failed"));
    }

    // --- QtRO registry host, as logos-protocol RemoteTransportHost::publishObject does ---
    const QString url = argValue(argc, argv, "--url", QStringLiteral("local:qro_t"));
    QRemoteObjectRegistryHost host;
    const bool listening = host.setRegistryUrl(QUrl(url));
    const QString sockFile = QDir::tempPath() + QLatin1Char('/') + QUrl(url).path();
    qjl::out(QStringLiteral("server: setRegistryUrl(%1)=%2 lastError=%3 socket=%4 exists=%5")
        .arg(url).arg(listening).arg(int(host.lastError())).arg(sockFile).arg(QFileInfo::exists(sockFile)));
    if (!listening) {
        qjl::out(QStringLiteral("server: QTRO FAIL could not listen"));
        return 3;
    }
    EchoObject obj(pluginHello);
    const bool enabled = host.enableRemoting(&obj, QStringLiteral("Echo"));
    qjl::out(QStringLiteral("server: enableRemoting(Echo)=%1").arg(enabled));
    if (!enabled) return 4;

    const int exitAfter = argValue(argc, argv, "--exit-after-ms", QStringLiteral("0")).toInt();
    if (exitAfter > 0) {
        QTimer::singleShot(exitAfter, &app, []() {
            qjl::out(QStringLiteral("server: exit-after timer fired -> quit"));
            QCoreApplication::quit();
        });
    }
    qjl::out(QStringLiteral("server: READY"));
    const int rc = app.exec();
    qjl::out(QStringLiteral("server: exec() returned %1; socket exists after=%2").arg(rc).arg(QFileInfo::exists(sockFile)));
    return rc;
}
