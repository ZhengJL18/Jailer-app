pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // AGP 9 移除了 getDefaultProguardFile('proguard-android.txt')，
    // flutter_inappwebview_android 仍调用它 → 降到 8.9.x（保留该 API + 兼容）。
    id("com.android.application") version "8.9.2" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
