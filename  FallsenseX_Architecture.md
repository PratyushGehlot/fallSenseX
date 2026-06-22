# Fall Sense X — System Architecture & Execution Flow

## 1. Hardware Overview

| Component | Details |
|-----------|---------|
| MCU | XIAO ESP32S3 (Xtensa LX7, dual-core) |
| Radar | LD6001 mmWave (UART @ 115200 baud, GPIO5/GPIO6) |
| LED | WS2812 (GPIO2, single pixel) |
| Button | GPIO (CONFIG_BUTTON_GPIO) |
| Storage | SPIFFS + NVS |
| Connectivity | WiFi AP+STA |

---

## 2. Boot & Initialization Sequence

```
Power On
 └─ app_main()  [Core 1, main task]
     ├─ setenv("TZ", "IST-5:30")
     ├─ mount_spiffs()                          ~100-500ms
     ├─ ws2812_init() + boot blink (6×100ms)    ~600ms
     ├─ wifi_config_init()  [NVS init]          ~10ms
     ├─ firebase_config_init()                  ~50ms
     ├─ web_server_init()  [HTTPD + NVS load]   ~100ms
     ├─ button_init()                            ~10ms
     ├─ mode_change_callback(DEVICE_MODE_NORMAL)
     │   └─ reconfigure_wifi_stream()
     │       └─ wifi_stream_init()
     │           └─ WiFi AP started (default)
     ├─ (optional) firebase_command_task created  [prio 5, 4096 stack]
     ├─ web_server_start()
     ├─ (commented) presence_heartbeat_task
     ├─ (commented) device_heartbeat_task
     ├─ radar_sensor_init(&radar_cfg)
     │   ├─ radar_uart_init()                    UART1 @ 115200
     │   ├─ xSemaphoreCreateMutex()              s_data_mutex
     │   ├─ s_running = true
     │   ├─ xTaskCreate(radar_rx_task)           prio 10, 8192 stack
     │   └─ radar_start()  → AT+START
     └─ ESP_LOGI("App initialization complete!")
```

**Boot Time Budget:** ~2–3 seconds until radar data starts flowing.

---

## 3. FreeRTOS Task Map

| Task Name | Source File | Priority | Stack | Period / Lifecycle |
|-----------|-------------|----------|-------|--------------------|
| `main` (app_main) | `fall_sense_x_main.c` | 1 (default) | 4096 | Runs once during boot, then exits |
| `radar_rx_task` | `radar_sensor.c` | 10 | 8192 | Infinite loop, ~10Hz UART poll |
| `tcp_accept_task` | `wifi_stream.c` | 5 | 4096 | Infinite loop, TCP server on port 3333 |
| `uart_input_task` | `web_server.c` | 5 | 3072 | Infinite loop, 100ms UART poll for debug |
| `firebase_command_task` | `fall_sense_x_main.c` | 5 | 4096 | Every 5 seconds |
| `fall_alert_task` | `fall_sense_x_main.c` | 5 | 2048 | Created on fall, runs 5s then self-deletes |
| `IDLE0` / `IDLE1` | FreeRTOS kernel | 0 | — | Runs when no other task is ready |

### Task Priority Order (highest → lowest)
1. `radar_rx_task` (prio 10) — time-critical UART + detection
2. `firebase_command_task`, `uart_input_task`, `tcp_accept_task`, `fall_alert_task` (prio 5)
3. `IDLE` tasks (prio 0)

---

## 4. Sensor Data Flow (Radar → Processing)

```
LD6001 Radar
    │  UART 115200 baud, 8N1
    ▼
UART1 RX Ring Buffer (2048 bytes)
    │  uart_read_bytes(RADAR_UART_NUM, rx_buf, 1000, 100ms timeout)
    ▼
radar_rx_task()  [~10Hz frame rate]
    │  Parse lines, detect "-----PointNum" header
    ├─ wifi_stream_send(line_buf)  → TCP streaming to connected clients
    ├─ accumulate points into s_frame_points[]
    └─ On frame end → detect_humans()
            │
            ├─ Filter by confidence (≥0.4)
            ├─ DBSCAN clustering (eps=0.55m, min_samples=5)
            ├─ compute_cluster_features()
            ├─ classify_posture() → STANDING / SITTING / LYING / SLEEPING
            ├─ Track management (EMA smoothing, gating)
            ├─ update_track_fall_state() → FALL state machine
            └─ Call s_config.detection_cb (radar_detection_callback)
                    │
                    ▼
            radar_detection_callback()
                ├─ Update presence debounce (10s clear delay)
                ├─ Update WS2812 LED color by posture
                ├─ Rate-limit Firebase push (500ms min interval)
                └─ firebase_push_frame() → HTTPS PUT → Firebase Realtime DB
```

### Radar Data Rate
- **UART Baud:** 115200
- **Frame Rate:** ~10 Hz (one frame every ~100ms)
- **Points per Frame:** up to 128 (RADAR_MAX_POINTS)
- **Processing Latency:** <5ms per frame (well within budget)

### Detection Pipeline Inside `detect_humans()`
1. **Confidence filter:** `point_confidence(snr, abs, dpk)` ≥ 0.4
2. **Clustering:** 3-iteration DBSCAN expansion
3. **Feature extraction:** centroid, z-range, XY span, velocity mean/variance
4. **Posture classification:**
   - `z_max ≥ 1.0m` + `z_range > 0.4` + `xy_span < 1.2` → STANDING
   - `z_max ≥ 0.6m` + `z_range > 0.2` → SITTING
   - otherwise → LYING / SLEEPING (based on velocity)
5. **Fall state machine:**
   ```
   FALL_NONE → FALL_SUSPECT (2+ evidence)
            → FALL_CONFIRMED (counter ≥ 2 frames)
            → FALL_COOLDOWN (5s hold + recovery)
            → FALL_NONE (standing up)
   ```
6. **Smoothing:** EMA alpha=0.4 on all spatial/temporal features

---

## 5. Firebase Push Flow

```
radar_detection_callback()
    │
    ├─ Rate check: throttle 500ms between pushes
    │  s_last_firebase_push_ms → skip if < 500ms elapsed
    │
    ├─ Build firebase_frame_t:
    │  .timestamp    = gettimeofday().tv_sec
    │  .timestamp_ms = tv_usec / 1000
    │  .frame_id     = "YYYY_MM_DD_HHhMMmSSs_<counter>"
    │  .device_id    = from s_firebase.device_id
    │  .x, y, z      = raw radar coords (meters)
    │  .velocity     = m/s
    │  .posture      = enum → string
    │  .confidence   = 0.0–1.0
    │  .present      = true/false
    │  .temperature  = CPU temp (°C)
    │
    └─ firebase_push_frame()
        ├─ xSemaphoreTake(s_http_mutex)
        ├─ snprintf JSON payload (512 bytes max)
        ├─ Build URL:
        │   https://<db>/devices/<id>/frames/<frame_id>.json?auth=<token>
        ├─ esp_http_client_init() [HTTPS, crt_bundle]
        ├─ esp_http_client_perform()  [BLOCKING 0.5–3s]
        └─ xSemaphoreGive(s_http_mutex)
```

### Firebase Push Rate (After Fix)

| Scenario | Push Rate | Notes |
|----------|-----------|-------|
| Human present, normal | ≤ 2 Hz (500ms throttle) | Every 500ms at most |
| Human absent (debounce 10s) | 1-shot on absence | Then stops |
| Fall detected | Immediate (no throttle override) | Fall uses same path |

**Original bug:** callback was firing at ~10Hz (every radar frame), each HTTPS call blocking 0.5–3s → WiFi task starved → **Task Watchdog timeout**.

**Fix:** `FIREBASE_PUSH_MIN_INTERVAL_MS = 500` gates the push.

---

## 6. WiFi & Networking

```
mode_change_callback(mode)
    └─ reconfigure_wifi_stream()
        └─ wifi_stream_init()
            ├─ esp_netif + event loop init (first call)
            ├─ WiFi mode: AP (config) or AP+STA (normal)
            ├─ TCP server on port 3333
            └─ xTaskCreate(tcp_accept_task)  [prio 5]
                └─ select() loop, 100ms timeout
                    └─ accept() → fan-out to WIFI_STREAM_MAX_CLIENTS (3)
```

- **Default mode:** AP (`FallSenseX` / `fallsense123`)
- **Paired mode:** Uses stored STA credentials
- **Raw radar streaming:** `wifi_stream_send(line_buf)` sends every line to all TCP clients

---

## 7. Interrupt / Event Sources

| Source | Handler | Action |
|--------|---------|--------|
| Button GPIO (falling/rising) | `gpio_isr_handler()` | Start/stop press timer, count presses |
| Long press timer (3s) | Software timer | Call `BUTTON_EVENT_LONG_PRESS` |
| Double press window (500ms) | Software timer | Call `BUTTON_EVENT_DOUBLE_PRESS` |
| WiFi AP client connect | WiFi event | LED blink purple, callback |
| WiFi STA got IP | IP event | SNTP init, Firebase device info post |

---

## 8. Timing Budget Summary

| Phase | Duration | Notes |
|-------|----------|-------|
| Boot → radar streaming | ~2–3s | SPIFFS + LED + WiFi + Firebase |
| Radar UART poll cycle | 100ms | `uart_read_bytes` timeout |
| Frame processing | <5ms | DBSCAN + tracking + callbacks |
| Firebase HTTPS round-trip | 500–3000ms | Network dependent, **blocking** |
| Presence debounce timeout | 10,000ms | After last human detection |
| Heartbeat interval (if enabled) | 10,000ms | With exponential backoff |

---

## 9. Key Configuration Constants

```c
// Radar
RADAR_UART_BAUD          = 115200
RADAR_MAX_POINTS         = 128
FALL_CONFIRMATION_THRESHOLD = 2
GRID_X/Y/Z               = 6.0 / 6.0 / 2.5

// Detection thresholds (RADAR_CONFIG_DEFAULT)
eps                      = 0.55
min_samples              = 5
human_conf_threshold     = 0.3
fall_v_threshold         = -0.3
fall_z_drop_threshold    = 0.10
fall_accel_threshold     = -1.0
fall_hold_time_us        = 5,000,000 (5s)
track_gate_radius        = 0.8
track_miss_limit         = 5

// Firebase throttle (added fix)
FIREBASE_PUSH_MIN_INTERVAL_MS = 500

// Presence
PRESENCE_CLEAR_DELAY_MS  = 10,000 (10s)
```

---

## 10. Known Issues & Fixes

| Issue | Root Cause | Fix Applied |
|-------|------------|-------------|
| Task Watchdog timeout | Firebase pushed on every radar frame (~10Hz), blocking WiFi | Rate-limited to 500ms in `radar_detection_callback()` |
| Empty `timestamp` in frame | `firebase_frame_t.timestamp = 0` | Now populated from `gettimeofday()` |
| `localtime_r` compile error | Passed `uint32_t*` instead of `time_t*` | Fixed type to `time_t now_sec` |

---

## 11. File Index

| File | Role |
|------|------|
| `main/app/fall_sense_x_main.c` | Main app, callbacks, tasks, Firebase push |
| `main/app/radar_sensor.c` | UART driver, DBSCAN, tracking, fall state machine |
| `main/app/radar_sensor.h` | Radar config structs, default params |
| `main/app/web_server.c` | HTTP server, UART debug task, NVS storage |
| `main/app/wifi_stream.c` | WiFi AP/STA, TCP server, client streaming |
| `main/app/button_handler.c` | GPIO ISR, debounce, timer-based events |
| `main/app/ota_update.c` | OTA polling (currently commented out) |
| `components/firebase/firebase.c` | HTTP client, JSON build, Firebase push |
| `components/firebase/include/firebase.h` | Firebase API, frame struct |
| `tools/professional_radar_tool.py` | PC-side radar configuration GUI |
