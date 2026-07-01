import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:fall_sense_x_mobile/services/auth_service.dart';
import 'package:fall_sense_x_mobile/services/ota_service.dart';
import 'package:fall_sense_x_mobile/models/radar_models.dart';
import '../theme/app_theme.dart';
import '../widgets/status_card.dart';
import 'dashboard_page.dart' show OtaUpdateSheet;
import 'share_device_page.dart';
import 'detection_trends_page.dart';
import '../widgets/installation_guide_carousel.dart';
import 'device_calibration_wizard_page.dart';
import 'posture_calibration_page.dart';
import 'activity_zones_page.dart';
import 'device_alerts_page.dart';

/// Device detail/settings screen, matching the premium reference's Device
/// Settings UI. Camera-only items from the earlier Tuya-style reference
/// (HDR, watermark, image rotation, Wi-Fi SSID) remain skipped since they
/// don't apply to a fall-detection radar sensor.
class DeviceSettingsPage extends StatefulWidget {
  final String deviceId;
  const DeviceSettingsPage({super.key, required this.deviceId});

  @override
  State<DeviceSettingsPage> createState() => _DeviceSettingsPageState();
}

class _DeviceSettingsPageState extends State<DeviceSettingsPage> {
  final DeviceService _deviceService = DeviceService();
  StreamSubscription? _deviceSub;
  StreamSubscription? _infoSub;
  StreamSubscription? _onlineSub;
  StreamSubscription? _frameSub;
  StreamSubscription? _prefsSub;
  Map<String, dynamic>? _device;
  String? _firmwareVersion;
  String? _latestFirmwareVersion;
  String? _deviceModel;
  String? _pin;
  bool _isOwner = false;
  bool _isOnline = false;
  DateTime? _lastSeen;
  int? _rssi;
  bool _hasFallen = false;
  int _zoneCount = 0;
  bool _postureTracking = true;
  bool _fallDetectionAlerts = true;
  bool _nightMode = false;
  bool _statusLedEnabled = true;
  String? _latestFirmwareUrl;

  bool get _updateAvailable =>
      _firmwareVersion != null &&
      _latestFirmwareVersion != null &&
      OtaService.compareVersions(_latestFirmwareVersion!, _firmwareVersion!) > 0;

  @override
  void initState() {
    super.initState();
    final userId = AuthService().currentUser()?.uid;
    _deviceSub = _deviceService.getDeviceData(widget.deviceId).listen((event) {
      if (!mounted) return;
      final value = event.snapshot.value;
      if (value is Map) {
        final wasOwner = _isOwner;
        setState(() {
          _device = Map<String, dynamic>.from(value);
          _isOwner = _device?['ownerId'] == userId;
          _nightMode = (_device?['uiPrefs'] as Map?)?['nightModeEnabled'] as bool? ?? false;
          _postureTracking = (_device?['uiPrefs'] as Map?)?['postureTrackingEnabled'] as bool? ?? true;
          _statusLedEnabled = (_device?['uiPrefs'] as Map?)?['statusLedEnabled'] as bool? ?? true;
        });
        if (_isOwner && !wasOwner) _loadPin();
      }
    });
    _infoSub = OtaService.infoRef(widget.deviceId).onValue.listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value;
      if (data is Map) {
        setState(() {
          _firmwareVersion = data['firmwareVersion']?.toString();
          _deviceModel = data['deviceModel']?.toString();
        });
        OtaService.manifestRef(_deviceModel ?? 'fallsensex').onValue.listen((manifestEvent) {
          if (!mounted) return;
          final manifest = manifestEvent.snapshot.value;
          if (manifest is Map) {
            setState(() {
              _latestFirmwareVersion = manifest['version']?.toString();
              _latestFirmwareUrl = manifest['url']?.toString();
            });
          }
        });
      }
    });
    _onlineSub = FirebaseDatabase.instance.ref('devices/${widget.deviceId}/online').onValue.listen((event) {
      if (!mounted) return;
      final data = event.snapshot.value;
      bool isOnline = false;
      int? rssi;
      if (data is Map && data['value'] == true && data['timestamp'] != null) {
        final ts = DateTime.fromMillisecondsSinceEpoch((data['timestamp'] as num).toInt() * 1000);
        _lastSeen = ts;
        isOnline = DateTime.now().difference(ts) < const Duration(seconds: 75);
        rssi = (data['rssi'] as num?)?.toInt();
      }
      setState(() {
        _isOnline = isOnline;
        _rssi = rssi;
      });
    });
    _frameSub = FirebaseDatabase.instance
        .ref('devices/${widget.deviceId}/frames')
        .limitToLast(1)
        .onValue
        .listen((event) {
      if (!mounted) return;
      final latest = latestFrameFromSnapshot(event.snapshot.value);
      final detections = latest != null ? humanDetectionsFromFrameMap(latest) : <HumanDetection>[];
      setState(() => _hasFallen = detections.any((d) => d.posture.toUpperCase() == 'FALL'));
    });
    _prefsSub = FirebaseDatabase.instance.ref('devices/${widget.deviceId}/alertPrefs/fallAlerts').onValue.listen((event) {
      if (!mounted) return;
      setState(() => _fallDetectionAlerts = event.snapshot.value as bool? ?? true);
    });
    _loadZoneCount();
  }

  Future<void> _loadZoneCount() async {
    final zones = await _deviceService.getZones(widget.deviceId);
    if (mounted) setState(() => _zoneCount = zones.length);
  }

  Future<void> _loadPin() async {
    final pin = await _deviceService.getDevicePin(widget.deviceId);
    if (mounted) setState(() => _pin = pin);
  }

  @override
  void dispose() {
    _deviceSub?.cancel();
    _infoSub?.cancel();
    _onlineSub?.cancel();
    _frameSub?.cancel();
    _prefsSub?.cancel();
    super.dispose();
  }

  Future<void> _renameDevice() async {
    final controller = TextEditingController(text: _device?['name'] ?? '');
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Device Name'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty) {
      await _deviceService.renameDevice(widget.deviceId, newName);
    }
  }

  Future<void> _setPostureTracking(bool value) async {
    setState(() => _postureTracking = value);
    await FirebaseDatabase.instance.ref('devices/${widget.deviceId}/uiPrefs/postureTrackingEnabled').set(value);
  }

  Future<void> _setFallDetectionAlerts(bool value) async {
    setState(() => _fallDetectionAlerts = value);
    await FirebaseDatabase.instance.ref('devices/${widget.deviceId}/alertPrefs/fallAlerts').set(value);
    final topic = 'device_${widget.deviceId}_alerts';
    if (value) {
      await FirebaseMessaging.instance.subscribeToTopic(topic);
    } else {
      await FirebaseMessaging.instance.unsubscribeFromTopic(topic);
    }
  }

  Future<void> _setNightMode(bool value) async {
    setState(() => _nightMode = value);
    await FirebaseDatabase.instance.ref('devices/${widget.deviceId}/uiPrefs/nightModeEnabled').set(value);
  }

  /// Real toggle: firmware polls this path every 5s (see
  /// firebase_get_status_led_enabled in firebase.c) and sets WS2812
  /// brightness to 0/255 accordingly - the only on-device indicator
  /// affected is the status LED, not detection itself.
  Future<void> _setStatusLedEnabled(bool value) async {
    setState(() => _statusLedEnabled = value);
    await FirebaseDatabase.instance.ref('devices/${widget.deviceId}/uiPrefs/statusLedEnabled').set(value);
  }

  Future<void> _confirmRestart() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restart Device'),
        content: const Text('The device will reboot and be briefly offline. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Restart')),
        ],
      ),
    );
    if (confirmed == true) {
      await _deviceService.restartDevice(widget.deviceId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Restart command sent')));
      }
    }
  }

  Future<void> _confirmUnshare() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave Device'),
        content: const Text('This will remove your access to this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave', style: TextStyle(color: AppColors.statusFall)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final userId = AuthService().currentUser()?.uid;
      if (userId != null) {
        await _deviceService.unshareDevice(widget.deviceId, userId);
      }
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _confirmRemoveDevice() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Device'),
        content: const Text(
          'This unregisters the device from your account and removes everyone\'s access. '
          'The physical device keeps working and can be re-added later. This can\'t be undone from here.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove', style: TextStyle(color: AppColors.statusFall)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _deviceService.removeDevice(widget.deviceId);
      if (mounted) Navigator.popUntil(context, (route) => route.isFirst);
    }
  }

  String _formatLastSeen() {
    if (_lastSeen == null) return '—';
    final diff = DateTime.now().difference(_lastSeen!);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  /// rssi comes straight from the device's heartbeat PUT (esp_wifi_sta_get_ap_info,
  /// see firebase_post_heartbeat) - real dBm reading from the radio, not a guess.
  String _wifiStrengthLabel() {
    if (!_isOnline || _rssi == null) return '—';
    final r = _rssi!;
    if (r >= -55) return 'Excellent';
    if (r >= -67) return 'Good';
    if (r >= -75) return 'Fair';
    return 'Weak';
  }

  Color _wifiStrengthColor() {
    if (!_isOnline || _rssi == null) return AppColors.textSecondary;
    final r = _rssi!;
    if (r >= -67) return AppColors.statusOnline;
    if (r >= -75) return const Color(0xFFFF9F0A);
    return AppColors.statusFall;
  }

  void _showOtaSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => OtaUpdateSheet(
        deviceId: widget.deviceId,
        currentVersion: _firmwareVersion ?? 'unknown',
        latestVersion: _latestFirmwareVersion,
        latestUrl: _latestFirmwareUrl,
        updateAvailable: _updateAvailable,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = _device?['name'] ?? widget.deviceId;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device Settings'),
        actions: [IconButton(icon: const Icon(Icons.edit_outlined), onPressed: _renameDevice)],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.asset('assets/images/device_photo.png', width: 56, height: 56, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text('ID: ${widget.deviceId}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: (_isOnline ? AppColors.statusOnline : AppColors.statusOffline).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _isOnline ? 'Online' : 'Offline',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _isOnline ? AppColors.statusOnline : AppColors.statusOffline,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const SectionHeader(title: 'DEVICE INFORMATION'),
          SettingsSectionCard(children: [
            SettingsTile(
              icon: Icons.bolt_outlined,
              iconCircleColor: _isOnline ? AppColors.statusOnline : AppColors.statusOffline,
              title: 'Device Status',
              value: _isOnline ? 'Online' : 'Offline',
            ),
            SettingsTile(icon: Icons.schedule, iconCircleColor: AppColors.accent, title: 'Last Seen', value: _formatLastSeen()),
            SettingsTile(
              icon: Icons.wifi,
              iconCircleColor: _wifiStrengthColor(),
              title: 'Wi-Fi Strength',
              value: _wifiStrengthLabel(),
              subtitle: _rssi != null ? '$_rssi dBm' : null,
            ),
            SettingsTile(
              icon: Icons.system_update_outlined,
              iconCircleColor: AppColors.accent,
              title: 'Firmware Version',
              value: _firmwareVersion ?? '—',
              subtitle: _updateAvailable ? 'Update available' : 'Up to date',
              onTap: _showOtaSheet,
            ),
            SettingsTile(icon: Icons.tag, iconCircleColor: AppColors.accent, title: 'Device ID', value: widget.deviceId),
            SettingsTile(
              icon: Icons.health_and_safety_outlined,
              iconCircleColor: _hasFallen ? AppColors.statusFall : AppColors.statusOnline,
              title: 'Device Health',
              value: _hasFallen ? 'Fall detected' : 'All systems normal',
            ),
            if (_isOwner)
              SettingsTile(icon: Icons.password_outlined, iconCircleColor: AppColors.accent, title: 'Device PIN', value: _pin ?? 'Not set'),
          ]),
          const SizedBox(height: 16),
          const SectionHeader(title: 'DEVICE SETTINGS'),
          SettingsSectionCard(children: [
            SettingsTile(
              icon: Icons.accessibility_new,
              iconCircleColor: AppColors.accent,
              title: 'Posture Tracking',
              subtitle: 'Track posture and body movements',
              trailingWidget: Switch(value: _postureTracking, onChanged: _setPostureTracking),
            ),
            SettingsTile(
              icon: Icons.warning_amber_outlined,
              iconCircleColor: AppColors.accent,
              title: 'Fall Detection',
              subtitle: 'Detect falls and send alerts',
              trailingWidget: Switch(value: _fallDetectionAlerts, onChanged: _setFallDetectionAlerts),
            ),
            SettingsTile(
              icon: Icons.place_outlined,
              iconCircleColor: AppColors.accent,
              title: 'Activity Zones',
              subtitle: 'Manage detection zones',
              value: '$_zoneCount Zone${_zoneCount == 1 ? '' : 's'}',
              onTap: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => ActivityZonesPage(deviceId: widget.deviceId)));
                _loadZoneCount();
              },
            ),
            SettingsTile(
              icon: Icons.notifications_none,
              iconCircleColor: AppColors.accent,
              title: 'Device Alerts',
              subtitle: 'Customize alert preferences',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => DeviceAlertsPage(deviceId: widget.deviceId, deviceName: name)),
              ),
            ),
            SettingsTile(
              icon: Icons.nightlight_outlined,
              iconCircleColor: AppColors.accent,
              title: 'Night Mode',
              subtitle: 'Reduce sensitivity at night',
              trailingWidget: Switch(value: _nightMode, onChanged: _setNightMode),
            ),
            SettingsTile(
              icon: Icons.lightbulb_outline,
              iconCircleColor: AppColors.accent,
              title: 'Status LED',
              subtitle: 'Turn the on-device indicator light on/off',
              trailingWidget: Switch(value: _statusLedEnabled, onChanged: _setStatusLedEnabled),
            ),
            SettingsTile(
              icon: Icons.restart_alt,
              iconCircleColor: AppColors.accent,
              title: 'Restart Device',
              subtitle: 'Restart your device',
              onTap: _confirmRestart,
            ),
            if (_isOwner)
              SettingsTile(
                icon: Icons.delete_outline,
                iconCircleColor: AppColors.statusFall,
                title: 'Remove Device',
                subtitle: 'Remove device from your home',
                titleColor: AppColors.statusFall,
                onTap: _confirmRemoveDevice,
              ),
          ]),
          const SizedBox(height: 16),
          const SectionHeader(title: 'MORE'),
          SettingsSectionCard(children: [
            SettingsTile(
              icon: Icons.insights_outlined,
              iconCircleColor: AppColors.accent,
              title: 'Detection Trends',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DetectionTrendsPage(deviceId: widget.deviceId))),
            ),
            SettingsTile(
              icon: Icons.menu_book_outlined,
              iconCircleColor: AppColors.accent,
              title: 'Installation Guide',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const InstallationGuideCarousel())),
            ),
            if (_isOwner) ...[
              SettingsTile(
                icon: Icons.tune,
                iconCircleColor: AppColors.accent,
                title: 'Device Calibration',
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DeviceCalibrationWizardPage(deviceId: widget.deviceId))),
              ),
              SettingsTile(
                icon: Icons.accessibility_new,
                iconCircleColor: AppColors.accent,
                title: 'Posture Calibration',
                subtitle: 'Requires same Wi-Fi network as device',
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PostureCalibrationPage(deviceId: widget.deviceId))),
              ),
              SettingsTile(
                icon: Icons.share_outlined,
                iconCircleColor: AppColors.accent,
                title: 'Share Device',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ShareDevicePage(deviceId: widget.deviceId, deviceName: name)),
                ),
              ),
            ],
          ]),
          if (!_isOwner) ...[
            const SizedBox(height: 16),
            SettingsSectionCard(children: [
              SettingsTile(
                icon: Icons.link_off,
                iconCircleColor: AppColors.statusFall,
                title: 'Leave Device',
                titleColor: AppColors.statusFall,
                onTap: _confirmUnshare,
              ),
            ]),
          ],
        ],
      ),
    );
  }
}
