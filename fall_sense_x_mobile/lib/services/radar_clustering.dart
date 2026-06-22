import 'dart:math' as math;
import '../models/radar_models.dart';

/// Clusters a raw radar point cloud into human detections, ported from the
/// PC visualizer's DBSCAN + posture-threshold approach
/// (tools/pc_app_code/build_src/HumanRadar_PC_Visualizer.py) so the live LAN
/// view can show the same bounding boxes/postures the PC tool does, without
/// needing the device to do this classification.
///
/// Clustering runs on the horizontal plane (RadarPoint.x, RadarPoint.z);
/// RadarPoint.y (height) is only used afterwards to classify posture per
/// cluster, matching how radar_sensor.c and the PC tool both work.
class RadarClusterer {
  final double eps;
  final int minSamples;
  final double pointConfThreshold;
  final double clusterConfThreshold;
  final double standingHeight;
  final double sittingHeight;
  final double lyingHeight;

  const RadarClusterer({
    this.eps = 0.55,
    this.minSamples = 5,
    this.pointConfThreshold = 0.4,
    this.clusterConfThreshold = 0.3,
    this.standingHeight = 1.0,
    this.sittingHeight = 0.6,
    this.lyingHeight = 0.35,
  });

  List<HumanDetection> cluster(List<RadarPoint> points) {
    final candidates = <RadarPoint>[];
    for (final p in points) {
      if (p.intensity >= pointConfThreshold) {
        candidates.add(p);
      }
    }
    if (candidates.length < minSamples) {
      return const [];
    }

    final labels = _dbscan(candidates);
    final clusterIndices = <int, List<int>>{};
    for (var i = 0; i < labels.length; i++) {
      final label = labels[i];
      if (label < 0) continue; // noise
      clusterIndices.putIfAbsent(label, () => []).add(i);
    }

    final detections = <HumanDetection>[];
    var hid = 1;
    for (final indices in clusterIndices.values) {
      final clusterPoints = indices.map((i) => candidates[i]).toList();

      final meanConf = clusterPoints.map((p) => p.intensity).reduce((a, b) => a + b) / clusterPoints.length;
      final sizeScore = math.min(clusterPoints.length / 15.0, 1.0);
      final clusterConf = 0.6 * meanConf + 0.4 * sizeScore;
      if (clusterConf < clusterConfThreshold) continue;

      final xs = clusterPoints.map((p) => p.x).toList();
      final ys = clusterPoints.map((p) => p.y).toList();
      final zs = clusterPoints.map((p) => p.z).toList();
      final velocities = clusterPoints.map((p) => p.velocity).toList();

      final cx = xs.reduce((a, b) => a + b) / xs.length;
      final cz = zs.reduce((a, b) => a + b) / zs.length;
      final avgHeight = ys.reduce((a, b) => a + b) / ys.length;
      final avgVelocity = velocities.reduce((a, b) => a + b) / velocities.length;

      final xExtent = (_ptp(xs)) + 0.5;
      final zExtent = (_ptp(zs)) + 0.5;
      final heightExtent = math.max(_ptp(ys), 1.0);

      detections.add(HumanDetection(
        id: 'H$hid',
        x: cx,
        y: avgHeight,
        z: cz,
        width: xExtent,
        height: heightExtent,
        depth: zExtent,
        posture: _classifyPosture(avgHeight),
        confidence: clusterConf,
        velocity: avgVelocity,
      ));
      hid++;
    }

    return detections;
  }

  String _classifyPosture(double height) {
    if (height >= standingHeight) return 'STANDING';
    if (height >= sittingHeight) return 'SITTING';
    if (height >= lyingHeight) return 'LYING';
    return 'FALL';
  }

  double _ptp(List<double> values) {
    var min = values.first, max = values.first;
    for (final v in values) {
      if (v < min) min = v;
      if (v > max) max = v;
    }
    return max - min;
  }

  /// Simple O(n^2) DBSCAN over the (x, z) horizontal plane. Frame sizes here
  /// are small (tens of points), so this is cheap - no need for a spatial
  /// index.
  List<int> _dbscan(List<RadarPoint> points) {
    final n = points.length;
    final labels = List<int>.filled(n, -2); // -2 = unvisited, -1 = noise
    var clusterId = 0;

    List<int> neighbors(int i) {
      final result = <int>[];
      for (var j = 0; j < n; j++) {
        if (i == j) continue;
        final dx = points[i].x - points[j].x;
        final dz = points[i].z - points[j].z;
        if (math.sqrt(dx * dx + dz * dz) <= eps) {
          result.add(j);
        }
      }
      return result;
    }

    for (var i = 0; i < n; i++) {
      if (labels[i] != -2) continue;

      final neighborIdx = neighbors(i);
      if (neighborIdx.length + 1 < minSamples) {
        labels[i] = -1;
        continue;
      }

      labels[i] = clusterId;
      final seeds = List<int>.from(neighborIdx);
      var k = 0;
      while (k < seeds.length) {
        final j = seeds[k];
        k++;
        if (labels[j] == -1) {
          labels[j] = clusterId;
        }
        if (labels[j] != -2) continue;
        labels[j] = clusterId;

        final jNeighbors = neighbors(j);
        if (jNeighbors.length + 1 >= minSamples) {
          for (final idx in jNeighbors) {
            if (!seeds.contains(idx)) {
              seeds.add(idx);
            }
          }
        }
      }
      clusterId++;
    }

    return labels;
  }
}
