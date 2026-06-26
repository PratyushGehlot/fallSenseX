import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'dart:async';
import '../models/radar_models.dart';
import '../widgets/room_3d_view.dart' as view2d;
import '../widgets/radar_3d_visualization.dart' as view3d;
import '../widgets/room_3d_replay.dart';
import 'live_3d_view_page.dart';
import 'package:fall_sense_x_mobile/services/notification_service.dart';
import 'package:fall_sense_x_mobile/services/auth_service.dart';
import 'package:fall_sense_x_mobile/services/ota_service.dart';

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

  double _roomLength = 10.0;
  double _roomWidth = 10.0;
  double _roomHeight = 8.0;

  StreamSubscription<DatabaseEvent>? _infoSubscription;
  StreamSubscription<DatabaseEvent>? _manifestSubscription;
  String? _currentFirmwareVersion;
  String _deviceModel = 'fallsensex';
  String? _latestFirmwareVersion;
  String? _latestFirmwareUrl;

  bool get _updateAvailable =>
      _currentFirmwareVersion != null &&
      _latestFirmwareVersion != null &&
      OtaService.compareVersions(_latestFirmwareVersion!, _currentFirmwareVersion!) > 0;

  @override
  void initState() {
    super.initState();
    _framesRef = FirebaseDatabase.instance.ref('devices/${widget.deviceId}/frames');
    _onlineRef = FirebaseDatabase.instance.ref('devices/${widget.deviceId}/online');
    _startRealTimeUpdates();
    _startOnlineMonitoring();
    _startFirmwareVersionMonitoring();
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
    _infoSubscription?.cancel();
    _manifestSubscription?.cancel();
    super.dispose();
  }

  void _startFirmwareVersionMonitoring() {
    _infoSubscription = OtaService.infoRef(widget.deviceId).onValue.listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value;
      if (data is Map) {
        final version = data['firmwareVersion']?.toString();
        final model = data['deviceModel']?.toString();
        setState(() {
          _currentFirmwareVersion = version;
          if (model != null && model.isNotEmpty) {
            _deviceModel = model;
          }
        });
        _manifestSubscription?.cancel();
        _manifestSubscription = OtaService.manifestRef(_deviceModel).onValue.listen((manifestEvent) {
          if (!mounted) return;
          final manifest = manifestEvent.snapshot.value;
          if (manifest is Map) {
            setState(() {
              _latestFirmwareVersion = manifest['version']?.toString();
              _latestFirmwareUrl = manifest['url']?.toString();
            });
          }
        });
      }
    });
  }

  void _showOtaSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _OtaUpdateSheet(
        deviceId: widget.deviceId,
        currentVersion: _currentFirmwareVersion ?? 'unknown',
        latestVersion: _latestFirmwareVersion,
        latestUrl: _latestFirmwareUrl,
        updateAvailable: _updateAvailable,
      ),
    );
  }

  Future<void> _subscribeToDeviceAlerts() async {
    try {
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
      NotificationService.showNotification(
        title: 'Device Offline',
        body: 'FallSenseX device is not responding. Check power and internet connection.',
        notificationId: 9999,
      );
    }
  }

  void _navigateTo3DView() {
    List<view3d.HumanDetection> detections = [];

    if (_frames.isNotEmpty) {
      final latestFrame = _frames.last;
      final present = latestFrame['present'] as bool? ?? false;

      if (present) {
        final roomLenM = _roomLength / 3.28084;
        final roomWidM = _roomWidth / 3.28084;

        for (final d in humanDetectionsFromFrameMap(latestFrame)) {
          final cornerX = d.x + roomLenM / 2.0;
          final cornerY = d.y + roomWidM / 2.0;

          detections.add(view3d.HumanDetection(
            id: d.id,
            x: cornerX,
            y: d.z,
            z: cornerY,
            width: 0.6,
            height: 1.8,
            depth: 0.4,
            posture: d.posture,
            confidence: d.confidence,
            velocity: d.velocity,
          ));
        }
      }
    }

    final roomLengthMeters = _roomLength / 3.28084;
    final roomWidthMeters = _roomWidth / 3.28084;
    final roomHeightMeters = _roomHeight / 3.28084;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Live3DViewPage(
          deviceId: widget.deviceId,
          cloudDetections: detections,
          roomLengthM: roomLengthMeters,
          roomWidthM: roomWidthMeters,
          roomHeightM: roomHeightMeters,
        ),
      ),
    );
  }

  void _navigateTo2DView() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => view2d.Room3DView(
          frames: _frames,
          roomLength: _roomLength,
          roomWidth: _roomWidth,
          roomHeight: _roomHeight,
          framesRef: _framesRef,
        ),
      ),
    );
  }

  void _navigateToReplay() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Room3DReplay(
          deviceId: widget.deviceId,
          roomLength: _roomLength,
          roomWidth: _roomWidth,
          roomHeight: _roomHeight,
        ),
      ),
    );
  }

  void _showRoomConfigDialog() {
    final lengthController = TextEditingController(text: _roomLength.toString());
    final widthController = TextEditingController(text: _roomWidth.toString());
    final heightController = TextEditingController(text: _roomHeight.toString());

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Room Configuration (feet)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: lengthController,
              decoration: const InputDecoration(labelText: 'Length (X)'),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: widthController,
              decoration: const InputDecoration(labelText: 'Width (Y)'),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: heightController,
              decoration: const InputDecoration(labelText: 'Height (Z)'),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _roomLength = double.tryParse(lengthController.text) ?? _roomLength;
                _roomWidth = double.tryParse(widthController.text) ?? _roomWidth;
                _roomHeight = double.tryParse(heightController.text) ?? _roomHeight;
              });
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
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

  Future<void> _signOut() async {
    await AuthService().signOut();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
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
        actions: [
          IconButton(
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.system_update),
                if (_updateAvailable)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            onPressed: _showOtaSheet,
            tooltip: _updateAvailable ? 'Update available' : 'Firmware version',
          ),
          IconButton(
            icon: const Icon(Icons.view_in_ar),
            onPressed: _navigateTo3DView,
            tooltip: '3D View',
          ),
          IconButton(
            icon: const Icon(Icons.map),
            onPressed: _navigateTo2DView,
            tooltip: '2D View',
          ),
          IconButton(
            icon: const Icon(Icons.replay),
            onPressed: _navigateToReplay,
            tooltip: 'Replay',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showRoomConfigDialog,
            tooltip: 'Configure Room',
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _signOut,
            tooltip: 'Sign Out',
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
                      if (_frames.isNotEmpty) _buildLatestFrameCard(_frames.last),
                      const SizedBox(height: 16),
                      Text(
                        'Frame History (${_frames.length} entries)',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: Scrollbar(
                          child: ListView.builder(
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

  Widget _buildFrameCard(Map<String, dynamic> frame, int index) {
    final present = frame['present'] as bool? ?? false;
    final detections = humanDetectionsFromFrameMap(frame);
    final timestamp = frame['timestamp'] ?? frame['timestamp_ms'] ?? 'N/A';
    final formattedTimestamp = _formatTimestamp(timestamp);
    final headerPosture = detections.isNotEmpty ? detections.first.posture : 'Unknown';
    final subtitle = !present
        ? 'Not present'
        : detections.map((d) => '${d.posture} (${(d.confidence * 100).toStringAsFixed(0)}%)').join(' · ');

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Text(_getPostureEmoji(headerPosture), style: const TextStyle(fontSize: 24)),
        title: Text(
          present ? '${detections.length} ${detections.length == 1 ? 'person' : 'people'}' : 'No one present',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: _getPostureColor(headerPosture),
          ),
        ),
        subtitle: Text(subtitle),
        trailing: Text(
          formattedTimestamp,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
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

/// Bottom sheet shown from the dashboard app bar: current vs latest firmware
/// version, an "Update Now" button, and a live progress view once an update
/// has been triggered (driven by /devices/{deviceId}/ota_status).
class _OtaUpdateSheet extends StatefulWidget {
  final String deviceId;
  final String currentVersion;
  final String? latestVersion;
  final String? latestUrl;
  final bool updateAvailable;

  const _OtaUpdateSheet({
    required this.deviceId,
    required this.currentVersion,
    required this.latestVersion,
    required this.latestUrl,
    required this.updateAvailable,
  });

  @override
  State<_OtaUpdateSheet> createState() => _OtaUpdateSheetState();
}

class _OtaUpdateSheetState extends State<_OtaUpdateSheet> {
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