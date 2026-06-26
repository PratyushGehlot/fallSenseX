import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'dart:math';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final DatabaseReference _usersRef = FirebaseDatabase.instance.ref('users');

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

  Future<void> signOut() async {
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

  Future<void> shareDevice(String deviceId, String targetUid) async {
    // Only the owner can share; we assume the caller has verified ownership
    await _devicesRef.child(deviceId).child('sharedWith').child(targetUid).set(true);
  }

  Future<void> unshareDevice(String deviceId, String targetUid) async {
    // Only the owner can unshare
    await _devicesRef.child(deviceId).child('sharedWith').child(targetUid).remove();
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