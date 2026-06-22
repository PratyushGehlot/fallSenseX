import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'dart:async';
import 'package:flutter/services.dart' show rootBundle;
import '../models/radar_models.dart';

export '../models/radar_models.dart' show RadarPoint, HumanDetection;

/// 3D Radar Visualization using WebView + Three.js
class Radar3DVisualization extends StatefulWidget {
  final double roomLength, roomWidth, roomHeight;
  final List<HumanDetection>? humanDetections;
  final List<RadarPoint>? radarPoints;
  final bool showPointCloud, showBoundingBoxes, showLabels;
  /// When provided, each emitted frame replaces the rendered point cloud live
  /// (used for the LAN TCP point-cloud stream) instead of the static
  /// [radarPoints] snapshot.
  final Stream<List<RadarPoint>>? livePointsStream;
  /// When provided, each emitted list replaces the rendered bounding
  /// boxes/labels live (e.g. client-side clustering results from the LAN
  /// stream) instead of the static [humanDetections] snapshot.
  final Stream<List<HumanDetection>>? liveDetectionsStream;

  const Radar3DVisualization({
    Key? key,
    this.roomLength = 10.0, this.roomWidth = 10.0, this.roomHeight = 8.0,
    this.humanDetections, this.radarPoints, this.livePointsStream, this.liveDetectionsStream,
    this.showPointCloud = true, this.showBoundingBoxes = true, this.showLabels = true,
  }) : super(key: key);

  @override
  State<Radar3DVisualization> createState() => _Radar3DVisualizationState();
}

class _Radar3DVisualizationState extends State<Radar3DVisualization> {
  late final WebViewController _controller;
  bool _isReady = false;
  final _initCompleter = Completer<void>();
  StreamSubscription<List<RadarPoint>>? _liveSubscription;
  StreamSubscription<List<HumanDetection>>? _liveDetectionsSubscription;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  @override
  void dispose() {
    _liveSubscription?.cancel();
    _liveDetectionsSubscription?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(Radar3DVisualization oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.livePointsStream != widget.livePointsStream) {
      _subscribeToLiveStream();
    }
    if (oldWidget.liveDetectionsStream != widget.liveDetectionsStream) {
      _subscribeToLiveDetectionsStream();
    }
    if (widget.livePointsStream == null && widget.humanDetections != oldWidget.humanDetections) {
      updateHumanDetections(widget.humanDetections ?? []);
    }
  }

  void _subscribeToLiveStream() {
    _liveSubscription?.cancel();
    if (widget.livePointsStream == null) return;
    _liveSubscription = widget.livePointsStream!.listen(updatePoints);
  }

  void _subscribeToLiveDetectionsStream() {
    _liveDetectionsSubscription?.cancel();
    if (widget.liveDetectionsStream == null) return;
    _liveDetectionsSubscription = widget.liveDetectionsStream!.listen(updateHumanDetections);
  }

  Future<void> _initController() async {
    _controller = WebViewController();
    // WebViewController defaults JavaScript to disabled - without this, the
    // entire Three.js scene script never runs and the page just paints the
    // CSS background (black), with nothing else ever rendering.
    await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    // Load HTML content from assets
    try {
      final htmlContent = await rootBundle.loadString('assets/radar_3d.html');
      _controller.loadHtmlString(htmlContent);
    } catch (e) {
      debugPrint('Failed to load HTML: $e');
      return;
    }
    // Wait for page to load then initialize
    _waitForPageLoad();
  }

  Future<void> _waitForPageLoad() async {
    await Future.delayed(const Duration(milliseconds: 1000));
    await _sendInitialData();
    if (!_initCompleter.isCompleted) {
      _initCompleter.complete();
    }
    if (mounted) {
      setState(() => _isReady = true);
    }
    _subscribeToLiveStream();
    _subscribeToLiveDetectionsStream();
  }

  Future<void> _sendInitialData() async {
    await _runJs("setRoomDimensions(${widget.roomLength}, ${widget.roomWidth}, ${widget.roomHeight});");
    if (widget.humanDetections != null) {
      await updateHumanDetections(widget.humanDetections!);
    }
    if (widget.radarPoints != null) {
      await updatePoints(widget.radarPoints!);
    }
  }

  Future<void> _runJs(String code) async {
    try {
      await _controller.runJavaScript(code);
    } catch (e) {
      debugPrint('JS error: $e');
    }
  }

  Future<void> updatePoints(List<RadarPoint> points) async {
    if (!_isReady) return;
    final json = jsonEncode(points.map((p) => p.toJson()).toList());
    await _runJs("updatePoints($json);");
  }

  Future<void> updateHumanDetections(List<HumanDetection> detections) async {
    if (!_isReady) return;
    if (detections.isEmpty) {
      await _runJs("updateHumanDetection(null);");
      return;
    }
    final json = jsonEncode(detections.map((d) => d.toJson()).toList());
    await _runJs("updateHumanDetection($json);");
  }

  Future<void> updateData({List<RadarPoint>? points, List<HumanDetection>? detections}) async {
    if (points != null) await updatePoints(points);
    if (detections != null) await updateHumanDetections(detections);
  }

  @override
  Widget build(BuildContext context) {
    return _isReady
        ? WebViewWidget(controller: _controller)
        : const Center(child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [CircularProgressIndicator(), SizedBox(height: 16), Text('Loading 3D Engine...')],
          ));
  }
}
