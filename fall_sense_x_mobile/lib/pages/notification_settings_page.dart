import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:fall_sense_x_mobile/services/auth_service.dart';
import '../widgets/status_card.dart';

/// Real toggles, not decorative ones:
/// - Fall Alerts subscribes/unsubscribes from every owned/shared device's
///   `device_{id}_alerts` FCM topic (the same topic dashboard_page.dart
///   subscribes to on open) - turning it off stops fall-alert pushes for
///   all of this user's devices.
/// - Offline Alerts is read by dashboard_page.dart before firing the local
///   "Device Offline" notification.
/// Both are persisted under users/{uid}/notificationPrefs.
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() => _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  final DeviceService _deviceService = DeviceService();
  bool _fallAlerts = true;
  bool _offlineAlerts = true;
  bool _loading = true;
  String? _uid;

  DatabaseReference get _prefsRef => FirebaseDatabase.instance.ref('users/$_uid/notificationPrefs');

  @override
  void initState() {
    super.initState();
    _uid = AuthService().currentUser()?.uid;
    _load();
  }

  Future<void> _load() async {
    if (_uid == null) return;
    final snapshot = await _prefsRef.get();
    if (snapshot.exists && snapshot.value is Map) {
      final prefs = Map<String, dynamic>.from(snapshot.value as Map);
      setState(() {
        _fallAlerts = prefs['fallAlerts'] as bool? ?? true;
        _offlineAlerts = prefs['offlineAlerts'] as bool? ?? true;
      });
    }
    setState(() => _loading = false);
  }

  Future<void> _setFallAlerts(bool value) async {
    setState(() => _fallAlerts = value);
    await _prefsRef.update({'fallAlerts': value});

    final userId = _uid;
    if (userId == null) return;
    final snapshot = await _deviceService.getUserDevices(userId).first;
    final raw = snapshot.snapshot.value;
    if (raw is! Map) return;
    for (final entry in raw.entries) {
      final data = entry.value as Map;
      final isMine = data['ownerId'] == userId || (data['sharedWith']?[userId] == true);
      if (!isMine) continue;
      final topic = 'device_${entry.key}_alerts';
      if (value) {
        await FirebaseMessaging.instance.subscribeToTopic(topic);
      } else {
        await FirebaseMessaging.instance.unsubscribeFromTopic(topic);
      }
    }
  }

  Future<void> _setOfflineAlerts(bool value) async {
    setState(() => _offlineAlerts = value);
    await _prefsRef.update({'offlineAlerts': value});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notification Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeader(title: 'ALERT TYPES'),
                  SettingsSectionCard(children: [
                    SettingsTile(
                      icon: Icons.warning_amber_outlined,
                      title: 'Fall Alerts',
                      subtitle: 'Push notifications when a fall is detected on any of your devices',
                      trailingWidget: Switch(value: _fallAlerts, onChanged: _setFallAlerts),
                    ),
                    SettingsTile(
                      icon: Icons.wifi_off,
                      title: 'Offline Alerts',
                      subtitle: 'Notify me when a device stops responding',
                      trailingWidget: Switch(value: _offlineAlerts, onChanged: _setOfflineAlerts),
                    ),
                  ]),
                ],
              ),
            ),
    );
  }
}
