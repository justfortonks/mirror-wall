plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Builds are numbered like the Mac app's: CI passes the repository's commit count.
val buildNumber = (System.getenv("MIRROR_WALL_BUILD") ?: "1").toInt()

// Release builds are signed with the key in these variables (CI reads them from repository
// secrets); without them only the debug build is made.
val keystorePath: String? = System.getenv("ANDROID_KEYSTORE_PATH")

android {
    namespace = "com.justfortonks.mirrorwall.cast"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.justfortonks.mirrorwall.cast"
        minSdk = 29
        targetSdk = 35
        versionCode = buildNumber
        versionName = "0.$buildNumber"
    }

    signingConfigs {
        if (keystorePath != null) {
            create("release") {
                storeFile = file(keystorePath)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (keystorePath != null) signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}
