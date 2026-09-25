// :logos-core -- Kotlin wrapper for liblogos (logos_core_* + lp_* C ABIs).
//
// No native build here: liblogos_jni.so is compiled by scripts/android/build-jni.sh
// and, together with the whole liblogos runtime (Qt, liblogos_core,
// liblogos_host_qt.so, ...), staged by scripts/android/stage.sh into
// src/main/jniLibs/<abi>/ and src/main/modules-staged/<abi>/ (both gitignored); the
// latter is packaged as assets/modules/<abi>/.
// With nothing staged the library still compiles; LogosCore.start() then fails
// with a clear "native runtime not packaged" error.
//
// No org.jetbrains.kotlin.android plugin: AGP 9 has built-in Kotlin support.
plugins {
    alias(libs.plugins.android.library)
}

val logosAbis: List<String> =
    (findProperty("logos.abis") as String? ?: "x86_64").split(',').map { it.trim() }.filter { it.isNotEmpty() }

android {
    namespace = "com.fryorcraken.logoslib.core"
    compileSdk = libs.versions.compileSdk.get().toInt()

    defaultConfig {
        minSdk = libs.versions.minSdk.get().toInt()
        ndk { abiFilters += logosAbis }
        consumerProguardFiles("consumer-rules.pro")
    }

    sourceSets {
        getByName("main") {
            jniLibs.directories += "src/main/jniLibs"
            // stage.sh puts each ABI's module directories in their own asset root
            // (src/main/modules-staged/<abi>/modules/<abi>/...): unlike jniLibs, assets are
            // not filtered by abiFilters, so only the selected ABIs' roots are added.
            assets.directories += logosAbis.map { "src/main/modules-staged/$it" }
        }
    }

    packaging {
        jniLibs {
            // The module host (liblogos_host_qt.so) is an executable that liblogos
            // posix_spawn()s; it must be extracted to nativeLibraryDir to be exec'able.
            useLegacyPackaging = true
            // stage.sh strips (or deliberately keeps symbols); AGP must not need an NDK.
            keepDebugSymbols += "**/*.so"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    // Flow / StateFlow are part of the public API.
    api(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.coroutines.android)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
