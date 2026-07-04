# Enabling true background GPS tracking (Increment 6, optional)

The default app tracks location every 2 minutes while open/foregrounded. To keep
tracking when the phone is locked (until check-out), enable the foreground-service
module. This uses native plugins and MUST be built via CI and tested on a device.

## Steps
1. Add to `pubspec.yaml` dependencies:
   ```
     flutter_background_service: ^5.0.5
     flutter_background_service_android: ^6.2.2
   ```
2. Move `optional/background_service.dart` into `lib/`.
3. In `lib/main.dart`:
   - `import 'background_service.dart';`
   - in `main()` (before runApp): `WidgetsFlutterBinding.ensureInitialized(); await initBackgroundTracking();`
   - call `startTracking();` right after a successful **Check-In**, and
     `stopTracking();` on **Check-Out** and on logout.
4. The CI workflow already injects the required permissions
   (FOREGROUND_SERVICE, FOREGROUND_SERVICE_LOCATION, ACCESS_BACKGROUND_LOCATION,
   POST_NOTIFICATIONS, WAKE_LOCK). Android 10+ also requires the user to grant
   "Allow all the time" location — prompt for it after check-in.
5. Add backlog-drain (optional): on app start / Sync, read `bg_backlog` from
   SharedPreferences and POST each entry, then clear it.

## Verification note
Background execution behaviour varies by Android OEM (battery optimisation). Test
on the actual handset models your team uses and, if needed, guide users to exclude
WineFlow from battery optimisation.
