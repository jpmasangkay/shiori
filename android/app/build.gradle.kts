import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.example.manga_reader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.shiori.reader"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            val storeFilePath = keystoreProperties["storeFile"] as String?
            if (storeFilePath != null) {
                storeFile = file(storeFilePath)
            }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = if (keystorePropertiesFile.exists() && keystoreProperties.isNotEmpty()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    applicationVariants.all {
        val variant = this
        outputs.all {
            if (variant.buildType.name == "release") {
                (this as? com.android.build.gradle.api.ApkVariantOutput)?.outputFileName = "shiori.apk"
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("io.reactivex:rxjava:1.3.8")
    implementation("com.squareup.okhttp3:okhttp:5.0.0-alpha.14")
    implementation("com.squareup.okhttp3:logging-interceptor:5.0.0-alpha.14")
    implementation("com.squareup.okhttp3:okhttp-brotli:5.0.0-alpha.14")
    implementation("org.jsoup:jsoup:1.17.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.8.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json-okio:1.8.0")
    implementation("androidx.preference:preference-ktx:1.2.1")
    implementation("uy.kohesive.injekt:injekt-core:1.16.1")
    implementation("com.squareup.zstd:zstd-kmp-okio:0.4.0")
}

flutter {
    source = "../.."
}

tasks.matching { it.name == "assembleRelease" }.configureEach {
    doLast {
        val flutterApkDir = file("${rootProject.projectDir}/../build/app/outputs/flutter-apk")
        val gradleApkDir = file("${layout.buildDirectory.get().asFile}/outputs/apk/release")

        val gradleShiori = file("$gradleApkDir/shiori.apk")
        val gradleRelease = file("$gradleApkDir/app-release.apk")
        if (gradleRelease.exists() && !gradleShiori.exists()) {
            gradleRelease.copyTo(gradleShiori, overwrite = true)
        }

        if (flutterApkDir.exists()) {
            val flutterRelease = file("$flutterApkDir/app-release.apk")
            val flutterShiori = file("$flutterApkDir/shiori.apk")
            if (gradleShiori.exists()) {
                gradleShiori.copyTo(flutterShiori, overwrite = true)
            } else if (flutterRelease.exists()) {
                flutterRelease.copyTo(flutterShiori, overwrite = true)
            }
        }
    }
}
