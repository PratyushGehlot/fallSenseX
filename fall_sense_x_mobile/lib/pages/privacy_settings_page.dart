import 'package:flutter/material.dart';
import '../widgets/status_card.dart';

class PrivacySettingsPage extends StatelessWidget {
  const PrivacySettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SectionHeader(title: 'YOUR DATA'),
          SettingsSectionCard(children: [
            SettingsTile(
              icon: Icons.sensors_outlined,
              title: 'Sensor Data',
              subtitle: 'Presence, posture, and fall-detection events are stored under your account '
                  'and only visible to you and anyone you explicitly share a device with.',
            ),
            SettingsTile(
              icon: Icons.lock_outline,
              title: 'Encryption',
              subtitle: 'Data is transmitted over TLS and stored in Firebase, access-controlled by '
                  'per-device ownership and sharing rules.',
            ),
            SettingsTile(
              icon: Icons.share_outlined,
              title: 'Sharing',
              subtitle: 'Devices are only visible to other accounts you explicitly share them with, '
                  'via email, UID, or invite code.',
            ),
          ]),
          const SizedBox(height: 16),
          const SectionHeader(title: 'ACCOUNT DATA'),
          SettingsSectionCard(children: [
            SettingsTile(
              icon: Icons.delete_outline,
              title: 'Delete My Data',
              subtitle: 'To request account or device data deletion, contact support (see Help & Support).',
            ),
          ]),
        ],
      ),
    );
  }
}
