/**
 * @file firebase.c
 * @brief Firebase Integration Implementation for ESP32
 * @details Uses ESP-IDF HTTP client to push frame data to Firebase Realtime Database
 */

#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "esp_crt_bundle.h"
#include "driver/temperature_sensor.h"  // Temperature sensor include
#include "cJSON.h"
#include "esp_wifi.h"
#include "esp_system.h"

#include "firebase.h"

static const char *TAG = "firebase";

/* Firebase state */
static SemaphoreHandle_t s_http_mutex = NULL;
static struct {
    bool initialized;
    bool enabled;
    char database_url[128];
    char auth_token[128];
    char device_id[32];
    uint32_t push_interval_ms;
    uint8_t max_retry;
    bool enable_temperature;
    bool enable_reset_cmd;
    esp_err_t last_status;
    TaskHandle_t push_task_handle;
} s_firebase = {
    .initialized = false,
    .enabled = true,
    .push_task_handle = NULL,
    .enable_temperature = false,
    .enable_reset_cmd = false,
};

/* Frame counter for unique frame IDs (increments each frame, resets on power cycle) */
static uint32_t s_frame_counter = 0;

/* Buffer for Firebase JSON payload */
#define FIREBASE_JSON_SIZE 512
#define FIREBASE_URL_PATH_SIZE 512
/* Header fields (~150B) + up to FIREBASE_MAX_TARGETS entries (~110B each) +
 * margin. Stack-allocated per push - see push_frame_to_firebase. */
#define FIREBASE_MULTI_TARGET_JSON_SIZE (256 + FIREBASE_MAX_TARGETS * 128)

/* Forward declaration for static function */
static esp_err_t firebase_get_command(const char *command_path, char *value_buf, size_t buf_size);

/* HTTP event handler */
static esp_err_t http_event_handler(esp_http_client_event_t *evt)
{
    switch (evt->event_id) {
        case HTTP_EVENT_ERROR:
            ESP_LOGD(TAG, "HTTP_EVENT_ERROR");
            break;
        case HTTP_EVENT_ON_CONNECTED:
            ESP_LOGD(TAG, "HTTP_EVENT_ON_CONNECTED");
            break;
        case HTTP_EVENT_HEADER_SENT:
            ESP_LOGD(TAG, "HTTP_EVENT_HEADER_SENT");
            break;
        case HTTP_EVENT_ON_HEADER:
            ESP_LOGD(TAG, "HTTP_EVENT_ON_HEADER, key=%s, value=%s",
                     (char *)evt->header_key, (char *)evt->header_value);
            break;
        case HTTP_EVENT_ON_DATA:
            ESP_LOGD(TAG, "HTTP_EVENT_ON_DATA, len=%d", evt->data_len);
            break;
        case HTTP_EVENT_ON_FINISH:
            ESP_LOGD(TAG, "HTTP_EVENT_ON_FINISH");
            break;
        case HTTP_EVENT_DISCONNECTED:
            ESP_LOGD(TAG, "HTTP_EVENT_DISCONNECTED");
            break;
        default:
            break;
    }
    return ESP_OK;
}

/* Get current timestamp */
static void get_timestamp(uint32_t *sec, uint32_t *ms)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    if (sec) *sec = (uint32_t)tv.tv_sec;
    if (ms) *ms = (uint32_t)(tv.tv_usec / 1000);
}

/* Diagnostic snapshot logged around connection failures, to tell apart
 * heap pressure, weak WiFi, and DNS/server-side issues without having to
 * guess from "Failed to open new connection" alone. minimum_free is the
 * lowest free-heap value ever observed since boot - if it's gotten close
 * to free_now repeatedly, that's a stronger fragmentation signal than
 * free_now alone. RSSI requires the STA to currently be associated; -127
 * is logged if esp_wifi_sta_get_ap_info fails (e.g. briefly disconnected/
 * reconnecting), which is itself diagnostic. */
static void log_network_diagnostics(const char *context)
{
    uint32_t free_now = esp_get_free_heap_size();
    uint32_t min_ever = esp_get_minimum_free_heap_size();

    wifi_ap_record_t ap_info;
    int8_t rssi = -127;
    if (esp_wifi_sta_get_ap_info(&ap_info) == ESP_OK) {
        rssi = ap_info.rssi;
    }

    ESP_LOGW(TAG, "[%s] diagnostics: free_heap=%lu min_free_heap_ever=%lu wifi_rssi=%d dBm",
             context, (unsigned long)free_now, (unsigned long)min_ever, (int)rssi);
}

/* Generate human-readable frame ID from timestamp + counter:
 * Format: "YYYY_MM_DD_HHhMMmSSs_<counter>"
 * Example: "2026_05_08_08h55m20s_123"
 * The counter increments with each frame and resets on device power cycle.
 */
static void generate_frame_id(char *buf, size_t buf_size, uint32_t timestamp, uint32_t timestamp_ms)
{
    struct tm tm_info;
    time_t t = (time_t)timestamp;
    localtime_r(&t, &tm_info);
    
    // Use global frame counter (increments each call, resets on power cycle)
    uint32_t counter = s_frame_counter++;
    
    // Format: YYYY_MM_DD_HHhMMmSSs_<counter>
    snprintf(buf, buf_size, "%04d_%02d_%02d_%02dh%02dm%02ds_%lu",
             tm_info.tm_year + 1900,
             tm_info.tm_mon + 1,
             tm_info.tm_mday,
             tm_info.tm_hour,
             tm_info.tm_min,
             tm_info.tm_sec,
             counter);
}

/* Convert posture enum to string */
static const char *posture_to_string(uint8_t posture)
{
    switch (posture) {
        case 0: return "UNKNOWN";
        case 1: return "STANDING";
        case 2: return "SITTING";
        case 3: return "LYING";
        case 4: return "SLEEPING";
        case 5: return "FALL";
        case 6: return "NO_PRESENCE";
        default: return "UNKNOWN";
    }
}

/* Push frame data to Firebase */
static esp_err_t push_frame_to_firebase(const firebase_frame_t *frame)
{
    if (!s_firebase.initialized || !s_firebase.enabled) {
        return ESP_ERR_INVALID_STATE;
    }

    if (s_http_mutex == NULL || xSemaphoreTake(s_http_mutex, portMAX_DELAY) != pdTRUE) {
        ESP_LOGE(TAG, "Failed to lock Firebase HTTP mutex");
        return ESP_FAIL;
    }

    char url_path[FIREBASE_URL_PATH_SIZE];
    char frame_id[32];

    /* Generate or use provided frame ID */
    if (frame->frame_id != NULL && strlen(frame->frame_id) > 0) {
        strncpy(frame_id, frame->frame_id, sizeof(frame_id) - 1);
        frame_id[sizeof(frame_id) - 1] = '\0';
    } else {
        /* Generate timestamp-based ID with milliseconds: HHMMSSmmm_DDMMYY */
        generate_frame_id(frame_id, sizeof(frame_id), frame->timestamp, frame->timestamp_ms);
    }

    /* Build JSON payload by hand (no cJSON tree) - a long-running device
     * pushing frames every few hundred ms can't afford the 50-100+ small
     * heap allocations a cJSON tree costs per multi-target frame (one
     * malloc per node plus one per duplicated key); that heap churn was
     * implicated in intermittent esp-tls connection failures under sustained
     * load. "targets" is a map keyed by track_id (not a JSON array) so each
     * person's entry can be updated/merged independently and so the app can
     * use track_id as a stable widget key across frames. */
    char json_payload[FIREBASE_MULTI_TARGET_JSON_SIZE];
    int off = snprintf(json_payload, sizeof(json_payload),
        "{"
        "\"timestamp\":%lu,"
        "\"timestamp_ms\":%lu,"
        "\"device_id\":\"%s\","
        "\"present\":%s,"
        "\"temperature\":%.1f,"
        "\"targets\":{",
        frame->timestamp,
        frame->timestamp_ms,
        s_firebase.device_id,
        frame->present ? "true" : "false",
        frame->temperature);

    int n = frame->target_count;
    if (n > FIREBASE_MAX_TARGETS) {
        n = FIREBASE_MAX_TARGETS;
    }
    for (int i = 0; i < n && off > 0 && off < sizeof(json_payload); i++) {
        const firebase_target_t *t = &frame->targets[i];
        off += snprintf(json_payload + off, sizeof(json_payload) - off,
            "%s\"%u\":{\"x\":%.2f,\"y\":%.2f,\"z\":%.2f,\"velocity\":%.3f,\"posture\":\"%s\",\"confidence\":%.2f}",
            i > 0 ? "," : "",
            (unsigned)t->track_id,
            t->x, t->y, t->z, t->velocity,
            posture_to_string(t->posture),
            t->confidence);
    }
    if (off > 0 && off < sizeof(json_payload)) {
        off += snprintf(json_payload + off, sizeof(json_payload) - off, "}}");
    }

    if (off <= 0 || off >= sizeof(json_payload)) {
        ESP_LOGE(TAG, "Failed to build JSON payload (would overflow %d-byte buffer)",
                 (int)sizeof(json_payload));
        xSemaphoreGive(s_http_mutex);
        return ESP_ERR_NO_MEM;
    }
    int json_len = off;

    /* Build URL with custom frame ID - use PUT to set specific key */
    if (s_firebase.auth_token[0] != '\0') {
        snprintf(url_path, sizeof(url_path),
                 "%s/devices/%s/frames/%s.json?auth=%s",
                 s_firebase.database_url,
                 s_firebase.device_id,
                 frame_id,
                 s_firebase.auth_token
        );
    } else {
        snprintf(url_path, sizeof(url_path),
                 "%s/devices/%s/frames/%s.json",
                 s_firebase.database_url,
                 s_firebase.device_id,
                 frame_id
        );
    }

    /* Configure HTTP client - use PUT for custom key.
     * timeout_ms: frame pushes are small, frequent, heartbeat-style data -
     * if Firebase doesn't respond in 5s it's not about to, and a tighter
     * timeout caps how long one stuck attempt can block the push task
     * (and therefore back up s_firebase_queue) before firebase_push_frame's
     * retry loop in firebase_push_frame() gives up and moves on. */
    esp_http_client_config_t config = {
        .url = url_path,
        .method = HTTP_METHOD_PUT,
        .event_handler = http_event_handler,
        .timeout_ms = 5000,
        .buffer_size = 1024,
        .crt_bundle_attach = esp_crt_bundle_attach,  // Use built-in CA root certificates for HTTPS
    };

    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        ESP_LOGE(TAG, "Failed to initialize HTTP client");
        xSemaphoreGive(s_http_mutex);
        return ESP_FAIL;
    }

    /* Set headers */
    esp_http_client_set_header(client, "Content-Type", "application/json");

    /* Set post data */
    esp_http_client_set_post_field(client, json_payload, json_len);

    /* Execute request */
    esp_err_t err = esp_http_client_perform(client);
    if (err == ESP_OK) {
        int status_code = esp_http_client_get_status_code(client);
        if (status_code == 200 || status_code == 201) {
            ESP_LOGI(TAG, "Frame pushed successfully to Firebase");
            ESP_LOGD(TAG, "HTTP POST Status = %d, content_length = %lld",
                     status_code,
                     esp_http_client_get_content_length(client));
            err = ESP_OK;
        } else {
            ESP_LOGE(TAG, "HTTP POST failed with status = %d", status_code);
            err = ESP_FAIL;
        }
    } else {
        ESP_LOGE(TAG, "HTTP POST request failed: %s", esp_err_to_name(err));
        log_network_diagnostics("push_frame");
    }

    esp_http_client_cleanup(client);
    xSemaphoreGive(s_http_mutex);
    return err;
}

esp_err_t firebase_init(const firebase_config_t *config)
{
    if (s_firebase.initialized) {
        ESP_LOGW(TAG, "Firebase already initialized");
        return ESP_OK;
    }

    if (config == NULL || config->database_url == NULL) {
        ESP_LOGE(TAG, "Invalid Firebase configuration");
        return ESP_ERR_INVALID_ARG;
    }

    /* Store configuration */
    strncpy(s_firebase.database_url, config->database_url, sizeof(s_firebase.database_url) - 1);
    s_firebase.database_url[sizeof(s_firebase.database_url) - 1] = '\0';

    /* Ensure database URL has a scheme (http:// or https://) */
    if (strncmp(s_firebase.database_url, "http://", 7) != 0 &&
        strncmp(s_firebase.database_url, "https://", 8) != 0) {
        char temp_url[256];
        snprintf(temp_url, sizeof(temp_url), "https://%s", s_firebase.database_url);
        strncpy(s_firebase.database_url, temp_url, sizeof(s_firebase.database_url) - 1);
        s_firebase.database_url[sizeof(s_firebase.database_url) - 1] = '\0';
        ESP_LOGW(TAG, "Database URL missing scheme, prepending https://");
    }

    /* Remove trailing slash if present to avoid double slash in path */
    size_t len = strlen(s_firebase.database_url);
    if (len > 0 && s_firebase.database_url[len - 1] == '/') {
        s_firebase.database_url[len - 1] = '\0';
    }

    if (config->auth_token != NULL) {
        strncpy(s_firebase.auth_token, config->auth_token, sizeof(s_firebase.auth_token) - 1);
        s_firebase.auth_token[sizeof(s_firebase.auth_token) - 1] = '\0';
    } else {
        s_firebase.auth_token[0] = '\0';
    }

    if (config->device_id != NULL) {
        strncpy(s_firebase.device_id, config->device_id, sizeof(s_firebase.device_id) - 1);
        s_firebase.device_id[sizeof(s_firebase.device_id) - 1] = '\0';
    } else {
        /* Generate default device ID from MAC address */
        uint8_t mac[6];
        esp_read_mac(mac, ESP_MAC_WIFI_STA);
        snprintf(s_firebase.device_id, sizeof(s_firebase.device_id), "FallSenseX_%02X%02X%02X",
                mac[3], mac[4], mac[5]);
    }

    s_firebase.push_interval_ms = config->push_interval_ms > 0 ? config->push_interval_ms : 1000;
    s_firebase.max_retry = config->max_retry > 0 ? config->max_retry : 3;
    s_firebase.enable_temperature = config->enable_temperature;
    s_firebase.enable_reset_cmd = config->enable_reset_cmd;
    s_firebase.enabled = true;
    s_firebase.last_status = ESP_OK;

    if (s_http_mutex == NULL) {
        s_http_mutex = xSemaphoreCreateMutex();
        if (s_http_mutex == NULL) {
            ESP_LOGE(TAG, "Failed to create Firebase HTTP mutex");
            return ESP_ERR_NO_MEM;
        }
    }

    s_firebase.initialized = true;

    ESP_LOGI(TAG, "Firebase initialized");
    ESP_LOGI(TAG, "  Database URL: %s", s_firebase.database_url);
    ESP_LOGI(TAG, "  Device ID: %s", s_firebase.device_id);
    ESP_LOGI(TAG, "  Push interval: %lu ms", s_firebase.push_interval_ms);
    ESP_LOGI(TAG, "  Temperature reporting: %s", s_firebase.enable_temperature ? "enabled" : "disabled");
    ESP_LOGI(TAG, "  Reset command: %s", s_firebase.enable_reset_cmd ? "enabled" : "disabled");

    return ESP_OK;
}

void firebase_deinit(void)
{
    if (!s_firebase.initialized) {
        return;
    }

    if (s_firebase.push_task_handle != NULL) {
        vTaskDelete(s_firebase.push_task_handle);
        s_firebase.push_task_handle = NULL;
    }

    if (s_http_mutex != NULL) {
        vSemaphoreDelete(s_http_mutex);
        s_http_mutex = NULL;
    }

    s_firebase.initialized = false;
    s_firebase.enabled = false;

    ESP_LOGI(TAG, "Firebase deinitialized");
}

bool firebase_is_ready(void)
{
    return s_firebase.initialized && s_firebase.enabled;
}

esp_err_t firebase_push_frame(const firebase_frame_t *frame)
{
    if (!s_firebase.initialized) {
        ESP_LOGE(TAG, "Firebase not initialized");
        return ESP_ERR_INVALID_STATE;
    }

    if (!s_firebase.enabled) {
        ESP_LOGD(TAG, "Firebase disabled");
        return ESP_ERR_INVALID_STATE;
    }

    if (frame == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    /* Fill timestamp if not set */
    if (frame->timestamp == 0) {
        firebase_frame_t frame_copy = *frame;
        get_timestamp(&frame_copy.timestamp, &frame_copy.timestamp_ms);
        frame = &frame_copy;
    }

    /* Retry logic */
    esp_err_t err = ESP_FAIL;
    for (int retry = 0; retry < s_firebase.max_retry; retry++) {
        err = push_frame_to_firebase(frame);
        if (err == ESP_OK) {
            break;
        }
        ESP_LOGW(TAG, "Push failed, retry %d/%d", retry + 1, s_firebase.max_retry);
        vTaskDelay(pdMS_TO_TICKS(100));
    }

    s_firebase.last_status = err;
    return err;
}

/* Get Firebase push interval in milliseconds */
uint32_t firebase_get_push_interval_ms(void)
{
    return s_firebase.push_interval_ms;
}

esp_err_t firebase_push_frames(const firebase_frame_t *frames, size_t count)
{
    if (!s_firebase.initialized || !s_firebase.enabled) {
        return ESP_ERR_INVALID_STATE;
    }

    if (frames == NULL || count == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    /* Push frames one by one */
    for (size_t i = 0; i < count; i++) {
        esp_err_t err = firebase_push_frame(&frames[i]);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "Failed to push frame %zu/%zu", i + 1, count);
            return err;
        }
    }

    return ESP_OK;
}

esp_err_t firebase_get_last_status(void)
{
    return s_firebase.last_status;
}

esp_err_t firebase_post_device_info(const char *ip_address, const char *port,
                                     const char *firmware_version, const char *device_model)
{
    if (!s_firebase.initialized || !s_firebase.enabled) {
        ESP_LOGE(TAG, "Firebase not ready");
        return ESP_ERR_INVALID_STATE;
    }

    if (!ip_address) {
        return ESP_ERR_INVALID_ARG;
    }

    if (s_http_mutex == NULL || xSemaphoreTake(s_http_mutex, portMAX_DELAY) != pdTRUE) {
        ESP_LOGE(TAG, "Failed to lock Firebase HTTP mutex");
        return ESP_FAIL;
    }

    char url_path[FIREBASE_URL_PATH_SIZE];
    snprintf(url_path, sizeof(url_path),
             "%s/devices/%s/info.json",
             s_firebase.database_url,
             s_firebase.device_id);

    char json_payload[256];
    uint32_t sec, ms;
    get_timestamp(&sec, &ms);
    
    snprintf(json_payload, sizeof(json_payload),
             "{\"device_id\":\"%s\",\"ip_address\":\"%s\",\"port\":\"%s\","
             "\"timestamp\":%lu,\"online\":true,\"firmwareVersion\":\"%s\",\"deviceModel\":\"%s\"}",
             s_firebase.device_id,
             ip_address,
             port ? port : "3333",
             sec,
             firmware_version ? firmware_version : "unknown",
             device_model ? device_model : "fallsensex");

    ESP_LOGI(TAG, "Posting device info: IP=%s", ip_address);

    esp_http_client_config_t config = {
        .url = url_path,
        .method = HTTP_METHOD_PUT,
        .event_handler = http_event_handler,
        .timeout_ms = 15000,
        .buffer_size = 1024,
        .crt_bundle_attach = esp_crt_bundle_attach,
    };

    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        ESP_LOGE(TAG, "Failed to initialize HTTP client");
        xSemaphoreGive(s_http_mutex);
        return ESP_FAIL;
    }

    esp_http_client_set_header(client, "Content-Type", "application/json");
    esp_http_client_set_post_field(client, json_payload, strlen(json_payload));

    esp_err_t err = esp_http_client_perform(client);
    if (err == ESP_OK) {
        int status_code = esp_http_client_get_status_code(client);
        if (status_code == 200 || status_code == 201) {
            ESP_LOGI(TAG, "Device info posted successfully");
            err = ESP_OK;
        } else {
            ESP_LOGE(TAG, "HTTP PUT failed with status = %d", status_code);
            err = ESP_FAIL;
        }
    } else {
        ESP_LOGE(TAG, "HTTP request failed: %s", esp_err_to_name(err));
    }

    esp_http_client_cleanup(client);
    xSemaphoreGive(s_http_mutex);
    return err;
}

esp_err_t firebase_post_heartbeat(uint32_t timestamp, uint32_t timestamp_ms)
{
    if (!s_firebase.initialized || !s_firebase.enabled) {
        ESP_LOGE(TAG, "Firebase not ready");
        return ESP_ERR_INVALID_STATE;
    }

    if (s_http_mutex == NULL || xSemaphoreTake(s_http_mutex, portMAX_DELAY) != pdTRUE) {
        ESP_LOGE(TAG, "Failed to lock Firebase HTTP mutex");
        return ESP_FAIL;
    }

    /* Path must match what the app and monitorDeviceOnline both read/write:
     * /devices/{deviceId}/online (NOT /heartbeat - that was a stale name). */
    char url_path[FIREBASE_URL_PATH_SIZE];
    if (s_firebase.auth_token[0] != '\0') {
        snprintf(url_path, sizeof(url_path),
                 "%s/devices/%s/online.json?auth=%s",
                 s_firebase.database_url,
                 s_firebase.device_id,
                 s_firebase.auth_token);
    } else {
        snprintf(url_path, sizeof(url_path),
                 "%s/devices/%s/online.json",
                 s_firebase.database_url,
                 s_firebase.device_id);
    }

    char json_payload[128];
    int json_len = snprintf(json_payload, sizeof(json_payload),
        "{\"timestamp\":%lu,\"timestamp_ms\":%lu,\"value\":true,\"device_id\":\"%s\"}",
        timestamp,
        timestamp_ms,
        s_firebase.device_id);

    if (json_len <= 0 || json_len >= sizeof(json_payload)) {
        ESP_LOGE(TAG, "Failed to build heartbeat JSON payload");
        xSemaphoreGive(s_http_mutex);
        return ESP_ERR_NO_MEM;
    }

    esp_http_client_config_t config = {
        .url = url_path,
        .method = HTTP_METHOD_PUT,
        .event_handler = http_event_handler,
        .timeout_ms = 5000,
        .buffer_size = 512,
        .crt_bundle_attach = esp_crt_bundle_attach,
    };

    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        ESP_LOGE(TAG, "Failed to initialize heartbeat HTTP client");
        xSemaphoreGive(s_http_mutex);
        return ESP_FAIL;
    }

    esp_http_client_set_header(client, "Content-Type", "application/json");
    esp_http_client_set_post_field(client, json_payload, json_len);

    esp_err_t err = esp_http_client_perform(client);
    if (err == ESP_OK) {
        int status_code = esp_http_client_get_status_code(client);
        if (status_code == 200 || status_code == 201) {
            ESP_LOGD(TAG, "Heartbeat posted successfully");
            err = ESP_OK;
        } else {
            ESP_LOGW(TAG, "Heartbeat HTTP status = %d", status_code);
            err = ESP_FAIL;
        }
    } else {
        ESP_LOGW(TAG, "Heartbeat request failed: %s", esp_err_to_name(err));
    }

    esp_http_client_cleanup(client);
    xSemaphoreGive(s_http_mutex);
    return err;
}

esp_err_t firebase_post_device_pin(const char *pin)
{
    if (!s_firebase.initialized || !s_firebase.enabled) {
        ESP_LOGE(TAG, "Firebase not ready");
        return ESP_ERR_INVALID_STATE;
    }
    if (pin == NULL || pin[0] == '\0') {
        return ESP_ERR_INVALID_ARG;
    }

    if (s_http_mutex == NULL || xSemaphoreTake(s_http_mutex, portMAX_DELAY) != pdTRUE) {
        ESP_LOGE(TAG, "Failed to lock Firebase HTTP mutex");
        return ESP_FAIL;
    }

    /* Read access on this path is owner-only (not shared viewers) - see
     * firebase_rules.json's "secrets" node under devices/$deviceId. */
    char url_path[FIREBASE_URL_PATH_SIZE];
    if (s_firebase.auth_token[0] != '\0') {
        snprintf(url_path, sizeof(url_path),
                 "%s/devices/%s/secrets/pin.json?auth=%s",
                 s_firebase.database_url,
                 s_firebase.device_id,
                 s_firebase.auth_token);
    } else {
        snprintf(url_path, sizeof(url_path),
                 "%s/devices/%s/secrets/pin.json",
                 s_firebase.database_url,
                 s_firebase.device_id);
    }

    uint32_t sec, ms;
    get_timestamp(&sec, &ms);
    char json_payload[96];
    int json_len = snprintf(json_payload, sizeof(json_payload),
        "{\"value\":\"%s\",\"setAt\":%lu}",
        pin, sec);

    if (json_len <= 0 || json_len >= sizeof(json_payload)) {
        ESP_LOGE(TAG, "Failed to build device-pin JSON payload");
        xSemaphoreGive(s_http_mutex);
        return ESP_ERR_NO_MEM;
    }

    esp_http_client_config_t config = {
        .url = url_path,
        .method = HTTP_METHOD_PUT,
        .event_handler = http_event_handler,
        .timeout_ms = 10000,
        .buffer_size = 512,
        .crt_bundle_attach = esp_crt_bundle_attach,
    };

    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        ESP_LOGE(TAG, "Failed to initialize device-pin HTTP client");
        xSemaphoreGive(s_http_mutex);
        return ESP_FAIL;
    }

    esp_http_client_set_header(client, "Content-Type", "application/json");
    esp_http_client_set_post_field(client, json_payload, json_len);

    esp_err_t err = esp_http_client_perform(client);
    if (err == ESP_OK) {
        int status_code = esp_http_client_get_status_code(client);
        if (status_code == 200 || status_code == 201) {
            ESP_LOGI(TAG, "Device PIN synced to Firebase");
            err = ESP_OK;
        } else {
            ESP_LOGW(TAG, "Device-pin sync HTTP status = %d", status_code);
            err = ESP_FAIL;
        }
    } else {
        ESP_LOGW(TAG, "Device-pin sync request failed: %s", esp_err_to_name(err));
    }

    esp_http_client_cleanup(client);
    xSemaphoreGive(s_http_mutex);
    return err;
}

/* Read CPU temperature using ESP-IDF temperature sensor API */
float firebase_read_cpu_temperature(void) {
    static temperature_sensor_handle_t tsens_handle = NULL;
    float temperature;
    esp_err_t err;
    
    // Initialize temperature sensor if not already done
    if (tsens_handle == NULL) {
        temperature_sensor_config_t tsens_config = {
            .range_min = -10,
            .range_max = 80,
            .clk_src = TEMPERATURE_SENSOR_CLK_SRC_DEFAULT,
        };
        
        err = temperature_sensor_install(&tsens_config, &tsens_handle);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "Failed to install temperature sensor: %s", esp_err_to_name(err));
            return 0.0f;
        }
        
        err = temperature_sensor_enable(tsens_handle);
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "Failed to enable temperature sensor: %s", esp_err_to_name(err));
            return 0.0f;
        }
    }
    
    // Read temperature
    err = temperature_sensor_get_celsius(tsens_handle, &temperature);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Failed to read temperature: %s", esp_err_to_name(err));
        return 0.0f;
    }
    
    return temperature;
}

firebase_command_t firebase_check_for_reset_command(void)
{
    if (!s_firebase.initialized || !s_firebase.enabled) {
        return FIREBASE_CMD_NONE;
    }

    if (!s_firebase.enable_reset_cmd) {
        return FIREBASE_CMD_NONE;  // Reset command functionality disabled
    }

    char value[32] = {0};
    char command_path[128];
    
    snprintf(command_path, sizeof(command_path),
             "/devices/%s/commands/reset",
             s_firebase.device_id);

    if (firebase_get_command(command_path, value, sizeof(value)) == ESP_OK) {
        if (strcmp(value, "true") == 0 || strcmp(value, "1") == 0 ||
            strcmp(value, "reset") == 0) {
            // Clear the command after receiving
            firebase_clear_command(command_path);
            return FIREBASE_CMD_RESET;
        }
    }
    return FIREBASE_CMD_NONE;
}

esp_err_t firebase_post_ota_status(const char *state, int progress, const char *error)
{
    if (!s_firebase.initialized || !s_firebase.enabled) {
        return ESP_ERR_INVALID_STATE;
    }

    if (s_http_mutex == NULL || xSemaphoreTake(s_http_mutex, portMAX_DELAY) != pdTRUE) {
        ESP_LOGE(TAG, "Failed to lock Firebase HTTP mutex");
        return ESP_FAIL;
    }

    char url_path[FIREBASE_URL_PATH_SIZE];
    snprintf(url_path, sizeof(url_path),
             "%s/devices/%s/ota_status.json",
             s_firebase.database_url,
             s_firebase.device_id);

    uint32_t sec, ms;
    get_timestamp(&sec, &ms);

    char json_payload[256];
    snprintf(json_payload, sizeof(json_payload),
              "{\"state\":\"%s\",\"progress\":%d,\"error\":\"%s\",\"timestamp\":%lu}",
              state ? state : "unknown",
              progress,
              error ? error : "",
              sec);

    esp_http_client_config_t config = {
        .url = url_path,
        .method = HTTP_METHOD_PUT,
        .event_handler = http_event_handler,
        .timeout_ms = 5000,
        .buffer_size = 512,
        .crt_bundle_attach = esp_crt_bundle_attach,
    };

    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        xSemaphoreGive(s_http_mutex);
        return ESP_FAIL;
    }

    esp_http_client_set_header(client, "Content-Type", "application/json");
    esp_http_client_set_post_field(client, json_payload, strlen(json_payload));

    esp_err_t err = esp_http_client_perform(client);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "OTA status post failed: %s", esp_err_to_name(err));
    }

    esp_http_client_cleanup(client);
    xSemaphoreGive(s_http_mutex);
    return err;
}

esp_err_t firebase_trim_frames(int max_frames)
{
    if (!s_firebase.initialized || !s_firebase.enabled || max_frames <= 0) {
        return ESP_ERR_INVALID_STATE;
    }

    if (s_http_mutex == NULL || xSemaphoreTake(s_http_mutex, portMAX_DELAY) != pdTRUE) {
        ESP_LOGE(TAG, "Failed to lock Firebase HTTP mutex");
        return ESP_FAIL;
    }

    /* Firebase RTDB rejects shallow=true combined with any query parameter
     * (orderBy/limitToFirst/etc - returns 400), so this can't be done in one
     * request. Step 1: a plain shallow GET (no orderBy) just to get the
     * total count cheaply, without fetching frame bodies. */
    char url_path[FIREBASE_URL_PATH_SIZE];
    snprintf(url_path, sizeof(url_path),
             "%s/devices/%s/frames.json?shallow=true",
             s_firebase.database_url,
             s_firebase.device_id);

    const size_t buf_size = 8192;
    char *response = malloc(buf_size);
    if (response == NULL) {
        xSemaphoreGive(s_http_mutex);
        return ESP_ERR_NO_MEM;
    }

    esp_http_client_config_t get_config = {
        .url = url_path,
        .method = HTTP_METHOD_GET,
        .timeout_ms = 10000,
        .buffer_size = 1024,
        .crt_bundle_attach = esp_crt_bundle_attach,
    };

    esp_http_client_handle_t client = esp_http_client_init(&get_config);
    if (client == NULL) {
        free(response);
        xSemaphoreGive(s_http_mutex);
        return ESP_FAIL;
    }

    esp_err_t err = esp_http_client_perform(client);
    int status_code = esp_http_client_get_status_code(client);
    int total_read = 0;
    if (err == ESP_OK && status_code == 200) {
        total_read = esp_http_client_read_response(client, response, buf_size - 1);
    }
    esp_http_client_cleanup(client);

    if (err != ESP_OK || status_code != 200 || total_read <= 0) {
        ESP_LOGW(TAG, "Frame count fetch failed: err=%s status=%d", esp_err_to_name(err), status_code);
        free(response);
        xSemaphoreGive(s_http_mutex);
        return ESP_FAIL;
    }
    response[total_read] = '\0';

    cJSON *count_root = cJSON_Parse(response);
    free(response);
    if (count_root == NULL || !cJSON_IsObject(count_root)) {
        if (count_root != NULL) {
            cJSON_Delete(count_root);
        }
        xSemaphoreGive(s_http_mutex); /* node is empty/null - nothing to trim */
        return ESP_OK;
    }

    int count = cJSON_GetArraySize(count_root);
    cJSON_Delete(count_root);
    if (count <= max_frames) {
        xSemaphoreGive(s_http_mutex);
        return ESP_OK;
    }
    int excess = count - max_frames;

    /* Step 2: fetch only the oldest `excess` keys directly via orderBy +
     * limitToFirst (no shallow this time - that combo is what's illegal,
     * not orderBy/limitToFirst alone). This returns full frame bodies, but
     * only for the small number of entries actually being deleted, not the
     * whole collection - the JSON-escaped quotes around $key are required
     * by the RTDB REST API's query syntax. */
    char list_url[FIREBASE_URL_PATH_SIZE];
    snprintf(list_url, sizeof(list_url),
             "%s/devices/%s/frames.json?orderBy=%%22$key%%22&limitToFirst=%d",
             s_firebase.database_url,
             s_firebase.device_id,
             excess);

    char *list_response = malloc(buf_size);
    if (list_response == NULL) {
        xSemaphoreGive(s_http_mutex);
        return ESP_ERR_NO_MEM;
    }

    esp_http_client_config_t list_config = {
        .url = list_url,
        .method = HTTP_METHOD_GET,
        .timeout_ms = 10000,
        .buffer_size = 1024,
        .crt_bundle_attach = esp_crt_bundle_attach,
    };

    esp_http_client_handle_t list_client = esp_http_client_init(&list_config);
    if (list_client == NULL) {
        free(list_response);
        xSemaphoreGive(s_http_mutex);
        return ESP_FAIL;
    }

    esp_err_t list_err = esp_http_client_perform(list_client);
    int list_status = esp_http_client_get_status_code(list_client);
    int list_read = 0;
    if (list_err == ESP_OK && list_status == 200) {
        list_read = esp_http_client_read_response(list_client, list_response, buf_size - 1);
    }
    esp_http_client_cleanup(list_client);

    if (list_err != ESP_OK || list_status != 200 || list_read <= 0) {
        ESP_LOGW(TAG, "Oldest-frames fetch failed: err=%s status=%d", esp_err_to_name(list_err), list_status);
        free(list_response);
        xSemaphoreGive(s_http_mutex);
        return ESP_FAIL;
    }
    list_response[list_read] = '\0';

    cJSON *root = cJSON_Parse(list_response);
    free(list_response);
    if (root == NULL || !cJSON_IsObject(root)) {
        if (root != NULL) {
            cJSON_Delete(root);
        }
        xSemaphoreGive(s_http_mutex);
        return ESP_FAIL;
    }

    /* Build a single multi-path delete body from the returned keys - their
     * values (full frame bodies) aren't needed, only which keys to delete. */
    cJSON *delete_body = cJSON_CreateObject();
    cJSON *child = root->child;
    int marked = 0;
    while (child != NULL) {
        cJSON_AddNullToObject(delete_body, child->string);
        child = child->next;
        marked++;
    }
    cJSON_Delete(root);

    char *patch_body = cJSON_PrintUnformatted(delete_body);
    cJSON_Delete(delete_body);
    if (patch_body == NULL) {
        xSemaphoreGive(s_http_mutex);
        return ESP_ERR_NO_MEM;
    }

    char patch_url[FIREBASE_URL_PATH_SIZE];
    snprintf(patch_url, sizeof(patch_url),
             "%s/devices/%s/frames.json",
             s_firebase.database_url,
             s_firebase.device_id);

    esp_http_client_config_t patch_config = {
        .url = patch_url,
        .method = HTTP_METHOD_PATCH,
        .timeout_ms = 10000,
        .buffer_size = 512,
        .crt_bundle_attach = esp_crt_bundle_attach,
    };

    esp_http_client_handle_t patch_client = esp_http_client_init(&patch_config);
    if (patch_client == NULL) {
        free(patch_body);
        xSemaphoreGive(s_http_mutex);
        return ESP_FAIL;
    }

    esp_http_client_set_header(patch_client, "Content-Type", "application/json");
    esp_http_client_set_post_field(patch_client, patch_body, strlen(patch_body));

    esp_err_t patch_err = esp_http_client_perform(patch_client);
    int patch_status = esp_http_client_get_status_code(patch_client);
    esp_http_client_cleanup(patch_client);
    free(patch_body);
    xSemaphoreGive(s_http_mutex);

    if (patch_err == ESP_OK && (patch_status == 200 || patch_status == 204)) {
        ESP_LOGI(TAG, "Trimmed %d old frame(s), keeping most recent %d", marked, max_frames);
        return ESP_OK;
    }

    ESP_LOGW(TAG, "Frame trim PATCH failed: err=%s status=%d", esp_err_to_name(patch_err), patch_status);
    return ESP_FAIL;
}

bool firebase_check_for_ota_command(firebase_ota_command_t *out_cmd)
{
    if (!s_firebase.initialized || !s_firebase.enabled || out_cmd == NULL) {
        return false;
    }

    char value[384] = {0};
    char command_path[128];

    snprintf(command_path, sizeof(command_path),
             "/devices/%s/commands/ota_update",
             s_firebase.device_id);

    if (firebase_get_command(command_path, value, sizeof(value)) != ESP_OK) {
        return false;
    }

    cJSON *root = cJSON_Parse(value);
    if (!root) {
        return false; /* null/empty node (no command pending) is not an error */
    }

    cJSON *url = cJSON_GetObjectItem(root, "url");
    cJSON *version = cJSON_GetObjectItem(root, "version");
    if (!url || !url->valuestring || !url->valuestring[0]) {
        cJSON_Delete(root);
        return false;
    }

    memset(out_cmd, 0, sizeof(*out_cmd));
    strncpy(out_cmd->url, url->valuestring, sizeof(out_cmd->url) - 1);
    if (version && version->valuestring) {
        strncpy(out_cmd->version, version->valuestring, sizeof(out_cmd->version) - 1);
    }
    cJSON_Delete(root);

    firebase_clear_command(command_path);
    return true;
}

void firebase_set_enabled(bool enabled)
{
    s_firebase.enabled = enabled;
    ESP_LOGI(TAG, "Firebase %s", enabled ? "enabled" : "disabled");
}

bool firebase_get_enabled(void)
{
    return s_firebase.enabled;
}

bool firebase_get_enable_temperature(void)
{
    return s_firebase.enable_temperature;
}

bool firebase_get_enable_reset_cmd(void)
{
    return s_firebase.enable_reset_cmd;
}

esp_err_t firebase_push_telemetry(const firebase_telemetry_t *telemetry)
{
    if (!s_firebase.enable_temperature) {
        return ESP_ERR_INVALID_STATE;  // Temperature reporting disabled
    }

    if (telemetry == NULL || s_firebase.database_url[0] == '\0') {
        return ESP_ERR_INVALID_ARG;
    }

    if (s_http_mutex == NULL || xSemaphoreTake(s_http_mutex, portMAX_DELAY) != pdTRUE) {
        ESP_LOGE(TAG, "Failed to lock Firebase HTTP mutex");
        return ESP_FAIL;
    }

    char json_payload[FIREBASE_JSON_SIZE];
    char url_path[FIREBASE_URL_PATH_SIZE];

    /* Build JSON payload */
    int json_len = snprintf(json_payload, sizeof(json_payload),
        "{"
        "\"timestamp\":%lu,"
        "\"timestamp_ms\":%lu,"
        "\"device_id\":\"%s\","
        "\"temperature\":%.1f"
        "}",
        telemetry->timestamp,
        telemetry->timestamp_ms,
        s_firebase.device_id,
        telemetry->temperature);

    if (json_len <= 0 || json_len >= sizeof(json_payload)) {
        ESP_LOGE(TAG, "Failed to build telemetry JSON payload");
        xSemaphoreGive(s_http_mutex);
        return ESP_ERR_NO_MEM;
    }

    /* Build URL for telemetry data */
    if (s_firebase.auth_token[0] != '\0') {
        snprintf(url_path, sizeof(url_path),
                 "%s/devices/%s/telemetry/temperature.json?auth=%s",
                 s_firebase.database_url,
                 s_firebase.device_id,
                 s_firebase.auth_token);
    } else {
        snprintf(url_path, sizeof(url_path),
                 "%s/devices/%s/telemetry/temperature.json",
                 s_firebase.database_url,
                 s_firebase.device_id);
    }

    /* Configure HTTP client */
    esp_http_client_config_t config = {
        .url = url_path,
        .method = HTTP_METHOD_PUT,
        .event_handler = http_event_handler,
        .timeout_ms = 15000,
        .buffer_size = 1024,
        .crt_bundle_attach = esp_crt_bundle_attach,
    };

    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        ESP_LOGE(TAG, "Failed to initialize HTTP client");
        xSemaphoreGive(s_http_mutex);
        return ESP_FAIL;
    }

    /* Set headers */
    esp_http_client_set_header(client, "Content-Type", "application/json");

    /* Set post data */
    esp_http_client_set_post_field(client, json_payload, json_len);

    /* Execute request */
    esp_err_t err = esp_http_client_perform(client);
    if (err == ESP_OK) {
        int status_code = esp_http_client_get_status_code(client);
        if (status_code == 200 || status_code == 201) {
            ESP_LOGI(TAG, "Telemetry pushed successfully to Firebase");
            err = ESP_OK;
        } else {
            ESP_LOGE(TAG, "Telemetry push failed with status = %d", status_code);
            err = ESP_FAIL;
        }
    } else {
        ESP_LOGE(TAG, "Telemetry push request failed: %s", esp_err_to_name(err));
    }

    esp_http_client_cleanup(client);
    xSemaphoreGive(s_http_mutex);
    return err;
}

esp_err_t firebase_clear_command(const char *command_path)
{
    if (!s_firebase.initialized || !s_firebase.enabled) {
        return ESP_ERR_INVALID_STATE;
    }

    if (s_http_mutex == NULL || xSemaphoreTake(s_http_mutex, portMAX_DELAY) != pdTRUE) {
        ESP_LOGE(TAG, "Failed to lock Firebase HTTP mutex");
        return ESP_FAIL;
    }

    char url_path[FIREBASE_URL_PATH_SIZE];
    if (s_firebase.auth_token[0] != '\0') {
        snprintf(url_path, sizeof(url_path),
                 "%s/%s.json?auth=%s",
                 s_firebase.database_url,
                 command_path,
                 s_firebase.auth_token);
    } else {
        snprintf(url_path, sizeof(url_path),
                 "%s/%s.json",
                 s_firebase.database_url,
                 command_path);
    }

    esp_http_client_config_t config = {
        .url = url_path,
        .method = HTTP_METHOD_DELETE,
        .event_handler = http_event_handler,
        .timeout_ms = 15000,
        .buffer_size = 256,
        .crt_bundle_attach = esp_crt_bundle_attach,
    };

    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        ESP_LOGE(TAG, "Failed to initialize HTTP client");
        xSemaphoreGive(s_http_mutex);
        return ESP_FAIL;
    }

    /* Execute request */
    esp_err_t err = esp_http_client_perform(client);
    if (err == ESP_OK) {
        int status_code = esp_http_client_get_status_code(client);
        if (status_code == 200 || status_code == 204) {
            ESP_LOGI(TAG, "Command cleared successfully");
            err = ESP_OK;
        } else {
            ESP_LOGE(TAG, "Command clear failed with status = %d", status_code);
            err = ESP_FAIL;
        }
    } else {
        ESP_LOGE(TAG, "Command clear request failed: %s", esp_err_to_name(err));
    }

    esp_http_client_cleanup(client);
    xSemaphoreGive(s_http_mutex);
    return err;
}

/* Get command from Firebase */
static esp_err_t firebase_get_command(const char *command_path, char *value_buf, size_t buf_size)
{
    if (!s_firebase.initialized || !s_firebase.enabled) {
        return ESP_ERR_INVALID_STATE;
    }

    if (s_http_mutex == NULL || xSemaphoreTake(s_http_mutex, portMAX_DELAY) != pdTRUE) {
        ESP_LOGE(TAG, "Failed to lock Firebase HTTP mutex");
        return ESP_FAIL;
    }

    char url_path[FIREBASE_URL_PATH_SIZE];
    if (s_firebase.auth_token[0] != '\0') {
        snprintf(url_path, sizeof(url_path),
                 "%s/%s.json?auth=%s",
                 s_firebase.database_url,
                 command_path,
                 s_firebase.auth_token);
    } else {
        snprintf(url_path, sizeof(url_path),
                 "%s/%s.json",
                 s_firebase.database_url,
                 command_path);
    }

    esp_http_client_config_t config = {
        .url = url_path,
        .method = HTTP_METHOD_GET,
        .event_handler = http_event_handler,
        .timeout_ms = 15000,
        .buffer_size = 256,
        .crt_bundle_attach = esp_crt_bundle_attach,
    };

    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        xSemaphoreGive(s_http_mutex);
        return ESP_FAIL;
    }

    esp_err_t err = esp_http_client_perform(client);
    if (err == ESP_OK) {
        int status_code = esp_http_client_get_status_code(client);
        if (status_code == 200) {
            int len = esp_http_client_read_response(client, value_buf, buf_size - 1);
            if (len > 0) {
                value_buf[len] = '\0';
                esp_http_client_cleanup(client);
                xSemaphoreGive(s_http_mutex);
                return ESP_OK;
            }
        }
    }

    esp_http_client_cleanup(client);
    xSemaphoreGive(s_http_mutex);
    return ESP_FAIL;
}

const char* firebase_get_device_id(void)
{
    return s_firebase.initialized ? s_firebase.device_id : NULL;
}

const char* firebase_get_auth_token(void)
{
    return s_firebase.initialized ? s_firebase.auth_token : NULL;
}

const char* firebase_get_database_url(void)
{
    return s_firebase.initialized ? s_firebase.database_url : NULL;
}