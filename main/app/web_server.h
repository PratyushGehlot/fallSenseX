/**
 * @file web_server.h
 * @brief Fall Sense X Web Server
 * @details Web interface for configuring the Fall Sense X device
 */

#ifndef WEB_SERVER_H
#define WEB_SERVER_H

#include "esp_err.h"
#include <stdbool.h>
#include <stddef.h>

#define WEB_SERVER_PORT 80

typedef enum {
    DEVICE_MODE_NORMAL = 0,
    DEVICE_MODE_CONFIG,
    DEVICE_MODE_PAIRED,
} device_mode_t;

typedef void (*mode_change_cb_t)(device_mode_t new_mode);

typedef struct {
    const char *ssid;
    const char *password;
    mode_change_cb_t mode_change_callback;
} web_server_config_t;

esp_err_t web_server_init(const web_server_config_t *config);
esp_err_t web_server_start(void);
void web_server_stop(void);
void web_server_deinit(void);

/* Get current device mode */
device_mode_t web_server_get_device_mode(void);

/* Set device mode */
esp_err_t web_server_set_device_mode(device_mode_t mode);

/* Get/Set WiFi credentials */
esp_err_t web_server_get_wifi_credentials(char *ssid, size_t ssid_len, char *password, size_t password_len);
esp_err_t web_server_set_wifi_credentials(const char *ssid, const char *password);

/* Get LED brightness (0-100) */
int web_server_get_led_brightness(void);

/* Pushes the persisted radar calibration/confidence settings into the
 * live radar_sensor_t config. Must be called once after
 * radar_sensor_init() succeeds (the settings have no effect before
 * that), and is also called automatically on every /radar_save or
 * /radar_calibrate. */
void web_server_apply_radar_config(void);

/* OTA update */
esp_err_t web_server_ota_check_update(const char *server_url, const char *firmware_version);
esp_err_t web_server_ota_start_update(const char *url);
int web_server_ota_get_progress(void);
const char* web_server_ota_get_state_string(void);
const char* web_server_ota_get_error_string(void);

/* UART Debug - run saved init sequence */
void web_server_run_uart_init_sequence(void);
const char* web_server_get_uart_init_sequence(void);

#endif /* WEB_SERVER_H */
