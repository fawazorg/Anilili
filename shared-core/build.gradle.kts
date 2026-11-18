plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    androidTarget {
        compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
    jvm {
        compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
    iosX64 {
        binaries.framework {
            baseName = "SharedCore"
            isStatic = true
        }
        testRuns["test"].deviceId = providers.gradleProperty("iosSimulatorDeviceId")
            .getOrElse("iPhone 16")
    }
    iosArm64 {
        binaries.framework {
            baseName = "SharedCore"
            isStatic = true
        }
    }
    sourceSets {
        commonMain.dependencies {
            api(libs.kotlinx.serialization.json)
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.1")
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")
        }
    }
}

android {
    namespace = "com.anilili.shared.core"
    compileSdk = 36
    defaultConfig { minSdk = 22 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
