plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// FCM push needs android/app/google-services.json (from the Firebase console,
// or written by CI from the GOOGLE_SERVICES_JSON secret). It is git-ignored.
// Without it the APK still builds; the app then reports push as
// "Not configured in this build" and falls back to the in-app alerts poll.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
} else {
    logger.warn("google-services.json not found: building WITHOUT Firebase push (EXTERNAL CONFIG REQUIRED)")
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

    // Two SEPARATE signing configs:
    //  * "dev": the committed development key (android/app/autometa-dev.p12).
    //    Its password is in source on purpose: it is PUBLIC, like a debug key,
    //    and exists only so sideloaded test builds update over each other.
    //    Never use it for Play Store uploads.
    //  * "production": a private key supplied ONLY through the environment
    //    (CI secrets or a local shell): ANDROID_KEYSTORE_PATH,
    //    ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, optional
    //    ANDROID_KEY_PASSWORD (defaults to the store password).
    // Set AUTOMETA_REQUIRE_PRODUCTION_SIGNING=true for store builds: the build
    // then fails instead of silently falling back to the dev key.
    val prodPath = System.getenv("ANDROID_KEYSTORE_PATH")?.takeIf { it.isNotBlank() }
    val requireProd = System.getenv("AUTOMETA_REQUIRE_PRODUCTION_SIGNING") == "true"
    if (requireProd && prodPath == null) {
        throw GradleException("AUTOMETA_REQUIRE_PRODUCTION_SIGNING=true but ANDROID_KEYSTORE_PATH is not set")
    }
    signingConfigs {
        create("dev") {
            storeFile = file("autometa-dev.p12")
            storePassword = "VBQK-buMV4Ua1scmLu4ETY6No7Piuzb3"
            keyAlias = "autometa"
            keyPassword = storePassword
            storeType = "pkcs12"
        }
        if (prodPath != null) {
            create("production") {
                fun need(name: String) = System.getenv(name)?.takeIf { it.isNotBlank() }
                    ?: throw GradleException("$name is required when ANDROID_KEYSTORE_PATH is set")
                storeFile = file(prodPath)
                storePassword = need("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = need("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")?.takeIf { it.isNotBlank() } ?: storePassword
                // Accept both PKCS12 (.p12/.pfx) and legacy JKS keystores.
                if (prodPath.endsWith(".p12") || prodPath.endsWith(".pfx")) storeType = "pkcs12"
            }
        }
    }

    // Single edition. (The former "autosend" edition, which used an
    // Accessibility Service to tap Send in consumer WhatsApp, was removed.)
    flavorDimensions += "edition"
    productFlavors {
        create("standard") {
            dimension = "edition"
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("dev")
        }
        release {
            signingConfig = signingConfigs.getByName(if (prodPath != null) "production" else "dev")
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
