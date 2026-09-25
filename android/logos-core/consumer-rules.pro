# liblogos_jni.so resolves these by name (Java_* entry points and the static
# callbacks it looks up in JNI_OnLoad), so R8 must neither rename nor strip them.
-keep class com.fryorcraken.logoslib.core.internal.LogosNative { *; }
