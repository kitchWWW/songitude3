import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

fun props(name: String) = Properties().apply {
    val f = rootProject.file(name)
    if (f.exists()) f.inputStream().use { load(it) }
}

// The Maps key is a per-machine secret: it lives in local.properties (git-ignored), never the repo.
val mapsKey: String = props("local.properties").getProperty("MAPS_API_KEY") ?: ""

// The Play upload key. keystore.properties is git-ignored and points at a .jks outside the repo;
// when it is absent (a fresh clone, CI) the release build still assembles, just unsigned.
val keystore = props("keystore.properties")

android {
    namespace = "com.brianellissound.songitude"
    compileSdk = 36

    defaultConfig {
        // The Kotlin package stays com.brianellissound.songitude — see SYNC.md — only the id differs.
        applicationId = "com.brianellissound.chromic"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
        manifestPlaceholders["MAPS_API_KEY"] = mapsKey
    }

    signingConfigs {
        if (keystore.getProperty("storeFile") != null) {
            create("release") {
                storeFile = file(keystore.getProperty("storeFile"))
                storePassword = keystore.getProperty("storePassword")
                keyAlias = keystore.getProperty("keyAlias")
                keyPassword = keystore.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true; buildConfig = true }
    packaging { resources { excludes += "/META-INF/{AL2.0,LGPL2.1}" } }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.material3)
    implementation(libs.androidx.material.icons.extended)
    implementation(libs.androidx.media)
    implementation(libs.maps.compose)
    implementation(libs.play.services.maps)
    implementation(libs.play.services.location)
    implementation(libs.coil.compose)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)
    debugImplementation(libs.androidx.ui.tooling)
}

// The baked-in catalog/bio/artwork snapshot (assets/seed), refreshed before every build so a
// release can never ship a stale one. The script is shared with the iOS fork; offline it warns
// and keeps the last seed rather than failing the build.
val refreshSeed by tasks.registering(Exec::class) {
    description = "Refresh the Chromic content seed for both apps"
    commandLine("python3", rootProject.file("../ios-chromic/tools/refresh_seed.py").absolutePath)
    isIgnoreExitValue = true
}
tasks.named("preBuild") { dependsOn(refreshSeed) }
