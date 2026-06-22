# Fall Sense X Mobile

A Flutter mobile application for real-time monitoring of human presence and posture detection using mmWave radar sensor data. Features authentication, device registration, and multi-user support.

## Features

- **User Authentication**: Email/password login and registration
- **Device Registration**: Users can register and manage multiple devices
- **Device Sharing**: Share devices with other users via UID, email, or invite code
- **Invite System**: Generate 6-character invite codes for device access
- **Multi-user Access**: Multiple users can view the same device simultaneously
- **Real-time Visualization**: Live updates of radar sensor data from Firebase
- **Live LAN Streaming**: Connect directly to the device's TCP point-cloud server (port 3333) when on the same network, with client-side DBSCAN clustering and posture classification ported from the PC visualizer — works even when Firebase only has the latest detection
- **Posture Detection**: Displays human posture states (Standing, Sitting, Lying, Sleeping, Fall)
- **2D Room View**: Custom painter-based top-down view with a posture-colored human marker
- **3D Radar Visualization**: WebView-based Three.js scene showing the room as a single wireframe box, a ceiling-mounted sensor marker, and posture-colored bounding box(es) — supports both the Firebase snapshot and the live LAN point cloud
- **Replay**: Step or auto-play back through recent stored frames for a device, with adjustable playback speed
- **OTA Updates**: One-tap firmware update trigger with live progress, backed by a Firebase Storage manifest and a remote command the device polls for
- **Device Status Monitoring**: Online/offline heartbeat tracking with push notifications
- **Room Configuration**: Customizable room dimensions (length, width, height in feet)

## App Flow

```
Login Page → Device List → Dashboard
```

1. **Login/Register**: Users authenticate with email/password
2. **Device List**: Shows registered/shared devices; if the user has exactly one device, this is skipped and they land straight on its Dashboard
3. **Dashboard**: Monitor device data with 2D/3D visualizations, replay, and OTA status
4. **Share Device**: Share devices with family via UID, email, or invite code (share action is on each device row in the list)

## Posture States

Colors mirror the WS2812 LED colors the firmware shows on the physical device, kept in sync across the 2D view, 3D view, and live LAN clustering via `kPostureColors` in `lib/models/radar_models.dart`.

| Posture | Color | RGB |
|---------|-------|-----|
| Standing | Parrot green | `(0, 255, 127)` |
| Sitting | Purple | `(128, 0, 128)` |
| Lying / Sleeping | Yellow | `(255, 255, 0)` |
| Fall | Red | `(255, 0, 0)` |
| No Presence | Grey (UI only, no LED) | — |

## Prerequisites

- Flutter SDK (3.11.5 or compatible)
- Android/iOS device or emulator
- Firebase project with Authentication, Realtime Database, and Cloud Messaging enabled

## Setup

1. **Clone the repository**:
   ```bash
   git clone <repository-url>
   cd fall_sense_x_mobile
   ```

2. **Install dependencies**:
   ```bash
   flutter pub get
   ```

3. **Configure Firebase**:
   - Create a Firebase project at https://console.firebase.google.com/
   - Enable Authentication (Email/Password provider)
   - Enable Realtime Database
   - Enable Cloud Messaging
   - Run `flutterfire configure` or update `lib/firebase_options.dart`

4. **Set up Firebase Database Rules** (for testing):
    Deploy `firebase_rules.json` using:
    ```bash
    firebase deploy --only database:rules
    ```
    Or copy the contents of `firebase_rules.json` from the project root into the Firebase Console Rules tab and click **Publish**.

    **Note:** For testing, you may need to disable "Require authentication" in Firebase Console → Realtime Database → ⚙️ Settings, since the ESP32 writes to the database using its own credentials.

5. **Run the app**:
   ```bash
   flutter run
   ```

## Firebase Data Structure

```
devices/
  └── {deviceId}/
      ├── ownerId           # UID of device owner
      ├── sharedWith/       # Shared user access map
      │   └── {uid}: true
      ├── frames/           # Sensor frames (firmware trims this to the last ~100 on-device)
      │   └── {frameId}: {x, y, z, posture, present, confidence, velocity, temperature, timestamp}
      ├── online/
      │   └── {timestamp, value, offline_notified}
      ├── info/
      │   └── {device_id, ip_address, port, firmware_version, device_model, timestamp, online}
      └── ota/
          ├── status/       # {state, progress, error} - polled by the app for OTA progress
          └── command/      # remote OTA trigger, written by the app, watched by the device

invites/
  └── {code}/
      ├── deviceId
      ├── ownerUid
      └── createdAt

users/
  └── {uid}/
      ├── name
      ├── email
      └── createdAt
```

`firebase_rules.json` (project root) is the source of truth for access rules — ownership/sharing-gated reads and writes per sub-node, plus a `timestamp` index on `frames` so the replay feature's time-range query works.

## Project Structure

```
lib/
├── main.dart                       # App entry, auth routing, single-device auto-skip target
├── firebase_options.dart           # Firebase configuration
├── models/
│   └── radar_models.dart           # RadarPoint, HumanDetection, RadarFrame, shared posture colors
├── services/
│   ├── auth_service.dart           # Authentication and device management
│   ├── notification_service.dart   # Push notification handling
│   ├── ota_service.dart            # OTA manifest/status/command Firebase paths, version compare
│   ├── radar_tcp_service.dart      # Raw TCP client for the device's live point-cloud stream (port 3333)
│   └── radar_clustering.dart       # Dart port of the PC visualizer's DBSCAN + posture classification
├── pages/
│   ├── login_page.dart             # Login/Register UI
│   ├── find_device_page.dart       # Device list, registration, sharing
│   ├── live_3d_view_page.dart      # Cloud vs. Live (LAN) toggle wrapper around the 3D view
│   └── dashboard_page.dart         # Main monitoring dashboard, OTA badge/sheet
└── widgets/
    ├── room_3d_view.dart           # 2D top-down view (also reused by replay)
    ├── room_3d_replay.dart         # Time-range playback of stored frames
    └── radar_3d_visualization.dart # 3D WebView + Three.js view (assets/radar_3d.html)
```

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| firebase_core | ^2.15.0 | Firebase initialization |
| firebase_auth | ^4.9.0 | User authentication |
| firebase_database | ^10.4.0 | Realtime data |
| firebase_messaging | ^14.9.0 | Push notifications |
| flutter_local_notifications | ^17.0.0 | Local alerts |
| fl_chart | ^0.66.2 | Charting |
| webview_flutter | ^4.13.1 | 3D rendering (Three.js via WebView) |

Live LAN streaming uses `dart:io` `Socket` directly (no extra package) — it only works on Android/iOS, since browsers block raw TCP sockets. On web, the "Live (LAN)" toggle is disabled with an explanatory tooltip and the app falls back to the Firebase-driven Cloud view.

## Testing Flow

1. Create user accounts via the app registration
2. Register devices using their IDs on the Find Device page
3. Deploy sensor firmware to devices with matching IDs
4. Each user sees only their registered devices

## Building for Release

```bash
flutter build apk --release    # Android
flutter build ios --release    # iOS
```

## Clean and rebuild + Run
```bash
flutter clean  
flutter pub get
flutter run
```