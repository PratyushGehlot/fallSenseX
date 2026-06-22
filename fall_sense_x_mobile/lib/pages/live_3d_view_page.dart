import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../models/radar_models.dart';
import '../services/radar_clustering.dart';
import '../services/radar_tcp_service.dart';
import '../widgets/radar_3d_visualization.dart';

/// 3D View with two data sources:
/// - "Cloud": the latest single detection pushed to Firebase (works from
///   anywhere, low refresh rate).
/// - "Live (LAN)": the raw point cloud streamed directly from the device's
///   TCP server on port 3333 (wifi_stream.c) - only works when the phone is
///   on the same network as the device, but updates continuously and shows
///   every detected point, not just the classified result. Useful for
///   debugging detection behavior in different scenarios.
class Live3DViewPage extends StatefulWidget {
  final String deviceId;
  final List<HumanDetection> cloudDetections;
  final double roomLengthM;
  final double roomWidthM;
  final double roomHeightM;

  const Live3DViewPage({
    super.key,
    required this.deviceId,
    required this.cloudDetections,
    required this.roomLengthM,
    required this.roomWidthM,
    required this.roomHeightM,
  });

  @override
  State<Live3DViewPage> createState() => _Live3DViewPageState();
}

class _Live3DViewPageState extends State<Live3DViewPage> {
  late final RadarTcpService _tcpService;
  static const _clusterer = RadarClusterer();
  late final Stream<List<HumanDetection>> _liveDetectionsStream;
  final _ipController = TextEditingController();
  RadarTcpStatus _status = RadarTcpStatus.idle;
  bool _liveMode = false;

  @override
  void initState() {
    super.initState();
    _tcpService = RadarTcpService(
      roomLengthM: widget.roomLengthM,
      roomWidthM: widget.roomWidthM,
      roomHeightM: widget.roomHeightM,
    );
    _liveDetectionsStream = _tcpService.frames.map(_clusterer.cluster);
    _tcpService.status.listen((s) {
      if (mounted) setState(() => _status = s);
    });
    _prefillDeviceIp();
  }

  Future<void> _prefillDeviceIp() async {
    try {
      final snap = await FirebaseDatabase.instance
          .ref('devices/${widget.deviceId}/info/ip_address')
          .get();
      final ip = snap.value?.toString();
      if (ip != null && ip.isNotEmpty) {
        _ipController.text = ip;
      }
    } catch (_) {
      // No saved IP yet - user can type one in manually.
    }
  }

  Future<void> _goLive() async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Live LAN streaming needs a raw TCP socket, which browsers don\'t allow. '
            'Run this on an Android/iOS device or emulator instead of Chrome/web.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
      return;
    }
    final ip = _ipController.text.trim();
    if (ip.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the device IP first (must be on the same WiFi network)')),
      );
      return;
    }
    setState(() => _liveMode = true);
    final ok = await _tcpService.connect(ip, 3333);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not connect. Check the IP and that your phone is on the same network.')),
      );
    }
  }

  Future<void> _goCloud() async {
    await _tcpService.disconnect();
    setState(() => _liveMode = false);
  }

  @override
  void dispose() {
    _tcpService.dispose();
    _ipController.dispose();
    super.dispose();
  }

  String _statusLabel() {
    switch (_status) {
      case RadarTcpStatus.connecting:
        return 'Connecting...';
      case RadarTcpStatus.connected:
        return 'Live';
      case RadarTcpStatus.failed:
        return 'Connection failed';
      case RadarTcpStatus.disconnected:
        return 'Disconnected';
      case RadarTcpStatus.idle:
        return 'Not connected';
    }
  }

  Color _statusColor() {
    switch (_status) {
      case RadarTcpStatus.connected:
        return Colors.green;
      case RadarTcpStatus.connecting:
        return Colors.orange;
      case RadarTcpStatus.failed:
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('3D View'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Text(_liveMode ? 'Live (LAN)' : 'Cloud'),
                Tooltip(
                  message: kIsWeb
                      ? 'Live LAN streaming requires a native Android/iOS build (browsers block raw TCP sockets)'
                      : 'Toggle live LAN point-cloud streaming',
                  child: Switch(
                    value: _liveMode,
                    onChanged: kIsWeb ? null : (value) => value ? _goLive() : _goCloud(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_liveMode)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              color: Colors.grey[900],
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(shape: BoxShape.circle, color: _statusColor()),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _ipController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Device IP',
                        labelStyle: TextStyle(color: Colors.grey[400]),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(_statusLabel(), style: TextStyle(color: _statusColor(), fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.refresh, color: Colors.white),
                    onPressed: _goLive,
                    tooltip: 'Reconnect',
                  ),
                ],
              ),
            ),
          Expanded(
            child: Radar3DVisualization(
              roomLength: widget.roomLengthM,
              roomWidth: widget.roomWidthM,
              roomHeight: widget.roomHeightM,
              humanDetections: _liveMode ? null : widget.cloudDetections,
              livePointsStream: _liveMode ? _tcpService.frames : null,
              liveDetectionsStream: _liveMode ? _liveDetectionsStream : null,
              showPointCloud: true,
              showBoundingBoxes: true,
              showLabels: true,
            ),
          ),
        ],
      ),
    );
  }
}
