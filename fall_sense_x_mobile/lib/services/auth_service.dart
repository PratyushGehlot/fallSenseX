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

  /// Generate an invite code for a device (must be called by the owner)
  /// Returns the generated code
  Future<String> generateInviteCode(String deviceId, String ownerUid) async {
    // Generate a random 6-character code (uppercase letters and digits)
    final random = Random();
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final code = List.generate(6, (_) => chars[random.nextInt(chars.length)]).join();

    // Save the invite globally with deviceId, ownerUid, and timestamp
    final inviteRef = _invitesRef.child(code);
    await inviteRef.set({
      'deviceId': deviceId,
      'ownerUid': ownerUid,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });

    return code;
  }

  /// Join a device using an invite code
  /// Returns true if successful, false if invalid/expired invite
  Future<bool> joinDeviceByCode(String code, String userId) async {
    try {
      final inviteRef = _invitesRef.child(code);
      final inviteEvent = await inviteRef.once();
      final inviteSnapshot = inviteEvent.snapshot;

      if (inviteSnapshot.value == null) {
        return false; // Invite not found or already used
      }

      final inviteData =
          Map<String, dynamic>.from(inviteSnapshot.value as Map);
      final deviceId = inviteData['deviceId'] as String?;
      final ownerUid = inviteData['ownerUid'] as String?;
      final createdAt = inviteData['createdAt'] as int?;

      // Optional: Check if invite is expired (e.g., older than 24 hours)
      // final now = DateTime.now().millisecondsSinceEpoch;
      // if (createdAt != null && now - createdAt > 24 * 60 * 60 * 1000) {
      //   await inviteRef.remove(); // Clean up expired invite
      //   return false;
      // }

      // Verify the invite owner matches the device's actual owner
      if (deviceId == null || ownerUid == null) {
        return false;
      }

      final deviceRef = _devicesRef.child(deviceId);
      final deviceEvent = await deviceRef.once();
      final deviceSnapshot = deviceEvent.snapshot;

      if (deviceSnapshot.value == null) {
        return false; // Device not found
      }

      final deviceData =
          Map<String, dynamic>.from(deviceSnapshot.value as Map);
      final deviceOwnerId = deviceData['ownerId'] as String?;

      if (ownerUid != null &&
          deviceOwnerId != null &&
          ownerUid == deviceOwnerId) {
        // Valid invite: share the device with the user
        await shareDevice(deviceId, userId);
        // Remove the invite to prevent reuse
        await inviteRef.remove();
        return true;
      }

      return false;
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
}