import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_database/firebase_database.dart';
import 'package:fall_sense_x_mobile/services/auth_service.dart';
import '../theme/app_theme.dart';

class _PostureStep {
  final String phase; // standing | sitting | lying - matches firmware's /radar_calibrate
  final String title;
  final String instruction;
  final IconData icon;

  const _PostureStep({required this.phase, required this.title, required this.instruction, required this.icon});
}

const _steps = [
  _PostureStep(
    phase: 'standing',
    title: 'Standing',
    instruction: 'Please stand still and upright, directly under the sensor.',
    icon: Icons.accessibility_new,
  ),
  _PostureStep(
    phase: 'sitting',
    title: 'Sitting',
    instruction: 'Please sit in your usual position, under the sensor.',
    icon: Icons.chair_alt_outlined,
  ),
  _PostureStep(
    phase: 'lying',
    title: 'Lying Down',
    instruction: 'Please lie down in your usual sleeping position, under the sensor.',
    icon: Icons.bed_outlined,
  ),
];

/// Posture Calibration flow, mirroring the premium reference UI. Unlike the
/// Device Calibration wizard's Scan Room / Set Zones steps, this is fully
/// functional: it calls the firmware's real POST /radar_calibrate endpoint
/// (main/app/web_server.c) over the local network, authenticated with the
/// device's PIN (same pattern live_3d_view_page.dart uses for the LAN TCP
/// stream - the device must be on the same Wi-Fi network as the phone).
class PostureCalibrationPage extends StatefulWidget {
  final String deviceId;
  const PostureCalibrationPage({super.key, required this.deviceId});

  @override
  State<PostureCalibrationPage> createState() => _PostureCalibrationPageState();
}

class _PostureCalibrationPageState extends State<PostureCalibrationPage> {
  bool _started = false;
  int _stepIndex = 0;
  bool _isCapturing = false;
  int _countdown = 3;
  Timer? _timer;
  String? _error;
  Completer<void>? _countdownDone;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<String?> _resolveDeviceIp() async {
    final snap = await FirebaseDatabase.instance.ref('devices/${widget.deviceId}/info/ip_address').get();
    return snap.value?.toString();
  }

  /// /radar_calibrate captures an instant snapshot of the current detected
  /// height server-side - there's no real multi-second "capturing" process
  /// on the device. This short pre-roll just gives the person time to settle
  /// into position before the snapshot is taken, rather than faking a long
  /// countdown around a call that would actually resolve almost immediately.
  Future<void> _captureCurrentStep() async {
    setState(() {
      _isCapturing = true;
      _countdown = 3;
      _error = null;
    });

    _timer?.cancel();
    _countdownDone = Completer<void>();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _countdown--);
      if (_countdown <= 0) {
        t.cancel();
        _countdownDone?.complete();
      }
    });
    await _countdownDone?.future;
    if (!mounted || !_isCapturing) return;

    try {
      final ip = await _resolveDeviceIp();
      if (ip == null || ip.isEmpty) {
        throw Exception('Device IP not known yet - make sure the device is online and on the same Wi-Fi network.');
      }
      final pin = await DeviceService().getDevicePin(widget.deviceId);
      final response = await http
          .post(
            Uri.parse('http://$ip/radar_calibrate'),
            headers: {
              'Content-Type': 'application/json',
              if (pin != null) 'X-Device-PIN': pin,
            },
            body: jsonEncode({'phase': _steps[_stepIndex].phase}),
          )
          .timeout(const Duration(seconds: 10));

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['success'] != true) {
        throw Exception(body['error']?.toString() ?? 'Calibration failed');
      }

      _timer?.cancel();
      if (!mounted) return;
      if (_stepIndex < _steps.length - 1) {
        setState(() {
          _stepIndex++;
          _isCapturing = false;
        });
      } else {
        setState(() => _isCapturing = false);
        _showComplete();
      }
    } catch (e) {
      _timer?.cancel();
      if (!mounted) return;
      setState(() {
        _isCapturing = false;
        _error = '$e';
      });
    }
  }

  void _stopCapture() {
    _timer?.cancel();
    setState(() => _isCapturing = false);
    if (_countdownDone?.isCompleted == false) {
      _countdownDone?.complete();
    }
  }

  void _showComplete() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Calibration Complete'),
        content: const Text('Posture thresholds have been updated on your device.'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context);
            },
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Posture Calibration')),
      body: _started ? _buildStepView() : _buildIntro(),
    );
  }

  Widget _buildIntro() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 96,
              height: 96,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.accentLight),
              child: const Icon(Icons.accessibility_new, size: 48, color: AppColors.accent),
            ),
          ),
          const SizedBox(height: 24),
          const Text('Calibrate Posture Detection', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'We\'ll learn your natural postures to detect movements and falls more accurately.',
            style: TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 24),
          _buildBullet(Icons.person_outline, 'Personalized to you', 'Better posture detection for your height'),
          _buildBullet(Icons.timer_outlined, 'Takes less than 2 minutes', '3 short steps: standing, sitting, lying down'),
          _buildBullet(Icons.wifi, 'Requires the same Wi-Fi network', 'Your phone must be on the same network as the device'),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => setState(() => _started = true),
              child: const Text('Start Calibration'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBullet(IconData icon, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.accent, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(subtitle, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepView() {
    final step = _steps[_stepIndex];
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: List.generate(_steps.length, (i) {
              final reached = i <= _stepIndex;
              return Expanded(
                child: Container(
                  margin: const EdgeInsets.only(right: 6),
                  height: 4,
                  decoration: BoxDecoration(
                    color: reached ? AppColors.accent : const Color(0xFFE5E5EA),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 8),
          Text('${_stepIndex + 1}. ${step.title}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 24),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 160,
                    height: 160,
                    decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.accentLight),
                    child: Icon(step.icon, size: 72, color: AppColors.accent),
                  ),
                  const SizedBox(height: 24),
                  Text(step.instruction, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textSecondary)),
                  const SizedBox(height: 16),
                  if (_isCapturing) ...[
                    Text('Calibration in progress…', style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Text('Please hold still', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                    const SizedBox(height: 16),
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: AppColors.accentLight,
                      child: Text('$_countdown', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.statusFall)),
                  ],
                ],
              ),
            ),
          ),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isCapturing ? null : _captureCurrentStep,
              child: Text(_isCapturing ? 'Capturing…' : 'Start'),
            ),
          ),
          if (_isCapturing) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(onPressed: _stopCapture, child: const Text('Stop')),
            ),
          ],
        ],
      ),
    );
  }
}
