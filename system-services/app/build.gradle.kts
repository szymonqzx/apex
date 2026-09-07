plugins {
    id("com.android.application")
}

android {
    namespace = "com.apex.services"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.apex.services"
        minSdk = 33
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        aidl = true
    }
}

dependencies {
    // Hidden API stubs for ServiceManager, TaskOrganizer, etc.
    // These are compile-only; real implementations provided by framework at runtime.
    compileOnly(files("/home/takon/apex/build/stubs/apex-hidden-api-stubs.jar"))
}
