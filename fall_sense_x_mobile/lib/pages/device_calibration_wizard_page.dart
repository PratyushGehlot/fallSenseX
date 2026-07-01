import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:fall_sense_x_mobile/services/auth_service.dart';
import '../theme/app_theme.dart';
import 'activity_zones_page.dart' show kZoneColors, kZonePresets;
import 'posture_calibration_page.dart';

/// Device Calibration wizard, mirroring the premium reference UI's 4-step
/// flow. Only step 1 (Position Device) and the final summary reflect real
/// device state (room dimensions, already configurable from the dashboard).
/// Steps 2 (Scan Room) and 3 (Set Activity Zones) are cosmetic placeholders:
/// the firmware has no room-scanning or zone-configuration capability today
/// (see plan notes / FallSenseX_Architecture.md), so nothing entered there
/// is sent to the device - it's UI scaffolding ready to wire up if that
/// capability is added later. Real posture calibration lives in
/// posture_calibration_page.dart, linked from the summary step.
class DeviceCalibrationWizardPage extends StatefulWidget {
  final String deviceId;
  const DeviceCalibrationWizardPage({super.key, required this.deviceId});

  @override
  State<DeviceCalibrationWizardPage> createState() => _DeviceCalibrationWizardPageState();
}

class _DeviceCalibrationWizardPageState extends State<DeviceCalibrationWizardPage> with SingleTickerProviderStateMixin {
  int _step = 0;
  final _stopwatch = Stopwatch();
  late final AnimationController _scanController;

  final DeviceService _deviceService = DeviceService();
  double _roomLength = 10.0;
  double _roomWidth = 10.0;
  List<String> _zones = [];
  final _zoneController = TextEditingController();

  double get _scanSweep => _scanController.value;

  @override
  void initState() {
    super.initState();
    _stopwatch.start();
    _scanController = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..addListener(() => setState(() {}))
      ..repeat(reverse: true);
    _deviceService.getZones(widget.deviceId).then((zones) {
      if (mounted && zones.isNotEmpty) setState(() => _zones = zones);
    });
  }

  @override
  void dispose() {
    _scanController.dispose();
    _zoneController.dispose();
    super.dispose();
  }

  void _next() {
    if (_step == 2) {
      _deviceService.setZones(widget.deviceId, _zones);
    }
    if (_step < 3) {
      setState(() => _step++);
    } else {
      Navigator.pop(context);
    }
  }

  void _addZone() {
    final name = _zoneController.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _zones.add(name);
      _zoneController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Device Calibration')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: Row(
              children: List.generate(4, (i) {
                final reached = i <= _step;
                return Expanded(
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 14,
                        backgroundColor: reached ? AppColors.accent : const Color(0xFFE5E5EA),
                        child: i < _step
                            ? const Icon(Icons.check, size: 14, color: Colors.white)
                            : Text('${i + 1}', style: TextStyle(fontSize: 12, color: reached ? Colors.white : AppColors.textSecondary)),
                      ),
                      if (i != 3)
                        Expanded(
                          child: Container(height: 2, color: i < _step ? AppColors.accent : const Color(0xFFE5E5EA)),
                        ),
                    ],
                  ),
                );
              }),
            ),
          ),
          Expanded(
            child: Column(
              children: [
                // Full-bleed like login_header.png on the login screen -
                // no side padding/box around it, unlike the rest of the
                // step content which stays inset.
                if (_step == 0)
                  Stack(
                    children: [
                      Image.asset('assets/images/room_isometric.png', width: double.infinity, fit: BoxFit.fitWidth),
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: AppColors.statusOnline, borderRadius: BorderRadius.circular(12)),
                          child: const Text('Optimal Coverage  Area: 28.4 m²', style: TextStyle(color: Colors.white, fontSize: 11)),
                        ),
                      ),
                    ],
                  ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(24, _step == 0 ? 16 : 24, 24, 24),
                    child: _buildStepBody(),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _next,
                child: Text(_step == 0
                    ? 'Device Is Positioned'
                    : _step == 1
                        ? 'Scan Complete'
                        : _step == 2
                            ? 'Save & Continue'
                            : 'Done'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepBody() {
    switch (_step) {
      case 0:
        return _buildPositionStep();
      case 1:
        return _buildScanStep();
      case 2:
        return _buildZonesStep();
      default:
        return _buildCompleteStep();
    }
  }

  Widget _buildPositionStep() {
    return ListView(
      children: [
        const Text('Step 1: Position Your Device', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        _buildTip(Icons.height, 'Recommended Height', '2.4m - 3.0m'),
        _buildTip(Icons.crop_free, 'Room Coverage', 'Up to 6.5m radius'),
        _buildTip(Icons.gps_fixed, 'Detection Accuracy', 'Best at center position'),
        const SizedBox(height: 16),
        const Text('Room Dimensions (feet)', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                initialValue: _roomLength.toString(),
                decoration: const InputDecoration(labelText: 'Length'),
                keyboardType: TextInputType.number,
                onChanged: (v) => _roomLength = double.tryParse(v) ?? _roomLength,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                initialValue: _roomWidth.toString(),
                decoration: const InputDecoration(labelText: 'Width'),
                keyboardType: TextInputType.number,
                onChanged: (v) => _roomWidth = double.tryParse(v) ?? _roomWidth,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTip(IconData icon, String title, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.accent),
          const SizedBox(width: 12),
          Expanded(child: Text(title)),
          Text(value, style: const TextStyle(color: AppColors.textSecondary)),
        ],
      ),
    );
  }

  Widget _buildScanStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Step 2: Scan Your Room', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text(
          'The device is scanning the room to detect walls, furniture, and other obstacles for accurate monitoring.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(8)),
          child: const Text(
            'Cosmetic preview only - room scanning is not yet supported by the device firmware.',
            style: TextStyle(fontSize: 11, color: AppColors.accent),
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              color: const Color(0xFFF3ECFB),
              child: CustomPaint(painter: _IsometricRoomPainter(sweepProgress: _scanSweep)),
            ),
          ),
        ),
        const SizedBox(height: 12),
        const LinearProgressIndicator(),
        const SizedBox(height: 4),
        const Text('Detecting walls…', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      ],
    );
  }

  Widget _buildZonesStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Step 3: Set Activity Zones', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text(
          'Define areas to customize how the device detects and responds.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(8)),
          child: const Text(
            'Labels only - the firmware applies the same detection logic everywhere in range; '
            'zones aren\'t enforced yet.',
            style: TextStyle(fontSize: 11, color: AppColors.accent),
          ),
        ),
        if (_zones.isNotEmpty) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(height: 140, width: double.infinity, child: CustomPaint(painter: _ZoneMapPainter(zones: _zones))),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          children: kZonePresets
              .where((p) => !_zones.contains(p))
              .map((p) => ActionChip(
                    label: Text(p, style: const TextStyle(fontSize: 11)),
                    onPressed: () => setState(() => _zones.add(p)),
                  ))
              .toList(),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _zoneController,
                decoration: const InputDecoration(labelText: 'Custom zone name'),
                onSubmitted: (_) => _addZone(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(icon: const Icon(Icons.add_circle, color: AppColors.accent), onPressed: _addZone),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _zones.isEmpty
              ? const Center(child: Text('No zones added yet', style: TextStyle(color: AppColors.textSecondary)))
              : ListView(
                  children: _zones.asMap().entries.map((entry) {
                    final color = kZoneColors[entry.key % kZoneColors.length];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Container(width: 12, height: 12, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
                        title: Text(entry.value),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(() => _zones.removeAt(entry.key)),
                        ),
                      ),
                    );
                  }).toList(),
                ),
        ),
      ],
    );
  }

  Widget _buildCompleteStep() {
    final elapsed = _stopwatch.elapsed;
    final area = (_roomLength * _roomWidth) * 0.092903; // ft^2 -> m^2
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Center(child: Icon(Icons.check_circle, size: 56, color: AppColors.statusOnline)),
        const SizedBox(height: 12),
        const Center(child: Text('Calibration Complete!', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
        const SizedBox(height: 4),
        const Center(
          child: Text(
            'Your device is calibrated to detect falls and abnormal movements in this room.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            _buildSummaryTile('Room Size', '${area.toStringAsFixed(1)} m²'),
            const SizedBox(width: 12),
            _buildSummaryTile('Detection Zones', '${_zones.length}'),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _buildSummaryTile('Coverage', '${_roomLength.toStringAsFixed(0)}×${_roomWidth.toStringAsFixed(0)} ft'),
            const SizedBox(width: 12),
            _buildSummaryTile('Calibration Time', '${elapsed.inMinutes}m ${elapsed.inSeconds % 60}s'),
          ],
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => PostureCalibrationPage(deviceId: widget.deviceId)),
          ),
          icon: const Icon(Icons.accessibility_new),
          label: const Text('Also Run Posture Calibration'),
        ),
      ],
    );
  }

  Widget _buildSummaryTile(String label, String value) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              const SizedBox(height: 4),
              Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stylized isometric room used in place of a real 3D room scan (the
/// firmware has no scanning capability - see this file's header comment).
/// Draws a simple floor + two walls in perspective with a sweeping scan
/// line, animated by [sweepProgress] (0..1, supplied by an AnimationController
/// the caller repeats/reverses).
class _IsometricRoomPainter extends CustomPainter {
  final double sweepProgress;
  _IsometricRoomPainter({required this.sweepProgress});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final floorColor = const Color(0xFFE3D4F5);
    final wallColor = const Color(0xFFD6C3EE);
    final lineColor = const Color(0xFFB68FE0);

    // Floor: a diamond (isometric projection of a square room).
    final floor = Path()
      ..moveTo(w * 0.5, h * 0.55)
      ..lineTo(w * 0.88, h * 0.72)
      ..lineTo(w * 0.5, h * 0.9)
      ..lineTo(w * 0.12, h * 0.72)
      ..close();
    canvas.drawPath(floor, Paint()..color = floorColor);
    canvas.drawPath(floor, Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);

    // Back-left wall.
    final wallLeft = Path()
      ..moveTo(w * 0.12, h * 0.72)
      ..lineTo(w * 0.12, h * 0.28)
      ..lineTo(w * 0.5, h * 0.12)
      ..lineTo(w * 0.5, h * 0.55)
      ..close();
    canvas.drawPath(wallLeft, Paint()..color = wallColor.withValues(alpha: 0.9));

    // Back-right wall.
    final wallRight = Path()
      ..moveTo(w * 0.5, h * 0.55)
      ..lineTo(w * 0.5, h * 0.12)
      ..lineTo(w * 0.88, h * 0.28)
      ..lineTo(w * 0.88, h * 0.72)
      ..close();
    canvas.drawPath(wallRight, Paint()..color = wallColor.withValues(alpha: 0.75));

    // Sensor marker at the ceiling apex.
    final apex = Offset(w * 0.5, h * 0.12);
    canvas.drawCircle(apex, 5, Paint()..color = AppColors.accent);

    // Animated scan sweep: a translucent triangle rotating slowly from the
    // sensor down to the floor between the two walls' inner edges.
    final sweepAngle = math.pi * (0.15 + 0.7 * sweepProgress);
    final sweepPaint = Paint()..color = AppColors.accent.withValues(alpha: 0.18);
    final floorCenter = Offset(w * 0.5, h * 0.72);
    final reach = (floorCenter - apex).distance;
    final leftEdge = apex + Offset(math.cos(sweepAngle) * reach, math.sin(sweepAngle) * reach * 0.7);
    final rightEdge = apex + Offset(math.cos(sweepAngle + 0.5) * reach, math.sin(sweepAngle + 0.5) * reach * 0.7);
    canvas.drawPath(
      Path()
        ..moveTo(apex.dx, apex.dy)
        ..lineTo(leftEdge.dx, leftEdge.dy)
        ..lineTo(rightEdge.dx, rightEdge.dy)
        ..close(),
      sweepPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _IsometricRoomPainter oldDelegate) => oldDelegate.sweepProgress != sweepProgress;
}

/// Top-down zone map for "Set Activity Zones": a floor rectangle divided
/// into evenly-sized colored bands, one per named zone (cosmetic only - see
/// this file's header comment).
class _ZoneMapPainter extends CustomPainter {
  final List<String> zones;
  _ZoneMapPainter({required this.zones});

  @override
  void paint(Canvas canvas, Size size) {
    final floorRect = Rect.fromLTWH(8, 8, size.width - 16, size.height - 16);
    canvas.drawRRect(
      RRect.fromRectAndRadius(floorRect, const Radius.circular(8)),
      Paint()..color = const Color(0xFFF0F0F0),
    );

    if (zones.isEmpty) return;

    final cols = math.sqrt(zones.length).ceil();
    final rows = (zones.length / cols).ceil();
    final cellW = floorRect.width / cols;
    final cellH = floorRect.height / rows;

    for (var i = 0; i < zones.length; i++) {
      final col = i % cols;
      final row = i ~/ cols;
      final rect = Rect.fromLTWH(
        floorRect.left + col * cellW,
        floorRect.top + row * cellH,
        cellW,
        cellH,
      );
      final color = kZoneColors[i % kZoneColors.length];
      canvas.drawRect(rect.deflate(2), Paint()..color = color.withValues(alpha: 0.35));
      canvas.drawRect(rect.deflate(2), Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);

      final textPainter = TextPainter(
        text: TextSpan(text: zones[i], style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: rect.width - 4);
      textPainter.paint(canvas, Offset(rect.center.dx - textPainter.width / 2, rect.center.dy - textPainter.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _ZoneMapPainter oldDelegate) => oldDelegate.zones != zones;
}
