import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fall_sense_x_mobile/services/auth_service.dart';
import '../theme/app_theme.dart';
import '../widgets/installation_guide_carousel.dart';
import '../widgets/bluetooth_scan_tab.dart';

/// Add Device flow: register a new sensor by ID, join one shared via invite
/// code, or scan for nearby devices over Bluetooth. FallSenseX has a single
/// device type, so unlike the Tuya reference's category grid this is a
/// simple tabbed form. The Bluetooth tab is UI-only for now - see
/// widgets/bluetooth_scan_tab.dart for why.
class AddDevicePage extends StatefulWidget {
  final String? userId;
  const AddDevicePage({super.key, required this.userId});

  @override
  State<AddDevicePage> createState() => _AddDevicePageState();
}

class _AddDevicePageState extends State<AddDevicePage> with SingleTickerProviderStateMixin {
  final DeviceService _deviceService = DeviceService();
  final _deviceIdController = TextEditingController();
  final _deviceNameController = TextEditingController();
  final _codeController = TextEditingController();
  late TabController _tabController;
  bool _isLoading = false;
  String? _message;

  // "Add New" tab step flow, matching the premium reference's
  // Power On -> Connect Wi-Fi -> Select Room -> Complete wizard.
  int _addStep = 0;
  bool _blinkConfirmed = false;
  bool _wifiConfigured = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _deviceIdController.dispose();
    _deviceNameController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _registerDevice() async {
    if (_deviceIdController.text.isEmpty) {
      setState(() => _message = 'Enter device ID');
      return;
    }
    if (widget.userId == null) {
      setState(() => _message = 'User not authenticated');
      return;
    }
    setState(() {
      _isLoading = true;
      _message = null;
    });
    final deviceId = _deviceIdController.text.trim();
    try {
      final success = await _deviceService.registerDevice(
        widget.userId!,
        deviceId,
        _deviceNameController.text.isEmpty ? 'My Device' : _deviceNameController.text,
      );
      if (!mounted) return;
      if (!success) {
        setState(() {
          _message = 'Device ID already registered to another user';
          _isLoading = false;
        });
        return;
      }
      setState(() {
        _isLoading = false;
        _addStep = 3;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _message = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  void _finishAddFlow() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const InstallationGuideCarousel()),
    );
  }

  Future<void> _joinByCode() async {
    final code = _codeController.text.trim().toUpperCase();
    if (code.length != 6) {
      setState(() => _message = 'Invite code must be 6 characters');
      return;
    }
    if (widget.userId == null) {
      setState(() => _message = 'User not authenticated');
      return;
    }
    setState(() {
      _isLoading = true;
      _message = null;
    });
    try {
      final success = await _deviceService.joinDeviceByCode(code, widget.userId!);
      if (!mounted) return;
      setState(() => _isLoading = false);
      if (success) {
        Navigator.pop(context);
      } else {
        setState(() => _message = 'Invalid or expired invite code');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _message = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Device'),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.accent,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.accent,
          tabs: const [
            Tab(text: 'Add New'),
            Tab(text: 'Join With Code'),
            Tab(text: 'Bluetooth'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildAddNewTab(), _buildJoinTab(), const BluetoothScanTab()],
      ),
    );
  }

  static const _stepLabels = ['Power On', 'Connect Wi-Fi', 'Select Room', 'Complete'];

  Widget _buildAddNewTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: List.generate(_stepLabels.length, (i) {
              final reached = i <= _addStep;
              return Expanded(
                child: Column(
                  children: [
                    Row(
                      children: [
                        if (i != 0) Expanded(child: Container(height: 2, color: i <= _addStep ? AppColors.accent : const Color(0xFFE5E5EA))),
                        CircleAvatar(
                          radius: 12,
                          backgroundColor: reached ? AppColors.accent : const Color(0xFFE5E5EA),
                          child: i < _addStep
                              ? const Icon(Icons.check, size: 12, color: Colors.white)
                              : Text('${i + 1}', style: TextStyle(fontSize: 11, color: reached ? Colors.white : AppColors.textSecondary)),
                        ),
                        if (i != _stepLabels.length - 1)
                          Expanded(child: Container(height: 2, color: i < _addStep ? AppColors.accent : const Color(0xFFE5E5EA))),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(_stepLabels[i], style: const TextStyle(fontSize: 9, color: AppColors.textSecondary)),
                  ],
                ),
              );
            }),
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + MediaQuery.of(context).padding.bottom),
            child: _buildAddStepBody(),
          ),
        ),
      ],
    );
  }

  Widget _buildAddStepBody() {
    switch (_addStep) {
      case 0:
        return _buildPowerOnStep();
      case 1:
        return _buildConnectWifiStep();
      case 2:
        return _buildSelectRoomStep();
      default:
        return _buildAddCompleteStep();
    }
  }

  Widget _buildPowerOnStep() {
    return ListView(
      children: [
        Center(
          child: Container(
            width: 140,
            height: 140,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.accentLight),
            padding: const EdgeInsets.all(24),
            child: Image.asset('assets/images/device_photo.png', fit: BoxFit.contain),
          ),
        ),
        const SizedBox(height: 24),
        const Text('Power On Your Device', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text(
          'Make sure your FallSense device is powered on and the indicator light is blinking.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const InstallationGuideCarousel())),
          child: const Text('Need help?'),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text('1. Power on the device and wait for the indicator light to blink.'),
                SizedBox(height: 12),
                Text('2. Confirm blinking light\nMake sure the indicator light is blinking blue. This indicates the device is ready to connect.'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _blinkConfirmed,
          onChanged: (v) => setState(() => _blinkConfirmed = v ?? false),
          title: const Text('The indicator light is blinking blue', style: TextStyle(fontSize: 13)),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _blinkConfirmed ? () => setState(() => _addStep = 1) : null,
            child: const Text('Next'),
          ),
        ),
      ],
    );
  }

  Widget _buildConnectWifiStep() {
    return ListView(
      children: [
        const Text('Connect to Wi-Fi', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text(
          'FallSenseX devices are configured for Wi-Fi directly on the device (via its own setup '
          'network) rather than through this app - this keeps your Wi-Fi password off your phone.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text('1. On your phone, connect to the Wi-Fi network the device is broadcasting.'),
                SizedBox(height: 12),
                Text('2. Follow the on-device setup page to enter your home Wi-Fi credentials.'),
                SizedBox(height: 12),
                Text('3. Wait for the indicator light to turn solid - that means it connected successfully.'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _wifiConfigured,
          onChanged: (v) => setState(() => _wifiConfigured = v ?? false),
          title: const Text('My device is connected to Wi-Fi', style: TextStyle(fontSize: 13)),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _wifiConfigured ? () => setState(() => _addStep = 2) : null,
            child: const Text('Next'),
          ),
        ),
      ],
    );
  }

  Widget _buildSelectRoomStep() {
    return ListView(
      children: [
        const Text('Select Room', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text(
          'Enter the device ID printed on the label, and name it after the room it\'s in.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _deviceIdController,
          decoration: const InputDecoration(labelText: 'Device ID', hintText: 'e.g. FallSense_X1'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _deviceNameController,
          decoration: const InputDecoration(labelText: 'Room / Device Name', hintText: 'e.g. Living Room'),
        ),
        const SizedBox(height: 20),
        if (_isLoading)
          const Center(child: CircularProgressIndicator())
        else
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(onPressed: _registerDevice, child: const Text('Next')),
          ),
        if (_message != null) ...[
          const SizedBox(height: 16),
          Text(_message!, style: const TextStyle(color: AppColors.statusFall)),
        ],
      ],
    );
  }

  Widget _buildAddCompleteStep() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.check_circle, size: 64, color: AppColors.statusOnline),
        const SizedBox(height: 16),
        const Text('Device Added!', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
          '${_deviceNameController.text.isEmpty ? "Your device" : _deviceNameController.text} is ready. '
          'Next, walk through the installation guide for best placement.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(onPressed: _finishAddFlow, child: const Text('View Installation Guide')),
        ),
      ],
    );
  }

  Widget _buildJoinTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Enter the 6-character invite code shared with you by the device owner.',
            style: TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _codeController,
            maxLength: 6,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
              LengthLimitingTextInputFormatter(6),
            ],
            decoration: const InputDecoration(
              labelText: 'Invite Code',
              hintText: 'e.g. AB12CD',
            ),
          ),
          const SizedBox(height: 20),
          if (_isLoading)
            const Center(child: CircularProgressIndicator())
          else
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _joinByCode,
                child: const Text('Join Device'),
              ),
            ),
          if (_message != null) ...[
            const SizedBox(height: 16),
            Text(_message!, style: const TextStyle(color: AppColors.statusFall)),
          ],
        ],
      ),
    );
  }
}
