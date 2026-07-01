import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:fall_sense_x_mobile/models/radar_models.dart';
import '../theme/app_theme.dart';

enum _Period { day, week, month, custom }

class _StatusEvent {
  final String label;
  final Color color;
  final DateTime time;

  const _StatusEvent({required this.label, required this.color, required this.time});
}

/// Posture -> one of the three Activity Breakdown buckets shown in the
/// premium reference.
String _activityBucket(String posture) {
  switch (posture.toUpperCase()) {
    case 'SITTING':
      return 'Sitting / Resting';
    case 'LYING':
    case 'SLEEPING':
      return 'Lying Down';
    default:
      return 'Moving Around';
  }
}

/// Reports page: Day/Week/Month/Custom period picker, Activity Summary
/// cards (with vs-previous-period deltas), an hourly Activity Timeline bar
/// chart, and an Activity Breakdown by posture - all computed from the same
/// /devices/{deviceId}/frames stream DashboardPage already uses (bucketing
/// consecutive frames into status transitions and time-weighted durations).
class DetectionTrendsPage extends StatefulWidget {
  final String deviceId;
  const DetectionTrendsPage({super.key, required this.deviceId});

  @override
  State<DetectionTrendsPage> createState() => _DetectionTrendsPageState();
}

class _DetectionTrendsPageState extends State<DetectionTrendsPage> {
  _Period _period = _Period.day;
  DateTime _anchor = DateTime.now();
  DateTimeRange? _customRange;
  StreamSubscription<DatabaseEvent>? _sub;
  List<Map<String, dynamic>> _frames = [];

  @override
  void initState() {
    super.initState();
    _sub = FirebaseDatabase.instance
        .ref('devices/${widget.deviceId}/frames')
        .limitToLast(2000)
        .onValue
        .listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value;
      final frames = <Map<String, dynamic>>[];
      if (data is Map) {
        data.forEach((key, value) {
          if (value is Map) frames.add(Map<String, dynamic>.from(value));
        });
        frames.sort((a, b) => frameTimestampMs(a).compareTo(frameTimestampMs(b)));
      }
      setState(() => _frames = frames);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  DateTime get _dayStart => DateTime(_anchor.year, _anchor.month, _anchor.day);

  DateTimeRange get _currentRange {
    switch (_period) {
      case _Period.day:
        return DateTimeRange(start: _dayStart, end: _dayStart.add(const Duration(days: 1)));
      case _Period.week:
        return DateTimeRange(start: _dayStart.subtract(const Duration(days: 6)), end: _dayStart.add(const Duration(days: 1)));
      case _Period.month:
        return DateTimeRange(start: _dayStart.subtract(const Duration(days: 29)), end: _dayStart.add(const Duration(days: 1)));
      case _Period.custom:
        return _customRange ?? DateTimeRange(start: _dayStart, end: _dayStart.add(const Duration(days: 1)));
    }
  }

  DateTimeRange get _previousRange {
    final current = _currentRange;
    final span = current.end.difference(current.start);
    return DateTimeRange(start: current.start.subtract(span), end: current.start);
  }

  List<Map<String, dynamic>> _framesInRange(DateTimeRange range) {
    return _frames.where((f) {
      final t = DateTime.fromMillisecondsSinceEpoch(frameTimestampMs(f));
      return !t.isBefore(range.start) && t.isBefore(range.end);
    }).toList();
  }

  String _statusLabel(Map<String, dynamic> frame) {
    final detections = humanDetectionsFromFrameMap(frame);
    final present = frame['present'] as bool? ?? false;
    if (detections.any((d) => d.posture.toUpperCase() == 'FALL')) return 'Someone falls down';
    if (present) return 'Falling detection';
    return 'Normal';
  }

  Color _statusColor(String label) {
    switch (label) {
      case 'Someone falls down':
        return AppColors.statusFall;
      case 'Falling detection':
        return AppColors.statusPresence;
      case 'Offline':
        return AppColors.statusOffline;
      default:
        return const Color(0xFFD8E8FF);
    }
  }

  /// Time-weighted duration each frame's status holds until the next frame
  /// (or range end for the last frame), summed per status label.
  Map<String, Duration> _durationsByLabel(List<Map<String, dynamic>> frames, DateTime rangeEnd) {
    final totals = <String, Duration>{};
    for (var i = 0; i < frames.length; i++) {
      final start = DateTime.fromMillisecondsSinceEpoch(frameTimestampMs(frames[i]));
      final end = i + 1 < frames.length ? DateTime.fromMillisecondsSinceEpoch(frameTimestampMs(frames[i + 1])) : rangeEnd;
      if (end.isBefore(start)) continue;
      final label = _statusLabel(frames[i]);
      totals[label] = (totals[label] ?? Duration.zero) + end.difference(start);
    }
    return totals;
  }

  /// Time-weighted duration per Activity Breakdown bucket (Moving Around /
  /// Sitting / Lying Down), only counting frames where someone is present.
  Map<String, Duration> _durationsByBucket(List<Map<String, dynamic>> frames, DateTime rangeEnd) {
    final totals = <String, Duration>{};
    for (var i = 0; i < frames.length; i++) {
      final frame = frames[i];
      final present = frame['present'] as bool? ?? false;
      if (!present) continue;
      final detections = humanDetectionsFromFrameMap(frame);
      if (detections.isEmpty) continue;
      final bucket = _activityBucket(detections.first.posture);
      final start = DateTime.fromMillisecondsSinceEpoch(frameTimestampMs(frame));
      final end = i + 1 < frames.length ? DateTime.fromMillisecondsSinceEpoch(frameTimestampMs(frames[i + 1])) : rangeEnd;
      if (end.isBefore(start)) continue;
      totals[bucket] = (totals[bucket] ?? Duration.zero) + end.difference(start);
    }
    return totals;
  }

  int _fallEpisodes(List<Map<String, dynamic>> frames) {
    var count = 0;
    String? lastLabel;
    for (final frame in frames) {
      final label = _statusLabel(frame);
      if (label == 'Someone falls down' && lastLabel != 'Someone falls down') count++;
      lastLabel = label;
    }
    return count;
  }

  List<_StatusEvent> _events(List<Map<String, dynamic>> frames) {
    final events = <_StatusEvent>[];
    String? lastLabel;
    for (final frame in frames) {
      final label = _statusLabel(frame);
      if (label != lastLabel) {
        events.add(_StatusEvent(label: label, color: _statusColor(label), time: DateTime.fromMillisecondsSinceEpoch(frameTimestampMs(frame))));
        lastLabel = label;
      }
    }
    return events.reversed.toList();
  }

  Future<void> _pickCustomRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
      initialDateRange: _customRange,
    );
    if (range != null) {
      setState(() {
        _period = _Period.custom;
        _customRange = DateTimeRange(start: range.start, end: range.end.add(const Duration(days: 1)));
      });
    }
  }

  void _shiftAnchor(int days) {
    setState(() => _anchor = _anchor.add(Duration(days: days)));
  }

  @override
  Widget build(BuildContext context) {
    final range = _currentRange;
    final frames = _framesInRange(range);
    final prevFrames = _framesInRange(_previousRange);

    final durations = _durationsByLabel(frames, range.end.isAfter(DateTime.now()) ? DateTime.now() : range.end);
    final prevDurations = _durationsByLabel(prevFrames, _previousRange.end);

    final activeTime = (durations['Falling detection'] ?? Duration.zero) + (durations['Someone falls down'] ?? Duration.zero);
    final prevActiveTime = (prevDurations['Falling detection'] ?? Duration.zero) + (prevDurations['Someone falls down'] ?? Duration.zero);
    final normalTime = durations['Normal'] ?? Duration.zero;
    final prevNormalTime = prevDurations['Normal'] ?? Duration.zero;
    final fallCount = _fallEpisodes(frames);
    final prevFallCount = _fallEpisodes(prevFrames);
    final activeAlerts = fallCount; // alerts == fall episodes today; no separate alert log exists yet
    final prevActiveAlerts = prevFallCount;

    final breakdown = _durationsByBucket(frames, range.end.isAfter(DateTime.now()) ? DateTime.now() : range.end);
    final breakdownTotal = breakdown.values.fold<Duration>(Duration.zero, (a, b) => a + b);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: [IconButton(icon: const Icon(Icons.calendar_today_outlined), onPressed: _pickCustomRange)],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
        children: [
          _buildPeriodToggle(),
          const SizedBox(height: 16),
          _buildDateNav(range),
          const SizedBox(height: 16),
          const Text('Activity Summary', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _buildSummaryCard(Icons.access_time, AppColors.accent, 'Active Time', _formatDuration(activeTime), _percentDelta(activeTime, prevActiveTime))),
              const SizedBox(width: 12),
              Expanded(child: _buildSummaryCard(Icons.check_circle_outline, AppColors.statusOnline, 'Normal Activity', _formatDuration(normalTime), _percentDelta(normalTime, prevNormalTime))),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _buildSummaryCard(Icons.warning_amber_outlined, AppColors.statusFall, 'Fall Detected', '$fallCount', _countDelta(fallCount, prevFallCount))),
              const SizedBox(width: 12),
              Expanded(child: _buildSummaryCard(Icons.notifications_none, AppColors.statusFall, 'Active Alerts', '$activeAlerts', _countDelta(activeAlerts, prevActiveAlerts))),
            ],
          ),
          const SizedBox(height: 24),
          const Text('Activity Timeline', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          SizedBox(height: 160, child: _buildTimelineChart(frames, range)),
          const SizedBox(height: 8),
          _buildTimelineLegend(),
          const SizedBox(height: 24),
          const Text('Activity Breakdown', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          _buildBreakdownRow('Moving Around', Icons.directions_walk, AppColors.statusOnline, breakdown['Moving Around'] ?? Duration.zero, breakdownTotal),
          _buildBreakdownRow('Sitting / Resting', Icons.chair_alt_outlined, AppColors.statusPresence, breakdown['Sitting / Resting'] ?? Duration.zero, breakdownTotal),
          _buildBreakdownRow('Lying Down', Icons.bed_outlined, const Color(0xFF8E5FE8), breakdown['Lying Down'] ?? Duration.zero, breakdownTotal),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(14)),
            child: const Row(
              children: [
                Icon(Icons.info_outline, color: AppColors.accent),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'All reports are based on AI analysis of sensor data. For medical advice, please consult a healthcare professional.',
                    style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          const Text('Recent Events', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (frames.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('No events recorded', style: TextStyle(color: AppColors.textSecondary))),
            )
          else
            ..._events(frames).take(20).map(_buildEventRow),
        ],
      ),
    );
  }

  Widget _buildPeriodToggle() {
    Widget pill(String label, _Period value) {
      final selected = _period == value;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _period = value),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(color: selected ? AppColors.accent : Colors.transparent, borderRadius: BorderRadius.circular(20)),
            alignment: Alignment.center,
            child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: selected ? Colors.white : AppColors.textSecondary)),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0xFFE5E5EA))),
      child: Row(
        children: [
          pill('Day', _Period.day),
          pill('Week', _Period.week),
          pill('Month', _Period.month),
          pill('Custom', _Period.custom),
        ],
      ),
    );
  }

  Widget _buildDateNav(DateTimeRange range) {
    if (_period == _Period.custom) {
      return Center(
        child: Text(
          '${_formatDate(range.start)} - ${_formatDate(range.end.subtract(const Duration(days: 1)))}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      );
    }
    if (_period != _Period.day) {
      return Center(
        child: Text('${_formatDate(range.start)} - ${_formatDate(range.end.subtract(const Duration(days: 1)))}', style: const TextStyle(fontWeight: FontWeight.w600)),
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _shiftAnchor(-1)),
        Text(_formatDate(_anchor), style: const TextStyle(fontWeight: FontWeight.w600)),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          onPressed: _dayStart.isBefore(DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day)) ? () => _shiftAnchor(1) : null,
        ),
      ],
    );
  }

  Widget _buildSummaryCard(IconData icon, Color color, String label, String value, Widget delta) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [Icon(icon, size: 16, color: color), const Spacer(), delta]),
            const SizedBox(height: 8),
            Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }

  Widget _percentDelta(Duration current, Duration previous) {
    if (previous == Duration.zero) {
      return current == Duration.zero ? const SizedBox.shrink() : const Text('New', style: TextStyle(fontSize: 10, color: AppColors.statusOnline));
    }
    final pct = ((current.inSeconds - previous.inSeconds) / previous.inSeconds * 100).round();
    final up = pct >= 0;
    return Text(
      '${up ? '+' : ''}$pct%',
      style: TextStyle(fontSize: 10, color: up ? AppColors.statusOnline : AppColors.statusFall, fontWeight: FontWeight.w600),
    );
  }

  Widget _countDelta(int current, int previous) {
    final diff = current - previous;
    if (diff == 0) return const Text('No change', style: TextStyle(fontSize: 10, color: AppColors.textSecondary));
    final up = diff > 0;
    return Text(
      '${up ? '+' : ''}$diff vs prev',
      style: TextStyle(fontSize: 10, color: up ? AppColors.statusFall : AppColors.statusOnline, fontWeight: FontWeight.w600),
    );
  }

  Widget _buildTimelineChart(List<Map<String, dynamic>> frames, DateTimeRange range) {
    final bucketCount = _period == _Period.day ? 24 : 10;
    final bucketSpan = range.end.difference(range.start).inMilliseconds / bucketCount;
    final levels = List<double>.filled(bucketCount, 0);

    for (final frame in frames) {
      final t = DateTime.fromMillisecondsSinceEpoch(frameTimestampMs(frame)).difference(range.start).inMilliseconds;
      final bucket = bucketSpan <= 0 ? 0 : (t / bucketSpan).floor().clamp(0, bucketCount - 1);
      final present = frame['present'] as bool? ?? false;
      final hasFallen = humanDetectionsFromFrameMap(frame).any((d) => d.posture.toUpperCase() == 'FALL');
      final level = hasFallen ? 3.0 : (present ? 2.0 : 0.5);
      if (level > levels[bucket]) levels[bucket] = level;
    }

    return BarChart(
      BarChartData(
        maxY: 3,
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: const FlTitlesData(
          leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        barGroups: List.generate(
          bucketCount,
          (i) => BarChartGroupData(x: i, barRods: [
            BarChartRodData(
              toY: levels[i] == 0 ? 0.15 : levels[i],
              width: bucketCount > 12 ? 6 : 12,
              borderRadius: BorderRadius.circular(3),
              color: levels[i] >= 3
                  ? AppColors.statusFall
                  : levels[i] >= 2
                      ? AppColors.accent
                      : const Color(0xFFD8E8FF),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildTimelineLegend() {
    Widget dot(Color c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: c)),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
        ]);
    return Wrap(spacing: 12, children: [
      dot(const Color(0xFFD8E8FF), 'Low Activity'),
      dot(AppColors.accent, 'Normal Activity'),
      dot(AppColors.statusFall, 'High Activity'),
    ]);
  }

  Widget _buildBreakdownRow(String label, IconData icon, Color color, Duration duration, Duration total) {
    final pct = total.inSeconds == 0 ? 0 : (duration.inSeconds / total.inSeconds * 100).round();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    Text('${_formatDuration(duration)} · $pct%', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: pct / 100, minHeight: 6, backgroundColor: const Color(0xFFE5E5EA), color: color),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, size: 18, color: AppColors.textSecondary),
        ],
      ),
    );
  }

  Widget _buildEventRow(_StatusEvent e) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: e.color)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  '${e.time.day.toString().padLeft(2, '0')}/${e.time.month.toString().padLeft(2, '0')}, '
                  '${e.time.hour.toString().padLeft(2, '0')}:${e.time.minute.toString().padLeft(2, '0')}:${e.time.second.toString().padLeft(2, '0')}',
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h == 0) return '${m}m';
    return '${h}h ${m}m';
  }

  String _formatDate(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}
