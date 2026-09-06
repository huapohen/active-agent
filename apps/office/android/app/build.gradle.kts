plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val productionSigning = System.getenv("OFFICE_ANDROID_PRODUCTION_SIGNING") == "1"
fun signingEnvironment(name: String): String = System.getenv(name)
    ?.takeIf { it.isNotBlank() }
    ?: throw GradleException("Missing production signing environment variable: $name")

android {
    namespace = "com.huapohen.activeOffice"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.huapohen.activeOffice"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (productionSigning) {
            create("production") {
                storeFile = file(signingEnvironment("ANDROID_KEYSTORE_PATH"))
                if (!storeFile!!.isFile) throw GradleException("Production signing keystore is unavailable")
                storePassword = signingEnvironment("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = signingEnvironment("ANDROID_KEY_ALIAS")
                keyPassword = signingEnvironment("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // CI preview builds are explicitly development-signed. The production
            // release script requires a configured release key and fails closed.
            signingConfig = signingConfigs.getByName(if (productionSigning) "production" else "debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
