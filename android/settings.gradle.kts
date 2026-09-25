pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "logoslib-android-poc"

// :logos-core -- Android library: Kotlin API + prebuilt JNI shim + staged liblogos runtime.
// :demo-app   -- single-Activity demo and the M4 instrumented acceptance test.
include(":logos-core")
include(":demo-app")
