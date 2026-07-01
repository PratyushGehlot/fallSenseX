import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'dart:async';
import '../models/radar_models.dart';
import 'live_monitor_page.dart';
import 'package:fall_sense_x_mobile/services/notification_service.dart';
import 'package:fall_sense_x_mobile/services/auth_service.dart';
import 'package:fall_sense_x_mobile/services/ota_service.dart';
import '../theme/app_theme.dart';
import 'device_settings_page.dart';
import 'detection_trends_page.dart';

class DashboardPage extends StatefulWidget {
  final String deviceId;
  const DashboardPage({super.key, required this.deviceId});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late final DatabaseReference _framesRef;
  late final DatabaseReference _onlineRef;
  
  List<Map<String, dynamic>> _frames = [];
  StreamSubscription<DatabaseEvent>? _subscription;
  StreamSubscription<DatabaseEvent>? _onlineSubscription;
  double? _latestTemperature;

  bool _isDeviceOnline = true;
  bool _wasOnline = true;
  DateTime? _lastHeartbeatTime;
  // Must comfortably exceed the firmware's worst-case heartbeat gap: a
  // single retry backoff cycle (heartbeat_backoff_ms in
  // fall_sense_x_main.c) can push the next heartbeat out to 60s after one
  // transient failure, even though the device is still actually online.
  static const Duration OFFLINE_TIMEOUT = Duration(seconds: 75);

  final double _roomLength = 10.0;
  final double _roomWidth = 10.0;
  final double _roomHeight = 8.0;

  @override
  void initState() {
    super.initState();
    _framesRef = FirebaseDatabase.instance.ref('devices/${widget.deviceId}/frames');
    _onlineRef = FirebaseDatabase.instance.ref('devices/${widget.deviceId}/online');
    _startRealTimeUpdates();
    _startOnlineMonitoring();
    NotificationService.requestPermissions();

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('Notification tapped: ${message.notification?.title}');
    });

    FirebaseMessaging.instance.getInitialMessage().then((RemoteMessage? message) {
      if (message != null) {
        debugPrint('App opened from notification: ${message.notification?.title}');
      }
    });

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      NotificationService.showNotification(
        title: message.notification?.title ?? 'FallSenseX',
        body: message.notification?.body ?? '',
        notificationId: message.messageId.hashCode,
      );
    });

    _subscribeToDeviceAlerts();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _onlineSubscription?.cancel();
    super.dispose();
  }

  /// Skips subscribing if the user explicitly muted fall alerts for this
  /// device (device_alerts_page.dart / notification_settings_page.dart) -
  /// otherwise just opening the dashboard would silently re-subscribe a
  /// device the user had muted.
  Future<void> _subscribeToDeviceAlerts() async {
    try {
      final prefSnapshot = await FirebaseDatabase.instance.ref('devices/${widget.deviceId}/alertPrefs/fallAlerts').get();
      if (prefSnapshot.exists && prefSnapshot.value == false) {
        debugPrint('Skipping alert subscription for ${widget.deviceId} - muted by user');
        return;
      }
      await FirebaseMessaging.instance.subscribeToTopic('device_${widget.deviceId}_alerts');
      debugPrint('Subscribed to device_${widget.deviceId}_alerts topic');
    } catch (e) {
      debugPrint('Failed to subscribe to topic: $e');
    }
  }

  void _startRealTimeUpdates() {
    _subscription = _framesRef.onValue.listen((DatabaseEvent event) {
      if (!mounted) return;
      final data = event.snapshot.value;
      if (data != null) {
        List<Map<String, dynamic>> frames = [];
        if (data is Map) {
          data.forEach((key, value) {
            if (value is Map) {
              Map<String, dynamic> frame = {};
              value.forEach((k, v) {
                frame[k.toString()] = v;
              });
              frame['id'] = key.toString();
              frames.add(frame);
            }
          });
          frames.sort((a, b) {
            final aTime = (a['timestamp'] as num?)?.toInt() ?? (a['timestamp_ms'] as num?)?.toInt() ?? 0;
            final bTime = (b['timestamp'] as num?)?.toInt() ?? (b['timestamp_ms'] as num?)?.toInt() ?? 0;
            return aTime.compareTo(bTime);
          });
        }
        setState(() {
          _frames = frames;
          if (frames.isNotEmpty) {
            final latestFrame = frames.last;
            final temp = latestFrame['temperature'];
            if (temp != null) {
              _latestTemperature = (temp as num).toDouble();
            }
          }
        });
      } else {
        setState(() {
          _frames = [];
          _latestTemperature = null;
        });
      }
    }, onError: (error) {
      debugPrint('Error listening to frames: $error');
    });
  }

  void _startOnlineMonitoring() {
    _onlineSubscription?.cancel();
    _onlineSubscription = _onlineRef.onValue.listen((DatabaseEvent event) {
      if (!mounted) return;
      final data = event.snapshot.value;
      bool isOnline = false;

      if (data is Map) {
        final timestamp = data['timestamp'];
        final value = data['value'];

        if (timestamp != null) {
          final ts = (timestamp as num).toInt();
          _lastHeartbeatTime = DateTime.fromMillisecondsSinceEpoch(ts * 1000);

          if (value == true) {
            final now = DateTime.now();
            isOnline = now.difference(_lastHeartbeatTime!) < OFFLINE_TIMEOUT;
          } else {
            isOnline = false;
          }
        }
      } else {
        isOnline = false;
      }

      setState(() {
        _isDeviceOnline = isOnline;
      });

      _handleOnlineStatusChange(isOnline);
    }, onError: (error) {
      debugPrint('Error listening to online status: $error');
      setState(() {
        _isDeviceOnline = false;
      });
    });
  }

  void _handleOnlineStatusChange(bool isOnline) {
    final wentOffline = !isOnline && _wasOnline;
    _wasOnline = isOnline;
    if (wentOffline) {
      _maybeShowOfflineNotification();
    }
  }

  /// Respects the "Offline Alerts" toggle in notification_settings_page.dart
  /// - defaults to on (matches that page's default) if the user has never
  /// visited Notification Settings.
  Future<void> _maybeShowOfflineNotification() async {
    final uid = AuthService().currentUser()?.uid;
    if (uid != null) {
      final snapshot = await FirebaseDatabase.instance.ref('users/$uid/notificationPrefs/offlineAlerts').get();
      if (snapshot.exists && snapshot.value == false) return;
    }
    NotificationService.showNotification(
      title: 'Device Offline',
      body: 'FallSenseX device is not responding. Check power and internet connection.',
      notificationId: 9999,
    );
  }

  /// 2D/3D View both open the unified LiveMonitorPage (pill-toggle screen
  /// matching the premium reference), just defaulting to a different tab.
  void _navigateTo3DView() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => LiveMonitorPage(
          deviceId: widget.deviceId,
          initialTab: 1,
          roomLengthFt: _roomLength,
          roomWidthFt: _roomWidth,
          roomHeightFt: _roomHeight,
        ),
      ),
    );
  }

  void _navigateTo2DView() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => LiveMonitorPage(
          deviceId: widget.deviceId,
          initialTab: 0,
          roomLengthFt: _roomLength,
          roomWidthFt: _roomWidth,
          roomHeightFt: _roomHeight,
        ),
      ),
    );
  }

  String _getPostureEmoji(String? posture) {
    switch (posture?.toUpperCase()) {
      case 'STANDING':
        return '🧍';
      case 'SITTING':
        return '🪑';
      case 'LYING':
        return '🛏️';
      case 'SLEEPING':
        return '😴';
      case 'NO_PRESENCE':
        return '⭕';
      default:
        return '❓';
    }
  }

  String _formatTimestamp(dynamic timestamp) {
    if (timestamp == null || timestamp == 'N/A') return 'N/A';
    final ts = (timestamp as num).toInt();
    final tsMs = ts > 10000000000 ? ts : ts * 1000;
    final dt = DateTime.fromMillisecondsSinceEpoch(tsMs);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')} ${dt.day}.${dt.month.toString().padLeft(2, '0')}.${(dt.year % 100).toString().padLeft(2, '0')}';
  }

  Color _getPostureColor(String? posture) {
    switch (posture?.toUpperCase()) {
      case 'STANDING':
        return Colors.green;
      case 'SITTING':
        return Colors.blue;
      case 'LYING':
        return Colors.orange;
      case 'SLEEPING':
        return Colors.purple;
      case 'FALL':
        return Colors.red;
      case 'NO_PRESENCE':
        return Colors.grey;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Expanded(child: Text('Device: ${widget.deviceId}')),
            const SizedBox(width: 8),
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isDeviceOnline ? Colors.green : Colors.red,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ],
        ),
        // 2D/3D view, Replay and Configure Room are all reachable from
        // inside LiveMonitorPage (opened by the 3D View icon below), and
        // signing out already lives in the Settings tab - so the only two
        // actions that need to stay here are 3D View and Device Settings.
        actions: [
          IconButton(
            icon: const Icon(Icons.view_in_ar),
            onPressed: _navigateTo3DView,
            tooltip: '3D View',
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => DeviceSettingsPage(deviceId: widget.deviceId)),
            ),
            tooltip: 'Device Settings',
          ),
        ],
      ),
      body: !_isDeviceOnline
          ? _buildOfflineScreen()
          : _frames.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildDeviceIdentityHeader(),
                      const SizedBox(height: 16),
                      _buildSystemStatusCard(),
                      const SizedBox(height: 16),
                      _buildLiveViewCard(_frames.isNotEmpty ? _frames.last : null),
                      if (_frames.isNotEmpty)
                        Theme(
                          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                          child: ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: const Text('Detection Details', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                            children: [_buildLatestFrameCard(_frames.last)],
                          ),
                        ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Recent Events', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                          TextButton(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => DetectionTrendsPage(deviceId: widget.deviceId)),
                            ),
                            child: const Text('View All'),
                          ),
                        ],
                      ),
                      Expanded(
                        child: Scrollbar(
                          child: ListView.builder(
                            padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
                            itemCount: _frames.length,
                            itemBuilder: (context, index) {
                              final frame = _frames[_frames.length - 1 - index];
                              return _buildFrameCard(frame, index);
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _buildOfflineScreen() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.wifi_off, size: 80, color: Colors.red[300]),
          const SizedBox(height: 24),
          Text(
            'Device Offline',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.red[300],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'The FallSenseX device is not responding.',
            style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => _startOnlineMonitoring(),
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  /// Device identity block mirroring the premium reference's Device Page
  /// header: thumbnail, name, mount description, and online status dot.
  Widget _buildDeviceIdentityHeader() {
    return Row(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            gradient: AppColors.heroGradient,
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(Icons.sensors, color: Colors.white, size: 28),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.deviceId, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              const Text('Ceiling Mount · Live Monitoring', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              const SizedBox(height: 4),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isDeviceOnline ? AppColors.statusOnline : AppColors.statusOffline,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _isDeviceOnline ? 'Device Online' : 'Device Offline',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _isDeviceOnline ? AppColors.statusOnline : AppColors.statusOffline,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// "Live View" card mirroring the premium reference: since FallSenseX is a
  /// radar sensor with no camera, there's no real photo feed - this shows an
  /// abstract radar-sweep graphic in the same layout (image area + status
  /// pills) rather than pretending to be a literal camera preview.
  Widget _buildLiveViewCard(Map<String, dynamic>? latestFrame) {
    final detections = latestFrame != null ? humanDetectionsFromFrameMap(latestFrame) : <HumanDetection>[];
    final present = latestFrame?['present'] as bool? ?? false;
    final posture = detections.isNotEmpty ? detections.first.posture : null;
    final hasFallen = detections.any((d) => d.posture.toUpperCase() == 'FALL');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Live View', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.statusOnline),
                ),
                const SizedBox(width: 4),
                const Text('Updated just now', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 3,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: _navigateTo2DView,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      height: 180,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Illustrative room photo, not the device's actual
                          // camera feed (the sensor is radar-only, no
                          // camera) - the figure overlay reflects the real
                          // latest detection's posture/presence though.
                          Image.asset('assets/images/live_view_placeholder.jpg', fit: BoxFit.cover),
                          if (present)
                            Center(
                              child: Icon(
                                Icons.accessibility_new,
                                size: 72,
                                color: hasFallen ? AppColors.statusFall : AppColors.accent,
                              ),
                            ),
                          Positioned(
                            left: 10,
                            bottom: 10,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(10)),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(width: 6, height: 6, decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.statusOnline)),
                                  const SizedBox(width: 5),
                                  const Text('Live', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          ),
                          Positioned(
                            right: 10,
                            bottom: 10,
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.92), shape: BoxShape.circle),
                              child: const Icon(Icons.open_in_full, size: 14, color: AppColors.textPrimary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: Column(
                  children: [
                    Expanded(
                      child: _buildLiveViewChip(
                        Icons.accessibility_new,
                        AppColors.statusOnline,
                        present ? (posture ?? 'Standing') : 'No One',
                        present ? 'Good Posture' : 'Detected',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: _buildLiveViewChip(
                        Icons.shield_outlined,
                        hasFallen ? AppColors.statusFall : AppColors.accent,
                        hasFallen ? 'Fall' : 'No Fall',
                        'Detected',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: _buildLiveViewChip(Icons.favorite_border, AppColors.accent, 'Normal', 'Activity'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLiveViewChip(IconData icon, Color color, String title, String subtitle) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(subtitle, style: const TextStyle(fontSize: 9, color: AppColors.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// "System Status" hero card mirroring the premium reference's Device
  /// Page: All Good / person-detected summary plus quick capability chips.
  Widget _buildSystemStatusCard() {
    final detections = _frames.isNotEmpty ? humanDetectionsFromFrameMap(_frames.last) : <HumanDetection>[];
    final hasFallen = detections.any((d) => d.posture.toUpperCase() == 'FALL');
    final present = _frames.isNotEmpty && (_frames.last['present'] as bool? ?? false);
    final allGood = !hasFallen;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: allGood ? AppColors.accentLight : AppColors.statusFall.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(
                allGood ? Icons.check_circle : Icons.warning_amber_rounded,
                color: allGood ? AppColors.statusOnline : AppColors.statusFall,
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      allGood ? 'All Good' : 'Fall Detected',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: allGood ? AppColors.statusOnline : AppColors.statusFall,
                      ),
                    ),
                    Text('Monitoring is active', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Icon(Icons.people_outline, size: 18, color: AppColors.textSecondary),
                  Text(present ? '${detections.length}' : '0', style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _buildCapabilityChip(Icons.accessibility_new, 'Posture Tracking', _isDeviceOnline ? 'Active' : 'Idle'),
            const SizedBox(width: 8),
            _buildCapabilityChip(Icons.directions_run, 'Fall Detection', _isDeviceOnline ? 'Active' : 'Idle'),
            const SizedBox(width: 8),
            _buildCapabilityChip(Icons.notifications_active_outlined, 'Alerts', 'Enabled'),
          ],
        ),
      ],
    );
  }

  Widget _buildCapabilityChip(IconData icon, String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE5E5EA)),
        ),
        child: Column(
          children: [
            Icon(icon, size: 18, color: AppColors.accent),
            const SizedBox(height: 4),
            Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
            Text(value, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _buildLatestFrameCard(Map<String, dynamic> frame) {
    final present = frame['present'] as bool? ?? false;
    final detections = humanDetectionsFromFrameMap(frame);
    final timestamp = frame['timestamp'] ?? frame['timestamp_ms'] ?? 'N/A';
    final formattedTimestamp = _formatTimestamp(timestamp);
    final headerPosture = detections.isNotEmpty ? detections.first.posture : 'Unknown';

    return Card(
      color: _getPostureColor(headerPosture).withOpacity(0.1),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(_getPostureEmoji(headerPosture), style: const TextStyle(fontSize: 32)),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    present
                        ? '${detections.length} ${detections.length == 1 ? 'person' : 'people'} detected'
                        : 'No one present',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: present ? Colors.green : Colors.red,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final d in detections) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${d.posture} (#${d.id})',
                      style: TextStyle(fontWeight: FontWeight.bold, color: _getPostureColor(d.posture)),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.deepPurple.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Conf: ${(d.confidence * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _buildInfoChip('Velocity', '${d.velocity.toStringAsFixed(2)} m/s', Icons.speed),
                  const SizedBox(width: 12),
                  _buildInfoChip('Position',
                      '(${(d.x * 3.28084).toStringAsFixed(1)}, ${(d.y * 3.28084).toStringAsFixed(1)}) ft',
                      Icons.location_on),
                ],
              ),
              const SizedBox(height: 8),
            ],
            if (_latestTemperature != null)
              Row(
                children: [
                  _buildInfoChip('Temperature', '${_latestTemperature!.toStringAsFixed(1)}°C', Icons.thermostat),
                ],
              ),
            const SizedBox(height: 4),
            Text(
              'Timestamp: $formattedTimestamp',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  /// Recent-events row styled like the premium reference: a colored
  /// check/info/warning icon circle, title + "time · context" subtitle.
  Widget _buildFrameCard(Map<String, dynamic> frame, int index) {
    final present = frame['present'] as bool? ?? false;
    final detections = humanDetectionsFromFrameMap(frame);
    final timestamp = frame['timestamp'] ?? frame['timestamp_ms'] ?? 'N/A';
    final formattedTimestamp = _formatTimestamp(timestamp);
    final hasFallen = detections.any((d) => d.posture.toUpperCase() == 'FALL');

    final String title;
    final IconData icon;
    final Color color;
    if (hasFallen) {
      title = 'Fall Detected';
      icon = Icons.warning_amber_rounded;
      color = AppColors.statusFall;
    } else if (present) {
      title = 'Person Detected';
      icon = Icons.info_outline;
      color = AppColors.statusPresence;
    } else {
      title = 'Normal Activity';
      icon = Icons.check_circle_outline;
      color = AppColors.statusOnline;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: color.withValues(alpha: 0.12),
          child: Icon(icon, size: 16, color: color),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        subtitle: Text(formattedTimestamp, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
      ),
    );
  }

  Widget _buildInfoChip(String label, String value, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.grey.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: Colors.grey[700]),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
                  Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet showing current vs latest firmware version, an "Update Now"
/// button, and a live progress view once an update has been triggered
/// (driven by /devices/{deviceId}/ota_status). Shared by dashboard_page.dart
/// and device_settings_page.dart's Firmware Version tile.
class OtaUpdateSheet extends StatefulWidget {
  final String deviceId;
  final String currentVersion;
  final String? latestVersion;
  final String? latestUrl;
  final bool updateAvailable;

  const OtaUpdateSheet({
    required this.deviceId,
    required this.currentVersion,
    required this.latestVersion,
    required this.latestUrl,
    required this.updateAvailable,
  });

  @override
  State<OtaUpdateSheet> createState() => _OtaUpdateSheetState();
}

class _OtaUpdateSheetState extends State<OtaUpdateSheet> {
  StreamSubscription<DatabaseEvent>? _statusSubscription;
  String? _state;
  int _progress = 0;
  String? _error;
  bool _updateTriggered = false;

  @override
  void dispose() {
    _statusSubscription?.cancel();
    super.dispose();
  }

  void _startWatchingStatus() {
    _statusSubscription?.cancel();
    _statusSubscription = OtaService.statusRef(widget.deviceId).onValue.listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value;
      if (data is Map) {
        setState(() {
          _state = data['state']?.toString();
          _progress = (data['progress'] as num?)?.toInt() ?? 0;
          _error = (data['error']?.toString().isNotEmpty ?? false) ? data['error'].toString() : null;
        });
      }
    });
  }

  Future<void> _triggerUpdate() async {
    if (widget.latestUrl == null || widget.latestVersion == null) {
      return;
    }
    setState(() => _updateTriggered = true);
    _startWatchingStatus();
    try {
      await OtaService.triggerUpdate(widget.deviceId, widget.latestUrl!, widget.latestVersion!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start update: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final showProgress = _updateTriggered && _state != null && _state != 'idle';

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Firmware Update', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Text('Current version: ${widget.currentVersion}'),
          const SizedBox(height: 4),
          Text(
            widget.latestVersion != null
                ? 'Latest available: ${widget.latestVersion}'
                : 'No firmware manifest available',
            style: TextStyle(color: widget.updateAvailable ? Colors.green : Colors.grey),
          ),
          const SizedBox(height: 20),
          if (showProgress) ...[
            LinearProgressIndicator(value: _progress / 100),
            const SizedBox(height: 8),
            Text(_error != null ? 'Failed: $_error' : '${_state ?? ''} (${_progress}%)'),
          ] else if (widget.updateAvailable)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _triggerUpdate,
                child: const Text('Update Now'),
              ),
            )
          else
            const Text('Your device is up to date.'),
        ],
      ),
    );
  }
}