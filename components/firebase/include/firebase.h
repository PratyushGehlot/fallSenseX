/**
 * @file firebase.h
 * @brief Firebase Integration for ESP32
 * @details Pushes human location frame data to Firebase Realtime Database
 * @author PratyushGehlot
 */

#ifndef FIREBASE_H
#define FIREBASE_H

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Maximum simultaneous people reported per frame. Mirrors RADAR_MAX_TARGETS
 * in radar_sensor.h - kept as a separate constant so this header doesn't
 * need to depend on the radar component, but the two must stay in sync. */
#define FIREBASE_MAX_TARGETS 5

/* One detected person within a frame. track_id is the radar tracker's
 * stable per-person ID (see human_target_t.track_id in radar_sensor.h) -
 * it's the key the app uses to tell "same person" apart from "different
 * person" across frames, so it's pushed as the JSON object key rather than
 * just another field (see push_frame_to_firebase in firebase.c). */
typedef struct {
    uint8_t track_id;
    float x;            /* X coordinate in meters */
    float y;            /* Y coordinate in meters */
    float z;            /* Z coordinate in meters */
    float velocity;     /* Velocity in m/s */
    uint8_t posture;    /* Posture enum value */
    float confidence;   /* Detection confidence 0.0-1.0 */
} firebase_target_t;

/* Frame data structure for Firebase - consolidated human location frame(s) + temperature */
typedef struct {
    firebase_target_t targets[FIREBASE_MAX_TARGETS];
    int target_count;   /* Number of valid entries in targets[] (0 = nobody present) */
    bool present;        /* True if target_count > 0 */
    uint32_t timestamp; /* Unix timestamp in seconds */
    uint32_t timestamp_ms; /* Milliseconds part */
    const char *frame_id; /* Optional custom frame ID (if NULL, auto-generated) */
    float temperature;  /* CPU temperature in Celsius */
} firebase_frame_t;

/* Telemetry data structure for Firebase */
typedef struct {
    uint32_t timestamp;    /* Unix timestamp in seconds */
    uint32_t timestamp_ms; /* Milliseconds part */
    float temperature;     /* CPU temperature in Celsius */
} firebase_telemetry_t;

/* Firebase configuration structure */
typedef struct {
    const char *database_url;  /* Firebase Realtime Database URL */
    const char *auth_token;    /* Firebase authentication token */
    const char *device_id;     /* Unique device identifier */
    uint32_t push_interval_ms; /* Push interval in milliseconds */
    uint8_t max_retry;         /* Maximum retry attempts */
    bool enable_temperature;   /* Enable temperature reporting (included in frames) */
    bool enable_reset_cmd;     /* Enable reset command functionality */
} firebase_config_t;

/* Command types */
typedef enum {
    FIREBASE_CMD_NONE = 0,
    FIREBASE_CMD_RESET = 1,
    FIREBASE_CMD_REBOOT = 2,
} firebase_command_t;

/* OTA update command details, written by the app to
 * /devices/{deviceId}/commands/ota_update as {"url": "...", "version": "..."}.
 * Ownership/write access to that path is enforced by Firebase security rules. */
typedef struct {
    char url[256];
    char version[32];
} firebase_ota_command_t;

/**
 * @brief Initialize Firebase with configuration
 * @param config Firebase configuration
 * @return ESP_OK on success, error code on failure
 */
esp_err_t firebase_init(const firebase_config_t *config);

/**
 * @brief Deinitialize Firebase
 */
void firebase_deinit(void);

/**
 * @brief Check if Firebase is enabled and connected
 * @return true if Firebase is ready, false otherwise
 */
bool firebase_is_ready(void);

/**
 * @brief Push a single frame to Firebase
 * @param frame Pointer to frame data
 * @return ESP_OK on success, error code on failure
 */
esp_err_t firebase_push_frame(const firebase_frame_t *frame);

/**
 * @brief Push multiple frames to Firebase
 * @param frames Array of frame data
 * @param count Number of frames
 * @return ESP_OK on success, error code on failure
 */
esp_err_t firebase_push_frames(const firebase_frame_t *frames, size_t count);

/**
 * @brief Get last Firebase push status
 * @return ESP_OK if last push was successful, ESP_FAIL otherwise
 */
esp_err_t firebase_get_last_status(void);

/**
 * @brief Post device info (IP, port, firmware version, model) to Firebase for remote access
 * @param ip_address Device IP address string
 * @param port Port number string (default "3333" if NULL)
 * @param firmware_version Current running firmware version string (may be NULL)
 * @param device_model Hardware/firmware model identifier used to match OTA manifests (may be NULL)
 * @return ESP_OK on success, error code on failure
 */
esp_err_t firebase_post_device_info(const char *ip_address, const char *port,
                                     const char *firmware_version, const char *device_model);

/**
 * @brief Push the device's local-access PIN to /devices/{deviceId}/secrets/pin
 *        so the owner can retrieve it from the app instead of reading serial
 *        logs. Only call this once, right after device_pin_init() generates
 *        a brand-new PIN - never on every boot, and never with a
 *        user-rotated PIN (device_pin_change() does not call this).
 * @details Firebase security rules restrict read access on this path to the
 *          device's owner only (not shared viewers) - see firebase_rules.json.
 *          This still means the PIN is stored in plaintext in the cloud,
 *          trading the "local-only secret independent of the cloud account"
 *          property for retrievability. Acceptable if you've decided that
 *          tradeoff is worth it; if not, don't call this and keep relying on
 *          the serial-log-at-flash-time workflow instead.
 * @param pin The plaintext PIN to store
 * @return ESP_OK on success, error code on failure
 */
esp_err_t firebase_post_device_pin(const char *pin);

/**
 * @brief Post device heartbeat/online status to Firebase
 * @param timestamp Unix timestamp in seconds
 * @param timestamp_ms Milliseconds part
 * @return ESP_OK on success, error code on failure
 */
esp_err_t firebase_post_heartbeat(uint32_t timestamp, uint32_t timestamp_ms);

/**
 * @brief Push telemetry data (temperature) to Firebase
 * @param telemetry Pointer to telemetry data
 * @return ESP_OK on success, error code on failure
 */
esp_err_t firebase_push_telemetry(const firebase_telemetry_t *telemetry);

/**
 * @brief Enable/disable Firebase
 * @param enabled true to enable, false to disable
 */
void firebase_set_enabled(bool enabled);

/**
 * @brief Get Firebase enabled status
 * @return true if enabled, false otherwise
 */
bool firebase_get_enabled(void);

/**
 * @brief Get Firebase temperature reporting enabled status
 * @return true if temperature reporting is enabled, false otherwise
 */
bool firebase_get_enable_temperature(void);

/**
 * @brief Get Firebase reset command enabled status
 * @return true if reset command functionality is enabled, false otherwise
 */
bool firebase_get_enable_reset_cmd(void);

/**
 * @brief Check for reset command from Firebase
 * @return FIREBASE_CMD_RESET if reset command is pending, FIREBASE_CMD_NONE otherwise
 */
firebase_command_t firebase_check_for_reset_command(void);

/**
 * @brief Check for a pending OTA update command from Firebase
 * @param out_cmd Filled with the OTA url/version if a command is pending
 * @return true if a valid OTA command was found (and has been cleared from Firebase), false otherwise
 */
bool firebase_check_for_ota_command(firebase_ota_command_t *out_cmd);

/**
 * @brief Report OTA progress/state to /devices/{deviceId}/ota_status for the app to poll.
 * @param state State string, e.g. "idle", "downloading", "success", "failed"
 * @param progress Progress percentage (0-100)
 * @param error Error message if state is "failed" (may be NULL)
 * @return ESP_OK on success, error code on failure
 */
esp_err_t firebase_post_ota_status(const char *state, int progress, const char *error);

/**
 * @brief Trim /devices/{deviceId}/frames down to the most recent max_frames entries.
 * @details Keys are timestamp-based strings, so they sort chronologically;
 *          this fetches the key list (shallow, ordered by key) and deletes
 *          the oldest excess in a single multi-path PATCH. Call this
 *          periodically (e.g. after each push) to keep RTDB storage bounded
 *          without needing a Cloud Function.
 * @param max_frames Maximum number of frames to retain
 * @return ESP_OK on success (including when nothing needed trimming), error code on failure
 */
esp_err_t firebase_trim_frames(int max_frames);

/**
 * @brief Clear a command from Firebase after processing
 * @param command_path Path to the command in Firebase
 * @return ESP_OK on success, error code on failure
 */
esp_err_t firebase_clear_command(const char *command_path);

/**
 * @brief Read the ESP32-S3 internal CPU temperature sensor
 * @return Temperature in Celsius, or 0.0f if the sensor could not be read
 */
float firebase_read_cpu_temperature(void);

/**
 * @brief Get the device ID string (read-only)
 * @return Device ID string if initialized, NULL otherwise
 */
const char* firebase_get_device_id(void);

/**
 * @brief Get the Firebase auth token (read-only)
 * @return Auth token string if initialized, NULL otherwise
 */
const char* firebase_get_auth_token(void);

/**
 * @brief Get the Firebase database URL (read-only)
 * @return Database URL string if initialized, NULL otherwise
 */
const char* firebase_get_database_url(void);

#ifdef __cplusplus
}
#endif

#endif /* FIREBASE_H */
