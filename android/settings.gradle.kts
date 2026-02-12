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
    id("com.android.application") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
}

include(":app")

// --- 修正開始：依賴解析管理 ---
dependencyResolutionManagement {
    // 改為 PREFER_SETTINGS，強制所有模組使用這裡定義的倉庫
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        google()
        mavenCentral()
        // 加入 JitPack (為了某些套件如 ffmpeg_kit 或其他依賴)
        maven { url = uri("https://jitpack.io") }
        // 加入 Flutter 的公開倉庫 (解決 io.flutter 找不到的問題)
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
    }
}
// --- 修正結束 ---