/**
 * @file ota_update.c
 * @brief OTA update implementation for ESP-IDF v5.x
 */

#include "ota_update.h"
#include "esp_log.h"
#include "esp_http_client.h"
#include "esp_https_ota.h"
#include "esp_ota_ops.h"
#include "esp_crt_bundle.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "cJSON.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "ws2812_led.h"
#include <string.h>
#include <strings.h>
#include <stdlib.h>

static const char *TAG = "ota_update";

#define OTA_NVS_NAMESPACE "ota_config"
#define OTA_NVS_KEY_SERVER_URL "server_url"
#define OTA_NVS_KEY_AUTO_CHECK "auto_check"
#define OTA_NVS_KEY_LATEST_VERSION "latest_version"
#define OTA_MAX_URL_LEN 256
#define OTA_MAX_VERSION_LEN 32

typedef struct {
    bool busy;
    bool active;
    bool auto_check_enabled;
    int progress;
    int image_size;
    char error[64];
    char latest_version[OTA_MAX_VERSION_LEN];
} ota_ctx_t;

static ota_ctx_t s_ctx;
/* Last percentage we logged at INFO level, so we print roughly every 10%
 * instead of flooding the log on every HTTP_EVENT_ON_DATA chunk. Reset in
 * ota_perform() at the start of each attempt. -1 = nothing logged yet. */
static int s_last_logged_pct = -1;

static void ota_set_error(const char *error)
{
    strncpy(s_ctx.error, error, sizeof(s_ctx.error) - 1);
    s_ctx.error[sizeof(s_ctx.error) - 1] = '\0';
}

static esp_err_t ota_http_event_handler(esp_http_client_event_t *evt)
{
    switch (evt->event_id) {
        case HTTP_EVENT_ON_HEADER:
            if (evt->header_key && strcasecmp(evt->header_key, "Content-Length") == 0 && evt->header_value) {
                s_ctx.image_size = atoi(evt->header_value);
                ESP_LOGI(TAG, "Firmware size: %d bytes", s_ctx.image_size);
            }
            break;
        case HTTP_EVENT_ON_DATA:
            if (s_ctx.active && evt->data_len) {
                s_ctx.progress += evt->data_len;
                if (s_ctx.image_size > 0) {
                    int pct = (s_ctx.progress * 100) / s_ctx.image_size;
                    if (pct > 100) {
                        pct = 100;
                    }
                    /* Promoted from ESP_LOGD to ESP_LOGI (temporarily) while
                     * diagnosing a stall where the download never completed
                     * or failed - this makes it visible at default log
                     * level whether bytes are actually still arriving, and
                     * how far it got, instead of total silence. */
                    if (pct >= s_last_logged_pct + 10) {
                        s_last_logged_pct = pct;
                        ESP_LOGI(TAG, "OTA download progress: %d%% (%d/%d bytes)",
                                 pct, s_ctx.progress, s_ctx.image_size);
                    }
                } else {
                    ESP_LOGD(TAG, "Downloaded %d bytes", s_ctx.progress);
                }
            }
            break;
        default:
            break;
    }
    return ESP_OK;
}

static int compare_versions(const char *v1, const char *v2)
{
    if (v1 == NULL || v2 == NULL) return 0;

    char a[OTA_MAX_VERSION_LEN];
    char b[OTA_MAX_VERSION_LEN];
    strncpy(a, v1, sizeof(a) - 1);
    a[sizeof(a) - 1] = '\0';
    strncpy(b, v2, sizeof(b) - 1);
    b[sizeof(b) - 1] = '\0';

    char *saveptr1 = NULL;
    char *saveptr2 = NULL;
    char *tok1 = strtok_r(a, ".", &saveptr1);
    char *tok2 = strtok_r(b, ".", &saveptr2);

    while (tok1 || tok2) {
        int n1 = tok1 ? atoi(tok1) : 0;
        int n2 = tok2 ? atoi(tok2) : 0;
        if (n1 > n2) return 1;
        if (n1 < n2) return -1;
        tok1 = strtok_r(NULL, ".", &saveptr1);
        tok2 = strtok_r(NULL, ".", &saveptr2);
    }
    return 0;
}

/* Blinks the on-board LED magenta/white while s_ctx.active is true, so an
 * OTA in progress is visible without needing the serial log. Self-deletes
 * as soon as the download/flash finishes (success or failure) and turns
 * the LED back off, since radar_detection_callback() (which normally
 * drives the LED) is paused for the same duration via
 * ota_update_is_busy(). */
static void ota_led_task(void *arg)
{
    static const ws2812_color_t colors[] = { WS2812_COLOR_MAGENTA, WS2812_COLOR_WHITE };
    int i = 0;
    while (s_ctx.active) {
        ws2812_set_color_all(colors[i % 2]);
        ws2812_show();
        i++;
        vTaskDelay(pdMS_TO_TICKS(200));
    }
    ws2812_clear();
    ws2812_show();
    vTaskDelete(NULL);
}

static esp_err_t ota_perform(const char *url)
{
    if (s_ctx.busy) {
        return ESP_ERR_INVALID_STATE;
    }

    s_ctx.busy = true;
    s_ctx.active = true;
    s_ctx.progress = 0;
    s_ctx.image_size = 0;
    s_ctx.error[0] = '\0';
    s_last_logged_pct = -1;

    xTaskCreate(ota_led_task, "ota_led", 2048, NULL, 2, NULL);

    esp_http_client_config_t http_config = {
        .url = url,
        .timeout_ms = 30000,
        .buffer_size = 2048,
        .event_handler = ota_http_event_handler,
        .crt_bundle_attach = esp_crt_bundle_attach,
    };

    esp_https_ota_config_t ota_config = {
        .http_config = &http_config,
    };

    ESP_LOGI(TAG, "Starting OTA from: %s", url);
    esp_err_t ret = esp_https_ota(&ota_config);

    s_ctx.active = false;

    if (ret != ESP_OK) {
        snprintf(s_ctx.error, sizeof(s_ctx.error), "ota failed:0x%x", ret);
        s_ctx.busy = false;
        return ret;
    }

    ret = esp_ota_set_boot_partition(esp_ota_get_next_update_partition(NULL));
    if (ret != ESP_OK) {
        ota_set_error("boot partition failed");
        s_ctx.busy = false;
        return ret;
    }

    s_ctx.busy = false;
    ESP_LOGI(TAG, "OTA success, restarting");
    vTaskDelay(pdMS_TO_TICKS(1000));
    esp_restart();
    return ESP_OK;
}

esp_err_t ota_update_init(void)
{
    memset(&s_ctx, 0, sizeof(s_ctx));
    s_ctx.auto_check_enabled = false;

    nvs_handle_t nvs;
    esp_err_t err = nvs_open(OTA_NVS_NAMESPACE, NVS_READONLY, &nvs);
    if (err == ESP_OK) {
        size_t len = sizeof(s_ctx.latest_version);
        if (nvs_get_str(nvs, OTA_NVS_KEY_LATEST_VERSION, s_ctx.latest_version, &len) != ESP_OK) {
            s_ctx.latest_version[0] = '\0';
        }
        uint8_t auto_check = 0;
        if (nvs_get_u8(nvs, OTA_NVS_KEY_AUTO_CHECK, &auto_check) == ESP_OK) {
            s_ctx.auto_check_enabled = auto_check ? true : false;
        }
        nvs_close(nvs);
    } else {
        s_ctx.latest_version[0] = '\0';
        s_ctx.auto_check_enabled = false;
    }

    return ESP_OK;
}

void ota_update_deinit(void)
{
    memset(&s_ctx, 0, sizeof(s_ctx));
}

ota_state_t ota_update_get_state(void)
{
    if (!s_ctx.busy) {
        return s_ctx.error[0] ? OTA_STATE_FAILED : OTA_STATE_IDLE;
    }
    if (ota_update_get_progress() >= 100) {
        return OTA_STATE_SUCCESS;
    }
    return OTA_STATE_DOWNLOADING;
}

int ota_update_get_progress(void)
{
    /* s_ctx.progress accumulates raw bytes downloaded (see
     * ota_http_event_handler) - convert to a 0-100 percentage here so
     * every caller (web_server.c's /ota_status, this getter's other
     * callers) gets a percentage rather than a raw byte count that grows
     * into the hundreds of thousands. */
    if (s_ctx.image_size <= 0) {
        return 0;
    }
    int pct = (s_ctx.progress * 100) / s_ctx.image_size;
    if (pct > 100) {
        pct = 100;
    }
    return pct;
}

bool ota_update_is_busy(void)
{
    return s_ctx.busy;
}

const char *ota_update_get_state_string(void)
{
    switch (ota_update_get_state()) {
        case OTA_STATE_IDLE: return "idle";
        case OTA_STATE_CHECKING: return "checking";
        case OTA_STATE_DOWNLOADING: return "downloading";
        case OTA_STATE_SUCCESS: return "success";
        case OTA_STATE_FAILED: return "failed";
        default: return "unknown";
    }
}

const char *ota_update_get_error_string(void)
{
    return s_ctx.error[0] ? s_ctx.error : "none";
}

esp_err_t ota_update_start_url(const char *url)
{
    if (!url || !url[0]) {
        return ESP_ERR_INVALID_ARG;
    }
    return ota_perform(url);
}

esp_err_t ota_update_start_https(const char *server_cert_pem, const char *url)
{
    if (!url || !url[0]) {
        return ESP_ERR_INVALID_ARG;
    }
    return ota_perform(url);
}

esp_err_t ota_update_set_server_url(const char *url)
{
    if (!url || !url[0]) {
        return ESP_ERR_INVALID_ARG;
    }

    nvs_handle_t nvs;
    esp_err_t err = nvs_open(OTA_NVS_NAMESPACE, NVS_READWRITE, &nvs);
    if (err != ESP_OK) {
        return err;
    }

    err = nvs_set_str(nvs, OTA_NVS_KEY_SERVER_URL, url);
    if (err == ESP_OK) {
        err = nvs_commit(nvs);
    }
    nvs_close(nvs);
    return err;
}

esp_err_t ota_update_get_server_url(char *buf, size_t len)
{
    if (!buf || len == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    nvs_handle_t nvs;
    esp_err_t err = nvs_open(OTA_NVS_NAMESPACE, NVS_READONLY, &nvs);
    if (err != ESP_OK) {
        buf[0] = '\0';
        return err;
    }

    size_t str_len = len;
    err = nvs_get_str(nvs, OTA_NVS_KEY_SERVER_URL, buf, &str_len);
    nvs_close(nvs);

    if (err != ESP_OK) {
        buf[0] = '\0';
    }
    return err;
}

esp_err_t ota_update_set_auto_check_enabled(bool enabled)
{
    nvs_handle_t nvs;
    esp_err_t err = nvs_open(OTA_NVS_NAMESPACE, NVS_READWRITE, &nvs);
    if (err != ESP_OK) {
        return err;
    }

    err = nvs_set_u8(nvs, OTA_NVS_KEY_AUTO_CHECK, enabled ? 1 : 0);
    if (err == ESP_OK) {
        err = nvs_commit(nvs);
    }
    nvs_close(nvs);

    s_ctx.auto_check_enabled = enabled;
    return err;
}

bool ota_update_get_auto_check_enabled(void)
{
    return s_ctx.auto_check_enabled;
}

esp_err_t ota_update_check_for_update(const char *manifest_url)
{
    if (!manifest_url || !manifest_url[0]) {
        return ESP_ERR_INVALID_ARG;
    }

    s_ctx.busy = true;
    s_ctx.error[0] = '\0';

    char response[1024];
    int response_len = 0;

    esp_http_client_config_t http_config = {
        .url = manifest_url,
        .timeout_ms = 15000,
        .buffer_size = 512,
        .crt_bundle_attach = esp_crt_bundle_attach,
    };

    esp_http_client_handle_t client = esp_http_client_init(&http_config);
    if (!client) {
        ota_set_error("manifest http init failed");
        s_ctx.busy = false;
        return ESP_FAIL;
    }

    esp_err_t err = esp_http_client_perform(client);
    if (err == ESP_OK) {
        response_len = esp_http_client_read(client, response, sizeof(response) - 1);
        if (response_len > 0) {
            response[response_len] = '\0';
        } else {
            response[0] = '\0';
        }
    } else {
        snprintf(s_ctx.error, sizeof(s_ctx.error), "manifest fetch failed:0x%x", err);
        esp_http_client_cleanup(client);
        s_ctx.busy = false;
        return err;
    }

    esp_http_client_cleanup(client);

    cJSON *root = cJSON_Parse(response);
    if (!root) {
        ota_set_error("manifest parse failed");
        s_ctx.busy = false;
        return ESP_ERR_INVALID_RESPONSE;
    }

    cJSON *version = cJSON_GetObjectItem(root, "version");
    cJSON *url = cJSON_GetObjectItem(root, "url");

    if (!version || !version->valuestring || !url || !url->valuestring) {
        cJSON_Delete(root);
        ota_set_error("manifest missing version/url");
        s_ctx.busy = false;
        return ESP_ERR_INVALID_RESPONSE;
    }

    if (compare_versions(version->valuestring, OTA_FIRMWARE_VERSION) > 0) {
        strncpy(s_ctx.latest_version, version->valuestring, sizeof(s_ctx.latest_version) - 1);
        s_ctx.latest_version[sizeof(s_ctx.latest_version) - 1] = '\0';

        nvs_handle_t nvs;
        esp_err_t nvs_err = nvs_open(OTA_NVS_NAMESPACE, NVS_READWRITE, &nvs);
        if (nvs_err == ESP_OK) {
            nvs_set_str(nvs, OTA_NVS_KEY_LATEST_VERSION, s_ctx.latest_version);
            nvs_commit(nvs);
            nvs_close(nvs);
        }

        ESP_LOGI(TAG, "Update available: %s -> %s", OTA_FIRMWARE_VERSION, s_ctx.latest_version);
        cJSON_Delete(root);
        s_ctx.busy = false;
        return ota_perform(url->valuestring);
    }

    ESP_LOGI(TAG, "No update needed. Current: %s, Latest: %s", OTA_FIRMWARE_VERSION, version->valuestring);
    cJSON_Delete(root);
    s_ctx.busy = false;
    return ESP_OK;
}

static void ota_auto_update_task(void *arg)
{
    ESP_LOGI(TAG, "OTA auto-update task started");
    vTaskDelay(pdMS_TO_TICKS(30000));

    while (1) {
        if (s_ctx.auto_check_enabled) {
            char server_url[OTA_MAX_URL_LEN];
            if (ota_update_get_server_url(server_url, sizeof(server_url)) == ESP_OK && server_url[0] != '\0') {
                ESP_LOGI(TAG, "Checking for OTA update at: %s", server_url);
                ota_update_check_for_update(server_url);
            } else {
                ESP_LOGW(TAG, "No OTA server URL configured");
            }
        }
        vTaskDelay(pdMS_TO_TICKS(600000));
    }
}

void ota_update_task_start(void)
{
    static TaskHandle_t ota_task_handle = NULL;
    if (ota_task_handle == NULL) {
        xTaskCreate(ota_auto_update_task, "ota_auto", 4096, NULL, 3, &ota_task_handle);
    }
}