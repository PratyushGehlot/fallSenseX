import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fall_sense_x_mobile/services/auth_service.dart';
import '../theme/app_theme.dart';
import 'share_device_page.dart';

/// "Device Sharing" settings entry: lists the user's devices and jumps to
/// the per-device Share Device page (this app's permission model is
/// per-device, not a single global toggle, so this page is a picker rather
/// than a standalone settings surface).
class DeviceSharingPage extends StatefulWidget {
  const DeviceSharingPage({super.key});

  @override
  State<DeviceSharingPage> createState() => _DeviceSharingPageState();
}

class _DeviceSharingPageState extends State<DeviceSharingPage> {
  final DeviceService _deviceService = DeviceService();
  StreamSubscription? _sub;
  List<Map<String, dynamic>> _devices = [];

  @override
  void initState() {
    super.initState();
    final userId = AuthService().currentUser()?.uid;
    if (userId != null) {
      _sub = _deviceService.getUserDevices(userId).listen((event) {
        if (!mounted) return;
        final value = event.snapshot.value;
        if (value is Map) {
          setState(() {
            _devices = value.entries
                .where((e) {
                  final data = e.value as Map;
                  return data['ownerId'] == userId ||
                      (data['sharedWith'] != null && (data['sharedWith'] as Map)[userId] == true);
                })
                .map((e) => {
                      'id': e.key,
                      ...Map<String, dynamic>.from(e.value),
                      'isOwner': (e.value as Map)['ownerId'] == userId,
                    })
                .toList();
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Device Sharing')),
      body: _devices.isEmpty
          ? const Center(child: Text('No devices yet', style: TextStyle(color: AppColors.textSecondary)))
          : ListView.separated(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
              itemCount: _devices.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final device = _devices[index];
                final isOwner = device['isOwner'] == true;
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.sensors, color: AppColors.accent),
                    title: Text(device['name'] ?? device['id']),
                    subtitle: Text(isOwner ? 'Owned by you' : 'Shared with you'),
                    trailing: isOwner
                        ? const Icon(Icons.chevron_right)
                        : const Icon(Icons.visibility_outlined, color: AppColors.textSecondary),
                    onTap: isOwner
                        ? () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ShareDevicePage(deviceId: device['id'], deviceName: device['name'] ?? device['id']),
                              ),
                            )
                        : null,
                  ),
                );
              },
            ),
    );
  }
}
