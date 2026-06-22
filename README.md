# Fall Sense X

An XIAO ESP32S3 based real-time human presence detection and fall monitoring system using a ceiling-mounted **LD6001 mmWave radar sensor**. The system classifies human posture (standing, sitting, lying, sleeping) and detects falls with audio/LED alerts — all without cameras, preserving privacy. A companion **Flutter mobile app** provides live 3D visualization, Firebase-backed alerts, and remote OTA updates.

## Features

- **Real-time posture classification** — Standing, Sitting, Lying, Sleeping
- **Fall detection** with multi-evidence state machine and audio alarm
- **Multi-target tracking** — up to 5 simultaneous people
- **Privacy-preserving** — radar-only sensing, no camera or image capture
- **Web Interface** — configure WiFi, radar thresholds, and OTA via the device's local web server
- **WiFi streaming** — raw point cloud data streamed over TCP for live 3D visualization (PC or mobile)
- **Firebase integration** — pushes human location/posture frames to Firebase Realtime Database for the mobile app and push notifications
- **Mobile app** (Flutter) — device pairing, live 3D radar view, fall alerts, OTA trigger
- **OTA updates** — HTTP/HTTPS firmware updates with dual OTA partitions (`ota_0`/`ota_1`)
- **PIN-gated local endpoints** — sensitive actions (reboot, threshold changes, manual OTA) require a device PIN, independent of Firebase auth
- **WS2812 status LED** — visual status/alert indication
- **Audio alerts** — distinct sounds for boot, presence detection, and fall events
- **Configurable thresholds** — all detection parameters tunable via the web interface

## Hardware

| Component | Model | Interface |
|---|---|---|
| MCU | [XIAO ESP32S3](https://www.seeedstudio.com/XIAO-ESP32S3-p-5327.html) | — |
| Radar Sensor | LD6001 mmWave | UART1 (TX: GPIO 6, RX: GPIO 5, 115200 baud) |
| Flash | 8 MB | SPI |
| Status LED | WS2812 RGB | RMT peripheral |
| Button | GPIO 3 | Config/Pairing mode |

### Wiring

The radar sensor connects to the XIAO ESP32S3 via UART:

| Radar Pin | XIAO ESP32S3 GPIO | Function |
|---|---|---|
| TX | GPIO 6 | Radar data output → ESP RX |
| RX | GPIO 5 | ESP TX → Radar commands |
| VCC | 3.3V | Power |
| GND | GND | Ground |

### Button Controls

| Action | Function |
|---|---|
| Long press (3s) | Enter Config Mode (Web Interface) |
| Double press | Enter Paired Mode |
| Short press | Normal Operation |

## Project Structure

```
FallSenseX/
├── main/
│   ├── app/                          # Core firmware application
│   │   ├── fall_sense_x_main.c       # Entry point (app_main)
│   │   ├── radar_sensor.c/.h         # Radar UART, clustering, posture/fall detection, tracking
│   │   ├── wifi_stream.c/.h          # WiFi AP/STA + TCP point-cloud streaming server
│   │   ├── web_server.c/.h           # Local HTTP server for config, thresholds, OTA
│   │   ├── ota_update.c/.h           # HTTP/HTTPS OTA firmware update logic
│   │   ├── device_pin.c/.h           # PIN auth for sensitive local web endpoints
│   │   └── button_handler.c/.h       # Button input handling (config/pairing mode)
│   └── CMakeLists.txt
├── components/
│   ├── bsp/                          # Board Support Package
│   ├── firebase/                     # Pushes location/posture frames to Firebase RTDB
│   └── ws2812_led/                   # WS2812 RGB status LED driver (RMT peripheral)
├── spiffs/                           # Audio files (flashed to SPIFFS partition)
│   ├── bootaudio.wav
│   ├── attention.wav                 # Fall alert sound
│   ├── humanpresensedetected.wav     # Presence notification
│   └── presense.wav
├── fall_sense_x_mobile/              # Flutter mobile app
│   ├── lib/pages/                    # Login, find-device, dashboard, live 3D view
│   ├── lib/services/                 # Auth, radar TCP/clustering, OTA, notifications
│   └── functions/                    # Firebase Cloud Functions backend
├── tools/                            # PC-side companion tools
│   ├── pc_app/                       # Point-cloud visualizer (Python)
│   ├── pc_app_code/                  # Visualizer source / build scripts
│   ├── radar_terminal/               # Radar config/terminal CLI tools
│   ├── radar_uart_debug/             # Standalone ESP-IDF project for UART debugging
│   ├── ota_flash_pc/                 # PC-side OTA flashing helper
│   └── ota_upload/                   # Node.js firmware upload helper
├── partitions.csv                    # Flash partition table (8 MB, dual OTA)
├── sdkconfig.defaults                # Default build configuration
└── idf_component.yml                 # Component manager dependencies
```

## Prerequisites

- [ESP-IDF v5.1+](https://docs.espressif.com/projects/esp-idf/en/latest/esp32s3/get-started/)
- [VS Code](https://code.visualstudio.com/) with [ESP-IDF Extension](https://marketplace.visualstudio.com/items?itemName=espressif.esp-idf-extension) (recommended)
- [Flutter SDK](https://docs.flutter.dev/get-started/install) (for the mobile app in `fall_sense_x_mobile/`)
- A Firebase project (Auth + Realtime Database) for cloud sync and push notifications

## Build & Flash (Firmware)

### Using ESP-IDF CLI

```bash
# Set target
idf.py set-target esp32s3

# Build firmware + SPIFFS image
idf.py build

# Flash to device (adjust COM port)
idf.py -p COM9 flash

# Monitor serial output
idf.py -p COM9 monitor

# Build, flash, and monitor in one step
idf.py -p COM9 flash monitor
```

### Using VS Code

1. Open the project folder in VS Code
2. ESP-IDF extension auto-detects the project
3. Use the toolbar buttons: **Build** → **Flash** → **Monitor**
4. Port and target are configured in `.vscode/settings.json`

## Mobile App

The Flutter app in `fall_sense_x_mobile/` pairs with the device over WiFi, receives the live TCP point-cloud stream for 3D visualization, and uses Firebase for authentication, alert push notifications, and remote OTA triggering.

```bash
cd fall_sense_x_mobile
flutter pub get
flutter run
```

## Web Interface

When in Config Mode:

1. Connect to WiFi AP `FallSenseX` (password: `fallsense123`)
2. Open browser at `http://192.168.4.1`
3. Configure WiFi credentials for normal operation, tune detection thresholds, or trigger an OTA update
4. Sensitive actions (reboot, threshold changes, manual OTA) require the device PIN (`X-Device-PIN` header) — see `main/app/device_pin.h`
5. Device will restart and connect to your WiFi

## Configuration

All detection parameters are configurable via the web interface or in `RADAR_CONFIG_DEFAULT()` in `main/app/radar_sensor.h`:

| Parameter | Default | Description |
|---|---|---|
| `eps` | 0.55m | DBSCAN clustering radius |
| `min_samples` | 5 | Minimum points per cluster |
| `standing_z` | 1.0m | Height threshold for standing posture |
| `sitting_z` | 0.6m | Height threshold for sitting posture |
| `lying_z` | 0.25m | Height threshold for lying posture |
| `fall_v_threshold` | -0.3 m/s | Downward velocity for fall evidence |
| `fall_z_drop_threshold` | 0.10m | Z-drop per frame for fall evidence |
| `fall_height_collapse` | 0.25m | Max height drop for fall evidence |
| `fall_hold_time_us` | 5,000,000 | Fall confirmed hold time (5 seconds) |
| `track_gate_radius` | 0.8m | Max distance for track association |

## OTA Updates

Firmware supports HTTP/HTTPS OTA via `main/app/ota_update.c`, writing to whichever of the dual `ota_0`/`ota_1` partitions is inactive. Updates can be triggered from the web interface, the mobile app's OTA service, or `tools/ota_flash_pc` / `tools/ota_upload`.

## Flash Partition Layout

| Partition | Size | Purpose |
|---|---|---|
| `sec_cert` | 16 KB | Secure certificate storage |
| `nvs` | 24 KB | Non-volatile storage |
| `otadata` | 8 KB | OTA partition selection state |
| `phy_init` | 44 KB | PHY calibration data |
| `ota_0` | 2900 KB | Application firmware (slot A) |
| `ota_1` | 2900 KB | Application firmware (slot B) |
| `storage` | 1 MB | SPIFFS (audio files) |

## License

See original project at https://github.com/PratyushGehlot/radar_human_detectmon
