plugins {
    id("com.android.application")
}

android {
    namespace = "io.apex.lineagehider"
    compileSdk = 36

    defaultConfig {
        applicationId = "io.apex.lineagehider"
        minSdk = 33
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles("proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources {
            // libxposed module registration: keep META-INF/xposed/*, drop the
            // rest of the bundled META-INF resources (AGP strips these by
            // default, which would silently disable the module).
            merges += "META-INF/xposed/*"
            excludes += "**"
        }
    }
}

dependencies {
    compileOnly("io.github.libxposed:api:102.0.0")
}
