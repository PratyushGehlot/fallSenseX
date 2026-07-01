import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:fall_sense_x_mobile/services/auth_service.dart';
import 'package:fall_sense_x_mobile/models/radar_models.dart';
import '../theme/app_theme.dart';
import '../widgets/status_card.dart';
import 'account_page.dart';
import 'add_device_page.dart';
import 'about_page.dart';
import 'dashboard_page.dart';
import 'detection_trends_page.dart';
import 'device_sharing_page.dart';
import 'help_support_page.dart';
import 'manage_home_page.dart';
import 'notification_settings_page.dart';
import 'privacy_settings_page.dart';

class _AlertEvent {
  final String deviceId;
  final String deviceName;
  final String type; // 'Fall', 'Activity', 'System'
  final String title;
  final DateTime time;

  const _AlertEvent({
    required this.deviceId,
    required this.deviceName,
    required this.type,
    required this.title,
    required this.time,
  });
}

class _LiveStatus {
  final bool isOnline;
  final bool present;
  final bool hasFallen;

  const _LiveStatus({this.isOnline = false, this.present = false, this.hasFallen = false});

  String get label {
    if (!isOnline) return 'Offline';
    if (hasFallen) return 'Fall detected';
    if (present) return 'Presence detected';
    return 'Normal';
  }
}

/// Landing page after login: 5-tab dashboard (Dashboard / Devices / Alerts /
/// Reports / Settings), modeled on the premium reference UI in
/// App_UI_Premium/. Live device status is tracked once here (rather than
/// per-card) so the Dashboard hero, Devices stats row, and Alerts tab can
/// all share the same aggregate counts without duplicate Firebase listeners.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _navIndex = 0;
  final DeviceService _deviceService = DeviceService();
  String? _userId;
  StreamSubscription? _devicesSubscription;
  List<Map<String, dynamic>> _devices = [];
  bool _autoNavigated = false;

  final Map<String, StreamSubscription> _frameSubs = {};
  final Map<String, StreamSubscription> _onlineSubs = {};
  final Map<String, _LiveStatus> _liveStatus = {};

  String _alertFilter = 'All';
  String? _alertEventsKey;
  Future<List<_AlertEvent>>? _alertEventsFuture;

  @override
  void initState() {
    super.initState();
    _userId = AuthService().currentUser()?.uid;
    if (_userId != null) {
      _loadDevices();
    }
  }

  void _loadDevices() {
    _devicesSubscription?.cancel();
    _devicesSubscription = _deviceService.getUserDevices(_userId!).listen((event) {
      if (!mounted) return;
      final value = event.snapshot.value;
      if (value is Map) {
        final devicesMap = value;
        final devices = devicesMap.entries
            .where((e) {
              final data = e.value as Map;
              return data['ownerId'] == _userId ||
                  (data['sharedWith'] != null && (data['sharedWith'] as Map)[_userId] == true);
            })
            .map((e) => {
                  'id': e.key,
                  ...Map<String, dynamic>.from(e.value),
                  'isOwner': (e.value as Map)['ownerId'] == _userId,
                })
            .toList();
        setState(() => _devices = devices);
        _syncLiveSubscriptions();
        _maybeAutoNavigate();
      } else {
        setState(() => _devices = []);
        _syncLiveSubscriptions();
      }
    });
  }

  void _syncLiveSubscriptions() {
    final currentIds = _devices.map((d) => d['id'] as String).toSet();

    for (final id in _frameSubs.keys.toList()) {
      if (!currentIds.contains(id)) {
        _frameSubs.remove(id)?.cancel();
        _onlineSubs.remove(id)?.cancel();
        _liveStatus.remove(id);
      }
    }

    for (final id in currentIds) {
      if (_frameSubs.containsKey(id)) continue;
      _liveStatus[id] = const _LiveStatus();
      _frameSubs[id] = FirebaseDatabase.instance
          .ref('devices/$id/frames')
          .limitToLast(1)
          .onValue
          .listen((event) {
        if (!mounted) return;
        final latest = latestFrameFromSnapshot(event.snapshot.value);
        final detections = latest != null ? humanDetectionsFromFrameMap(latest) : <HumanDetection>[];
        final present = latest?['present'] as bool? ?? false;
        final hasFallen = detections.any((d) => d.posture.toUpperCase() == 'FALL');
        setState(() {
          _liveStatus[id] = _LiveStatus(
            isOnline: _liveStatus[id]?.isOnline ?? false,
            present: present,
            hasFallen: hasFallen,
          );
        });
      });
      _onlineSubs[id] = FirebaseDatabase.instance.ref('devices/$id/online').onValue.listen((event) {
        if (!mounted) return;
        final data = event.snapshot.value;
        bool isOnline = false;
        if (data is Map && data['value'] == true && data['timestamp'] != null) {
          final ts = DateTime.fromMillisecondsSinceEpoch((data['timestamp'] as num).toInt() * 1000);
          isOnline = DateTime.now().difference(ts) < const Duration(seconds: 75);
        }
        setState(() {
          _liveStatus[id] = _LiveStatus(
            isOnline: isOnline,
            present: _liveStatus[id]?.present ?? false,
            hasFallen: _liveStatus[id]?.hasFallen ?? false,
          );
        });
      });
    }
  }

  /// Skips the device list when the user only has one device - most users
  /// will only ever have a single sensor. Fires once per page lifetime.
  void _maybeAutoNavigate() {
    if (_autoNavigated || _devices.length != 1) return;
    _autoNavigated = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _openDevice(_devices.first['id']);
    });
  }

  /// Builds the Alerts tab's historical event feed from each device's last
  /// 50 frames (fetched once, not streamed) - transitions into Fall and
  /// Activity events the same way Reports' timeline does. There is no
  /// persisted online/offline history in Firebase (only the current
  /// heartbeat value), so "System" events are synthesized only for devices
  /// that are offline right now, not a full historical offline log.
  Future<List<_AlertEvent>> _loadAlertEvents(List<Map<String, dynamic>> devices) async {
    final events = <_AlertEvent>[];
    for (final device in devices) {
      final id = device['id'] as String;
      final name = device['name'] as String? ?? id;
      final snapshot = await FirebaseDatabase.instance.ref('devices/$id/frames').limitToLast(50).get();
      final value = snapshot.value;
      final frames = <Map<String, dynamic>>[];
      if (value is Map) {
        value.forEach((key, v) {
          if (v is Map) frames.add(Map<String, dynamic>.from(v));
        });
        frames.sort((a, b) => frameTimestampMs(a).compareTo(frameTimestampMs(b)));
      }
      String? lastLabel;
      for (final frame in frames) {
        final detections = humanDetectionsFromFrameMap(frame);
        final present = frame['present'] as bool? ?? false;
        final hasFallen = detections.any((d) => d.posture.toUpperCase() == 'FALL');
        final label = hasFallen ? 'Fall' : (present ? 'Activity' : 'Normal');
        if (label != lastLabel && label != 'Normal') {
          events.add(_AlertEvent(
            deviceId: id,
            deviceName: name,
            type: label,
            title: label == 'Fall' ? 'Fall Detected' : 'Activity Detected',
            time: DateTime.fromMillisecondsSinceEpoch(frameTimestampMs(frame)),
          ));
        }
        lastLabel = label;
      }
      final status = _liveStatus[id];
      if (status != null && !status.isOnline) {
        events.add(_AlertEvent(deviceId: id, deviceName: name, type: 'System', title: 'Device Offline', time: DateTime.now()));
      }
    }
    events.sort((a, b) => b.time.compareTo(a.time));
    return events;
  }

  void _openDevice(String deviceId) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DashboardPage(deviceId: deviceId)),
    );
  }

  void _openAddDevice() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AddDevicePage(userId: _userId)),
    );
  }

  @override
  void dispose() {
    _devicesSubscription?.cancel();
    for (final sub in _frameSubs.values) {
      sub.cancel();
    }
    for (final sub in _onlineSubs.values) {
      sub.cancel();
    }
    super.dispose();
  }

  int get _onlineCount => _liveStatus.values.where((s) => s.isOnline).length;
  int get _alertCount => _liveStatus.values.where((s) => s.isOnline && s.hasFallen).length;
  int get _sharedCount => _devices.where((d) => d['isOwner'] != true).length;
  bool get _allGood => _alertCount == 0 && _devices.every((d) => _liveStatus[d['id']]?.isOnline ?? false);

  @override
  Widget build(BuildContext context) {
    final pages = [
      _buildDashboardTab(),
      _buildDevicesTab(),
      _buildAlertsTab(),
      _buildReportsTab(),
      _buildSettingsTab(),
    ];

    return Scaffold(
      body: SafeArea(child: pages[_navIndex]),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _navIndex,
        onTap: (i) => setState(() => _navIndex = i),
        items: [
          const BottomNavigationBarItem(icon: Icon(Icons.dashboard_outlined), activeIcon: Icon(Icons.dashboard), label: 'Dashboard'),
          const BottomNavigationBarItem(icon: Icon(Icons.devices_other_outlined), activeIcon: Icon(Icons.devices_other), label: 'Devices'),
          BottomNavigationBarItem(
            icon: _alertCount > 0
                ? Badge(label: Text('$_alertCount'), child: const Icon(Icons.notifications_outlined))
                : const Icon(Icons.notifications_outlined),
            activeIcon: const Icon(Icons.notifications),
            label: 'Alerts',
          ),
          const BottomNavigationBarItem(icon: Icon(Icons.bar_chart_outlined), activeIcon: Icon(Icons.bar_chart), label: 'Reports'),
          const BottomNavigationBarItem(icon: Icon(Icons.settings_outlined), activeIcon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Dashboard tab
  // ---------------------------------------------------------------------

  Widget _buildDashboardTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('FallSense', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            Row(
              children: [
                IconButton(
                  icon: _alertCount > 0
                      ? Badge(label: Text('$_alertCount'), child: const Icon(Icons.notifications_none))
                      : const Icon(Icons.notifications_none),
                  onPressed: () => setState(() => _navIndex = 2),
                ),
                IconButton(icon: const Icon(Icons.add), onPressed: _openAddDevice, tooltip: 'Add Device'),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildHeroCard(),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Your Devices', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            TextButton(onPressed: () => setState(() => _navIndex = 1), child: const Text('See All')),
          ],
        ),
        const SizedBox(height: 8),
        if (_devices.isEmpty)
          _buildEmptyState()
        else
          ..._devices.take(4).map((d) => _DeviceListRow(
                device: d,
                status: _liveStatus[d['id']] ?? const _LiveStatus(),
                onTap: () => _openDevice(d['id']),
              )),
      ],
    );
  }

  Widget _buildHeroCard() {
    final title = _allGood ? 'All is Good' : (_alertCount > 0 ? '$_alertCount Active Alert${_alertCount > 1 ? 's' : ''}' : 'Checking devices…');
    final subtitle = _allGood
        ? 'Your home is protected. All systems are active and monitoring.'
        : 'Review the Alerts tab for details.';
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: _allGood ? AppColors.heroGradient : null,
        color: _allGood ? null : AppColors.statusFall,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(_allGood ? Icons.shield_outlined : Icons.warning_amber_outlined, color: Colors.white, size: 36),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(subtitle, style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.sensors_off, size: 56, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            const Text('No devices yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text(
              'Add your FallSenseX sensor to start monitoring.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(onPressed: _openAddDevice, icon: const Icon(Icons.add), label: const Text('Add Device')),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Devices tab
  // ---------------------------------------------------------------------

  Widget _buildDevicesTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('My Devices', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              ElevatedButton.icon(
                onPressed: _openAddDevice,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Device'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text('Manage and monitor all your FallSense devices', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 16),
          Row(
            children: [
              _StatChip(value: '${_devices.length}', label: 'Total Devices', color: AppColors.accent, icon: Icons.person_outline),
              const SizedBox(width: 8),
              _StatChip(value: '$_onlineCount', label: 'Online', color: AppColors.statusOnline, icon: Icons.check),
              const SizedBox(width: 8),
              _StatChip(value: '$_alertCount', label: 'Alerts', color: AppColors.statusFall, icon: Icons.notifications_none),
              const SizedBox(width: 8),
              _StatChip(value: '$_sharedCount', label: 'Shared Devices', color: const Color(0xFF8E5FE8), icon: Icons.people_outline),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Devices (${_devices.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
              TextButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.filter_list, size: 16),
                label: const Text('Filter'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: _devices.isEmpty
                ? _buildEmptyState()
                : ListView(
                    children: [
                      ..._devices.map((d) => _DeviceListRow(
                            device: d,
                            status: _liveStatus[d['id']] ?? const _LiveStatus(),
                            onTap: () => _openDevice(d['id']),
                          )),
                      const SizedBox(height: 8),
                      _buildAllWorkingWellBanner(),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildAllWorkingWellBanner() {
    if (_devices.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          const CircleAvatar(radius: 16, backgroundColor: Colors.white, child: Icon(Icons.info_outline, size: 16, color: AppColors.accent)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _allGood ? 'All Devices are Working Well' : 'Some Devices Need Attention',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  _allGood
                      ? 'Your home is protected. All systems are active and monitoring.'
                      : 'Check the Alerts tab for details.',
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.home_outlined, color: AppColors.accent, size: 28),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Alerts tab - current alert conditions, not historical (per-device
  // history already lives in Reports / Detection Trends).
  // ---------------------------------------------------------------------

  Widget _buildAlertsTab() {
    final key = _devices.map((d) => d['id']).join(',');
    if (_alertEventsKey != key) {
      _alertEventsKey = key;
      _alertEventsFuture = _loadAlertEvents(_devices);
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Alerts', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('Recent fall, activity and system events across your devices', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 12),
          _buildAlertFilterChips(),
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<List<_AlertEvent>>(
              future: _alertEventsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final events = (snapshot.data ?? [])
                    .where((e) => _alertFilter == 'All' || e.type == _alertFilter)
                    .toList();
                if (events.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.check_circle_outline, size: 56, color: AppColors.statusOnline),
                        SizedBox(height: 16),
                        Text('No alerts', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                        SizedBox(height: 4),
                        Text('Nothing to report for this filter.', style: TextStyle(color: AppColors.textSecondary)),
                      ],
                    ),
                  );
                }
                final today = DateTime.now();
                final yesterday = today.subtract(const Duration(days: 1));
                final groups = <String, List<_AlertEvent>>{};
                for (final e in events) {
                  String key;
                  if (_isSameDay(e.time, today)) {
                    key = 'Today';
                  } else if (_isSameDay(e.time, yesterday)) {
                    key = 'Yesterday';
                  } else {
                    key = _formatGroupDate(e.time);
                  }
                  groups.putIfAbsent(key, () => []).add(e);
                }
                return ListView(
                  children: [
                    for (final entry in groups.entries) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(entry.key, style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.textSecondary, fontSize: 12)),
                      ),
                      ...entry.value.map(_buildAlertRow),
                    ],
                    const SizedBox(height: 8),
                    _buildAiMonitoringBanner(),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAlertFilterChips() {
    const filters = ['All', 'Fall', 'Activity', 'System'];
    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: filters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final f = filters[i];
          final selected = _alertFilter == f;
          return GestureDetector(
            onTap: () => setState(() => _alertFilter = f),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: selected ? AppColors.accent : AppColors.background,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: selected ? AppColors.accent : const Color(0xFFE5E5EA)),
              ),
              alignment: Alignment.center,
              child: Text(f, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: selected ? Colors.white : AppColors.textSecondary)),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAlertRow(_AlertEvent e) {
    final color = e.type == 'Fall'
        ? AppColors.statusFall
        : e.type == 'System'
            ? AppColors.statusOffline
            : AppColors.statusPresence;
    final icon = e.type == 'Fall'
        ? Icons.warning_amber_outlined
        : e.type == 'System'
            ? Icons.wifi_off
            : Icons.directions_walk;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(backgroundColor: color.withValues(alpha: 0.12), child: Icon(icon, color: color, size: 20)),
        title: Text(e.title),
        subtitle: Text('${e.deviceName} · ${_formatTime(e.time)}'),
        trailing: e.type == 'Fall'
            ? TextButton(onPressed: () => _openDevice(e.deviceId), child: const Text('View'))
            : const Icon(Icons.chevron_right, color: AppColors.textSecondary),
        onTap: () => _openDevice(e.deviceId),
      ),
    );
  }

  Widget _buildAiMonitoringBanner() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(14)),
      child: const Row(
        children: [
          Icon(Icons.auto_awesome, color: AppColors.accent),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'AI-Powered Monitoring: alerts are generated automatically from sensor data and may need confirmation.',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  String _formatGroupDate(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[d.month - 1]} ${d.day}';
  }

  String _formatTime(DateTime d) {
    final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final period = d.hour < 12 ? 'AM' : 'PM';
    return '$hour:${d.minute.toString().padLeft(2, '0')} $period';
  }

  // ---------------------------------------------------------------------
  // Reports tab - pick a device to view its Detection Trends.
  // ---------------------------------------------------------------------

  Widget _buildReportsTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Reports', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('Select a device to view its detection trends', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 16),
          Expanded(
            child: _devices.isEmpty
                ? _buildEmptyState()
                : ListView(
                    children: _devices
                        .map((d) => Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                leading: const Icon(Icons.insights_outlined, color: AppColors.accent),
                                title: Text(d['name'] ?? d['id']),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => DetectionTrendsPage(deviceId: d['id'])),
                                ),
                              ),
                            ))
                        .toList(),
                  ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Settings tab
  // ---------------------------------------------------------------------

  Widget _buildSettingsTab() {
    final user = AuthService().currentUser();
    final email = user?.email ?? '';
    final displayName = (user?.displayName?.isNotEmpty ?? false) ? user!.displayName! : (email.isNotEmpty ? email.split('@').first : 'Account');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Settings', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: AppColors.accent,
                  backgroundImage: user?.photoURL != null ? NetworkImage(user!.photoURL!) : null,
                  child: user?.photoURL == null
                      ? Text(
                          displayName[0].toUpperCase(),
                          style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                        )
                      : null,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(displayName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(email, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const SectionHeader(title: 'GENERAL'),
        SettingsSectionCard(children: [
          SettingsTile(
            icon: Icons.person_outline,
            iconCircleColor: AppColors.accent,
            title: 'Account',
            subtitle: 'Manage your account',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountPage())),
          ),
          SettingsTile(
            icon: Icons.home_outlined,
            iconCircleColor: AppColors.accent,
            title: 'Home Management',
            subtitle: 'Manage homes and rooms',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ManageHomePage())),
          ),
          SettingsTile(
            icon: Icons.share_outlined,
            iconCircleColor: AppColors.accent,
            title: 'Device Sharing',
            subtitle: 'Share devices with family',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DeviceSharingPage())),
          ),
          SettingsTile(
            icon: Icons.notifications_none,
            iconCircleColor: AppColors.accent,
            title: 'Notification Settings',
            subtitle: 'Manage notifications',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationSettingsPage())),
          ),
          SettingsTile(
            icon: Icons.privacy_tip_outlined,
            iconCircleColor: AppColors.accent,
            title: 'Privacy Settings',
            subtitle: 'Manage your privacy',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PrivacySettingsPage())),
          ),
        ]),
        const SizedBox(height: 16),
        const SectionHeader(title: 'SUPPORT'),
        SettingsSectionCard(children: [
          SettingsTile(
            icon: Icons.help_outline,
            iconCircleColor: AppColors.accent,
            title: 'Help & Support',
            subtitle: 'Get help and find answers',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpSupportPage())),
          ),
          SettingsTile(
            icon: Icons.info_outline,
            iconCircleColor: AppColors.accent,
            title: 'About FallSense',
            subtitle: 'Version $kAppVersion',
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutPage())),
          ),
          SettingsTile(
            icon: Icons.logout,
            iconCircleColor: AppColors.statusFall,
            title: 'Log Out',
            subtitle: 'Sign out from your account',
            titleColor: AppColors.statusFall,
            onTap: () async => AuthService().signOut(),
          ),
        ]),
        const SizedBox(height: 16),
        Center(child: Text('App Version $kAppVersion', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary))),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final String value;
  final String label;
  final Color color;
  final IconData icon;

  const _StatChip({required this.value, required this.label, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          child: Column(
            children: [
              CircleAvatar(radius: 16, backgroundColor: color.withValues(alpha: 0.12), child: Icon(icon, size: 16, color: color)),
              const SizedBox(height: 6),
              Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 9, color: AppColors.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Device row used on the Dashboard and Devices tabs, mirroring the
/// reference's "Living Room / FallSense Pro / Online / No Fall / Normal"
/// rows. The reference uses a real room photo thumbnail; since FallSenseX is
/// a radar sensor (no camera) and no photo assets exist for this product, a
/// gradient + sensor-icon thumbnail stands in for it at the same size/shape.
class _DeviceListRow extends StatelessWidget {
  final Map<String, dynamic> device;
  final _LiveStatus status;
  final VoidCallback onTap;

  const _DeviceListRow({required this.device, required this.status, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  gradient: AppColors.heroGradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.sensors, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(device['name'] ?? device['id'], style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    const Text('FallSense Pro', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: (status.isOnline ? AppColors.statusOnline : AppColors.statusOffline).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: status.isOnline ? AppColors.statusOnline : AppColors.statusOffline,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            status.isOnline ? 'Online' : 'Offline',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: status.isOnline ? AppColors.statusOnline : AppColors.statusOffline,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          status.hasFallen ? Icons.warning_amber_outlined : Icons.check_circle_outline,
                          size: 13,
                          color: status.hasFallen ? AppColors.statusFall : AppColors.statusOnline,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          status.hasFallen ? 'Fall Detected' : 'No Fall',
                          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                        ),
                        const SizedBox(width: 10),
                        const Icon(Icons.show_chart, size: 13, color: AppColors.textSecondary),
                        const SizedBox(width: 2),
                        Text(
                          status.present ? 'Active' : 'Normal',
                          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.more_vert, color: AppColors.textSecondary, size: 18),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
