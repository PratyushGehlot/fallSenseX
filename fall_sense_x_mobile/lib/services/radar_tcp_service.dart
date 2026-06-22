import 'dart:async';
import 'dart:io';
import '../models/radar_models.dart';

enum RadarTcpStatus { idle, connecting, connected, disconnected, failed }

/// Connects directly to the ESP32's raw point-cloud TCP server (wifi_stream.c,
/// port 3333) over the LAN and parses the same line protocol the PC
/// visualizer (tools/pc_app_code) uses, so this only works when the phone is
/// on the same network as the device.
///
/// Line protocol (mirrored verbatim from the radar's UART output):
///   "-----PointNum:<n>-----"          frame boundary
///   "x=..,y=..,z=..,v=..,snr=..,abs=..,dpk=.."   one point
///
/// The device sends sensor-centered raw coordinates; this applies the same
/// corner-shift + Z-flip transform the PC tool and the Firebase-driven 3D
/// view both use, so live points line up with the rest of the scene.
class RadarTcpService {
  Socket? _socket;
  StreamSubscription<List<int>>? _subscription;
  final _frameController = StreamController<List<RadarPoint>>.broadcast();
  final _statusController = StreamController<RadarTcpStatus>.broadcast();

  String _buffer = '';
  final List<RadarPoint> _currentFrame = [];

  final double roomLengthM;
  final double roomWidthM;
  final double roomHeightM;

  RadarTcpService({
    required this.roomLengthM,
    required this.roomWidthM,
    required this.roomHeightM,
  });

  Stream<List<RadarPoint>> get frames => _frameController.stream;
  Stream<RadarTcpStatus> get status => _statusController.stream;

  static final RegExp _pointRe = RegExp(
    r'x=([-0-9.]+),y=([-0-9.]+),z=([-0-9.]+),v=([-0-9.]+),'
    r'snr=([-0-9.]+),abs=([-0-9.]+),dpk=([-0-9.]+)',
  );

  Future<bool> connect(String host, int port, {Duration timeout = const Duration(seconds: 5)}) async {
    await disconnect();
    _statusController.add(RadarTcpStatus.connecting);
    try {
      _socket = await Socket.connect(host, port, timeout: timeout);
      _statusController.add(RadarTcpStatus.connected);
      _subscription = _socket!.listen(
        _onData,
        onError: (_) => _handleDisconnect(),
        onDone: _handleDisconnect,
        cancelOnError: true,
      );
      return true;
    } catch (e) {
      _statusController.add(RadarTcpStatus.failed);
      return false;
    }
  }

  void _onData(List<int> chunk) {
    _buffer += String.fromCharCodes(chunk);
    int idx;
    while ((idx = _buffer.indexOf('\n')) != -1) {
      final line = _buffer.substring(0, idx).trim();
      _buffer = _buffer.substring(idx + 1);
      _processLine(line);
    }
    // Guard against a malformed/binary stream growing the buffer forever.
    if (_buffer.length > 8192) {
      _buffer = '';
    }
  }

  void _processLine(String line) {
    if (line.contains('-----PointNum')) {
      if (_currentFrame.isNotEmpty) {
        _frameController.add(List<RadarPoint>.from(_currentFrame));
        _currentFrame.clear();
      }
      return;
    }

    final m = _pointRe.firstMatch(line);
    if (m == null) return;

    final rawX = double.tryParse(m.group(1)!) ?? 0.0;
    final rawY = double.tryParse(m.group(2)!) ?? 0.0;
    final rawZ = double.tryParse(m.group(3)!) ?? 0.0;
    final v = double.tryParse(m.group(4)!) ?? 0.0;
    final snr = double.tryParse(m.group(5)!) ?? 0.0;
    final absVal = double.tryParse(m.group(6)!) ?? 0.0;
    final dpk = double.tryParse(m.group(7)!) ?? 0.0;

    // Match the convention already used for the Firebase-driven detection
    // (dashboard_page.dart): RadarPoint.x/z are the corner-shifted horizontal
    // axes, RadarPoint.y is the raw sensor height with NO flip (Three.js
    // treats y as vertical). Mixing this up makes points land off-camera.
    final x = rawX + roomLengthM / 2.0;
    final y = rawZ;
    final z = rawY + roomWidthM / 2.0;

    final confidence = (snr / 40.0).clamp(0.0, 1.0) * 0.45 +
        (absVal / 15.0).clamp(0.0, 1.0) * 0.40 +
        (dpk / 10.0).clamp(0.0, 1.0) * 0.15;

    _currentFrame.add(RadarPoint(
      x: x,
      y: y,
      z: z,
      velocity: v,
      intensity: confidence,
    ));
  }

  void _handleDisconnect() {
    _statusController.add(RadarTcpStatus.disconnected);
    _subscription = null;
    _socket = null;
  }

  Future<void> disconnect() async {
    await _subscription?.cancel();
    _subscription = null;
    _socket?.destroy();
    _socket = null;
    _buffer = '';
    _currentFrame.clear();
  }

  void dispose() {
    disconnect();
    _frameController.close();
    _statusController.close();
  }
}
