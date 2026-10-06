import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名的密钥信息放在 android/key.properties（已被 .gitignore 忽略，不进版本库）。
// 文件不存在时（CI 或别人 clone）自动退回 debug 签名，保证仍能出包。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}

android {
    // 包名（应用唯一标识；如需上架应用商店，建议改为你自己域名的反写，如 com.yourname.xxx）
    namespace = "com.starksky16.formatfactory"
    // 编译 SDK：跟随 Flutter 当前支持的最新版（Android 16 / API 36）
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 包名（与上方 namespace 保持一致）
        applicationId = "com.starksky16.formatfactory"
        // 最低支持 Android 7.0 (API 24)。
        // ⚠️ 不要再调低：转码引擎 ffmpeg_kit_flutter_new 的底层库要求 minSdk >= 24
        minSdk = 24
        // 目标 SDK：跟随 Flutter 当前支持的最新版（Android 16 / API 36），即"最高到最新版"
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 正式签名配置：读取 android/key.properties（storeFile 用正斜杠，避免 Properties 转义）
    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // 有 key.properties 就用正式签名；没有（CI / 别人 clone）退回 debug 签名
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // SAF 文档操作（MainActivity 的存储通道使用）
    implementation("androidx.documentfile:documentfile:1.0.1")
    // JVM 单元测试（用于解密算法本地验证）
    testImplementation("junit:junit:4.13.2")
}
