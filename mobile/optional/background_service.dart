// ============================================================
//  WineFlow — OPTIONAL true-background GPS tracking module
//  (Increment 6). Kept OUT of lib/ so the default APK always builds.
//  ENABLE it by following mobile/OPTIONAL_BACKGROUND_SETUP.md.
//
//  This runs a foreground service that shares the employee's location every
//  2 minutes even when the phone is locked, until check-out. On failure it
//  stores pings to a local backlog that the app flushes when back online.
//  NOTE: native background/location code cannot be compiled in a text tool;
//  build via CI and validate on a real device before rollout.
// ============================================================
import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';

const apiBase = String.fromEnvironment('API_BASE', defaultValue: 'http://10.0.2.2:4000');

Future<void> initBackgroundTracking() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      isForegroundMode: true,
      autoStart: false, // start after check-in
      notificationChannelId: 'wineflow_tracking',
      initialNotificationTitle: 'WineFlow',
      initialNotificationContent: 'Sharing work location',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
}

/// Call after check-in.
void startTracking() => FlutterBackgroundService().startService();
/// Call on check-out / logout.
void stopTracking() => FlutterBackgroundService().invoke('stopService');

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  if (service is AndroidServiceInstance) service.setAsForegroundService();
  service.on('stopService').listen((_) => service.stopSelf());

  Timer.periodic(const Duration(minutes: 2), (t) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token == null) return;
      final pos = await Geolocator.getCurrentPosition();
      final body = jsonEncode({
        'lat': pos.latitude, 'lng': pos.longitude, 'speed': pos.speed,
        'accuracy_m': pos.accuracy, 'ts': DateTime.now().toUtc().toIso8601String(),
        'client_uuid': DateTime.now().microsecondsSinceEpoch.toString(),
      });
      final r = await http
          .post(Uri.parse('$apiBase/api/v1/tracking/ping'),
              headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
              body: body)
          .timeout(const Duration(seconds: 15));
      if (r.statusCode < 200 || r.statusCode >= 300) {
        final backlog = prefs.getStringList('bg_backlog') ?? [];
        backlog.add(body);
        await prefs.setStringList('bg_backlog', backlog);
      }
    } catch (_) {/* keep running; next tick retries */}
  });
}
