import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:fall_sense_x_mobile/services/auth_service.dart';
import '../theme/app_theme.dart';
import '../widgets/status_card.dart';

const List<Color> _avatarColors = [
  Color(0xFFFFC107),
  Color(0xFFFF9F0A),
  Color(0xFF2F6FE4),
  Color(0xFF8E5FE8),
  Color(0xFF34C759),
];

const Map<String, String> _permissionLabels = {
  'view': 'Can View',
  'manage': 'Can Manage',
  'full': 'Full Access',
};

const Map<String, String> _permissionDescriptions = {
  'view': 'Can view live feed and basic alerts',
  'manage': 'Can view, manage settings and zones',
  'full': 'Can view, manage, share and edit all settings',
};

const Map<String, IconData> _permissionIcons = {
  'view': Icons.visibility_outlined,
  'manage': Icons.edit_outlined,
  'full': Icons.workspace_premium_outlined,
};

Color _colorForUid(String uid) => _avatarColors[uid.hashCode.abs() % _avatarColors.length];

/// Share Device screen, matching the premium reference's "People with
/// Access" + "Permission Levels" layout. Sharing logic (UID/email lookup,
/// invite codes) is unchanged from before, just relocated into the "+
/// Share with Others" sheet.
class ShareDevicePage extends StatefulWidget {
  final String deviceId;
  final String deviceName;
  const ShareDevicePage({super.key, required this.deviceId, required this.deviceName});

  @override
  State<ShareDevicePage> createState() => _ShareDevicePageState();
}

class _ShareDevicePageState extends State<ShareDevicePage> {
  final DeviceService _deviceService = DeviceService();
  List<Map<String, String>> _sharedUsers = [];
  bool _isLoading = true;
  bool _canViewLiveFeed = true;

  DatabaseReference get _permissionsRef => FirebaseDatabase.instance.ref('devices/${widget.deviceId}/permissions');

  @override
  void initState() {
    super.initState();
    _loadSharedUsers();
    _loadPermissions();
  }

  Future<void> _loadSharedUsers() async {
    final users = await _deviceService.getSharedUsers(widget.deviceId);
    if (mounted) {
      setState(() {
        _sharedUsers = users;
        _isLoading = false;
      });
    }
  }

  Future<void> _loadPermissions() async {
    final snapshot = await _permissionsRef.child('canViewLiveFeed').get();
    if (mounted && snapshot.exists) {
      setState(() => _canViewLiveFeed = snapshot.value as bool? ?? true);
    }
  }

  Future<void> _setCanViewLiveFeed(bool value) async {
    setState(() => _canViewLiveFeed = value);
    await _permissionsRef.child('canViewLiveFeed').set(value);
  }

  Future<void> _unshare(String uid) async {
    await _deviceService.unshareDevice(widget.deviceId, uid);
    _loadSharedUsers();
  }

  Future<void> _changePermission(String uid, String currentLevel) async {
    final newLevel = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _permissionLabels.keys
              .map((level) => ListTile(
                    leading: Icon(_permissionIcons[level], color: AppColors.accent),
                    title: Text(_permissionLabels[level]!),
                    subtitle: Text(_permissionDescriptions[level]!, style: const TextStyle(fontSize: 11)),
                    trailing: level == currentLevel ? const Icon(Icons.check, color: AppColors.accent) : null,
                    onTap: () => Navigator.pop(context, level),
                  ))
              .toList(),
        ),
      ),
    );
    if (newLevel != null && newLevel != currentLevel) {
      await _deviceService.setSharePermission(widget.deviceId, uid, newLevel);
      _loadSharedUsers();
    }
  }

  void _showAddSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _AddShareSheet(
        deviceId: widget.deviceId,
        deviceName: widget.deviceName,
        onShared: _loadSharedUsers,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService().currentUser();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Share Device'),
        actions: [IconButton(icon: const Icon(Icons.add), onPressed: _showAddSheet)],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(gradient: AppColors.heroGradient, borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.sensors, color: Colors.white),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.deviceName, style: const TextStyle(fontWeight: FontWeight.w600)),
                        const Text('FallSense Pro', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const SectionHeader(title: 'PEOPLE WITH ACCESS'),
          if (_isLoading)
            const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Center(child: CircularProgressIndicator()))
          else
            SettingsSectionCard(children: [
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppColors.accent,
                  child: Text(
                    (user?.email?.isNotEmpty ?? false) ? user!.email![0].toUpperCase() : 'Y',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
                title: Text('You${user?.email != null ? ' (Owner)' : ''}'),
                subtitle: Text(user?.email ?? '', style: const TextStyle(fontSize: 12)),
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(12)),
                  child: const Text('Owner', style: TextStyle(fontSize: 11, color: AppColors.accent, fontWeight: FontWeight.w600)),
                ),
              ),
              ..._sharedUsers.map((sharedUser) {
                final uid = sharedUser['uid']!;
                final level = sharedUser['permission'] ?? 'view';
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: _colorForUid(uid),
                    child: Text(sharedUser['label']![0].toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                  title: Text(sharedUser['label']!),
                  subtitle: Text(_permissionLabels[level] ?? level, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.chevron_right, color: AppColors.textSecondary),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18, color: AppColors.textSecondary),
                        onPressed: () => _unshare(uid),
                      ),
                    ],
                  ),
                  onTap: () => _changePermission(uid, level),
                );
              }),
            ]),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _showAddSheet,
            icon: const Icon(Icons.person_add_alt_outlined, size: 18),
            label: const Text('Share with Others'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 44)),
          ),
          const SizedBox(height: 24),
          const SectionHeader(title: 'PERMISSIONS'),
          SettingsSectionCard(children: [
            SettingsTile(
              icon: Icons.visibility_outlined,
              iconCircleColor: AppColors.accent,
              title: 'Can View Live Feed',
              subtitle: 'Allow shared users to view this device\'s live feed',
              trailingWidget: Switch(value: _canViewLiveFeed, onChanged: _setCanViewLiveFeed),
            ),
          ]),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(14)),
            child: Row(
              children: [
                const Icon(Icons.shield_outlined, color: AppColors.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Your device is secure', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      const Text('All shared access is encrypted and protected.', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Single-flow "Add People" sheet matching share_with_others_UI.png: an
/// email invite (with a permission-level picker, reusing the existing
/// email-lookup-then-share logic) plus a separate invite-code generator.
/// The mockup calls the code section "Share Invite Link" with a fake
/// fallsensex.com URL and a 7-day expiry - there's no real web routing or
/// deep-link handler in this app to back a clickable link, and the actual
/// invite TTL is 15 minutes (see AuthService.inviteTtl), so this shows the
/// real 6-character code and its real expiry instead of inventing a link
/// that wouldn't do anything if tapped. Raw-UID sharing (no email lookup)
/// is kept as a small "Share by User ID" fallback since the new design
/// doesn't have a slot for it but some users won't have looked-up emails.
class _AddShareSheet extends StatefulWidget {
  final String deviceId;
  final String deviceName;
  final VoidCallback onShared;
  const _AddShareSheet({required this.deviceId, required this.deviceName, required this.onShared});

  @override
  State<_AddShareSheet> createState() => _AddShareSheetState();
}

class _AddShareSheetState extends State<_AddShareSheet> {
  final DeviceService _deviceService = DeviceService();
  final _emailController = TextEditingController();
  String _permissionLevel = 'view';
  bool _isBusy = false;
  String? _generatedCode;
  DateTime? _codeExpiresAt;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _shareByUid(String uid) async {
    setState(() => _isBusy = true);
    try {
      await _deviceService.shareDevice(widget.deviceId, uid, permissionLevel: _permissionLevel);
      widget.onShared();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _showError('$e');
    }
    if (mounted) setState(() => _isBusy = false);
  }

  Future<void> _shareByEmail() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) return;
    setState(() => _isBusy = true);
    try {
      final uid = await _deviceService.getUidByEmail(email);
      if (uid == null) {
        _showError('No user found with this email');
      } else {
        await _deviceService.shareDevice(widget.deviceId, uid, targetEmail: email, permissionLevel: _permissionLevel);
        widget.onShared();
        if (mounted) Navigator.pop(context);
      }
    } catch (e) {
      _showError('$e');
    }
    if (mounted) setState(() => _isBusy = false);
  }

  Future<void> _generateCode() async {
    final userId = AuthService().currentUser()?.uid;
    if (userId == null) return;
    setState(() => _isBusy = true);
    try {
      final code = await _deviceService.generateInviteCode(widget.deviceId, userId);
      setState(() {
        _generatedCode = code;
        _codeExpiresAt = DateTime.now().add(DeviceService.inviteTtl);
      });
    } catch (e) {
      _showError('$e');
    }
    if (mounted) setState(() => _isBusy = false);
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _promptShareByUid() async {
    final controller = TextEditingController();
    final uid = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Share by User ID'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'User UID')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Share')),
        ],
      ),
    );
    if (uid != null && uid.isNotEmpty) _shareByUid(uid);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).padding.bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset('assets/images/device_photo.png', width: 44, height: 44, fit: BoxFit.cover),
                ),
                const SizedBox(width: 12),
                Text(widget.deviceName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 20),
            const Text('Invite by Email', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('Enter the email address of the person you want to invite.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(height: 10),
            TextField(controller: _emailController, decoration: const InputDecoration(labelText: 'Email Address')),
            const SizedBox(height: 12),
            const Text('Permission Level', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: _permissionLevel,
              items: _permissionLabels.entries
                  .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                  .toList(),
              onChanged: (v) => setState(() => _permissionLevel = v ?? 'view'),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AppColors.accentLight, borderRadius: BorderRadius.circular(12)),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: AppColors.accent, size: 18),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'They will receive an invitation. The person will receive an email invitation to join and access this device.',
                      style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isBusy ? null : _shareByEmail,
                child: Text(_isBusy ? 'Sending...' : 'Send Invitation'),
              ),
            ),
            TextButton(onPressed: _isBusy ? null : _promptShareByUid, child: const Text('Share by User ID instead')),
            const SizedBox(height: 8),
            const Divider(),
            const SizedBox(height: 8),
            const Text('Share Invite Code', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('Anyone with the code can request access to this device.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            if (_generatedCode != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE5E5EA))),
                child: Column(
                  children: [
                    Text(_generatedCode!, style: const TextStyle(fontSize: 26, letterSpacing: 4, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.schedule, size: 14, color: AppColors.textSecondary),
                        const SizedBox(width: 4),
                        Text(
                          _codeExpiresAt != null ? 'Expires in ${_codeExpiresAt!.difference(DateTime.now()).inMinutes}m' : '',
                          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: _generatedCode!));
                        _showError('Copied to clipboard');
                      },
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('Copy Code'),
                    ),
                  ],
                ),
              )
            else
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _isBusy ? null : _generateCode,
                  child: Text(_isBusy ? 'Generating...' : 'Generate Invite Code'),
                ),
              ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0xFFFFF7E0), borderRadius: BorderRadius.circular(12)),
              child: const Row(
                children: [
                  Icon(Icons.lock_outline, color: Color(0xFFB8860B), size: 18),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text('Keep your device secure. Only share the code with people you trust.', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
