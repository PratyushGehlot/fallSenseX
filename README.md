# Fall Sense X

An XIAO ESP32S3 based real-time human presence detection and fall monitoring system using a ceiling-mounted **LD6001 mmWave radar sensor**. The system classifies human posture (standing, sitting, lying, sleeping) and detects falls with audio alerts — all without cameras, preserving privacy.

## Features

- **Real-time posture classification** — Standing, Sitting, Lying, Sleeping
- **Fall detection** with multi-evidence state machine and audio alarm
- **Multi-target tracking** — up to 5 simultaneous people
- **Privacy-preserving** — radar-only sensing, no camera or image capture
- **Web Interface** — Configure device via WiFi web interface
- **WiFi streaming** — raw point cloud data streamed to PC for 3D visualization
- **Audio alerts** — distinct sounds for presence detection and fall events
- **Configurable thresholds** — all detection parameters tunable via web interface

## Hardware

| Component | Model | Interface |
|---|---|---|
| MCU | [XIAO ESP32S3](https://www.seeedstudio.com/XIAO-ESP32S3-p-5327.html) | — |
| Radar Sensor | LD6001 mmWave | UART1 (TX: GPIO 5, RX: GPIO 6, 115200 baud) |
| Flash | 8 MB QIO | SPI |
| Button | GPIO 0 | Config/Pairing mode |

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
│   ├── app/                        # Core application
│   │   ├── fall_sense_x_main.c    # Entry point (app_main)
│   │   ├── radar_sensor.c/.h      # Radar UART, detection, tracking
│   │   ├── wifi_stream.c/.h       # WiFi AP + TCP streaming server
│   │   ├── web_server.c/.h       # Web interface for configuration
│   │   └── button_handler.c/.h   # Button input handling
│   ├── CMakeLists.txt
├── components/bsp/                 # Board Support Package
├── spiffs/                         # Audio files (flashed to SPIFFS partition)
│   ├── bootaudio.wav
│   ├── attention.wav               # Fall alert sound
│   └── humanpresensedetected.wav  # Presence notification
├── pc_app/                         # PC companion tools
├── partitions.csv                  # Flash partition table (8 MB)
├── sdkconfig.defaults              # Default build configuration
└── idf_component.yml               # Component manager dependencies
```

## Prerequisites

- [ESP-IDF v5.1+](https://docs.espressif.com/projects/esp-idf/en/latest/esp32s3/get-started/)
- [VS Code](https://code.visualstudio.com/) with [ESP-IDF Extension](https://marketplace.visualstudio.com/items?itemName=espressif.esp-idf-extension) (recommended)

## Build & Flash

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

## Web Interface

When in Config Mode:

1. Connect to WiFi AP `FallSenseX_Config` (password: `fallsense123`)
2. Open browser at `http://192.168.4.1`
3. Configure WiFi credentials for normal operation
4. Device will restart and connect to your WiFi

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

## Flash Partition Layout

| Partition | Size | Purpose |
|---|---|---|
| `ota_0` | 1900 KB | Application firmware |
| `storage` | 1400 KB | SPIFFS (audio files) |
| `model` | 2800 KB | Reserved for ML models |
| `nvs` | 24 KB | Non-volatile storage |

## License

See original project at https://github.com/PratyushGehlot/radar_human_detectmon
