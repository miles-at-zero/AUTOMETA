plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.autometa.app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications requires core library desugaring.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "dev.autometa.app"
        minSdk = 24
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Stable key so every build installs as an update over the previous one.
        // Default: the committed DEVELOPMENT key (public, like any debug key).
        // For Play Store, set ANDROID_KEYSTORE_PATH / ANDROID_KEYSTORE_PASSWORD
        // (e.g. from GitHub secrets) to sign with a private key instead.
        create("stable") {
            val customPath = System.getenv("ANDROID_KEYSTORE_PATH")
            storeFile = if (customPath.isNullOrBlank()) file("autometa-dev.p12") else file(customPath)
            storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")?.takeIf { it.isNotBlank() } ?: "VBQK-buMV4Ua1scmLu4ETY6No7Piuzb3"
            keyAlias = System.getenv("ANDROID_KEY_ALIAS")?.takeIf { it.isNotBlank() } ?: "autometa"
            keyPassword = storePassword
            storeType = "pkcs12"
        }
    }

    // Two editions. Play Protect blocks sideloaded apps that declare an
    // Accessibility Service, so the default build leaves it out.
    flavorDimensions += "edition"
    productFlavors {
        create("standard") {
            dimension = "edition"
        }
        create("autosend") {
            dimension = "edition"
            versionNameSuffix = "-autosend"
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("stable")
        }
        release {
            signingConfig = signingConfigs.getByName("stable")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
