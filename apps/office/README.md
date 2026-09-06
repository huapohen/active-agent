# 人机 · Active Office

One Flutter client for macOS, Windows, iOS, Android and Web. The client uses the same
`active-im/v1` identity, room, document, message and task APIs as an Agent worker.
Credentials remain in process memory; the app contains no model key or administrator token.

## Develop

Use Flutter **3.47.2** / Dart **3.13.2**. The committed lockfile pins Dart packages.
Android uses Gradle 8.14.3, Android Gradle Plugin 8.11.1, Kotlin 2.2.20,
Java 21 and Android SDK 36. The Gradle distribution has an official SHA-256 pin.
Flutter currently warns that this compatible Android tooling combination will
lose support in a future release; upgrade it together after native builds pass.

```sh
cd apps/office
flutter pub get --enforce-lockfile
flutter analyze --fatal-infos
flutter test
flutter run -d macos
```

If a machine-wide Gradle init script injects repositories, Flutter's included build
can reject it with `FAIL_ON_PROJECT_REPOS`. Use a separate `GRADLE_USER_HOME` for
this checkout rather than editing Flutter or deleting the global dependency cache.

Start the service from the repository root with `python scripts/dev_office.py`.
Sign in with an individual human or Agent credential created by that service.
Local defaults are `http://127.0.0.1:3218` for desktop and iOS Simulator,
`http://10.0.2.2:3218` for Android Emulator. Physical devices use a reachable HTTPS
service; `127.0.0.1` on a phone refers to that phone.

Android Debug allows HTTP only for `localhost`, `127.0.0.1` and emulator host
`10.0.2.2`. Release retains a cleartext-deny policy. iOS Debug permits local-network
development through a separate Info-Debug.plist; Release/Profile do not include
that ATS exception. These native settings are defense in depth: application code
must also enforce the service URL policy because Dart sockets do not universally
inherit iOS ATS. The macOS sandbox grants outgoing network access.

## Meetings and attachments

The client includes `flutter_webrtc` 1.6.1 for live meeting media and `file_picker`
12.2.0 for user-selected attachments and downloads. Microphone and camera usage
descriptions are included on Apple platforms; Android declares these permissions
without requiring camera or microphone hardware. Media access still requires the
operating system or browser permission prompt. Web meetings need HTTPS or
localhost, and the service must provide WebRTC signaling and reachable ICE/TURN
configuration for peers on different networks. Windows users can control desktop
camera and microphone access in system privacy settings.

The macOS sandbox permits read/write access only to user-selected files. Android
uses the system document picker, with no blanket storage or photo-library
permission. Attachment credentials remain in client memory and are not embedded
in download URLs or application packages.

Apple's WebRTC Swift package pins the upstream native archive SHA-256. Before a
Windows build, run `python ../../scripts/build_office_webrtc.py` from this directory
to verify and cache the pinned native WebRTC archive; CI runs this automatically.

## Build

| Platform | Command | Output |
| --- | --- | --- |
| macOS | `flutter build macos --release` | `build/macos/Build/Products/Release/Active Office.app` |
| Windows (Windows host) | `flutter build windows --release` | `build/windows/x64/runner/Release/` |
| Android | `flutter build apk --release` | `build/app/outputs/flutter-apk/app-release.apk` |
| Android local development | `flutter build apk --debug` | `build/app/outputs/flutter-apk/app-debug.apk` |
| iOS unsigned (macOS host) | `flutter build ios --release --no-codesign` | `build/ios/iphoneos/Runner.app` |
| iOS Simulator | `flutter build ios --simulator --debug` | `build/ios/iphonesimulator/Runner.app` |
| Web | `flutter build web --release --base-href /office/ --no-web-resources-cdn` | `build/web/` |

Serve the web output at `/office/` on the Doc Free origin so requests use the same
origin. The build packages renderer resources locally. Tokens must never be passed
through `--dart-define`, command-line arguments, URLs or checked-in config.

## Build evidence and distribution

The [Office clients workflow](../../.github/workflows/office-clients.yml) runs native
host builds for all five targets and retains commit-named artifacts. A configured
workflow is not a successful build: check the run and exact commit before claiming
platform validation. Windows cannot be compiled on this macOS development host.

Artifacts are development previews. Android release currently uses the development
signing key and must receive a private release signing configuration before store
distribution. macOS archives are not notarized; iOS archives are unsigned and cannot
be installed on physical devices without signing. No personal Apple team, signing
identity, provisioning profile, keystore or store credential is committed.
