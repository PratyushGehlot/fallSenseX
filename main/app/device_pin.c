/**
 * @file device_pin.c
 * @brief PIN-based authentication for sensitive LAN-local web endpoints
 */

#include "device_pin.h"
#include "nvs.h"
#include "esp_random.h"
#include "esp_log.h"
#include "mbedtls/sha256.h"
#include <string.h>
#include <stdio.h>

static const char *TAG = "device_pin";

#define PIN_NVS_NAMESPACE "device_auth"
#define PIN_NVS_KEY_HASH  "pin_hash"
#define PIN_NVS_KEY_SALT  "pin_salt"
#define PIN_SALT_LEN      16
#define PIN_HASH_LEN      32
#define PIN_HDR_MAX_LEN   32

static void compute_hash(const uint8_t *salt, const char *pin, uint8_t *out_hash)
{
    mbedtls_sha256_context ctx;
    mbedtls_sha256_init(&ctx);
    mbedtls_sha256_starts(&ctx, 0);
    mbedtls_sha256_update(&ctx, salt, PIN_SALT_LEN);
    mbedtls_sha256_update(&ctx, (const uint8_t *)pin, strlen(pin));
    mbedtls_sha256_finish(&ctx, out_hash);
    mbedtls_sha256_free(&ctx);
}

static esp_err_t store_pin(const char *pin)
{
    uint8_t salt[PIN_SALT_LEN];
    esp_fill_random(salt, sizeof(salt));

    uint8_t hash[PIN_HASH_LEN];
    compute_hash(salt, pin, hash);

    nvs_handle_t nvs;
    esp_err_t err = nvs_open(PIN_NVS_NAMESPACE, NVS_READWRITE, &nvs);
    if (err != ESP_OK) {
        return err;
    }

    err = nvs_set_blob(nvs, PIN_NVS_KEY_SALT, salt, sizeof(salt));
    if (err == ESP_OK) {
        err = nvs_set_blob(nvs, PIN_NVS_KEY_HASH, hash, sizeof(hash));
    }
    if (err == ESP_OK) {
        err = nvs_commit(nvs);
    }
    nvs_close(nvs);
    return err;
}

/* TODO(dev-only): fixed to "1234" on every boot while the serial-console
 * PIN-recovery flow gets sorted out. Re-enable the random-default path
 * below before deploying anywhere outside the bench. */
#define FIXED_DEV_PIN "1234"

esp_err_t device_pin_init(void)
{
    esp_err_t set_err = store_pin(FIXED_DEV_PIN);
    if (set_err == ESP_OK) {
        ESP_LOGW(TAG, "================================================");
        ESP_LOGW(TAG, " Device PIN fixed to: %s (dev-only, see device_pin.c)", FIXED_DEV_PIN);
        ESP_LOGW(TAG, "================================================");
    } else {
        ESP_LOGE(TAG, "Failed to store fixed dev PIN: %s", esp_err_to_name(set_err));
    }
    return set_err;
}

bool device_pin_verify(const char *pin)
{
    if (pin == NULL || pin[0] == '\0') {
        return false;
    }

    nvs_handle_t nvs;
    esp_err_t err = nvs_open(PIN_NVS_NAMESPACE, NVS_READONLY, &nvs);
    if (err != ESP_OK) {
        return false;
    }

    uint8_t stored_salt[PIN_SALT_LEN];
    uint8_t stored_hash[PIN_HASH_LEN];
    size_t salt_len = sizeof(stored_salt);
    size_t hash_len = sizeof(stored_hash);
    err = nvs_get_blob(nvs, PIN_NVS_KEY_SALT, stored_salt, &salt_len);
    if (err == ESP_OK) {
        err = nvs_get_blob(nvs, PIN_NVS_KEY_HASH, stored_hash, &hash_len);
    }
    nvs_close(nvs);

    if (err != ESP_OK || salt_len != PIN_SALT_LEN || hash_len != PIN_HASH_LEN) {
        return false;
    }

    uint8_t computed[PIN_HASH_LEN];
    compute_hash(stored_salt, pin, computed);

    /* Constant-time compare to avoid leaking match-length via timing. */
    uint8_t diff = 0;
    for (int i = 0; i < PIN_HASH_LEN; i++) {
        diff |= (uint8_t)(stored_hash[i] ^ computed[i]);
    }
    return diff == 0;
}

esp_err_t device_pin_change(const char *old_pin, const char *new_pin)
{
    if (new_pin == NULL || strlen(new_pin) < 4) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!device_pin_verify(old_pin)) {
        return ESP_ERR_INVALID_STATE;
    }
    return store_pin(new_pin);
}

bool device_pin_require(httpd_req_t *req)
{
    char pin[PIN_HDR_MAX_LEN] = {0};
    esp_err_t err = httpd_req_get_hdr_value_str(req, "X-Device-PIN", pin, sizeof(pin));

    if (err != ESP_OK || !device_pin_verify(pin)) {
        static const char *UNAUTHORIZED_JSON = "{\"success\":false,\"error\":\"Invalid or missing PIN\"}";
        httpd_resp_set_status(req, "401 Unauthorized");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_send(req, UNAUTHORIZED_JSON, strlen(UNAUTHORIZED_JSON));
        return false;
    }
    return true;
}
