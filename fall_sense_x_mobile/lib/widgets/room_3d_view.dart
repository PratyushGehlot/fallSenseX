import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:firebase_database/firebase_database.dart';
import '../models/radar_models.dart';

export '../models/radar_models.dart'
    show RadarPoint, HumanDetection, RadarFrame, formatTimestamp;

class Room3DView extends StatefulWidget {
  final List<Map<String, dynamic>> frames;
  final double roomLength;
  final double roomWidth;
  final double roomHeight;
  final DatabaseReference? framesRef;

  const Room3DView({
    Key? key,
    required this.frames,
    this.roomLength = 10.0,
    this.roomWidth = 10.0,
    this.roomHeight = 8.0,
    this.framesRef,
  }) : super(key: key);

  @override
  State<Room3DView> createState() => _Room3DViewState();
}

class _Room3DViewState extends State<Room3DView> {
  RadarFrame? _currentRadarFrame;
  Map<String, dynamic>? _latestRawFrame;
  StreamSubscription<DatabaseEvent>? _subscription;

  @override
  void initState() {
    super.initState();
    _applyFrame(widget.frames.isEmpty ? null : widget.frames.last);
    _startRealTimeUpdates();
  }

  void _startRealTimeUpdates() {
    if (widget.framesRef == null) return;

    _subscription = widget.framesRef!.onValue.listen((DatabaseEvent event) {
      final latest = latestFrameFromSnapshot(event.snapshot.value);
      if (mounted) setState(() => _applyFrame(latest));
    });
  }

  void _applyFrame(Map<String, dynamic>? frameMap) {
    _latestRawFrame = frameMap;
    if (frameMap == null) {
      _currentRadarFrame = null;
      return;
    }

    final present = frameMap['present'] as bool? ?? false;
    final timestampMs = frameTimestampMs(frameMap);
    final now = DateTime.now().millisecondsSinceEpoch;
    final isDataFresh = (now - timestampMs) < 86400000;

    List<HumanDetection> detections = const [];
    if (present && isDataFresh) {
      // Convert meters (sensor-centered) to centered feet for drawing.
      detections = humanDetectionsFromFrameMap(frameMap)
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
    }

    _currentRadarFrame = RadarFrame(
      timestamp: timestampMs,
      points: const [],
      detections: detections,
    );
  }

  @override
  void didUpdateWidget(Room3DView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frames != widget.frames) {
      _applyFrame(widget.frames.isEmpty ? null : widget.frames.last);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final detections = _currentRadarFrame?.detections ?? const [];
    final showInfoBar = detections.isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Room View (2D)'),
        backgroundColor: Colors.grey[900],
        actions: [
          if (_latestRawFrame != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  formatTimestamp(_latestRawFrame!['timestamp'] ?? _latestRawFrame!['timestamp_ms']),
                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                ),
              ),
            ),
        ],
      ),
      body: _currentRadarFrame == null
          ? const Center(
              child: Text(
                'No data available',
                style: TextStyle(color: Colors.white),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: widget.roomLength / widget.roomWidth,
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: RoomPainter(
                          frame: _currentRadarFrame!,
                          roomLength: widget.roomLength,
                          roomWidth: widget.roomWidth,
                          roomHeight: widget.roomHeight,
                        ),
                      ),
                    ),
                  ),
                ),
                if (showInfoBar)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.cyan.withOpacity(0.4)),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final human in detections)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Wrap(
                              spacing: 20,
                              runSpacing: 8,
                              alignment: WrapAlignment.center,
                              children: [
                                _buildInfoChip('#', human.id, Icons.tag),
                                _buildInfoChip('Posture', human.posture, Icons.accessibility_new),
                                _buildInfoChip('X', '${human.x.toStringAsFixed(1)} ft', Icons.straighten),
                                _buildInfoChip('Y', '${human.y.toStringAsFixed(1)} ft', Icons.straighten),
                                _buildInfoChip('Z', '${human.z.toStringAsFixed(1)} ft', Icons.height),
                                _buildInfoChip('Vel', '${human.velocity.toStringAsFixed(2)} m/s', Icons.speed),
                                _buildInfoChip('Conf', '${(human.confidence * 100).toStringAsFixed(0)}%', Icons.check_circle),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildInfoChip(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.cyan.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.cyan.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.cyan[300]),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 9,
                  color: Colors.cyan[200],
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class RoomPainter extends CustomPainter {
  final RadarFrame frame;
  final double roomLength;
  final double roomWidth;
  final double roomHeight;

  RoomPainter({
    required this.frame,
    required this.roomLength,
    required this.roomWidth,
    required this.roomHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint gridPaint = Paint()
      ..color = Colors.grey.withOpacity(0.25)
      ..strokeWidth = 1.0;

    final Paint wallPaint = Paint()
      ..color = Colors.blue.withOpacity(0.5)
      ..strokeWidth = 2.0;

    double scaleX = size.width / roomLength;
    double scaleY = size.height / roomWidth;
    double scale = math.min(scaleX, scaleY);

    double offsetX = (size.width - roomLength * scale) / 2;
    double offsetY = (size.height - roomWidth * scale) / 2;

    double halfLength = roomLength / 2;
    double halfWidth = roomWidth / 2;

    for (double gx = -halfLength; gx <= halfLength; gx += 1.0) {
      double canvasX = offsetX + (gx + halfLength) * scale;
      canvas.drawLine(
        Offset(canvasX, offsetY),
        Offset(canvasX, offsetY + roomWidth * scale),
        gridPaint,
      );
    }

    for (double gy = -halfWidth; gy <= halfWidth; gy += 1.0) {
      double canvasY = offsetY + (halfWidth - gy) * scale;
      canvas.drawLine(
        Offset(offsetX, canvasY),
        Offset(offsetX + roomLength * scale, canvasY),
        gridPaint,
      );
    }

    canvas.drawRect(
      Rect.fromLTWH(offsetX, offsetY, roomLength * scale, roomWidth * scale),
      wallPaint,
    );

    // Small marker for the sensor, mounted at the ceiling center - mirrors
    // the sensor box shown in the 3D view.
    double centerCanvasX = offsetX + halfLength * scale;
    double centerCanvasY = offsetY + halfWidth * scale;
    final Paint sensorPaint = Paint()..color = Colors.white.withOpacity(0.7);
    canvas.drawCircle(Offset(centerCanvasX, centerCanvasY), 4, sensorPaint);

    if (frame.detections.isEmpty) {
      _drawLabel(canvas, 'No human present', Offset(centerCanvasX, centerCanvasY + 24), Colors.grey);
      return;
    }

    for (final human in frame.detections) {
      // Coordinates are centered feet (sensor at 0,0). Grid center is (0,0).
      // +X right, +Y up. Canvas Y increases downward, so flip Y.
      double canvasX = centerCanvasX + human.x * scale;
      double canvasY = centerCanvasY - human.y * scale;

      final rgb = postureColorRgb(human.posture);
      final color = Color.fromARGB(255, rgb[0], rgb[1], rgb[2]);
      final iconSize = 0.9 * scale;

      final iconPainter = TextPainter(textDirection: TextDirection.ltr)
        ..text = TextSpan(
          text: String.fromCharCode(Icons.person_pin_circle.codePoint),
          style: TextStyle(
            fontSize: iconSize,
            fontFamily: Icons.person_pin_circle.fontFamily,
            package: Icons.person_pin_circle.fontPackage,
            color: human.posture.toUpperCase() == 'FALL' ? Colors.red : color,
          ),
        )
        ..layout();
      iconPainter.paint(canvas, Offset(canvasX - iconPainter.width / 2, canvasY - iconPainter.height / 2));

      _drawLabel(
        canvas,
        '${human.posture}${human.posture.toUpperCase() == "FALL" ? " !" : ""}',
        Offset(canvasX, canvasY + iconSize / 2 + 10),
        human.posture.toUpperCase() == 'FALL' ? Colors.red : color,
      );
    }
  }

  void _drawLabel(Canvas canvas, String text, Offset position, Color color) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    painter.layout();
    painter.paint(canvas, position - Offset(painter.width / 2, 0));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
