# Enabling push notifications (optional)

Push requires a Firebase project (google-services.json), so it is NOT part of the
default build (which would otherwise fail without that file). The backend is ready:
`POST /api/v1/me/device-token { token }` stores each user's FCM token.

## Steps (summary)
1. Create a Firebase project; add an Android app with your package id (com.wineflow...).
2. Download `google-services.json` into `android/app/`.
3. Add `firebase_core` and `firebase_messaging` to pubspec; apply the Google
   services Gradle plugin (per FlutterFire docs).
4. On login, obtain the FCM token and POST it to `/api/v1/me/device-token`.
5. Send notifications from your backend/admin using the stored tokens (e.g. on
   order approval or a new pending item).

Reference: FlutterFire Cloud Messaging documentation (firebase.flutter.dev).
