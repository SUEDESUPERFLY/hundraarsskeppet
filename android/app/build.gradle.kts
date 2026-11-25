// Livet på Hundraårsskeppet – Android-appen. Appen visar spelet från GitHub Pages i en helskärms-WebView,
// så nya versioner av spelet kommer automatiskt utan att appen behöver uppdateras i Google Play.
plugins {
    id("com.android.application")
}

val keystorePath: String? = System.getenv("UPLOAD_KEYSTORE")

android {
    namespace = "io.github.suedesuperfly.hundraarsskeppet"
    compileSdk = 36

    defaultConfig {
        applicationId = "io.github.suedesuperfly.hundraarsskeppet"
        minSdk = 24
        targetSdk = 36
        versionCode = (System.getenv("VERSION_CODE") ?: "1").toInt()
        versionName = System.getenv("VERSION_NAME") ?: "1.0"
    }

    signingConfigs {
        create("upload") {
            if (keystorePath != null) {
                storeFile = file(keystorePath)
                storePassword = System.getenv("UPLOAD_STORE_PASSWORD")
                keyAlias = System.getenv("UPLOAD_KEY_ALIAS")
                keyPassword = System.getenv("UPLOAD_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (keystorePath != null) signingConfig = signingConfigs.getByName("upload")
        }
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("androidx.core:core:1.13.1")
}
