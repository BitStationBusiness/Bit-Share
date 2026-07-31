import java.io.FileInputStream
import java.util.Properties

val releaseProperties = Properties()
val releasePropertiesFile = rootProject.file("key.properties")
if (releasePropertiesFile.exists()) {
    FileInputStream(releasePropertiesFile).use { releaseProperties.load(it) }
}

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("com.chaquo.python")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.bitstation.bitshare"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.bitstation.bitshare"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    signingConfigs {
        create("release") {
            val storeFilePath = releaseProperties.getProperty("storeFile")
                ?: throw GradleException("Falta android/key.properties para firmar el release.")
            storeFile = file(storeFilePath)
            keyAlias = releaseProperties.getProperty("keyAlias")
                ?: throw GradleException("Falta keyAlias en android/key.properties.")
            storePassword = System.getenv("BITSHARE_STORE_PASSWORD")
                ?: throw GradleException("Falta BITSHARE_STORE_PASSWORD para firmar el release.")
            keyPassword = System.getenv("BITSHARE_KEY_PASSWORD")
                ?: throw GradleException("Falta BITSHARE_KEY_PASSWORD para firmar el release.")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            keepDebugSymbols += "**/libpython.zip.so"
            keepDebugSymbols += "**/libffmpeg.zip.so"
            excludes += setOf(
                "**/armeabi-v7a/**",
                "**/x86/**",
                "**/x86_64/**",
            )
        }
    }
}

dependencies {
    val youtubeDlAndroid = "0.18.1"

    implementation("io.github.junkfood02.youtubedl-android:library:$youtubeDlAndroid")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:$youtubeDlAndroid")
    testImplementation("junit:junit:4.13.2")
}

chaquopy {
    defaultConfig {
        version = "3.13"
        buildPython("C:/Users/BitSt/.local/bin/python3.13.exe")
        pip {
            options("--no-deps")
            install("yt-dlp==2026.7.4")
            install("curl-cffi==0.15.0")
            install("cffi==1.17.1")
            install("chaquopy-libffi==3.3")
            install("pycparser==2.22")
            install("certifi==2026.7.22")
        }
    }
}

flutter {
    source = "../.."
}
