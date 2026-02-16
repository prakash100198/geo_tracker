import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// Model for location data
class LocationData {
  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final double? speed;
  final double? accuracy;
  final String activity;

  LocationData({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.speed,
    this.accuracy,
    this.activity = 'unknown',
  });

  String get formattedTime {
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    final second = timestamp.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  String get formattedDate {
    final day = timestamp.day.toString().padLeft(2, '0');
    final month = timestamp.month.toString().padLeft(2, '0');
    return '$day/$month/${timestamp.year}';
  }

  String get formattedCoords {
    return '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';
  }
}

// State notifier for location tracking
class LocationNotifier extends StateNotifier<List<LocationData>> {
  LocationNotifier() : super([]);

  void addLocation(LocationData location) {
    state = [location, ...state];
  }

  void clearLocations() {
    state = [];
  }
}

// Providers
final locationProvider =
    StateNotifierProvider<LocationNotifier, List<LocationData>>((ref) {
      return LocationNotifier();
    });

final isTrackingProvider = StateProvider<bool>((ref) => false);
final currentActivityProvider = StateProvider<String>((ref) => 'unknown');
final trackingIntervalProvider = StateProvider<int>(
  (ref) => 5,
); // Default 5 minutes

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool _isInitialized = false;
  String _currentActivity = 'unknown';

  @override
  void initState() {
    super.initState();
    _initBackgroundGeolocation();
  }

  Future<void> _initBackgroundGeolocation() async {
    print('🚀 Initializing Background Geolocation...');

    // Location event listener
    bg.BackgroundGeolocation.onLocation(_onLocation);

    // Motion change listener
    bg.BackgroundGeolocation.onMotionChange(_onMotionChange);

    // Activity change listener
    bg.BackgroundGeolocation.onActivityChange(_onActivityChange);

    // Heartbeat listener
    bg.BackgroundGeolocation.onHeartbeat(_onHeartbeat);

    // Get initial interval
    final intervalMinutes = ref.read(trackingIntervalProvider);
    final intervalSeconds = intervalMinutes * 60;
    final intervalMillis = intervalMinutes * 60 * 1000;

    // Configure the plugin with user-selected interval
    await bg.BackgroundGeolocation.ready(
      bg.Config(
        // Accuracy settings - medium for battery optimization
        desiredAccuracy: bg.Config.DESIRED_ACCURACY_MEDIUM,
        distanceFilter: 150.0, // meters
        // Motion detection
        stopTimeout: 1, // 1 minute before considering stationary
        activityRecognitionInterval: 10000, // 10 seconds
        // Heartbeat - user configurable interval
        heartbeatInterval: intervalSeconds,

        // Battery optimization
        disableElasticity: false,
        stopOnTerminate: false, // 🔥 KEEPS TRACKING EVEN WHEN APP IS CLOSED
        startOnBoot: true, // 🔥 RESUMES TRACKING AFTER PHONE RESTART
        foregroundService:
            true, // 🔥 RUNS AS FOREGROUND SERVICE (REQUIRED FOR ANDROID)
        enableHeadless: true, // 🔥 CRITICAL: Enables background operation
        // iOS specific
        pausesLocationUpdatesAutomatically: false,
        activityType: bg.Config.ACTIVITY_TYPE_OTHER,

        // Android specific
        locationUpdateInterval: intervalMillis,
        fastestLocationUpdateInterval: intervalMillis,

        // 🌐 HTTP/SERVER CONFIGURATION (for production)
        // Uncomment and configure these for real-world apps:

        // url: "https://your-api.com/api/locations",  // Your backend endpoint
        // method: "POST",
        // autoSync: true,  // Auto-send to server
        // autoSyncThreshold: 0,  // Send immediately (0 = no batching)
        // batchSync: false,  // Set true to batch multiple locations
        // maxBatchSize: 250,  // Max locations per batch
        // maxDaysToPersist: 7,  // Keep failed uploads for 7 days

        // // Authentication & Headers
        // headers: {
        //   "Authorization": "Bearer YOUR_AUTH_TOKEN",
        //   "Content-Type": "application/json",
        //   "X-API-Key": "your-api-key",
        // },

        // // Additional parameters sent with each location
        // params: {
        //   "user_id": "123",  // Replace with actual user ID
        //   "device_id": "android_abc",  // Device identifier
        // },

        // // Custom fields in the payload
        // extras: {
        //   "app_version": "1.0.0",
        //   "tracking_mode": "battery_poc",
        // },

        // Notification (required for Android foreground service)
        notification: bg.Notification(
          title: "Geo Tracker Active",
          text: "Recording location every $intervalMinutes minutes",
          color: "#4CAF50",
          smallIcon: "drawable/ic_launcher",
          largeIcon: "drawable/ic_launcher",
        ),

        // Debug settings - enable for testing, disable for production
        logLevel: bg.Config.LOG_LEVEL_VERBOSE,
        debug: true,
      ),
    );

    setState(() {
      _isInitialized = true;
    });

    // Load persisted locations from plugin's database
    await _loadPersistedLocations();

    // Check if tracking was previously active and sync UI state
    final state = await bg.BackgroundGeolocation.state;
    final isEnabled = state.enabled;

    print(
      '✅ Background Geolocation initialized with $intervalMinutes minute interval',
    );
    print('📊 Current tracking state: ${isEnabled ? "ACTIVE" : "STOPPED"}');

    if (isEnabled) {
      print('🔄 Tracking was already running in background - syncing UI state');
      ref.read(isTrackingProvider.notifier).state = true;
    }
  }

  Future<void> _loadPersistedLocations() async {
    try {
      print('📥 Loading persisted locations from plugin database...');

      // Query all locations from plugin's SQLite database
      final locations = await bg.BackgroundGeolocation.locations;

      print('📍 Found ${locations.length} persisted locations');

      if (locations.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No new background locations to sync'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      // Add them to our state in reverse order (newest first)
      for (var i = locations.length - 1; i >= 0; i--) {
        final loc = locations[i];

        // bg.BackgroundGeolocation.locations returns List<Map<Object?, Object?>>
        // We must convert (not cast) to Map<String, dynamic> using .from()
        final coordsRaw = loc['coords'];
        final activityRaw = loc['activity'];
        final timestampStr = loc['timestamp']?.toString();

        if (coordsRaw == null || coordsRaw is! Map) continue;

        final coords = Map<String, dynamic>.from(coordsRaw);
        final activity = activityRaw is Map
            ? Map<String, dynamic>.from(activityRaw)
            : <String, dynamic>{};

        DateTime timestamp;
        try {
          timestamp = timestampStr != null
              ? DateTime.parse(timestampStr)
              : DateTime.now();
        } catch (_) {
          timestamp = DateTime.now();
        }

        final locationData = LocationData(
          latitude: (coords['latitude'] as num?)?.toDouble() ?? 0.0,
          longitude: (coords['longitude'] as num?)?.toDouble() ?? 0.0,
          timestamp: timestamp,
          speed: (coords['speed'] as num?)?.toDouble(),
          accuracy: (coords['accuracy'] as num?)?.toDouble(),
          activity: (activity['type'] as String?) ?? 'unknown',
        );

        ref.read(locationProvider.notifier).addLocation(locationData);
      }

      // Clear the plugin's database after loading
      await bg.BackgroundGeolocation.destroyLocations();
      print(
        '🗑️ Cleared plugin database after loading ${locations.length} locations',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '✓ Synced ${locations.length} background location${locations.length > 1 ? 's' : ''}',
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('❌ Error loading persisted locations: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error syncing: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _updateTrackingInterval(int intervalMinutes) async {
    final intervalSeconds = intervalMinutes * 60;
    final intervalMillis = intervalMinutes * 60 * 1000;

    print('⚙️ Updating tracking interval to $intervalMinutes minutes');

    await bg.BackgroundGeolocation.setConfig(
      bg.Config(
        heartbeatInterval: intervalSeconds,
        locationUpdateInterval: intervalMillis,
        fastestLocationUpdateInterval: intervalMillis,
        notification: bg.Notification(
          title: "Geo Tracker Active",
          text: "Recording location every $intervalMinutes minutes",
          color: "#4CAF50",
          smallIcon: "drawable/ic_launcher",
          largeIcon: "drawable/ic_launcher",
        ),
      ),
    );

    ref.read(trackingIntervalProvider.notifier).state = intervalMinutes;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✓ Interval updated to $intervalMinutes minutes'),
          backgroundColor: Colors.blue,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _onLocation(bg.Location location) {
    print(
      '📍 Location Update: ${location.coords.latitude}, ${location.coords.longitude}',
    );

    final locationData = LocationData(
      latitude: location.coords.latitude,
      longitude: location.coords.longitude,
      timestamp: DateTime.now(),
      speed: location.coords.speed,
      accuracy: location.coords.accuracy,
      activity: _currentActivity,
    );

    ref.read(locationProvider.notifier).addLocation(locationData);
  }

  void _onMotionChange(bg.Location location) {
    final isMoving = location.isMoving;
    print('🚶 Motion Change: isMoving=$isMoving');

    final locationData = LocationData(
      latitude: location.coords.latitude,
      longitude: location.coords.longitude,
      timestamp: DateTime.now(),
      speed: location.coords.speed,
      accuracy: location.coords.accuracy,
      activity: isMoving ? 'moving' : 'stationary',
    );

    ref.read(locationProvider.notifier).addLocation(locationData);
  }

  void _onActivityChange(bg.ActivityChangeEvent event) {
    print(
      '🎯 Activity Change: ${event.activity} (confidence: ${event.confidence}%)',
    );

    setState(() {
      _currentActivity = event.activity;
    });

    ref.read(currentActivityProvider.notifier).state = event.activity;
  }

  void _onHeartbeat(bg.HeartbeatEvent event) async {
    print('❤️ Heartbeat fired - getting current position');

    try {
      final location = await bg.BackgroundGeolocation.getCurrentPosition(
        samples: 1,
        persist: false,
        timeout: 30,
      );

      final locationData = LocationData(
        latitude: location.coords.latitude,
        longitude: location.coords.longitude,
        timestamp: DateTime.now(),
        speed: location.coords.speed,
        accuracy: location.coords.accuracy,
        activity: 'heartbeat',
      );

      ref.read(locationProvider.notifier).addLocation(locationData);
    } catch (e) {
      print('❌ Error getting position: $e');
    }
  }

  Future<void> _startTracking() async {
    try {
      final intervalMinutes = ref.read(trackingIntervalProvider);
      final state = await bg.BackgroundGeolocation.start();
      print('🟢 Tracking started - Running in background!');
      print('📱 App can be closed - tracking will continue');
      print('🔔 You should see a persistent notification');
      print('⏱️ Update interval: $intervalMinutes minutes');
      ref.read(isTrackingProvider.notifier).state = true;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '✓ Background tracking started!\nWill track every $intervalMinutes min even when app is closed',
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      print('❌ Error starting tracking: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error starting tracking: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _stopTracking() async {
    try {
      final state = await bg.BackgroundGeolocation.stop();
      print('🔴 Tracking stopped - Background tracking disabled');
      ref.read(isTrackingProvider.notifier).state = false;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✓ Background tracking stopped'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('❌ Error stopping tracking: $e');
    }
  }

  void _clearLocations() {
    ref.read(locationProvider.notifier).clearLocations();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('All locations cleared'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<void> _openInMaps(double latitude, double longitude) async {
    final url = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude',
    );

    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not open maps'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      print('Error opening maps: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Color _getActivityColor(String activity) {
    switch (activity.toLowerCase()) {
      case 'still':
        return Colors.blue;
      case 'walking':
        return Colors.green;
      case 'running':
        return Colors.orange;
      case 'in_vehicle':
        return Colors.red;
      case 'on_bicycle':
        return Colors.purple;
      case 'moving':
        return Colors.amber;
      case 'stationary':
        return Colors.grey;
      case 'heartbeat':
        return Colors.pink;
      default:
        return Colors.grey;
    }
  }

  IconData _getActivityIcon(String activity) {
    switch (activity.toLowerCase()) {
      case 'still':
        return Icons.chair;
      case 'walking':
        return Icons.directions_walk;
      case 'running':
        return Icons.directions_run;
      case 'in_vehicle':
        return Icons.directions_car;
      case 'on_bicycle':
        return Icons.directions_bike;
      case 'moving':
        return Icons.trending_up;
      case 'stationary':
        return Icons.stop_circle;
      case 'heartbeat':
        return Icons.favorite;
      default:
        return Icons.help_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final locations = ref.watch(locationProvider);
    final isTracking = ref.watch(isTrackingProvider);
    final currentActivity = ref.watch(currentActivityProvider);
    final trackingInterval = ref.watch(trackingIntervalProvider);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Geo Tracker - Battery POC'),
        actions: [
          IconButton(
            icon: const Icon(Icons.sync),
            onPressed: _loadPersistedLocations,
            tooltip: 'Sync background locations',
          ),
          if (locations.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _clearLocations,
              tooltip: 'Clear all locations',
            ),
        ],
      ),
      body: Column(
        children: [
          // Status card
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isTracking
                    ? [Colors.green.shade50, Colors.green.shade100]
                    : [Colors.grey.shade100, Colors.grey.shade200],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isTracking ? Colors.green : Colors.grey,
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              children: [
                Icon(
                  isTracking ? Icons.gps_fixed : Icons.gps_off,
                  size: 56,
                  color: isTracking
                      ? Colors.green.shade700
                      : Colors.grey.shade500,
                ),
                const SizedBox(height: 12),
                Text(
                  isTracking ? 'Tracking Active' : 'Tracking Stopped',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isTracking
                        ? Colors.green.shade900
                        : Colors.grey.shade700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Updates every $trackingInterval minutes',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: _getActivityColor(currentActivity).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _getActivityIcon(currentActivity),
                        size: 16,
                        color: _getActivityColor(currentActivity),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Activity: ${currentActivity.replaceAll('_', ' ').toUpperCase()}',
                        style: TextStyle(
                          color: _getActivityColor(currentActivity),
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.deepPurple.shade50,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${locations.length} locations recorded',
                    style: TextStyle(
                      color: Colors.deepPurple.shade700,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Interval selector
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade300),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.timer,
                      size: 20,
                      color: Colors.deepPurple.shade700,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Update Interval',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey.shade800,
                      ),
                    ),
                    if (isTracking) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Stop to change',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.orange.shade900,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [2, 5, 8, 10, 15].map((minutes) {
                    final isSelected = trackingInterval == minutes;
                    return InkWell(
                      onTap: isTracking
                          ? null
                          : () async {
                              await _updateTrackingInterval(minutes);
                            },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Colors.deepPurple.shade600
                              : isTracking
                              ? Colors.grey.shade200
                              : Colors.deepPurple.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isSelected
                                ? Colors.deepPurple.shade600
                                : Colors.grey.shade300,
                            width: 2,
                          ),
                        ),
                        child: Text(
                          '$minutes min',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: isSelected
                                ? Colors.white
                                : isTracking
                                ? Colors.grey.shade500
                                : Colors.deepPurple.shade700,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Info banner
          if (isTracking && locations.isEmpty)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    color: Colors.blue.shade700,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Location updates will appear every $trackingInterval minutes',
                      style: TextStyle(
                        color: Colors.blue.shade900,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 16),

          // Location list
          Expanded(
            child: locations.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.location_searching,
                          size: 72,
                          color: Colors.grey.shade300,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'No locations recorded yet',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: Colors.grey.shade600,
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Start tracking to monitor battery usage',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: Colors.grey.shade500),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                    itemCount: locations.length,
                    itemBuilder: (context, index) {
                      final location = locations[index];
                      return Card(
                        elevation: 2,
                        margin: const EdgeInsets.only(bottom: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.all(12),
                          leading: CircleAvatar(
                            backgroundColor: Colors.deepPurple.shade100,
                            radius: 24,
                            child: Text(
                              '${locations.length - index}',
                              style: TextStyle(
                                color: Colors.deepPurple.shade900,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          title: InkWell(
                            onTap: () => _openInMaps(
                              location.latitude,
                              location.longitude,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    location.formattedCoords,
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.blue,
                                      decoration: TextDecoration.underline,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.open_in_new,
                                  size: 16,
                                  color: Colors.blue.shade600,
                                ),
                              ],
                            ),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Icon(
                                    Icons.access_time,
                                    size: 14,
                                    color: Colors.grey.shade600,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${location.formattedDate} ${location.formattedTime}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade700,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Icon(
                                    _getActivityIcon(location.activity),
                                    size: 14,
                                    color: _getActivityColor(location.activity),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    location.activity.replaceAll('_', ' '),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _getActivityColor(
                                        location.activity,
                                      ),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              if (location.accuracy != null) ...[
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.my_location,
                                      size: 14,
                                      color: Colors.grey.shade600,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Accuracy: ${location.accuracy!.toStringAsFixed(1)}m',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              if (location.speed != null &&
                                  location.speed! > 0) ...[
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.speed,
                                      size: 14,
                                      color: Colors.grey.shade600,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Speed: ${(location.speed! * 3.6).toStringAsFixed(1)} km/h',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                          trailing: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.deepPurple.shade50,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.location_on,
                              color: Colors.deepPurple.shade400,
                              size: 24,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: !_isInitialized
          ? null
          : FloatingActionButton.extended(
              onPressed: isTracking ? _stopTracking : _startTracking,
              backgroundColor: isTracking
                  ? Colors.red.shade600
                  : Colors.green.shade600,
              icon: Icon(isTracking ? Icons.stop : Icons.play_arrow, size: 28),
              label: Text(
                isTracking ? 'Stop Tracking' : 'Start Tracking',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
    );
  }

  @override
  void dispose() {
    bg.BackgroundGeolocation.removeListeners();
    super.dispose();
  }
}
