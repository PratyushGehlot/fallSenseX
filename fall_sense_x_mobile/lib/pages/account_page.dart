import 'package:flutter/material.dart';
import 'package:fall_sense_x_mobile/services/auth_service.dart';
import '../theme/app_theme.dart';
import '../widgets/status_card.dart';

class AccountPage extends StatelessWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = AuthService().currentUser();
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 36,
                    backgroundColor: AppColors.accentLight,
                    child: Text(
                      (user?.email?.isNotEmpty ?? false) ? user!.email![0].toUpperCase() : '?',
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: AppColors.accent),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(user?.email ?? 'Signed in', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const SectionHeader(title: 'ACCOUNT INFO'),
            SettingsSectionCard(children: [
              SettingsTile(icon: Icons.email_outlined, title: 'Email', value: user?.email ?? '—'),
              SettingsTile(icon: Icons.badge_outlined, title: 'User ID', value: _shortUid(user?.uid)),
              SettingsTile(
                icon: Icons.verified_user_outlined,
                title: 'Email Verified',
                value: (user?.emailVerified ?? false) ? 'Yes' : 'No',
              ),
            ]),
          ],
        ),
      ),
    );
  }

  String _shortUid(String? uid) {
    if (uid == null || uid.isEmpty) return '—';
    return uid.length > 12 ? '${uid.substring(0, 12)}…' : uid;
  }
}
