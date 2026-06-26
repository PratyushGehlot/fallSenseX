/**
 * @file device_pin.h
 * @brief PIN-based authentication for sensitive LAN-local web endpoints
 * @details The PIN gates actions that have no Firebase Auth context (device
 *          reboot, radar threshold changes, manual OTA trigger). It is
 *          independent of Firebase ownership and is meant to be shared only
 *          with whoever currently needs local access (e.g. an installer).
 */

#ifndef DEVICE_PIN_H
#define DEVICE_PIN_H

#include <stdbool.h>
#include "esp_err.h"
#include "esp_http_server.h"

/**
 * @brief Load the stored PIN hash from NVS, or generate and store a random
 *        default PIN on first boot (logged once via ESP_LOGW).
 */
esp_err_t device_pin_init(void);

/**
 * @brief Verify a candidate PIN against the stored hash (constant-time compare).
 */
bool device_pin_verify(const char *pin);

/**
 * @brief Change the PIN. Requires the current PIN to succeed.
 * @param old_pin Current PIN
 * @param new_pin New PIN (minimum 4 characters)
 */
esp_err_t device_pin_change(const char *old_pin, const char *new_pin);

/**
 * @brief Check whether a freshly-generated first-boot PIN is still waiting
 *        to be synced to Firebase (see device_pin_clear_pending_sync()).
 * @param out_pin Filled with the pending PIN if one is pending (may be NULL to just check)
 * @param out_len Size of out_pin buffer
 * @return true if a PIN is pending sync, false otherwise
 */
bool device_pin_get_pending_sync(char *out_pin, size_t out_len);

/**
 * @brief Mark the pending first-boot PIN as synced (call only after a
 *        successful push to Firebase, so a transient network failure can
 *        retry instead of losing the PIN silently).
 */
void device_pin_clear_pending_sync(void);

/**
 * @brief Require a valid X-Device-PIN header on the request.
 * @details On failure, sends a 401 JSON response and returns false. Callers
 *          must return immediately (without sending another response) when
 *          this returns false.
 */
bool device_pin_require(httpd_req_t *req);

#endif
