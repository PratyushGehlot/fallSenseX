import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fall_sense_x_mobile/services/auth_service.dart';

class FindDevicePage extends StatefulWidget {
  final String? userId;
  const FindDevicePage({super.key, required this.userId});

  @override
  State<FindDevicePage> createState() => _FindDevicePageState();
}

class _FindDevicePageState extends State<FindDevicePage> {
  final DeviceService _deviceService = DeviceService();
  final _deviceIdController = TextEditingController();
  final _deviceNameController = TextEditingController();
  bool _isLoading = false;
  String? _message;
  List<Map<String, dynamic>> _registeredDevices = [];
  String? _userId;
  StreamSubscription? _devicesSubscription;
  bool _autoNavigated = false;

  @override
  void initState() {
    super.initState();
    _userId = AuthService().currentUser()?.uid;
    if (_userId != null) {
      _loadUserDevices();
    }
  }

  void _loadUserDevices() {
    if (_userId == null) return;
    _devicesSubscription?.cancel();
    _devicesSubscription = _deviceService.getUserDevices(_userId!).listen((event) {
      if (!mounted) return;
      if (event.snapshot.value != null && event.snapshot.value is Map) {
        Map<dynamic, dynamic> devicesMap = event.snapshot.value as Map;
        setState(() {
          _registeredDevices = devicesMap.entries
              .where((e) {
                final data = e.value as Map;
                return data['ownerId'] == _userId ||
                    (data['sharedWith'] != null &&
                        (data['sharedWith'] as Map)[_userId] == true);
              })
              .map((e) {
                return {
                  'id': e.key,
                  ...Map<String, dynamic>.from(e.value),
                  'isOwner': (e.value as Map)['ownerId'] == _userId,
                };
              })
              .toList();
        });
        _maybeAutoNavigate();
      }
    });
  }

  /// Skips the device list entirely when the user only has one device -
  /// most users will only ever have one sensor, so making them tap through
  /// a list of one item every launch is unnecessary friction. Only fires
  /// once per page lifetime so navigating back here (e.g. to switch devices
  /// or register a new one) doesn't immediately bounce them forward again.
  void _maybeAutoNavigate() {
    if (_autoNavigated || _registeredDevices.length != 1) return;
    _autoNavigated = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.pushReplacementNamed(
        context,
        '/dashboard',
        arguments: {'deviceId': _registeredDevices.first['id']},
      );
    });
  }

  Future<void> _registerDevice() async {
    if (_deviceIdController.text.isEmpty) {
      setState(() => _message = 'Enter device ID');
      return;
    }
    if (_userId == null) {
      setState(() => _message = 'User not authenticated');
      return;
    }
    setState(() => _isLoading = true);
    try {
      final success = await _deviceService.registerDevice(
        _userId!,
        _deviceIdController.text.trim(),
        _deviceNameController.text.isEmpty
            ? 'My Device'
            : _deviceNameController.text,
      );
      if (!success) {
        setState(() => _message = 'Device ID already registered to another user');
        setState(() => _isLoading = false);
        return;
      }
      setState(() => _message = 'Device registered!');
      _deviceIdController.clear();
      _deviceNameController.clear();
    } catch (e) {
      setState(() => _message = 'Error: $e');
    }
    setState(() => _isLoading = false);
  }

  Future<void> _showShareDialog(String deviceId) async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Share Device'),
          content: SizedBox(
            width: 400,
            child: DefaultTabController(
              length: 3,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const TabBar(
                    tabs: [
                      Tab(text: 'UID'),
                      Tab(text: 'Email'),
                      Tab(text: 'Invite Code'),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 200,
                    child: TabBarView(
                      children: [
                        _buildShareByUidTab(deviceId),
                        _buildShareByEmailTab(deviceId),
                        _buildGenerateInviteCodeTab(deviceId),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildShareByUidTab(String deviceId) {
    final uidController = TextEditingController();
    return Column(
      children: [
        TextField(
          controller: uidController,
          decoration: const InputDecoration(
            labelText: 'User UID',
            hintText: 'Enter the user\'s UID',
          ),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: () async {
            final targetUid = uidController.text.trim();
            if (targetUid.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Please enter a UID')),
              );
              return;
            }
            try {
              await _deviceService.shareDevice(deviceId, targetUid);
              if (mounted) {
                Navigator.pop(context);
                setState(() => _message = 'Device shared successfully');
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Error sharing device: $e')),
                );
              }
            }
          },
          child: const Text('Share'),
        ),
      ],
    );
  }

  Widget _buildShareByEmailTab(String deviceId) {
    final emailController = TextEditingController();
    bool _isLookingUp = false;
    String? _lookedUpUid;
    return Column(
      children: [
        TextField(
          controller: emailController,
          decoration: const InputDecoration(
            labelText: 'Email',
            hintText: 'Enter the user\'s email',
          ),
        ),
        const SizedBox(height: 16),
        if (_isLookingUp)
          const SizedBox(
            height: 24,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_lookedUpUid != null)
          Text(
            'Found UID: $_lookedUpUid',
            style: const TextStyle(color: Colors.green),
          ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _isLookingUp
              ? null
              : () async {
                  final email = emailController.text.trim();
                  if (email.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please enter an email')),
                    );
                    return;
                  }
                  setState(() => _isLookingUp = true);
                  _lookedUpUid = null;
                  try {
                    final uid = await _deviceService.getUidByEmail(email);
                    if (uid == null) {
                      if (mounted) {
                        setState(() => _isLookingUp = false);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('No user found with this email')),
                        );
                      }
                    } else {
                      setState(() {
                        _isLookingUp = false;
                        _lookedUpUid = uid;
                      });
                      // Automatically share with the found UID
                      await _deviceService.shareDevice(deviceId, uid);
                      if (mounted) {
                        Navigator.pop(context);
                        setState(() => _message = 'Device shared successfully');
                      }
                    }
                  } catch (e) {
                    if (mounted) {
                      setState(() => _isLookingUp = false);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error: $e')),
                      );
                    }
                  }
                },
          child: Text(_isLookingUp ? 'Looking up...' : 'Look up and Share'),
        ),
      ],
    );
  }

  Widget _buildGenerateInviteCodeTab(String deviceId) {
    bool _isGenerating = false;
    String? _generatedCode;
    return Column(
      children: [
        if (_generatedCode != null)
          Column(
            children: [
              Text(
                'Invite Code:',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                _generatedCode!,
                style: const TextStyle(
                  fontSize: 24,
                  letterSpacing: 2,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _generatedCode!));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Code copied to clipboard')),
                    );
                  }
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy Code'),
              ),
            ],
          )
        else
          const Text(
            'Tap the button below to generate a shareable invite code.\n'
            'Share this code with someone to grant them access to this device.',
            textAlign: TextAlign.center,
          ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _isGenerating
              ? null
              : () async {
                  setState(() => _isGenerating = true);
                  try {
                    final code = await _deviceService.generateInviteCode(
                        deviceId, _userId!);
                    setState(() {
                      _isGenerating = false;
                      _generatedCode = code;
                    });
                  } catch (e) {
                    if (mounted) {
                      setState(() => _isGenerating = false);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error generating code: $e')),
                      );
                    }
                  }
                },
          child: Text(_isGenerating ? 'Generating...' : 'Generate Invite Code'),
        ),
      ],
    );
  }

  Future<void> _showJoinByCodeDialog() async {
    final codeController = TextEditingController();
    bool _isJoining = false;
    await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Join Device by Code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: codeController,
              decoration: const InputDecoration(
                labelText: 'Invite Code',
                hintText: 'Enter the 6-character code',
              ),
              maxLength: 6,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                LengthLimitingTextInputFormatter(6),
              ],
            ),
            const SizedBox(height: 16),
            if (_isJoining)
              const SizedBox(
                height: 24,
                child: Center(child: CircularProgressIndicator()),
              )
            else
              ElevatedButton(
                onPressed: _isJoining
                    ? null
                    : () async {
                        final code = codeController.text.trim().toUpperCase();
                        if (code.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Please enter a code')),
                          );
                          return;
                        }
                        if (code.length != 6) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Invite code must be 6 characters')),
                          );
                          return;
                        }
                        setState(() => _isJoining = true);
                        try {
                          final success = await _deviceService.joinDeviceByCode(
                              code, _userId!);
                          if (!mounted) return;
                          setState(() => _isJoining = false);
                          if (success) {
                            Navigator.pop(context);
                            setState(() => _message =
                                'Successfully joined device!');
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text(
                                      'Invalid or expired invite code')),
                            );
                          }
                        } catch (e) {
                          if (mounted) {
                            setState(() => _isJoining = false);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Error: $e')),
                            );
                          }
                        }
                      },
                child: Text(_isJoining ? 'Joining...' : 'Join Device'),
              ),
          ],
        ),
      ),
    ).then((_) {
      codeController.clear();
    });
  }

  @override
  void dispose() {
    _devicesSubscription?.cancel();
    _deviceIdController.dispose();
    _deviceNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: const Text('My Devices'),
        backgroundColor: Colors.grey[850],
        actions: [
          IconButton(
            icon: const Icon(Icons.add_box),
            tooltip: 'Join device by code',
            onPressed: _showJoinByCodeDialog,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await AuthService().signOut();
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Register New Device',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _deviceIdController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Device ID',
                labelStyle: TextStyle(color: Colors.grey[400]),
                hintText: 'e.g. FallSense_X1',
                hintStyle: TextStyle(color: Colors.grey[600]),
                filled: true,
                fillColor: Colors.grey[800],
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _deviceNameController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Device Name (optional)',
                labelStyle: TextStyle(color: Colors.grey[400]),
                hintText: 'e.g. Living Room Sensor',
                hintStyle: TextStyle(color: Colors.grey[600]),
                filled: true,
                fillColor: Colors.grey[800],
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _isLoading
                ? const CircularProgressIndicator()
                : SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _registerDevice,
                      icon: const Icon(Icons.add),
                      label: const Text('Register Device'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.deepPurple,
                      ),
                    ),
                  ),
            if (_message != null) ...[
              const SizedBox(height: 16),
              Text(_message!, style: const TextStyle(color: Colors.orange)),
            ],
            const SizedBox(height: 24),
            const Text(
              'Registered Devices',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _registeredDevices.isEmpty
                  ? Center(
                      child: Text(
                        'No devices registered',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _registeredDevices.length,
                      itemBuilder: (context, index) {
                        var device = _registeredDevices[index];
                        return Card(
                          color: Colors.grey[800],
                          child: ListTile(
                            leading: const Icon(Icons.device_unknown, color: Colors.deepPurple),
                            title: Text(
                              device['name'] ?? device['id'] ?? 'Unknown',
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: Text(
                              'ID: ${device['id']}',
                              style: TextStyle(color: Colors.grey[400]),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (device['isOwner'] == true)
                                  IconButton(
                                    icon: const Icon(Icons.share),
                                    color: Colors.cyan[300],
                                    tooltip: 'Share device',
                                    onPressed: () => _showShareDialog(device['id']),
                                  ),
                                const SizedBox(width: 4),
                                const Icon(Icons.arrow_forward_ios, color: Colors.grey, size: 16),
                              ],
                            ),
                            onTap: () {
                              Navigator.pushNamed(
                                context,
                                '/dashboard',
                                arguments: {'deviceId': device['id']},
                              );
                            },
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