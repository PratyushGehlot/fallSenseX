import 'package:flutter/material.dart';
import 'package:fall_sense_x_mobile/services/auth_service.dart';
import '../theme/app_theme.dart';

const List<Color> kZoneColors = [
  Color(0xFF34C759),
  Color(0xFFFF3B30),
  Color(0xFF8E5FE8),
  Color(0xFFFF9F0A),
  Color(0xFF2F6FE4),
];

const List<String> kZonePresets = ['Safe Zone', 'Fall Risk Zone', 'Sleep Zone'];

/// Standalone zone manager, reachable from Device Settings. Persists to
/// devices/{id}/uiZones via DeviceService.getZones/setZones. These are
/// organizational labels only - the firmware applies the same detection
/// logic everywhere in range, it doesn't enforce per-zone behavior.
class ActivityZonesPage extends StatefulWidget {
  final String deviceId;
  const ActivityZonesPage({super.key, required this.deviceId});

  @override
  State<ActivityZonesPage> createState() => _ActivityZonesPageState();
}

class _ActivityZonesPageState extends State<ActivityZonesPage> {
  final DeviceService _deviceService = DeviceService();
  final _controller = TextEditingController();
  List<String> _zones = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final zones = await _deviceService.getZones(widget.deviceId);
    if (mounted) setState(() {
      _zones = zones;
      _loading = false;
    });
  }

  Future<void> _save() async {
    await _deviceService.setZones(widget.deviceId, _zones);
  }

  void _addZone(String name) {
    if (name.trim().isEmpty || _zones.contains(name.trim())) return;
    setState(() => _zones.add(name.trim()));
    _controller.clear();
    _save();
  }

  void _removeZone(int index) {
    setState(() => _zones.removeAt(index));
    _save();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Activity Zones')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Label areas of the room for your own organization. These labels are not '
                    'enforced by the sensor - detection works the same everywhere in range.',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 6,
                    children: kZonePresets
                        .where((p) => !_zones.contains(p))
                        .map((p) => ActionChip(label: Text(p, style: const TextStyle(fontSize: 11)), onPressed: () => _addZone(p)))
                        .toList(),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          decoration: const InputDecoration(labelText: 'Custom zone name'),
                          onSubmitted: _addZone,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(icon: const Icon(Icons.add_circle, color: AppColors.accent), onPressed: () => _addZone(_controller.text)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _zones.isEmpty
                        ? const Center(child: Text('No zones added yet', style: TextStyle(color: AppColors.textSecondary)))
                        : ListView.builder(
                            padding: EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
                            itemCount: _zones.length,
                            itemBuilder: (context, index) {
                              final color = kZoneColors[index % kZoneColors.length];
                              return Card(
                                margin: const EdgeInsets.only(bottom: 8),
                                child: ListTile(
                                  leading: Container(width: 12, height: 12, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
                                  title: Text(_zones[index]),
                                  trailing: IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => _removeZone(index)),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
    );
  }
}
