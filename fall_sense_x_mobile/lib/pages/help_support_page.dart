import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/status_card.dart';
import '../widgets/installation_guide_carousel.dart';

const _supportEmail = 'support@fallsensex.example';

class HelpSupportPage extends StatelessWidget {
  const HelpSupportPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Help & Support')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
        children: [
          const SectionHeader(title: 'GET STARTED'),
          SettingsSectionCard(children: [
            SettingsTile(
              icon: Icons.menu_book_outlined,
              title: 'Installation Guide',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const InstallationGuideCarousel()),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          const SectionHeader(title: 'FAQ'),
          SettingsSectionCard(children: [
            SettingsTile(
              icon: Icons.wifi_off,
              title: 'My device shows Offline',
              subtitle: 'Check it has power and your Wi-Fi network is up. Devices report offline if no '
                  'heartbeat is received for 75 seconds.',
            ),
            SettingsTile(
              icon: Icons.accessibility_new,
              title: 'Posture detection seems off',
              subtitle: 'Run Posture Calibration from Device Settings - it teaches the sensor your '
                  'specific standing/sitting/lying heights.',
            ),
            SettingsTile(
              icon: Icons.bluetooth_disabled,
              title: 'Bluetooth setup isn\'t finding my device',
              subtitle: 'Bluetooth pairing isn\'t supported by the current firmware yet - add your '
                  'device by ID instead.',
            ),
          ]),
          const SizedBox(height: 16),
          const SectionHeader(title: 'CONTACT'),
          SettingsSectionCard(children: [
            SettingsTile(
              icon: Icons.mail_outline,
              title: 'Email Support',
              value: _supportEmail,
              onTap: () async {
                await Clipboard.setData(const ClipboardData(text: _supportEmail));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Support email copied to clipboard')),
                  );
                }
              },
            ),
          ]),
        ],
      ),
    );
  }
}
