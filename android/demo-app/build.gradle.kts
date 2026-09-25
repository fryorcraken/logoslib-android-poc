// :demo-app -- single-Activity demo of :logos-core, plus the M4 acceptance test
// (src/androidTest: connectedDebugAndroidTest on the x86_64 API 34 emulator).
//
// No org.jetbrains.kotlin.android plugin: AGP 9's built-in Kotlin support makes it
// incompatible with the new DSL (kotlin.plugin.compose is separate and still required).
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

val logosAbis: List<String> =
    (findProperty("logos.abis") as String? ?: "x86_64").split(',').map { it.trim() }.filter { it.isNotEmpty() }

android {
    namespace = "com.fryorcraken.logoslib.demo"
    compileSdk = libs.versions.compileSdk.get().toInt()

    defaultConfig {
        applicationId = "com.fryorcraken.logoslib.demo"
        minSdk = libs.versions.minSdk.get().toInt()
        targetSdk = libs.versions.targetSdk.get().toInt()
        versionCode = 1
        versionName = "0.1.0"
        ndk { abiFilters += logosAbis }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    packaging {
        jniLibs {
            // Required: liblogos_host_qt.so is exec'd from nativeLibraryDir, which only
            // exists (extracted) with legacy packaging. Apps targeting SDK 29+ may only
            // exec files from there.
            useLegacyPackaging = true
            keepDebugSymbols += "**/*.so"
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // POC-only: sign release with the debug key so it installs (as in logos-android-wrap-poc).
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
    }

    sourceSets {
        getByName("main") {
            // M5: the node config fixtures (devnet-rc4-gen-args.json, follower-mode.extra.yaml)
            // are read by BlockchainNode from the APK, so the repo's copies stay the only source.
            assets.directories += "../../config/blockchain"
        }
    }
}

dependencies {
    implementation(project(":logos-core"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.material3)

    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.test.runner)
    debugImplementation(libs.androidx.ui.tooling)
    debugImplementation(libs.androidx.ui.test.manifest)
}
