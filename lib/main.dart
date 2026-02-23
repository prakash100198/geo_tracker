import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geo_tracker/views/home_page.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:shared_preferences/shared_preferences.dart';

// ═══════════════════════════════════════════════════════════════════
// 🎯 HEADLESS TASK HANDLER - Runs when app is COMPLETELY CLOSED
// ═══════════════════════════════════════════════════════════════════
// WHY: When app is force-killed/swiped away, this function handles
//      location events in a minimal Dart isolate
// WHEN CALLED: App is DEAD - no UI, no state, no class instances
// WHAT IT DOES: Apply smart heartbeat logic and persist to storage
// ═══════════════════════════════════════════════════════════════════

/// Top-level function that runs when app is completely closed
/// MUST be top-level (not in a class) so plugin can invoke it
void headlessTask(bg.HeadlessEvent headlessEvent) async {
  print('\n🔵 ═══════════════════════════════════════════════════');
  print('🔵 HEADLESS MODE: App is CLOSED, but I\'m still running!');
  print('🔵 Event type: ${headlessEvent.name}');
  print('🔵 ═══════════════════════════════════════════════════\n');

  // Get persistent storage (works even when app is closed)
  final prefs = await SharedPreferences.getInstance();

  // Load persistent state
  bool isTraveling = prefs.getBool('is_traveling') ?? false;
  int lastHeartbeatMs = prefs.getInt('last_heartbeat_time') ?? 0;
  String currentActivity = prefs.getString('current_activity') ?? 'unknown';
  int totalTriggers = prefs.getInt('total_triggers') ?? 0;
  int totalHeartbeats = prefs.getInt('total_heartbeats') ?? 0;

  // NOTE: trigger counters are incremented per-case AFTER the travel check,
  // so vehicle-mode wake-ups do not inflate the efficiency denominator.

  // Handle different event types
  switch (headlessEvent.name) {
    // ═══════════════════════════════════════════════════════════════
    // 📍 LOCATION EVENT - Most common trigger
    // ═══════════════════════════════════════════════════════════════
    case bg.Event.LOCATION:
      final location = headlessEvent.event as bg.Location;

      // Silently ignore location events during vehicle travel.
      if (isTraveling) return;

      totalTriggers++;
      await prefs.setInt('total_triggers', totalTriggers);
      int locTriggers24h = prefs.getInt('triggers_24h') ?? 0;
      locTriggers24h++;
      await prefs.setInt('triggers_24h', locTriggers24h);

      print('🔔 HEADLESS TRIGGER #$totalTriggers: Location event');
      print(
        '   Coords: ${location.coords.latitude}, ${location.coords.longitude}',
      );
      print('   isMoving: ${location.isMoving}');
      print('   Speed: ${location.coords.speed} m/s');
      print('   Activity: $currentActivity');

      // ═══════════════════════════════════════════════════════════
      // SMART HEARTBEAT LOGIC - Same as when app is open
      // ═══════════════════════════════════════════════════════════

      // CHECK 1: Don't send if moving
      if (location.isMoving) {
        print('   ❌ SKIP: User is moving');
        return;
      }

      // CHECK 3: Don't send if high speed
      // Note: speed is -1 on iOS/Android when unavailable (not null in v5)
      final speed = location.coords.speed;
      if (speed > 2.0) {
        print('   ❌ SKIP: Speed too high (${speed.toStringAsFixed(1)} m/s)');
        return;
      }

      // CHECK 4: Don't send if last heartbeat was < 20 min ago
      final lastHeartbeatTime = DateTime.fromMillisecondsSinceEpoch(
        lastHeartbeatMs,
      );
      final timeSinceLastHeartbeat = DateTime.now().difference(
        lastHeartbeatTime,
      );
      if (timeSinceLastHeartbeat.inMinutes < 20) {
        print(
          '   ❌ SKIP: Last heartbeat was ${timeSinceLastHeartbeat.inMinutes} min ago',
        );
        return;
      }

      // ✅ ALL CHECKS PASSED - Send heartbeat!
      print('   ✅ SEND HEARTBEAT (headless mode)');
      await _sendHeadlessHeartbeat(prefs, location, totalHeartbeats);
      break;

    // ═══════════════════════════════════════════════════════════════
    // 🏃 MOTION CHANGE EVENT - User started/stopped moving
    // ═══════════════════════════════════════════════════════════════
    case bg.Event.MOTIONCHANGE:
      final location = headlessEvent.event as bg.Location;
      final isMoving = location.isMoving;

      // Silently ignore motion events during vehicle travel.
      if (isTraveling) return;

      totalTriggers++;
      await prefs.setInt('total_triggers', totalTriggers);
      int motTriggers24h = prefs.getInt('triggers_24h') ?? 0;
      motTriggers24h++;
      await prefs.setInt('triggers_24h', motTriggers24h);

      print('🔔 HEADLESS TRIGGER #$totalTriggers: Motion change → ${isMoving ? "MOVING" : "STATIONARY"}');

      // When user STOPS → immediate heartbeat
      if (!isMoving) {
        print('   ✅ IMMEDIATE HEARTBEAT: User arrived at location');
        await _sendHeadlessHeartbeat(prefs, location, totalHeartbeats);
      } else {
        print('   ℹ️  User started moving - will send when they stop');
      }
      break;

    // ═══════════════════════════════════════════════════════════════
    // 🎯 ACTIVITY CHANGE EVENT - Detect travel mode
    // ═══════════════════════════════════════════════════════════════
    case bg.Event.ACTIVITYCHANGE:
      final activity = headlessEvent.event as bg.ActivityChangeEvent;

      // Activity change MUST always run to detect travel transitions.
      // Only count as trigger in presence-detection mode.
      if (!isTraveling) {
        totalTriggers++;
        await prefs.setInt('total_triggers', totalTriggers);
        int actTriggers24h = prefs.getInt('triggers_24h') ?? 0;
        actTriggers24h++;
        await prefs.setInt('triggers_24h', actTriggers24h);
        print('🔔 HEADLESS TRIGGER #$totalTriggers: Activity change');
      } else {
        print('🔔 Activity change (travel mode — not counted as trigger)');
      }
      print('   Activity: ${activity.activity} (${activity.confidence}%)');

      // Update current activity
      currentActivity = activity.activity;
      await prefs.setString('current_activity', currentActivity);

      // Detect travel mode
      final wasTraveling = isTraveling;

      if ((activity.activity == 'in_vehicle' ||
              activity.activity == 'on_bicycle') &&
          activity.confidence > 70) {
        isTraveling = true;
        await prefs.setBool('is_traveling', true);

        if (!wasTraveling) {
          print('   🚗 TRAVEL MODE ACTIVATED (headless)');
          print('   ⚙️  Increasing distance filter to 500m');

          // Adjust config for travel mode
          await bg.BackgroundGeolocation.setConfig(
            bg.Config(
              distanceFilter: 500.0,
              desiredAccuracy: bg.Config.DESIRED_ACCURACY_LOW,
            ),
          );
        }
      } else {
        isTraveling = false;
        await prefs.setBool('is_traveling', false);

        if (wasTraveling) {
          print('   🏠 PRESENCE MODE ACTIVATED (headless)');
          print('   ⚙️  Restoring distance filter to 300m');

          // Restore normal config
          await bg.BackgroundGeolocation.setConfig(
            bg.Config(
              distanceFilter: 200.0, // restore to base config value
              desiredAccuracy: bg.Config.DESIRED_ACCURACY_MEDIUM,
            ),
          );
        }
      }
      break;

    // ═══════════════════════════════════════════════════════════════
    // 💓 HEARTBEAT EVENT - 20-min backup timer
    // ═══════════════════════════════════════════════════════════════
    case bg.Event.HEARTBEAT:
      // Silently ignore the 20-min backup timer during vehicle travel.
      if (isTraveling) return;

      totalTriggers++;
      await prefs.setInt('total_triggers', totalTriggers);
      int hbTriggers24h = prefs.getInt('triggers_24h') ?? 0;
      hbTriggers24h++;
      await prefs.setInt('triggers_24h', hbTriggers24h);

      print('🔔 HEADLESS TRIGGER #$totalTriggers: Heartbeat (20-min backup)');

      final heartbeatEvent = headlessEvent.event as bg.HeartbeatEvent;

      // ── PATH 1: Use last-known position from the heartbeat event ──────
      // Instant, never fails — no async call needed
      if (heartbeatEvent.location != null) {
        print('   ✅ SEND HEARTBEAT: Using last-known position (headless)');
        await _sendHeadlessHeartbeat(
          prefs,
          heartbeatEvent.location!,
          totalHeartbeats,
        );
        break;
      }

      // ── PATH 2: Fetch fresh position with background task guard ───────
      // CRITICAL: startBackgroundTask prevents Android from suspending the
      // isolate mid-await, which was silently killing getCurrentPosition.
      final taskId = await bg.BackgroundGeolocation.startBackgroundTask();
      try {
        final location = await bg.BackgroundGeolocation.getCurrentPosition(
          samples: 1,
          persist: false,
          timeout: 30,
        );
        print('   ✅ SEND HEARTBEAT: Stationary backup ping (headless)');
        await _sendHeadlessHeartbeat(prefs, location, totalHeartbeats);
      } catch (e) {
        print('   ❌ Error getting position: $e');
      } finally {
        bg.BackgroundGeolocation.stopBackgroundTask(taskId);
      }
      break;

    default:
      print('⚠️  Unhandled headless event: ${headlessEvent.name}');
  }
}

/// Helper function to send heartbeat in headless mode
Future<void> _sendHeadlessHeartbeat(
  SharedPreferences prefs,
  bg.Location location,
  int currentHeartbeats,
) async {
  // Accuracy gate: skip only truly junk cell-tower-only fixes
  // 1000m matches Radar.io's hard cutoff
  final accuracy = location.coords.accuracy;
  if (accuracy > 1000) {
    print(
      '   ❌ HEADLESS SKIP: Poor accuracy (${accuracy.toStringAsFixed(0)}m > 1000m)',
    );
    return;
  }

  // Increment heartbeat counter
  final newHeartbeats = currentHeartbeats + 1;
  await prefs.setInt('total_heartbeats', newHeartbeats);

  // Update last heartbeat time
  await prefs.setInt(
    'last_heartbeat_time',
    DateTime.now().millisecondsSinceEpoch,
  );

  // Increment 24h heartbeats
  int heartbeats24h = prefs.getInt('heartbeats_24h') ?? 0;
  heartbeats24h++;
  await prefs.setInt('heartbeats_24h', heartbeats24h);

  // Get total triggers for efficiency calculation
  final totalTriggers = prefs.getInt('total_triggers') ?? 1;
  final efficiency = (newHeartbeats / totalTriggers * 100).toStringAsFixed(1);

  print('💓 HEADLESS HEARTBEAT #$newHeartbeats sent');
  print('   📊 Efficiency: $newHeartbeats / $totalTriggers = $efficiency%');
  print(
    '   📍 Coords: ${location.coords.latitude}, ${location.coords.longitude}',
  );

  // Manually save heartbeat location so UI can display it on next sync
  final existingJson = prefs.getString('headless_heartbeats') ?? '[]';
  final List<dynamic> saved = jsonDecode(existingJson);
  saved.add({
    'lat': location.coords.latitude,
    'lng': location.coords.longitude,
    'timestamp': DateTime.now().toIso8601String(),
    'accuracy': location.coords.accuracy,
    'speed': location.coords.speed,
  });
  await prefs.setString('headless_heartbeats', jsonEncode(saved));

  // TODO: Send to backend server here
  // await http.post(yourServerUrl, body: {...});
}

void main() {
  // ═══════════════════════════════════════════════════════════════
  // 🎯 CRITICAL: Register headless task BEFORE runApp()
  // ═══════════════════════════════════════════════════════════════
  // This tells the plugin: "When app is closed, call headlessTask()"
  bg.BackgroundGeolocation.registerHeadlessTask(headlessTask);

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Geo Tracker POC',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
