// AGP 9 built-in Kotlin: no org.jetbrains.kotlin.android plugin applied here
// (same setup as logos-android-wrap-poc/android/demo-app-delivery).
plugins {
    id("com.android.application")
}

val qtJarDir = "${REPO_ROOT}/.work/probe/qt/6.11.1/android_x86_64/jar"

android {
    namespace = "org.logos.qrotest"
    compileSdk = 37

    defaultConfig {
        applicationId = "org.logos.qrotest"
        minSdk = 34
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        ndk { abiFilters += listOf("x86_64") }
    }

    flavorDimensions += "qt"
    productFlavors {
        // Variant A: Qt6Android.jar in the dex; Kotlin loads libQt6Core_x86_64.so
        // explicitly first so the JVM runs QtCore's JNI_OnLoad.
        create("withjar") {
            dimension = "qt"
            applicationIdSuffix = ".a"
            buildConfigField("boolean", "QT_JAR", "true")
            buildConfigField("String", "DEFAULT_JVM_MODE", "\"none\"")
        }
        // Variant B: no Qt jar; QtCore arrives only as a DT_NEEDED of libqrotest_jni.so.
        create("nojar") {
            dimension = "qt"
            applicationIdSuffix = ".b"
            buildConfigField("boolean", "QT_JAR", "false")
            buildConfigField("String", "DEFAULT_JVM_MODE", "\"realvm\"")
        }
    }

    buildFeatures { buildConfig = true }

    packaging {
        jniLibs {
            // Extract .so files to nativeLibraryDir so libqro_server.so can be exec'd.
            useLegacyPackaging = true
            keepDebugSymbols += "**/*.so"
        }
    }

    buildTypes {
        debug { isMinifyEnabled = false }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    "withjarImplementation"(files("$qtJarDir/Qt6Android.jar"))
    "withjarImplementation"("androidx.core:core:1.15.0")
}
