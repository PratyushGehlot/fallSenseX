import 'package:firebase_database/firebase_database.dart';

/// Firebase plumbing for the OTA update flow.
///
/// Update-available state and the firmware manifest are populated by the
/// `onFirmwareUploaded` Cloud Function whenever a `.bin` is pushed to
/// Storage at `firmware/{model}/{version}.bin`. Triggering an update just
/// writes a command the device's `firebase_command_task` already polls for
/// (`/devices/{deviceId}/commands/ota_update`) - access is governed by the
/// same ownership rules as the rest of `/devices/{deviceId}`, so no
/// additional auth is needed here.
class OtaService {
  static DatabaseReference manifestRef(String model) =>
      FirebaseDatabase.instance.ref('firmware_manifest/$model');

  static DatabaseReference infoRef(String deviceId) =>
      FirebaseDatabase.instance.ref('devices/$deviceId/info');

  static DatabaseReference statusRef(String deviceId) =>
      FirebaseDatabase.instance.ref('devices/$deviceId/ota_status');

  static DatabaseReference commandRef(String deviceId) =>
      FirebaseDatabase.instance.ref('devices/$deviceId/commands/ota_update');

  static Future<void> triggerUpdate(String deviceId, String url, String version) {
    return commandRef(deviceId).set({'url': url, 'version': version});
  }

  /// Returns 1 if a > b, -1 if a < b, 0 if equal.
  static int compareVersions(String a, String b) {
    final partsA = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final partsB = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final len = partsA.length > partsB.length ? partsA.length : partsB.length;
    for (var i = 0; i < len; i++) {
      final na = i < partsA.length ? partsA[i] : 0;
      final nb = i < partsB.length ? partsB[i] : 0;
      if (na != nb) return na > nb ? 1 : -1;
    }
    return 0;
  }
}
