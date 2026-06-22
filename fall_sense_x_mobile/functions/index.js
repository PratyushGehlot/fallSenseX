const functions = require("firebase-functions");
const admin = require("firebase-admin");

// Initialize Firebase Admin SDK
admin.initializeApp();

// Configuration
const OFFLINE_THRESHOLD_MS = 30 * 1000; // Device considered offline after 30s without heartbeat
const CHECK_INTERVAL_SEC = 30; // Run check every 30 seconds
const NOTIFICATION_TITLE = "Device Offline";
const NOTIFICATION_BODY = "FallSenseX device is not responding. Check power and internet connection.";

// Firmware uploads are expected at: firmware/{deviceModel}/{version}.bin
const FIRMWARE_PATH_RE = /^firmware\/([^/]+)\/([\w.\-]+)\.bin$/;
// How long the generated download URL for a firmware image stays valid.
const FIRMWARE_URL_EXPIRY_MS = 30 * 24 * 60 * 60 * 1000; // 30 days

/**
 * SCHEDULED CLOUD FUNCTION: Runs every 30 seconds to check all device heartbeats.
 * Detects devices that haven't sent a heartbeat within the threshold and sends
 * push notifications to subscribed users. Also updates the online status in Realtime Database.
 */
exports.monitorDeviceOnline = functions.pubsub
  .schedule(`every ${CHECK_INTERVAL_SEC} seconds`)
  .onRun(async (context) => {
    const now = Date.now();
    const devicesRef = admin.database().ref("/devices");
    
    try {
      const snapshot = await devicesRef.once("value");
      const devices = snapshot.val();
      
      if (!devices) {
        console.log("monitorDeviceOnline: No devices found in database");
        return null;
      }
      
      const updates = [];
      let checked = 0;
      let offlineCount = 0;
      
      for (const deviceId in devices) {
        const device = devices[deviceId];
        const online = device.online;
        
        // Skip if no online info
        if (!online || typeof online.timestamp !== "number") {
          continue;
        }
        
        checked++;
        const lastSeenMs = online.timestamp * 1000; // Convert seconds to ms
        const ageMs = now - lastSeenMs;
        const isOffline = ageMs > OFFLINE_THRESHOLD_MS;
        const wasNotified = online.offline_notified === true;
        const currentValue = online.value === true;
        
        if (isOffline && !wasNotified) {
          // Device went offline - send push notification
          console.log(`Device ${deviceId} OFFLINE (age=${Math.round(ageMs/1000)}s). Sending alert...`);
          offlineCount++;
          
          try {
            await sendOfflineNotification(deviceId, `No heartbeat for ${Math.round(ageMs/1000)} seconds`);
            
            // Update database: set value=false and mark as notified
            updates.push(
              admin.database().ref(`/devices/${deviceId}/online`).update({
                value: false,
                offline_notified: true,
                last_checked: Math.floor(now / 1000)
              })
            );
          } catch (err) {
            console.error(`Failed to send offline notification for ${deviceId}:`, err);
          }
        } else if (!isOffline && wasNotified) {
          // Device came back online - reset notified flag (heartbeat already set value=true)
          console.log(`Device ${deviceId} back online. Resetting notified flag.`);
          updates.push(
            admin.database().ref(`/devices/${deviceId}/online`).update({
              offline_notified: false,
              last_checked: Math.floor(now / 1000)
            })
          );
        } else if (isOffline && wasNotified) {
          // Already offline and notified - just update last_checked timestamp
          updates.push(
            admin.database().ref(`/devices/${deviceId}/online`).update({
              last_checked: Math.floor(now / 1000)
            })
          );
        }
      }
      
      // Apply all flag updates in parallel
      if (updates.length > 0) {
        await Promise.all(updates);
      }
      
      console.log(`monitorDeviceOnline: Checked ${checked} devices, ${offlineCount} offline alerts sent`);
      return null;
    } catch (error) {
      console.error("monitorDeviceOnline: Error:", error);
      return null;
    }
  });

/**
 * Sends a push notification to all users subscribed to this device's alert topic.
 * Topic format: device_{deviceId}_alerts
 */
async function sendOfflineNotification(deviceId, reason) {
  const topic = `device_${deviceId}_alerts`;
  
  const message = {
    notification: {
      title: NOTIFICATION_TITLE,
      body: `${NOTIFICATION_BODY}\nDevice: ${deviceId}\nReason: ${reason}`,
    },
    android: {
      priority: "high",
      notification: {
        channelId: "offline_alerts",
        sound: "default",
        vibrateTimingsMillis: [0, 500, 250, 500],
        color: "#ff0000",
      },
    },
    apns: {
      payload: {
        aps: {
          sound: "default",
          category: "OFFLINE_ALERT",
          badge: 1,
        },
      },
    },
    topic: topic,
    data: {
      deviceId: deviceId,
      alertType: "device_offline",
      reason: reason,
      timestamp: Date.now().toString(),
    },
  };
  
  try {
    const response = await admin.messaging().send(message);
    console.log(`✅ Offline notification sent to topic '${topic}':`, response);
    return response;
  } catch (error) {
    console.error(`❌ Failed to send offline notification for ${deviceId}:`, error);
    // Don't throw - we don't want to crash the function
    return null;
  }
}

/**
 * Compares two dot-separated version strings.
 * Returns 1 if a > b, -1 if a < b, 0 if equal.
 */
function compareVersions(a, b) {
  const partsA = String(a).split(".").map((n) => parseInt(n, 10) || 0);
  const partsB = String(b).split(".").map((n) => parseInt(n, 10) || 0);
  const len = Math.max(partsA.length, partsB.length);
  for (let i = 0; i < len; i++) {
    const na = partsA[i] || 0;
    const nb = partsB[i] || 0;
    if (na > nb) return 1;
    if (na < nb) return -1;
  }
  return 0;
}

/**
 * STORAGE TRIGGER: Runs when a firmware binary is uploaded to
 * firmware/{deviceModel}/{version}.bin (via the Firebase console, the
 * Admin SDK dev-upload script in tools/, or any other Storage write).
 *
 * - Publishes a manifest entry to /firmware_manifest/{deviceModel}
 * - Notifies owners/shared users of devices running an older version,
 *   reusing the existing per-device alert topic (device_{deviceId}_alerts)
 *   that the app already subscribes to.
 */
exports.onFirmwareUploaded = functions.storage.object().onFinalize(async (object) => {
  const match = FIRMWARE_PATH_RE.exec(object.name || "");
  if (!match) {
    return null; // Not a firmware upload, ignore.
  }

  const [, deviceModel, version] = match;
  console.log(`Firmware uploaded for model '${deviceModel}', version ${version}`);

  try {
    const bucket = admin.storage().bucket(object.bucket);
    const file = bucket.file(object.name);
    const [url] = await file.getSignedUrl({
      action: "read",
      expires: Date.now() + FIRMWARE_URL_EXPIRY_MS,
    });

    const manifest = {
      version,
      url,
      md5: object.md5Hash || null,
      sizeBytes: Number(object.size) || 0,
      uploadedAt: Date.now(),
    };

    await admin.database()
      .ref(`/firmware_manifest/${deviceModel}`)
      .set(manifest);

    await notifyDevicesOfUpdate(deviceModel, version, url);
    return null;
  } catch (error) {
    console.error(`onFirmwareUploaded: failed for ${object.name}:`, error);
    return null;
  }
});

/**
 * Sends an "update available" push notification to every device of the given
 * model whose last-reported firmware version is older than `version`.
 */
async function notifyDevicesOfUpdate(deviceModel, version, url) {
  const devicesSnap = await admin.database().ref("/devices").once("value");
  const devices = devicesSnap.val();
  if (!devices) {
    return;
  }

  const sends = [];
  for (const deviceId of Object.keys(devices)) {
    const device = devices[deviceId];
    const model = device?.info?.deviceModel || deviceModel;
    const currentVersion = device?.info?.firmwareVersion;

    if (model !== deviceModel) {
      continue;
    }
    if (currentVersion && compareVersions(version, currentVersion) <= 0) {
      continue; // Device is already on this version or newer.
    }

    const topic = `device_${deviceId}_alerts`;
    const message = {
      notification: {
        title: "Firmware Update Available",
        body: `A new firmware update (v${version}) is available for your FallSenseX device.`,
      },
      data: {
        deviceId,
        alertType: "firmware_update",
        version,
        url,
        timestamp: Date.now().toString(),
      },
      topic,
    };

    sends.push(
      admin.messaging().send(message).catch((err) => {
        console.error(`Failed to send update notification for ${deviceId}:`, err);
      })
    );
  }

  await Promise.all(sends);
  console.log(`notifyDevicesOfUpdate: notified ${sends.length} device(s) for model '${deviceModel}' v${version}`);
}

/**
 * Generates a Firebase Custom Token for ESP32 device authentication.
 * Returns: { token: string }
 */
exports.createCustomToken = functions.https.onCall(async (data, context) => {
  const { deviceId } = data;

  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "User must be signed in");
  }

  if (!deviceId) {
    throw new functions.https.HttpsError("invalid-argument", "Device ID is required");
  }

  try {
    // Create a custom token with deviceId as the UID
    // The token will be valid for 24 hours by default
    const token = await admin.auth().createCustomToken(deviceId, { 
      source: "esp32",
      ownerUid: context.auth.uid 
    });
    return { token };
  } catch (error) {
    console.error("Error creating custom token:", error);
    throw new functions.https.HttpsError("internal", "Failed to create custom token");
  }
});

/**
 * Callable function: Manually check device status from mobile app.
 * Returns: { deviceId, online, isOnline, offlineThresholdMs }
 */
exports.checkDeviceStatus = functions.https.onCall(async (data, context) => {
  const { deviceId } = data;
  
  if (!deviceId) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Device ID is required"
    );
  }
  
  try {
    const snapshot = await admin
      .database()
      .ref(`/devices/${deviceId}/online`)
      .get();
    
    const onlineData = snapshot.val();
    const now = Date.now();
    
    let isOnline = false;
    if (onlineData && onlineData.value === true && onlineData.timestamp) {
      const lastSeenMs = onlineData.timestamp * 1000;
      isOnline = now - lastSeenMs < OFFLINE_THRESHOLD_MS;
    }
    
    return {
      deviceId,
      online: onlineData,
      isOnline,
      offlineThresholdMs: OFFLINE_THRESHOLD_MS,
    };
  } catch (error) {
    console.error("Error checking device status:", error);
    throw new functions.https.HttpsError(
      "internal",
      "Failed to check device status"
    );
  }
});
