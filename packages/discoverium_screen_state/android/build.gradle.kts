group = "org.cygnusx1.discoverium.screenstate"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.3.21"

    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.3.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

// AGP 9+ can compile Kotlin itself, but only when the consumer actually enables
// it via the android.builtInKotlin Gradle property (this project sets it to
// false). Checking the AGP version alone would leave Kotlin sources with no
// compiler, and the plugin class would silently fail to build.
val agpMajor = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.substringBefore('.').toInt()
val builtInKotlin = providers.gradleProperty("android.builtInKotlin")
    .map { it.toBoolean() }
    .orElse(agpMajor >= 9)
    .get()

if (agpMajor < 9 || !builtInKotlin) {
    apply(plugin = "org.jetbrains.kotlin.android")
}

project.extensions.configure(org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension::class.java) {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

android {
    namespace = "org.cygnusx1.discoverium.screenstate"
    compileSdk = flutter.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 26
    }

    lint {
        disable.add("InvalidPackage")
    }
}
