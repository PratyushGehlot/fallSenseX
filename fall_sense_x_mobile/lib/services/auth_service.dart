import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'dart:math';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final DatabaseReference _usersRef = FirebaseDatabase.instance.ref('users');
  final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: ['email']);

  Future<User?> signIn(String email, String password) async {
    try {
      UserCredential result = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      return result.user;
    } catch (e) {
      throw Exception('Login failed: $e');
    }
  }

  Future<void> sendPasswordReset(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
    } catch (e) {
      throw Exception('Could not send reset email: $e');
    }
  }

  Future<User?> register(String email, String password, String name) async {
    try {
      UserCredential result = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      User? user = result.user;
      if (user != null) {
        await _usersRef.child(user.uid).set({
          'name': name,
          'email': email,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
        });
      }
      return user;
    } catch (e) {
      throw Exception('Registration failed: $e');
    }
  }

  /// Throws a plain string (not Exception) for the one expected
  /// non-error case - the user closing the Google account picker - so
  /// callers can tell "user cancelled" apart from a real failure.
  Future<User?> signInWithGoogle() async {
    try {
      final googleUser = await _googleSignIn.signIn();
      if (googleUser == null) {
        throw 'cancelled';
      }
      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      final result = await _auth.signInWithCredential(credential);
      final user = result.user;
      if (user != null && (result.additionalUserInfo?.isNewUser ?? false)) {
        await _usersRef.child(user.uid).set({
          'name': user.displayName ?? user.email?.split('@').first ?? 'User',
          'email': user.email,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
        });
      }
      return user;
    } catch (e) {
      if (e == 'cancelled') rethrow;
      throw Exception('Google sign-in failed: $e');
    }
  }

  Future<void> signOut() async {
    if (await _googleSignIn.isSignedIn()) {
      await _googleSignIn.signOut();
    }
    await _auth.signOut();
  }

  Stream<User?> authStateChanges() {
    return _auth.authStateChanges();
  }

  User? currentUser() {
    return _auth.currentUser;
  }
}

class DeviceService {
  final DatabaseReference _devicesRef = FirebaseDatabase.instance.ref('devices');
  final DatabaseReference _usersRef = FirebaseDatabase.instance.ref('users');
  final DatabaseReference _invitesRef = FirebaseDatabase.instance.ref('invites');
  final DatabaseReference _transfersRef = FirebaseDatabase.instance.ref('transfers');

  /// Owner-initiated request to hand a device to another account. The
  /// transfer only completes once [acceptOwnershipTransfer] is called by
  /// newOwnerUid - ownership never changes unilaterally.
  Future<void> requestOwnershipTransfer(
      String deviceId, String ownerUid, String newOwnerUid) async {
    await _transfersRef.child(deviceId).set({
      'ownerUid': ownerUid,
      'newOwnerUid': newOwnerUid,
      'requestedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Called by the recipient to accept a pending transfer, then finalizes
  /// the ownership change and cleans up the transfer record.
  Future<bool> acceptOwnershipTransfer(String deviceId, String newOwnerUid) async {
    final snapshot = await _transfersRef.child(deviceId).get();
    if (!snapshot.exists) {
      return false;
    }
    final transfer = Map<String, dynamic>.from(snapshot.value as Map);
    if (transfer['newOwnerUid'] != newOwnerUid || transfer['accepted'] != null) {
      return false;
    }

    await _transfersRef.child(deviceId).update({'accepted': true});

    // ownerId write must land first: the rule checks transfers/{deviceId}
    // for 'accepted', which would already be gone if bundled with the
    // transfer-record deletion below in one atomic update.
    await _devicesRef.child(deviceId).update({'ownerId': newOwnerUid});
    await _transfersRef.child(deviceId).remove();
    return true;
  }

  Stream<DatabaseEvent> getUserDevices(String userId) {
    return _devicesRef.onValue;
  }

  Future<bool> registerDevice(String userId, String deviceId, String deviceName) async {
    final doc = await _devicesRef.child(deviceId).once();
    if (doc.snapshot.value != null) {
      final data = Map<String, dynamic>.from(doc.snapshot.value as Map);
      if (data['ownerId'] != null && data['ownerId'] != userId) {
        // Device already owned by another user
        return false;
      }
    }
    // Proceed with update (allows owner to re-register or update name)
    await _devicesRef.child(deviceId).update({
      'ownerId': userId,
      'name': deviceName,
      'registeredAt': DateTime.now().millisecondsSinceEpoch,
      'deviceId': deviceId,
    });
    return true;
  }

  /// [permissionLevel] is one of 'view' | 'manage' | 'full' (see
  /// share_device_page.dart's Permission Levels section). It's recorded for
  /// display and for future enforcement - today every shared user can
  /// already view the device the same way regardless of level, since the
  /// app doesn't yet gate any screens by it.
  Future<void> shareDevice(String deviceId, String targetUid, {String? targetEmail, String permissionLevel = 'view'}) async {
    // Only the owner can share; we assume the caller has verified ownership
    await _devicesRef.child(deviceId).child('sharedWith').child(targetUid).set(true);
    await _devicesRef.child(deviceId).child('sharedPermissions').child(targetUid).set(permissionLevel);
    if (targetEmail != null && targetEmail.isNotEmpty) {
      await _devicesRef.child(deviceId).child('sharedWithEmails').child(targetUid).set(targetEmail);
    }
  }

  Future<void> setSharePermission(String deviceId, String targetUid, String permissionLevel) async {
    await _devicesRef.child(deviceId).child('sharedPermissions').child(targetUid).set(permissionLevel);
  }

  Future<void> unshareDevice(String deviceId, String targetUid) async {
    // Only the owner can unshare
    await _devicesRef.child(deviceId).child('sharedWith').child(targetUid).remove();
    await _devicesRef.child(deviceId).child('sharedWithEmails').child(targetUid).remove();
    await _devicesRef.child(deviceId).child('sharedPermissions').child(targetUid).remove();
  }

  Future<void> renameDevice(String deviceId, String newName) async {
    await _devicesRef.child(deviceId).update({'name': newName});
  }

  /// Unregisters the device from the caller's account: clears ownership and
  /// every sharedWith/permission/email entry, but leaves the device's own
  /// data (frames, info, firmware) untouched so it can be re-added by
  /// anyone later - this does not factory-reset or wipe the physical
  /// device, just this app's record of who owns it.
  Future<void> removeDevice(String deviceId) async {
    await _devicesRef.child(deviceId).update({
      'ownerId': null,
      'sharedWith': null,
      'sharedWithEmails': null,
      'sharedPermissions': null,
    });
  }

  /// Writes the real cloud-reachable restart command the firmware polls for
  /// (firebase_check_for_reset_command in firebase.c) - the device clears
  /// the command itself once it picks it up and reboots.
  Future<void> restartDevice(String deviceId) async {
    await _devicesRef.child(deviceId).child('commands/reset').set('reset');
  }

  /// Reads `sharedWith` UIDs for a device plus any emails/permission levels
  /// recorded at share-time, for display on the Share Device page. Shares
  /// created via the UID tab or an invite code never get a `sharedWithEmails`
  /// entry written, so for those this falls back to a live reverse lookup of
  /// `users/{uid}/email` (written by register()/signInWithGoogle for every
  /// account) rather than showing the raw UID - only bare UID if that user
  /// record is somehow missing entirely.
  Future<List<Map<String, String>>> getSharedUsers(String deviceId) async {
    final snapshot = await _devicesRef.child(deviceId).child('sharedWith').get();
    if (!snapshot.exists || snapshot.value is! Map) return [];
    final uids = (snapshot.value as Map).keys.map((k) => k.toString()).toList();

    final emailsSnapshot = await _devicesRef.child(deviceId).child('sharedWithEmails').get();
    final emails = emailsSnapshot.value is Map
        ? Map<String, dynamic>.from(emailsSnapshot.value as Map)
        : <String, dynamic>{};

    final permissionsSnapshot = await _devicesRef.child(deviceId).child('sharedPermissions').get();
    final permissions = permissionsSnapshot.value is Map
        ? Map<String, dynamic>.from(permissionsSnapshot.value as Map)
        : <String, dynamic>{};

    final missingEmailUids = uids.where((uid) => emails[uid] == null).toList();
    final lookedUp = await Future.wait(missingEmailUids.map((uid) => _usersRef.child(uid).child('email').get()));
    final lookedUpEmails = <String, String>{};
    for (var i = 0; i < missingEmailUids.length; i++) {
      final value = lookedUp[i].value;
      if (value != null) lookedUpEmails[missingEmailUids[i]] = value.toString();
    }

    return uids
        .map((uid) => {
              'uid': uid,
              'label': emails[uid]?.toString() ?? lookedUpEmails[uid] ?? uid,
              'permission': permissions[uid]?.toString() ?? 'view',
            })
        .toList();
  }

  /// Cosmetic activity-zone labels a user can tag for a device (see
  /// device_calibration_wizard_page.dart / activity_zones_page.dart). The
  /// firmware applies the same detection logic everywhere in range - these
  /// are not enforced geofences, just organizational labels.
  Future<List<String>> getZones(String deviceId) async {
    final snapshot = await _devicesRef.child(deviceId).child('uiZones').get();
    if (!snapshot.exists || snapshot.value is! List) return [];
    return (snapshot.value as List).whereType<String>().toList();
  }

  Future<void> setZones(String deviceId, List<String> zones) async {
    await _devicesRef.child(deviceId).child('uiZones').set(zones);
  }

  /// Look up a user's UID by their email address
  Future<String?> getUidByEmail(String email) async {
    try {
      final event = await _usersRef
          .orderByChild('email')
          .equalTo(email)
          .limitToFirst(1)
          .once();
      final snapshot = event.snapshot;
      if (snapshot.value != null) {
        final usersMap = snapshot.value as Map<dynamic, dynamic>;
        if (usersMap.isNotEmpty) {
          return usersMap.keys.first as String;
        }
      }
      return null;
    } catch (e) {
      debugPrint('Error looking up UID by email: $e');
      return null;
    }
  }

  static const Duration inviteTtl = Duration(minutes: 15);

  /// Generate an invite code for a device (must be called by the owner).
  /// Codes expire after [inviteTtl] and are single-use, both enforced by
  /// firebase_rules.json (no Cloud Function required).
  /// Returns the generated code.
  Future<String> generateInviteCode(String deviceId, String ownerUid) async {
    final random = Random.secure();
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final code = List.generate(6, (_) => chars[random.nextInt(chars.length)]).join();

    final now = DateTime.now().millisecondsSinceEpoch;
    final inviteRef = _invitesRef.child(code);
    await inviteRef.set({
      'deviceId': deviceId,
      'ownerUid': ownerUid,
      'createdAt': now,
      'expiresAt': now + inviteTtl.inMilliseconds,
    });

    return code;
  }

  /// Join a device using an invite code.
  ///
  /// Redemption is race-free without a Cloud Function: step 1 runs an RTDB
  /// transaction on `/invites/{code}` so only one caller can ever win the
  /// claim (sets `usedBy`); step 2 grants access via a multi-path update
  /// whose legitimacy the security rules re-derive from that claim. Expiry
  /// and single-use are both enforced server-side by firebase_rules.json,
  /// not by client trust.
  ///
  /// Returns true if successful, false if invalid/expired/already-used invite.
  Future<bool> joinDeviceByCode(String code, String userId) async {
    try {
      final inviteRef = _invitesRef.child(code);

      final result = await inviteRef.runTransaction((value) {
        if (value == null) {
          return Transaction.abort(); // code doesn't exist
        }
        final invite = Map<String, dynamic>.from(value as Map);
        final expiresAt = invite['expiresAt'] as int?;
        final usedBy = invite['usedBy'];
        final now = DateTime.now().millisecondsSinceEpoch;

        if (usedBy != null) {
          return Transaction.abort(); // already redeemed by someone
        }
        if (expiresAt == null || now >= expiresAt) {
          return Transaction.abort(); // expired
        }

        invite['usedBy'] = userId;
        return Transaction.success(invite);
      });

      if (!result.committed) {
        return false;
      }

      final invite = Map<String, dynamic>.from(
          (result.snapshot.value as Map?) ?? {});
      final deviceId = invite['deviceId'] as String?;
      if (deviceId == null) {
        return false;
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      await FirebaseDatabase.instance.ref().update({
        'devices/$deviceId/sharedWith/$userId': true,
        'devices/$deviceId/shareAudit/$userId': {
          'code': code,
          'joinedAt': now,
        },
      });

      return true;
    } catch (e) {
      debugPrint('Error joining device by code: $e');
      return false;
    }
  }

  Future<bool> checkDeviceExists(String deviceId) async {
    DatabaseEvent event = await _devicesRef.child(deviceId).once();
    return event.snapshot.value != null;
  }

  Stream<DatabaseEvent> getDeviceData(String deviceId) {
    return _devicesRef.child(deviceId).onValue;
  }

  /// Retrieves the device's local-access PIN (for LAN-only actions like
  /// reboot/threshold changes/manual OTA - see device_pin.h). Only the
  /// device owner can read this path (firebase_rules.json); returns null if
  /// the device hasn't synced a PIN yet (e.g. it already had a PIN before
  /// this feature existed) or the caller isn't the owner.
  Future<String?> getDevicePin(String deviceId) async {
    final snapshot = await _devicesRef.child(deviceId).child('secrets/pin/value').get();
    return snapshot.value?.toString();
  }
}