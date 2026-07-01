import 'package:flutter/material.dart';
import 'package:fall_sense_x_mobile/services/auth_service.dart';
import '../widgets/status_card.dart';

/// Mirrors the Tuya "My Home" / "Manage Home" screens. There is no
/// multi-home/group concept in the Firebase schema (devices belong directly
/// to ownerId + sharedWith), so this is intentionally a lightweight,
/// cosmetic single-home view rather than a real home-management backend.
class ManageHomePage extends StatelessWidget {
  const ManageHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = AuthService().currentUser();
    return Scaffold(
      appBar: AppBar(title: const Text('My Home')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: 'MEMBER'),
            SettingsSectionCard(children: [
              SettingsTile(
                icon: Icons.person_outline,
                title: user?.email ?? 'Me',
                value: 'Owner',
              ),
            ]),
            const SizedBox(height: 24),
            const SectionHeader(title: 'MANAGE HOME'),
            SettingsSectionCard(children: [
              SettingsTile(
                icon: Icons.devices_other_outlined,
                title: 'All Devices',
                onTap: () => Navigator.pop(context),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
