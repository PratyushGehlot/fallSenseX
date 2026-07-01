import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Version shown here mirrors pubspec.yaml's `version:` field directly,
/// rather than copying the premium reference's example "2.1.3".
const String kAppVersion = '1.0.0+1';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About FallSense')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(gradient: AppColors.heroGradient, shape: BoxShape.circle),
                child: const Icon(Icons.shield_outlined, color: Colors.white, size: 36),
              ),
            ),
            const SizedBox(height: 16),
            const Center(child: Text('FallSenseX', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
            const SizedBox(height: 4),
            const Center(child: Text('Version $kAppVersion', style: TextStyle(color: AppColors.textSecondary))),
            const SizedBox(height: 24),
            const Text(
              'FallSenseX is a radar-based fall detection and presence monitoring system. '
              'It tracks posture and movement without a camera, alerting you when a fall is detected.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            const Text(
              'Built with Flutter and Firebase. Detection runs entirely on-device using mmWave radar.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
