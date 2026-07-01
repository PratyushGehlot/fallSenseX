import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../theme/app_theme.dart';
import '../widgets/status_card.dart';

/// Per-device alert preferences. Unlike the global toggle in
/// notification_settings_page.dart (which subscribes/unsubscribes every
/// device at once), this scopes fall/offline alert subscriptions to just
/// this one device's FCM topic - useful once a user has more than one
/// sensor and wants to mute a specific room.
class DeviceAlertsPage extends StatefulWidget {
  final String deviceId;
  final String deviceName;
  const DeviceAlertsPage({super.key, required this.deviceId, required this.deviceName});

  @override
  State<DeviceAlertsPage> createState() => _DeviceAlertsPageState();
}

class _DeviceAlertsPageState extends State<DeviceAlertsPage> {
  bool _fallAlerts = true;
  bool _offlineAlerts = true;
  bool _loading = true;

  DatabaseReference get _prefsRef => FirebaseDatabase.instance.ref('devices/${widget.deviceId}/alertPrefs');
  String get _topic => 'device_${widget.deviceId}_alerts';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
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
    if (value) {
      await FirebaseMessaging.instance.subscribeToTopic(_topic);
    } else {
      await FirebaseMessaging.instance.unsubscribeFromTopic(_topic);
    }
  }

  Future<void> _setOfflineAlerts(bool value) async {
    setState(() => _offlineAlerts = value);
    await _prefsRef.update({'offlineAlerts': value});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Device Alerts')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.deviceName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  const Text(
                    'These settings only apply to this device. Use Notification Settings to manage alerts across all your devices.',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  SettingsSectionCard(children: [
                    SettingsTile(
                      icon: Icons.warning_amber_outlined,
                      title: 'Fall Alerts',
                      subtitle: 'Push notification when this device detects a fall',
                      trailingWidget: Switch(value: _fallAlerts, onChanged: _setFallAlerts),
                    ),
                    SettingsTile(
                      icon: Icons.wifi_off,
                      title: 'Offline Alerts',
                      subtitle: 'Notify me if this device stops responding',
                      trailingWidget: Switch(value: _offlineAlerts, onChanged: _setOfflineAlerts),
                    ),
                  ]),
                ],
              ),
            ),
    );
  }
}
