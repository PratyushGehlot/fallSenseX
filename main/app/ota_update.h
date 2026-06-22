/**
 * @file ota_update.h
 * @brief OTA Update Module
 */

#ifndef OTA_UPDATE_H
#define OTA_UPDATE_H

#include <stdbool.h>
#include "esp_err.h"

#define OTA_FIRMWARE_VERSION "1.0.0"

typedef enum {
    OTA_STATE_IDLE = 0,
    OTA_STATE_CHECKING,
    OTA_STATE_DOWNLOADING,
    OTA_STATE_WRITING,
    OTA_STATE_SUCCESS,
    OTA_STATE_FAILED,
} ota_state_t;

esp_err_t ota_update_init(void);
void ota_update_deinit(void);
ota_state_t ota_update_get_state(void);
int ota_update_get_progress(void);
const char *ota_update_get_state_string(void);
const char *ota_update_get_error_string(void);
esp_err_t ota_update_start_url(const char *url);
esp_err_t ota_update_start_https(const char *server_cert_pem, const char *url);
esp_err_t ota_update_set_server_url(const char *url);
esp_err_t ota_update_get_server_url(char *buf, size_t len);
esp_err_t ota_update_set_auto_check_enabled(bool enabled);
bool ota_update_get_auto_check_enabled(void);
esp_err_t ota_update_check_for_update(const char *manifest_url);
void ota_update_task_start(void);

/**
 * @brief True while an OTA download/flash is actively in progress.
 * @details Other subsystems (radar detection callback) poll this to pause
 *          themselves during an update - see radar_detection_callback() in
 *          fall_sense_x_main.c.
 */
bool ota_update_is_busy(void);

#endif
