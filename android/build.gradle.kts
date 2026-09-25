// Same AGP / Kotlin versions as logos-android-wrap-poc/android (AGP 9.4.0, Kotlin 2.4.20).
// AGP 9 has built-in Kotlin support, so no module applies org.jetbrains.kotlin.android;
// kotlin.plugin.compose is separate and still needed by :demo-app.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.compose) apply false
}
