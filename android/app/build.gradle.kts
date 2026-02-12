plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    // 關鍵修改 1：namespace 必須對應您的 Kotlin 檔案資料夾結構
    // 您的 MainActivity 位於 com/example/myapp/MainActivity.kt，所以這裡必須是 myapp
    namespace = "com.example.myapp" 
    
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // 關鍵修改 2：applicationId 是您希望 App 在手機/商店顯示的真實 ID
        // 根據您之前的 Manifest 設定，這裡應該是 meeting_recorder
        applicationId = "com.example.meeting_recorder"
        
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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