package org.logos.qrotest

object NativeBridge {
    /** Runs on the calling thread: constructs QCoreApplication (once) and invokes the QtRO client. */
    @JvmStatic
    external fun runClient(url: String, timeoutMs: Int, jvmMode: String): String

    /** posix_spawn(argv[0], argv, environ) from native code; returns pid or -errno. */
    @JvmStatic
    external fun spawnHelper(argv: Array<String>): Int
}
