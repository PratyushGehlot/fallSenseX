/**
 * @file radar_sensor.h
 * @brief Radar Human Detection & Fall Monitor
 * @details ESP32-S3-BOX-3 based real-time human presence detection and fall
 *          monitoring system using LD6001 mmWave radar sensor.
 * @author PratyushGehlot
 * @see https://github.com/PratyushGehlot/radar_human_detectmon
 */

#ifndef RADAR_SENSOR_H
#define RADAR_SENSOR_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

#define RADAR_MAX_POINTS    128
#define RADAR_MAX_TARGETS   5


#define RADAR_UART_NUM      UART_NUM_1
#define RADAR_UART_TXD_PIN  GPIO_NUM_6
#define RADAR_UART_RXD_PIN  GPIO_NUM_5
#define RADAR_UART_BAUD     115200
#define RADAR_UART_BUF_SIZE 1024

typedef struct {
    float x;
    float y;
    float z;
    float velocity;
    float snr;
    float abs_val;
    float dpk;
} radar_point_t;

typedef enum {
    POSTURE_UNKNOWN = 0,
    POSTURE_STANDING,
    POSTURE_SITTING,
    POSTURE_LYING,
    POSTURE_SLEEPING,
    POSTURE_FALL,
    POSTURE_NO_PRESENCE,
} human_posture_t;

typedef struct {
    bool present;
    /* Stable per-person ID assigned once by the tracker (see s_next_track_id
     * in radar_sensor.c) and held for as long as the person stays tracked -
     * lets callers (Firebase frames, the app's 3D viewer) tell "same person,
     * new frame" apart from "different person" across frames. */
    uint8_t track_id;
    human_posture_t posture;
    float center_x;
    float center_y;
    float center_z;
    /* 85th-percentile cluster height - the same robust height metric
     * classify_posture() uses internally, exposed so calibration (see
     * web_server.c's /radar_calibrate) captures the exact value the
     * thresholds are compared against. */
    float height;
    float avg_velocity;
    float confidence;
    int point_count;
} human_target_t;

typedef void (*radar_detection_cb_t)(const human_target_t *targets, int target_count);

typedef struct {
    float eps;
    int min_samples;
    float human_conf_threshold;
    float v_move_threshold;
    float fall_v_threshold;
    float standing_z;
    float sitting_z;
    float lying_z;
    float fall_z_drop_threshold;
    float fall_accel_threshold;
    float fall_height_collapse;
    float fall_xy_spread_lying;
    float fall_z_range_lying;
    float fall_hold_time_us;
    int   fall_recovery_frames;
    float track_gate_radius;
    int   track_miss_limit;
    /* Per-point confidence formula: confidence = w_snr*min(snr/snr_max,1)
     * + w_abs*min(abs/abs_max,1) + w_dpk*min(dpk/dpk_max,1). The *_max
     * values were originally hardcoded guesses that didn't match this
     * radar's actual signal range (see point_conf_threshold below) -
     * now tunable without a recompile via /radar_save. */
    float point_conf_w_snr;
    float point_conf_w_abs;
    float point_conf_w_dpk;
    float point_conf_snr_max;
    float point_conf_abs_max;
    float point_conf_dpk_max;
    /* Minimum per-point confidence to keep a point before clustering.
     * Used to be a hardcoded 0.4f literal inside detect_humans(). */
    float point_conf_threshold;
    radar_detection_cb_t detection_cb;
} radar_config_t;

#define RADAR_CONFIG_DEFAULT() { \
    .eps = 0.55f, \
    .min_samples = 5, \
    .human_conf_threshold = 0.3f, \
    .v_move_threshold = 0.05f, \
    .fall_v_threshold = -0.3f, \
    .standing_z = 1.0f, \
    .sitting_z = 0.6f, \
    .lying_z = 0.25f, \
    .fall_z_drop_threshold = 0.10f, \
    .fall_accel_threshold = -1.0f, \
    .fall_height_collapse = 0.25f, \
    .fall_xy_spread_lying = 0.8f, \
    .fall_z_range_lying = 0.25f, \
    .fall_hold_time_us = 5000000, \
    .fall_recovery_frames = 5, \
    .track_gate_radius = 0.8f, \
    .track_miss_limit = 5, \
    .point_conf_w_snr = 0.45f, \
    .point_conf_w_abs = 0.40f, \
    .point_conf_w_dpk = 0.15f, \
    .point_conf_snr_max = 40.0f, \
    .point_conf_abs_max = 15.0f, \
    .point_conf_dpk_max = 10.0f, \
    .point_conf_threshold = 0.4f, \
    .detection_cb = NULL, \
}

esp_err_t radar_sensor_init(const radar_config_t *config);
esp_err_t radar_send_command(const char *cmd, char *response, size_t resp_size, int timeout_ms);
esp_err_t radar_start(void);
esp_err_t radar_stop(void);
esp_err_t radar_configure(void);
const human_target_t *radar_get_targets(int *count);
human_posture_t radar_get_primary_posture(void);
const char *radar_posture_to_string(human_posture_t posture);
void radar_sensor_deinit(void);

/* Live config get/set - preserves the detection_cb and any fields the
 * caller doesn't touch, so callers should get_config() first, modify
 * just the fields they care about, then set_config(). Thread-safe
 * (guarded by the same mutex as radar_get_targets()). */
void radar_sensor_get_config(radar_config_t *out_config);
void radar_sensor_set_config(const radar_config_t *config);

#endif
