plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.myapp" 
    
    compileSdk = 36 // 👈 修正 1：配合最新套件要求改為 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.example.meeting_recorder"
        minSdk = flutter.minSdkVersion
        targetSdk = 36 // 👈 同步升級為 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 👈 修正 2：明確宣告 debug 簽名設定，防止 R8 解析依賴時崩潰
    signingConfigs {
        getByName("debug") {
            // 保留預設行為
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}