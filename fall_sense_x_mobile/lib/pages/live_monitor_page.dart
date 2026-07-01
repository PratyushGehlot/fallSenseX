import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../models/radar_models.dart';
import '../theme/app_theme.dart';
import '../widgets/room_3d_view.dart' show RoomPainter;
import '../widgets/radar_3d_visualization.dart' as view3d;
import '../widgets/room_3d_replay.dart';
import 'detection_trends_page.dart';
import 'device_settings_page.dart';
import 'live_3d_view_page.dart';

/// Unified "Living Room"-style monitor page, mirroring the premium
/// reference's 2D View / 3D View pill-toggle screen. Both visualizations are
/// driven by the same cloud frame stream and kept mounted in an IndexedStack
/// (rather than torn down on toggle) so the 3D WebView is only ever created
/// once per page visit.
///
/// This intentionally does not duplicate live_3d_view_page.dart's LAN/TCP
/// point-cloud streaming (that page has careful, hard-won handling of a
/// WebView resize bug - see its comments). That richer experience stays
/// reachable via the "Full Live View" button below.
class LiveMonitorPage extends StatefulWidget {
  final String deviceId;
  final int initialTab; // 0 = 2D, 1 = 3D
  final double roomLengthFt;
  final double roomWidthFt;
  final double roomHeightFt;

  const LiveMonitorPage({
    super.key,
    required this.deviceId,
    this.initialTab = 0,
    this.roomLengthFt = 10.0,
    this.roomWidthFt = 10.0,
    this.roomHeightFt = 8.0,
  });

  @override
  State<LiveMonitorPage> createState() => _LiveMonitorPageState();
}

class _LiveMonitorPageState extends State<LiveMonitorPage> {
  late int _tab;
  late double _roomLengthFt;
  late double _roomWidthFt;
  late double _roomHeightFt;
  StreamSubscription<DatabaseEvent>? _frameSub;
  StreamSubscription<DatabaseEvent>? _onlineSub;
  Map<String, dynamic>? _latestFrame;
  bool _isOnline = false;

  double get _roomLengthM => _roomLengthFt / 3.28084;
  double get _roomWidthM => _roomWidthFt / 3.28084;
  double get _roomHeightM => _roomHeightFt / 3.28084;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    _roomLengthFt = widget.roomLengthFt;
    _roomWidthFt = widget.roomWidthFt;
    _roomHeightFt = widget.roomHeightFt;
    _frameSub = FirebaseDatabase.instance
        .ref('devices/${widget.deviceId}/frames')
        .onValue
        .listen((event) {
      if (!mounted) return;
      setState(() => _latestFrame = latestFrameFromSnapshot(event.snapshot.value));
    });
    _onlineSub = FirebaseDatabase.instance.ref('devices/${widget.deviceId}/online').onValue.listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value;
      bool isOnline = false;
      if (data is Map && data['value'] == true && data['timestamp'] != null) {
        final ts = DateTime.fromMillisecondsSinceEpoch((data['timestamp'] as num).toInt() * 1000);
        isOnline = DateTime.now().difference(ts) < const Duration(seconds: 75);
      }
      setState(() => _isOnline = isOnline);
    });
  }

  @override
  void dispose() {
    _frameSub?.cancel();
    _onlineSub?.cancel();
    super.dispose();
  }

  bool get _present => _latestFrame?['present'] as bool? ?? false;

  List<HumanDetection> get _detectionsMeters =>
      _present && _latestFrame != null ? humanDetectionsFromFrameMap(_latestFrame!) : const [];

  /// Sensor-centered meters -> centered feet, matching Room3DView's
  /// _applyFrame so the embedded 2D painter renders identically.
  RadarFrame get _radarFrameFeet {
    final detections = _detectionsMeters
        .map((d) => HumanDetection(
              id: d.id,
              x: d.x * 3.28084,
              y: d.y * 3.28084,
              z: d.z * 3.28084,
              posture: d.posture,
              confidence: d.confidence,
              velocity: d.velocity,
            ))
        .toList();
    return RadarFrame(timestamp: _latestFrame != null ? frameTimestampMs(_latestFrame!) : 0, points: const [], detections: detections);
  }

  /// Sensor-centered meters -> room-corner-centered meters with y/z swapped,
  /// matching dashboard_page.dart's _navigateTo3DView mapping exactly.
  List<view3d.HumanDetection> get _detections3D {
    return _detectionsMeters.map((d) {
      final cornerX = d.x + _roomLengthM / 2.0;
      final cornerY = d.y + _roomWidthM / 2.0;
      return view3d.HumanDetection(
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
      );
    }).toList();
  }

  String get _headerPosture => _detectionsMeters.isNotEmpty ? _detectionsMeters.first.posture : 'NO_PRESENCE';
  bool get _hasFallen => _detectionsMeters.any((d) => d.posture.toUpperCase() == 'FALL');

  /// 2D View: a true top-down "radar's eye view" - room boundary box drawn
  /// to scale plus a dot at the detected person's actual x/y, via the same
  /// RoomPainter used by the original dashboard 2D view and replay.
  Widget _build2DView() {
    return Container(
      color: Colors.black,
      child: AspectRatio(
        aspectRatio: _roomLengthFt / _roomWidthFt,
        child: CustomPaint(
          size: Size.infinite,
          painter: RoomPainter(
            frame: _radarFrameFeet,
            roomLength: _roomLengthFt,
            roomWidth: _roomWidthFt,
            roomHeight: _roomHeightFt,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text(widget.deviceId, overflow: TextOverflow.ellipsis),
            const Icon(Icons.expand_more),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.straighten),
            tooltip: 'Room Dimensions',
            onPressed: _showRoomConfigDialog,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => DeviceSettingsPage(deviceId: widget.deviceId)),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPillToggle(),
            const SizedBox(height: 12),
            _buildVisualizationCard(),
            const SizedBox(height: 16),
            _buildDetectedNowRow(),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _buildPostureCard()),
                const SizedBox(width: 12),
                Expanded(child: _buildActivityCard()),
              ],
            ),
            const SizedBox(height: 16),
            _buildActionRow(),
          ],
        ),
      ),
    );
  }

  /// Room dimensions only affect the 2D/3D visualization's coordinate
  /// mapping (not real sensor data) - moved here from dashboard_page.dart's
  /// old top-bar icon since this is the only screen that uses them.
  void _showRoomConfigDialog() {
    final lengthController = TextEditingController(text: _roomLengthFt.toString());
    final widthController = TextEditingController(text: _roomWidthFt.toString());
    final heightController = TextEditingController(text: _roomHeightFt.toString());

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Room Dimensions (feet)'),
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              setState(() {
                _roomLengthFt = double.tryParse(lengthController.text) ?? _roomLengthFt;
                _roomWidthFt = double.tryParse(widthController.text) ?? _roomWidthFt;
                _roomHeightFt = double.tryParse(heightController.text) ?? _roomHeightFt;
              });
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget _buildPillToggle() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0xFFE5E5EA))),
      child: Row(
        children: [
          _buildPill('2D View', 0),
          _buildPill('3D View', 1),
        ],
      ),
    );
  }

  Widget _buildPill(String label, int index) {
    final selected = _tab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tab = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : AppColors.textSecondary,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVisualizationCard() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: 300,
        child: Stack(
          children: [
            Positioned.fill(
              child: IndexedStack(
                index: _tab,
                children: [
                  _build2DView(),
                  view3d.Radar3DVisualization(
                    key: const ValueKey('embedded_radar_3d'),
                    roomLength: _roomLengthM,
                    roomWidth: _roomWidthM,
                    roomHeight: _roomHeightM,
                    humanDetections: _detections3D,
                    showPointCloud: true,
                    showBoundingBoxes: true,
                    showLabels: true,
                  ),
                ],
              ),
            ),
            Positioned(
              left: 8,
              top: 8,
              bottom: 8,
              child: Column(
                children: [
                  _buildFloatingIcon(Icons.bar_chart, 'Reports', () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => DetectionTrendsPage(deviceId: widget.deviceId)),
                      )),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFloatingIcon(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), shape: BoxShape.circle),
          child: Icon(icon, size: 18, color: AppColors.accent),
        ),
      ),
    );
  }

  Widget _buildDetectedNowRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text('Detected Now', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(12)),
          child: Text(
            _present ? '${_detectionsMeters.length} Person${_detectionsMeters.length == 1 ? '' : 's'}' : 'Empty Room',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.accent),
          ),
        ),
      ],
    );
  }

  Widget _buildPostureCard() {
    final label = _present ? _headerPosture : 'No Presence';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Posture', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(
              _hasFallen ? 'Needs Attention' : 'Good Posture',
              style: TextStyle(fontSize: 11, color: _hasFallen ? AppColors.statusFall : AppColors.statusOnline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActivityCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Activity', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            const SizedBox(height: 4),
            Text(_hasFallen ? 'Fall Detected' : 'Normal Activity',
                style: TextStyle(fontWeight: FontWeight.bold, color: _hasFallen ? AppColors.statusFall : AppColors.textPrimary)),
            const SizedBox(height: 2),
            Text(
              _hasFallen ? 'Check on them now' : 'No Fall Detected',
              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionRow() {
    return Row(
      children: [
        _buildActionButton(Icons.replay, 'Replay', () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => Room3DReplay(
                  deviceId: widget.deviceId,
                  roomLength: _roomLengthFt,
                  roomWidth: _roomWidthFt,
                  roomHeight: _roomHeightFt,
                ),
              ),
            )),
        const SizedBox(width: 8),
        _buildActionButton(Icons.view_in_ar, 'Full View', () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => Live3DViewPage(
                  deviceId: widget.deviceId,
                  cloudDetections: _detections3D,
                  roomLengthM: _roomLengthM,
                  roomWidthM: _roomWidthM,
                  roomHeightM: _roomHeightM,
                ),
              ),
            )),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: (_isOnline ? AppColors.statusOnline : AppColors.statusOffline).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(shape: BoxShape.circle, color: _isOnline ? AppColors.statusOnline : AppColors.statusOffline),
              ),
              const SizedBox(width: 6),
              Text(
                _isOnline ? 'Live' : 'Offline',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _isOnline ? AppColors.statusOnline : AppColors.statusOffline,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton(IconData icon, String label, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
    );
  }
}
