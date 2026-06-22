/// Posture -> RGB color, mirroring the WS2812 LED colors the firmware sets
/// per posture (radar_detection_callback in fall_sense_x_main.c). Shared by
/// every view (2D, 3D, replay) so they never show different colors for the
/// same posture.
const Map<String, List<int>> kPostureColors = {
  'STANDING': [0, 255, 127], // WS2812_COLOR_PARROT_GREEN
  'SITTING': [128, 0, 128], // WS2812_COLOR_PURPLE
  'LYING': [255, 255, 0], // WS2812_COLOR_YELLOW
  'SLEEPING': [255, 255, 0], // WS2812_COLOR_YELLOW
  'FALL': [255, 0, 0], // WS2812_COLOR_RED
};

List<int> postureColorRgb(String posture) =>
    kPostureColors[posture.toUpperCase()] ?? const [0, 255, 0]; // WS2812_COLOR_GREEN

/// Data class for a single radar point
class RadarPoint {
  final double x, y, z, velocity;
  final String? classification;
  final double intensity;

  RadarPoint({
    required this.x, required this.y, required this.z,
    this.velocity = 0.0, this.classification, this.intensity = 1.0,
  });

  Map<String, dynamic> toJson() => {
    'x': x, 'y': y, 'z': z,
    'velocity': velocity, 'classification': classification, 'intensity': intensity,
  };

  factory RadarPoint.fromMap(Map<String, dynamic> map) => RadarPoint(
    x: (map['x'] as num?)?.toDouble() ?? 0.0,
    y: (map['y'] as num?)?.toDouble() ?? 0.0,
    z: (map['z'] as num?)?.toDouble() ?? 0.0,
    velocity: (map['velocity'] as num?)?.toDouble() ?? 0.0,
    classification: map['classification'] as String?,
    intensity: (map['intensity'] as num?)?.toDouble() ?? 1.0,
  );
}

/// Data class for human detection with bounding box
class HumanDetection {
  final String id;
  final double x, y, z, width, height, depth;
  final String posture;
  final double confidence, velocity;

  HumanDetection({
    required this.id, required this.x, required this.y, required this.z,
    this.width = 0.6, this.height = 1.8, this.depth = 0.4,
    required this.posture, this.confidence = 1.0, this.velocity = 0.0,
  });

  Map<String, dynamic> toJson() => {
    'id': id, 'x': x, 'y': y, 'z': z,
    'width': width, 'height': height, 'depth': depth,
    'posture': posture, 'confidence': confidence, 'velocity': velocity,
  };

  factory HumanDetection.fromMap(Map<String, dynamic> map, String id) => HumanDetection(
    id: id,
    x: (map['x'] as num?)?.toDouble() ?? 0.0,
    y: (map['y'] as num?)?.toDouble() ?? 0.0,
    z: (map['z'] as num?)?.toDouble() ?? 0.0,
    width: (map['width'] as num?)?.toDouble() ?? 0.6,
    height: (map['height'] as num?)?.toDouble() ?? 1.8,
    depth: (map['depth'] as num?)?.toDouble() ?? 0.4,
    posture: map['posture']?.toString() ?? 'UNKNOWN',
    confidence: (map['confidence'] as num?)?.toDouble() ?? 1.0,
    velocity: (map['velocity'] as num?)?.toDouble() ?? 0.0,
  );
}

class RadarFrame {
  final int timestamp;
  final List<RadarPoint> points;
  final HumanDetection? humanDetection;

  RadarFrame({
    required this.timestamp,
    required this.points,
    this.humanDetection,
  });
}

String formatTimestamp(dynamic timestamp) {
  if (timestamp == null) return 'N/A';
  final ts = (timestamp as num).toInt();
  final tsMs = ts > 10000000000 ? ts : ts * 1000;
  final dt = DateTime.fromMillisecondsSinceEpoch(tsMs);
  return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')} ${dt.day}.${dt.month.toString().padLeft(2, '0')}.${(dt.year % 100).toString().padLeft(2, '0')}';
}
