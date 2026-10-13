plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Builds are numbered like the Mac app's: CI passes the repository's commit count.
val buildNumber = (System.getenv("MIRROR_WALL_BUILD") ?: "1").toInt()

// Builds are signed with the key in these variables when they're set (CI reads them from
// repository secrets: the company's own key, for Intune / managed Google Play). Otherwise they're
// signed with test-signing.keystore, a test key kept in the repository so each test build installs
// over the last one. It is public, so it proves nothing about who made a build.
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
        create("mirrorWall") {
            if (keystorePath != null) {
                storeFile = file(keystorePath)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            } else {
                storeFile = rootProject.file("test-signing.keystore")
                storePassword = "mirrorwall-test"
                keyAlias = "mirrorwallcast"
                keyPassword = "mirrorwall-test"
            }
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("mirrorWall")
        }
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("mirrorWall")
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
