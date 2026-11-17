plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.library)
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
    sourceSets {
        commonTest.dependencies { implementation(kotlin("test")) }
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
