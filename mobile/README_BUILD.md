# WineFlow Mobile (Flutter) — building the real APK

This folder is a **buildable Flutter foundation** for the field app. It contains
the app code (`lib/`) and dependencies (`pubspec.yaml`). The Android/iOS platform
folders are generated at build time so the project stays lean.

## Option A — Build the APK in the cloud (no toolchain needed) ✅ recommended
1. Create a **free GitHub account** and a new repository, e.g. `wineflow-mobile`.
2. Upload the contents of this `mobile/` folder to that repo (including the
   `.github/workflows/build-apk.yml` file).
3. GitHub Actions runs automatically and **compiles `WineFlow.apk`**.
4. Open the run → **Artifacts** → download **WineFlow-apk**. That is your real,
   installable APK.

This is the honest way to get a genuine signed-debug APK without installing
Android Studio. The workflow scaffolds the Android project, injects the required
permissions, sets the API URL, and runs `flutter build apk`.

## Option B — Build locally
Install Flutter (https://docs.flutter.dev/get-started/install), then:
```bash
flutter create --platforms=android --org com.wineflow .
# add permissions (see step in the CI yml) to android/app/src/main/AndroidManifest.xml
flutter pub get
flutter build apk --release --dart-define=API_BASE=https://api.yourdomain.com
```
Output: `build/app/outputs/flutter-apk/app-release.apk` → rename to `WineFlow.apk`.

## Configure the server URL
The app reads `API_BASE` (a `--dart-define`). Point it at your deployed server,
e.g. `https://api.yourdomain.com`. Default is `http://10.0.2.2:4000` (Android emulator).

## Screens included
Register/OTP, login, dashboard, attendance (GPS), 2-minute GPS ping loop, outlet
visit (with shelf-photo), order booking, collection, **daily report, expense claim,
apply leave, new-outlet request, my route**.

## Optional add-ons (see the OPTIONAL_*.md files)
- True background GPS tracking (foreground service).
- Push notifications (Firebase).

## Scope note
This foundation implements: register/OTP, login, dashboard, attendance with GPS +
geofence, 5-minute GPS ping loop, outlet visit, order booking and collection entry,
all talking to the central server. Production polish (offline queue with retry,
true background tracking via a foreground service, push notifications, maps tiles)
is the documented next layer — see the Solution Blueprint.
