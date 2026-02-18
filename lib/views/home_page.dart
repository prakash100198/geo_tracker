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

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool _isInitialized = false;
  String _currentActivity = 'unknown';
  bool _isTraveling = false;
  DateTime _lastHeartbeatTime = DateTime.now().subtract(
    const Duration(hours: 1),
  );
  int _totalTriggers = 0;
  int _totalHeartbeats = 0;

  // 24-hour stats tracking
  int _triggers24h = 0;
  int _heartbeats24h = 0;
  DateTime? _stats24hStartTime;

  @override
  void initState() {
    super.initState();
    _loadPersistentState();
    _load24hStats();
    _initBackgroundGeolocation();
  }

  // ═══════════════════════════════════════════════════════════════════
  // 💾 PERSISTENT STATE - Sync with headless mode
  // ═══════════════════════════════════════════════════════════════════
  // WHY: Headless mode and UI mode share state via SharedPreferences
  // This ensures seamless continuity when app opens/closes

  Future<void> _loadPersistentState() async {
    final prefs = await SharedPreferences.getInstance();

    final isTraveling = prefs.getBool('is_traveling') ?? false;
    final lastHeartbeatMs = prefs.getInt('last_heartbeat_time');
    final activity = prefs.getString('current_activity') ?? 'unknown';
    final triggers = prefs.getInt('total_triggers') ?? 0;
    final heartbeats = prefs.getInt('total_heartbeats') ?? 0;

    setState(() {
      _isTraveling = isTraveling;
      _currentActivity = activity;
      _totalTriggers = triggers;
      _totalHeartbeats = heartbeats;
      if (lastHeartbeatMs != null) {
        _lastHeartbeatTime = DateTime.fromMillisecondsSinceEpoch(
          lastHeartbeatMs,
        );
      }
    });

    print('💾 Loaded persistent state:');
    print('   Traveling: $_isTraveling');
    print('   Activity: $_currentActivity');
    print('   Triggers: $_totalTriggers');
    print('   Heartbeats: $_totalHeartbeats');
  }

  Future<void> _saveTravelingState(bool isTraveling) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_traveling', isTraveling);
  }

  Future<void> _saveActivityState(String activity) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('current_activity', activity);
  }

  Future<void> _saveHeartbeatTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      'last_heartbeat_time',
      _lastHeartbeatTime.millisecondsSinceEpoch,
    );
  }

  Future<void> _saveTriggerCount() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('total_triggers', _totalTriggers);
  }

  Future<void> _saveHeartbeatCount() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('total_heartbeats', _totalHeartbeats);
  }

  // ═══════════════════════════════════════════════════
  // 24-HOUR STATS PERSISTENCE
  // ═══════════════════════════════════════════════════

  Future<void> _load24hStats() async {
    final prefs = await SharedPreferences.getInstance();

    final startTimeMs = prefs.getInt('stats_start_time');
    final triggers = prefs.getInt('triggers_24h') ?? 0;
    final heartbeats = prefs.getInt('heartbeats_24h') ?? 0;

    if (startTimeMs != null) {
      final startTime = DateTime.fromMillisecondsSinceEpoch(startTimeMs);
      final elapsed = DateTime.now().difference(startTime);

      // Reset if > 24h
      if (elapsed.inHours >= 24) {
        print('🔄 Resetting 24h stats (elapsed: ${elapsed.inHours}h)');
        await _reset24hStats();
      } else {
        setState(() {
          _stats24hStartTime = startTime;
          _triggers24h = triggers;
          _heartbeats24h = heartbeats;
        });
        print(
          '📊 Loaded 24h stats: $triggers triggers, $heartbeats heartbeats',
        );
      }
    } else {
      // First time - initialize
      await _reset24hStats();
    }
  }

  Future<void> _reset24hStats() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();

    await prefs.setInt('stats_start_time', now.millisecondsSinceEpoch);
    await prefs.setInt('triggers_24h', 0);
    await prefs.setInt('heartbeats_24h', 0);

    setState(() {
      _stats24hStartTime = now;
      _triggers24h = 0;
      _heartbeats24h = 0;
    });
  }

  Future<void> _increment24hTriggers() async {
    final prefs = await SharedPreferences.getInstance();
    _triggers24h++;
    await prefs.setInt('triggers_24h', _triggers24h);
  }

  Future<void> _increment24hHeartbeats() async {
    final prefs = await SharedPreferences.getInstance();
    _heartbeats24h++;
    await prefs.setInt('heartbeats_24h', _heartbeats24h);
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

    // Fixed 15-minute heartbeat interval (no longer user-configurable)
    const heartbeatMinutes = 15;
    const heartbeatSeconds = heartbeatMinutes * 60; // 900 seconds
    const heartbeatMillis = heartbeatMinutes * 60 * 1000; // 900000 ms

    print('🎯 Configuring SMART PRESENCE DETECTION system');
    print('📍 Strategy: Motion-based + Activity detection');
    print('🔋 Config #2: OPTIMIZED FOR BATTERY (1-3% target)');
    print('⏱️  Fixed heartbeat: $heartbeatMinutes minutes');
    print('🎯 Target: ~75-85 triggers/day, ~50-60 heartbeats/day');

    // Configure the plugin for SMART PRESENCE DETECTION
    await bg.BackgroundGeolocation.ready(
      bg.Config(
        // ═══════════════════════════════════════════════════
        // 🎯 CORE STRATEGY: Motion-Based Tracking
        // ═══════════════════════════════════════════════════
        // WHY: We want to detect "significant places" (where user spends time)
        // NOT periodic pings regardless of context

        // 1. DISTANCE FILTER - Reduces GPS drift noise
        // CONFIG #2 OPTIMIZED: 200m → 300m (+50%)
        // WHY: Less sensitive to movement = fewer triggers (Target: 75-85/day)
        // IMPACT: Reduces movement-based triggers by ~20-25%
        distanceFilter: 300.0, // meters (was 200.0)
        // 2. STATIONARY RADIUS - Geofence around stopped location
        // CONFIG #2 OPTIMIZED: 100m → 150m (+50%)
        // WHY: Larger buffer = fewer GPS drift wake-ups
        // IMPACT: Reduces GPS drift triggers by ~15-20%
        stationaryRadius: 150, // meters (was 100)
        // 3. STOP TIMEOUT - Time before considering "stationary"
        // CONFIG #2 OPTIMIZED: 5 min → 8 min (+60%)
        // WHY: Must stay still longer to count as "significant place"
        // IMPACT: Filters out more quick stops
        stopTimeout: 8, // minutes (was 5)
        // 4. DISABLE ELASTICITY - Don't auto-adjust distance filter
        // WHY: Plugin normally reduces distanceFilter when stationary. We want consistent behavior.
        // IMPACT: Predictable wake-up behavior, easier to optimize
        disableElasticity: true,

        // ═══════════════════════════════════════════════════
        // 🚗 TRAVEL SUPPRESSION: Activity Recognition
        // ═══════════════════════════════════════════════════
        // WHY: Don't send heartbeats during commutes/driving

        // 5. ACTIVITY RECOGNITION - Detect travel modes
        // CONFIG #2 OPTIMIZED: 1 min → 2 min (+100%)
        // WHY: Check activity half as often
        // IMPACT: Reduces activity check triggers by 50%
        activityRecognitionInterval: 120000, // 2 minutes (was 60000)
        // ═══════════════════════════════════════════════════
        // ⏰ HEARTBEAT BACKUP: Ensure regular updates
        // ═══════════════════════════════════════════════════
        // WHY: Even if user doesn't move, send heartbeat every 15 min

        // 6. HEARTBEAT INTERVAL - Safety net for long stays
        // WHY: Ensures at least one heartbeat every 15 min when stationary
        // IMPACT: User at home for 8h = 32 heartbeats (8*60/15)
        heartbeatInterval: heartbeatSeconds, // 900 seconds = 15 minutes
        // ═══════════════════════════════════════════════════
        // 🔋 ACCURACY SETTINGS: Balance accuracy vs battery
        // ═══════════════════════════════════════════════════

        // 7. DESIRED ACCURACY - Reduced for battery optimization
        // CONFIG #2 OPTIMIZED: MEDIUM → LOW (BIGGEST BATTERY SAVE!)
        // WHY: LOW uses GPS sparingly, relies more on cell towers + WiFi
        // IMPACT: 🔋 **30-40% battery savings** - Major optimization!
        desiredAccuracy: bg.Config.DESIRED_ACCURACY_LOW, // (was MEDIUM)
        // ═══════════════════════════════════════════════════
        // 📱 ANDROID-SPECIFIC: Location Update Intervals
        // ═══════════════════════════════════════════════════

        // 8. LOCATION UPDATE INTERVAL - Fallback for Android
        // CONFIG #2 OPTIMIZED: 15 min → 20 min (+33%)
        // WHY: Android FusedLocation API less frequent
        // IMPACT: Reduces Android-specific triggers
        locationUpdateInterval: 1200000, // 20 minutes (was 900000)
        // 9. FASTEST UPDATE INTERVAL - Minimum threshold
        // CONFIG #2 OPTIMIZED: 5 min → 10 min (+100%)
        // WHY: Higher minimum threshold between updates
        // IMPACT: Prevents rapid-fire location updates
        fastestLocationUpdateInterval: 600000, // 10 min (was 300000)
        // ═══════════════════════════════════════════════════
        // 🔥 BACKGROUND OPERATION
        // ═══════════════════════════════════════════════════
        stopOnTerminate: false, // Keep tracking when app closed
        startOnBoot: true, // Resume after phone restart
        foregroundService: true, // Required for Android background
        enableHeadless: true, // Critical for background operation
        // iOS specific
        pausesLocationUpdatesAutomatically: false,
        activityType: bg.Config.ACTIVITY_TYPE_OTHER,

        // Notification
        notification: bg.Notification(
          title: "Smart Presence Detection",
          text: "Tracking significant places (15min heartbeat)",
          color: "#4CAF50",
          smallIcon: "drawable/ic_launcher",
          largeIcon: "drawable/ic_launcher",
        ),

        // Debug
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

    print('✅ Background Geolocation initialized with 15-min heartbeat');
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

  void _onLocation(bg.Location location) {
    _totalTriggers++; // Count every wake-up
    _saveTriggerCount(); // Persist to SharedPreferences
    _increment24hTriggers(); // Persist 24h stats

    print('🔔 TRIGGER #$_totalTriggers: Location event');
    print(
      '   📍 Coords: ${location.coords.latitude}, ${location.coords.longitude}',
    );
    print('   🏃 isMoving: ${location.isMoving}');
    print('   ⚡ speed: ${location.coords.speed ?? 0} m/s');
    print('   🎯 activity: $_currentActivity');
    print('   🚗 traveling: $_isTraveling');

    // ═══════════════════════════════════════════════════
    // SMART HEARTBEAT LOGIC - Decide if should send
    // ═══════════════════════════════════════════════════

    // CHECK 1: Don't send if traveling
    if (_isTraveling) {
      print('   ❌ SKIP: User is traveling');
      return;
    }

    // CHECK 2: Don't send if moving
    if (location.isMoving) {
      print('   ❌ SKIP: User is moving');
      return;
    }

    // CHECK 3: Don't send if high speed (>2 m/s = ~7 km/h)
    final speed = location.coords.speed ?? 0.0;
    if (speed > 2.0) {
      print('   ❌ SKIP: Speed too high (${speed.toStringAsFixed(1)} m/s)');
      return;
    }

    // CHECK 4: Don't send if last heartbeat was < 15 min ago
    final timeSinceLastHeartbeat = DateTime.now().difference(
      _lastHeartbeatTime,
    );
    if (timeSinceLastHeartbeat.inMinutes < 15) {
      print(
        '   ❌ SKIP: Last heartbeat was ${timeSinceLastHeartbeat.inMinutes} min ago',
      );
      return;
    }

    // ✅ ALL CHECKS PASSED - Send heartbeat!
    print('   ✅ SEND HEARTBEAT: User at significant place');
    _sendHeartbeat(location);
  }

  void _sendHeartbeat(bg.Location location) {
    _totalHeartbeats++;
    _lastHeartbeatTime = DateTime.now();
    _saveHeartbeatCount(); // Persist to SharedPreferences
    _saveHeartbeatTime(); // Persist heartbeat time
    _increment24hHeartbeats(); // Persist 24h stats

    print('💓 HEARTBEAT #$_totalHeartbeats sent');
    print(
      '   📊 Efficiency: $_totalHeartbeats heartbeats / $_totalTriggers triggers = ${(_totalHeartbeats / _totalTriggers * 100).toStringAsFixed(1)}%',
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

    // TODO: Send to backend server here
    // await http.post(yourServerUrl, body: locationData);
  }

  void _onMotionChange(bg.Location location) {
    _totalTriggers++;
    _saveTriggerCount(); // Persist to SharedPreferences
    _increment24hTriggers(); // Persist 24h stats

    final isMoving = location.isMoving;
    print(
      '🔔 TRIGGER #$_totalTriggers: Motion change → ${isMoving ? "MOVING" : "STATIONARY"}',
    );
    print('   🚗 traveling: $_isTraveling');

    // ═══════════════════════════════════════════════════
    // MOTION CHANGE LOGIC
    // ═══════════════════════════════════════════════════
    // WHY: This fires when user starts/stops moving
    // KEY INSIGHT: When user STOPS, they've arrived at a significant place!

    if (!isMoving && !_isTraveling) {
      // User just became stationary (not traveling)
      // This is a HIGH CONFIDENCE event - user arrived somewhere!
      print('   ✅ IMMEDIATE HEARTBEAT: User arrived at location');
      _sendHeartbeat(location);
    } else if (isMoving) {
      print('   ℹ️  User started moving - will send heartbeat when they stop');
    } else {
      print('   ❌ SKIP: User stationary but traveling mode detected');
    }
  }

  void _onActivityChange(bg.ActivityChangeEvent event) async {
    _totalTriggers++;
    _saveTriggerCount(); // Persist to SharedPreferences
    _increment24hTriggers(); // Persist 24h stats

    print('🔔 TRIGGER #$_totalTriggers: Activity change');
    print(
      '   🎯 Activity: ${event.activity} (confidence: ${event.confidence}%)',
    );

    setState(() {
      _currentActivity = event.activity;
    });
    _saveActivityState(event.activity); // Persist activity

    ref.read(currentActivityProvider.notifier).state = event.activity;

    // ═══════════════════════════════════════════════════
    // TRAVEL DETECTION - Adjust behavior dynamically
    // ═══════════════════════════════════════════════════
    // WHY: Suppress heartbeats and reduce wake-ups during travel

    final wasTraveling = _isTraveling;

    // Detect if user is traveling (high confidence required)
    if ((event.activity == 'in_vehicle' || event.activity == 'on_bicycle') &&
        event.confidence > 70) {
      _isTraveling = true;
      _saveTravelingState(true); // Persist traveling state

      if (!wasTraveling) {
        print('   🚗 TRAVEL MODE ACTIVATED');
        print('   ⚙️  Increasing distanceFilter to 500m to reduce wake-ups');

        // Increase distance filter during travel
        // WHY: Reduces wake-ups from ~200 to ~50 during 1h commute
        await bg.BackgroundGeolocation.setConfig(
          bg.Config(
            distanceFilter: 500.0, // 500m - only wake on significant movement
            desiredAccuracy: bg.Config.DESIRED_ACCURACY_LOW, // Save battery
          ),
        );
      }
    } else {
      _isTraveling = false;
      _saveTravelingState(false); // Persist traveling state

      if (wasTraveling) {
        print('   🏠 PRESENCE MODE ACTIVATED');
        print('   ⚙️  Restoring distanceFilter to 300m for presence detection');

        // Restore normal settings for presence detection
        await bg.BackgroundGeolocation.setConfig(
          bg.Config(
            distanceFilter: 300.0, // 300m - normal sensitivity (Config #2)
            desiredAccuracy: bg.Config.DESIRED_ACCURACY_LOW, // Config #2
          ),
        );
      }
    }
  }

  void _onHeartbeat(bg.HeartbeatEvent event) async {
    _totalTriggers++;
    _saveTriggerCount(); // Persist to SharedPreferences
    _increment24hTriggers(); // Persist 24h stats

    print('🔔 TRIGGER #$_totalTriggers: Heartbeat (15-min backup)');
    print('   🚗 traveling: $_isTraveling');

    // ═══════════════════════════════════════════════════
    // HEARTBEAT LOGIC - Backup for long stationary periods
    // ═══════════════════════════════════════════════════
    // WHY: Ensures at least one heartbeat every 15 min when stationary
    // EXAMPLE: User at home for 3h = 12 heartbeats

    // Don't send if traveling
    if (_isTraveling) {
      print('   ❌ SKIP: User is traveling');
      return;
    }

    try {
      final location = await bg.BackgroundGeolocation.getCurrentPosition(
        samples: 1,
        persist: false,
        timeout: 30,
      );

      print('   ✅ SEND HEARTBEAT: Stationary backup ping');
      _sendHeartbeat(location);
    } catch (e) {
      print('   ❌ Error getting position: $e');
    }
  }

  Future<void> _startTracking() async {
    try {
      final state = await bg.BackgroundGeolocation.start();
      print('🟢 Smart presence tracking started!');
      print('📱 App can be closed - tracking will continue');
      print('🔔 You should see a persistent notification');
      print('⏱️ 15-min heartbeat backup + motion-based tracking');
      ref.read(isTrackingProvider.notifier).state = true;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              '✓ Smart presence detection started!\nMotion-based + 15-min heartbeat backup',
            ),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 4),
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

    // Calculate 24h stats efficiency
    final efficiency24h = _triggers24h > 0
        ? (_heartbeats24h / _triggers24h * 100).toStringAsFixed(0)
        : '0';

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
                  'Motion-based + 15-min heartbeat',
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
                    '${locations.length} heartbeats sent',
                    style: TextStyle(
                      color: Colors.deepPurple.shade700,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Session: ${_totalTriggers > 0 ? (_totalHeartbeats / _totalTriggers * 100).toStringAsFixed(0) : 0}% ($_totalHeartbeats/$_totalTriggers)',
                    style: TextStyle(
                      color: Colors.amber.shade900,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Last 24h: $efficiency24h% ($_heartbeats24h/$_triggers24h)',
                        style: TextStyle(
                          color: Colors.green.shade900,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () async {
                          await _reset24hStats();
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('✓ 24h stats reset'),
                                backgroundColor: Colors.green,
                                duration: Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.refresh,
                            size: 16,
                            color: Colors.green.shade700,
                          ),
                        ),
                      ),
                    ],
                  ),
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
                      'Heartbeats sent only at significant places (15-min backup)',
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
