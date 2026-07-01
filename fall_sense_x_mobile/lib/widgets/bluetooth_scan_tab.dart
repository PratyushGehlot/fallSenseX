import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../theme/app_theme.dart';

/// Bluetooth tab for the Add Device flow. The ESP32 firmware does not yet
/// advertise a BLE provisioning service (it's Wi-Fi only - see
/// main/app/wifi_stream.c), so this scans for and lists nearby BLE
/// peripherals, but tapping one cannot complete pairing yet. It's wired up
/// so a real provisioning flow can be dropped in once the firmware side
/// (enable the BT stack, add a GATT service for Wi-Fi credential hand-off)
/// exists - see this app's plan notes.
class BluetoothScanTab extends StatefulWidget {
  const BluetoothScanTab({super.key});

  @override
  State<BluetoothScanTab> createState() => _BluetoothScanTabState();
}

class _BluetoothScanTabState extends State<BluetoothScanTab> {
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<bool>? _isScanningSub;
  List<ScanResult> _results = [];
  bool _isScanning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  Future<void> _startScan() async {
    setState(() {
      _error = null;
      _results = [];
    });
    try {
      if (await FlutterBluePlus.isSupported == false) {
        setState(() => _error = 'Bluetooth is not supported on this device.');
        return;
      }
      _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        if (!mounted) return;
        setState(() {
          _results = results..sort((a, b) => b.rssi.compareTo(a.rssi));
        });
      });
      _isScanningSub?.cancel();
      _isScanningSub = FlutterBluePlus.isScanning.listen((scanning) {
        if (!mounted) return;
        setState(() => _isScanning = scanning);
      });
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start Bluetooth scan: $e');
    }
  }

  void _selectDevice(ScanResult result) {
    FlutterBluePlus.stopScan();
    showModalBottomSheet(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.device.platformName.isNotEmpty ? result.device.platformName : 'Unknown device',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            const Text(
              'Bluetooth pairing isn\'t supported by this device\'s firmware yet. '
              'Use "Add New" with the device ID printed on the label instead.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Got it'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _isScanningSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _isScanning ? 'Searching for nearby devices…' : 'Scan finished',
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
              ),
              if (_isScanning) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _isScanning ? null : _startScan,
                tooltip: 'Scan again',
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Bluetooth pairing is not yet supported by FallSenseX firmware - this view '
            'lists nearby BLE devices, but use "Add New" to register a sensor by ID.',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Expanded(child: Center(child: Text(_error!, style: const TextStyle(color: AppColors.statusFall))))
          else
            Expanded(
              child: _results.isEmpty
                  ? Center(
                      child: Text(
                        _isScanning ? 'Looking around…' : 'No nearby devices found',
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _results.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final result = _results[index];
                        final name = result.device.platformName;
                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.bluetooth, color: AppColors.accent),
                            title: Text(name.isNotEmpty ? name : result.device.remoteId.str),
                            subtitle: Text('RSSI: ${result.rssi} dBm'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _selectDevice(result),
                          ),
                        );
                      },
                    ),
            ),
        ],
      ),
    );
  }
}
