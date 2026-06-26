/**
 * @file fall_sense_x_main.c
 * @brief Fall Sense X Main Application
 * @details XIAO ESP32S3 based real-time human presence detection and fall
 *          monitoring system using LD6001 mmWave radar sensor.
 * @author PratyushGehlot
 * @see https://github.com/PratyushGehlot/fall_sense_x
 */

/*
 * Fall Sense X - mmWave Radar Human Presence and Fall Detection
 * This is the main application file for XIAO ESP32S3, which initializes the system,
 * mounts the SPIFFS file system, sets up the web interface for configuration,
 * and starts the main application loop. The application includes features such as
 * radar-based human presence detection and fall detection for home safety,
 * with a focus on privacy protection.
 */

#include <stdlib.h>
#include <time.h>
#include <string.h>

#include "esp_log.h"
#include "esp_err.h"
#include "esp_spiffs.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "freertos/queue.h"
#include "lwip/sockets.h"
#include "radar_sensor.h"
#include "wifi_stream.h"
#include "ws2812_led.h"
#include "web_server.h"
#include "button_handler.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "firebase.h"
#include "device_pin.h"
#include "esp_sntp.h"
#include "esp_timer.h"  // For esp_timer_get_time()
#include "ota_update.h"
#include <sys/time.h>

#define BSP_WS2812_LED_GPIO     (GPIO_NUM_2)
#define SPIFFS_MOUNT_POINT      "/spiffs"
#define CONFIG_MODE_AP_SSID     "FassSenseX"
#define CONFIG_MODE_AP_PASSWORD "fallsense123"
#define CONFIG_MODE_LED_BLINKS  6

static const char *TAG = "main";

/* Device state */
static device_mode_t s_current_mode = DEVICE_MODE_NORMAL;

/* Presence timeout configuration (ms) - delay after losing human before sending "no presence" */
#define PRESENCE_CLEAR_DELAY_MS  10000  // Send no-presence 10s after human leaves

/* NTP sync state */
static bool s_ntp_initialized = false;

/* Forward declarations */
static void wifi_config_init(void);
static void firebase_config_init(void);
static void button_event_handler(button_event_t event);
static void mount_spiffs(void);
static void on_client_connected(void);
static void on_client_disconnected(void);
static void on_ip_obtained(const char *ip_str);
static void ip_obtained_task(void *arg);
static void blink_config_mode_led(void);
static void reconfigure_wifi_stream(device_mode_t mode);
static void init_ntp_sync(void);
static void fall_alert_task(void *arg);
static void firebase_command_task(void *arg);  // Add forward declaration for command task
static void device_heartbeat_task(void *arg);  // Forward declaration for heartbeat task
static void ota_wait_wifi_task(void *arg);
static void firebase_ota_trigger_task(void *arg);
static void firebase_ota_monitor_task(void *arg);

static uint32_t s_last_detection_time = 0;
static bool s_human_present = false;
static bool s_absence_reported = false;  // Tracks if we've already sent "no presence" for current absence

/* Online heartbeat tracking */
static uint32_t s_last_heartbeat_ms = 0;
#define HEARTBEAT_INTERVAL_MS      10000  // Send heartbeat every 10 seconds
#define DEVICE_OFFLINE_TIMEOUT_MS  30000  // Mobile considers device offline after 30s of no heartbeat

/* Firebase push is decoupled from the radar UART RX task via a queue so that a slow/stalled
 * network call can never block UART ingestion (radar_rx_task runs at priority 10). */
typedef struct {
    firebase_frame_t frame;
    char frame_id_buf[64];
} firebase_queue_item_t;

#define FIREBASE_QUEUE_LEN 6
static QueueHandle_t s_firebase_queue = NULL;

/* Keep at most this many frames in Firebase (oldest are pruned) to stay within
 * the free-tier storage limit. Trimmed every FIREBASE_TRIM_INTERVAL pushes
 * rather than every push, since trimming costs an extra GET (+ PATCH when
 * something needs deleting) on top of the push itself. */
#define FIREBASE_MAX_FRAMES     100
#define FIREBASE_TRIM_INTERVAL  10

static void firebase_push_task(void *arg)
{
    firebase_queue_item_t item;
    uint32_t push_count = 0;
    while (1) {
        if (xQueueReceive(s_firebase_queue, &item, portMAX_DELAY) == pdTRUE) {
            item.frame.frame_id = item.frame_id_buf;
            firebase_push_frame(&item.frame);

            push_count++;
            if (push_count % FIREBASE_TRIM_INTERVAL == 0) {
                firebase_trim_frames(FIREBASE_MAX_FRAMES);
            }
        }
    }
}

/* Enqueue a frame for the firebase_push_task; drops the frame if the queue is full
 * rather than blocking the caller (typically radar_rx_task). */
static void firebase_enqueue_frame(const firebase_frame_t *frame, const char *frame_id)
{
    if (s_firebase_queue == NULL) {
        return;
    }
    firebase_queue_item_t item;
    item.frame = *frame;
    strncpy(item.frame_id_buf, frame_id ? frame_id : "", sizeof(item.frame_id_buf) - 1);
    item.frame_id_buf[sizeof(item.frame_id_buf) - 1] = '\0';
    item.frame.frame_id = NULL; /* fixed up by firebase_push_task after dequeue */

    if (xQueueSend(s_firebase_queue, &item, 0) != pdTRUE) {
        ESP_LOGW(TAG, "Firebase queue full, dropping frame");
    }
}

/*******************************************************************************
* Private functions
******************************************************************************/

/* Guards against spawning a new fall_alert_task on every single frame that
 * still reports POSTURE_FALL while the radar's fall_recovery_frames cooldown
 * is active (multiple frames per second, for several seconds, all classify
 * as FALL once confirmed). Without this, each of those frames spawned its
 * own concurrent 5s LED-blink task, all fighting over the same RMT channel
 * ("channel not in init state" storms) and each one also forced an
 * immediate, unthrottled Firebase push - see radar_detection_callback. */
static bool s_fall_alert_active = false;

/* Fall alert task - non-blocking LED blink for fall detection */
static void fall_alert_task(void *arg)
{
    ESP_LOGW(TAG, "Fall alert task started - blinking LED for 5 seconds");

    /* Blink RED LED for 5 seconds with 100ms interval */
    for (int j = 0; j < 50; j++) {
        ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_RED);
        ws2812_show();
        vTaskDelay(pdMS_TO_TICKS(100));
        ws2812_clear();
        ws2812_show();
        vTaskDelay(pdMS_TO_TICKS(100));
    }

    /* Play alert sound */
    //app_play_alert_sound();

    ESP_LOGW(TAG, "Fall alert task completed");
    s_fall_alert_active = false; /* re-arm: a later fall event can alert again */
    vTaskDelete(NULL);
}

/* Firebase command task - periodically checks for reset commands */
static void firebase_command_task(void *arg)
{
    /* Wait for network connectivity before attempting HTTP requests */
    ESP_LOGI(TAG, "Firebase command task waiting for network...");
    while (!wifi_stream_is_connected() || !s_ntp_initialized) {
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
    ESP_LOGI(TAG, "Firebase command task: network and time sync ready");

    while (1) {
        if (firebase_is_ready()) {
            /* One-time sync of a freshly-generated first-boot PIN (see
             * device_pin_init in device_pin.c). Retries here every 5s until
             * it succeeds, rather than being cleared on a transient
             * network failure. */
            char pending_pin[8];
            if (device_pin_get_pending_sync(pending_pin, sizeof(pending_pin))) {
                if (firebase_post_device_pin(pending_pin) == ESP_OK) {
                    device_pin_clear_pending_sync();
                }
            }

            firebase_command_t cmd = firebase_check_for_reset_command();
            if (cmd == FIREBASE_CMD_RESET) {
                ESP_LOGW(TAG, "Reset command received from Firebase - restarting device");
                esp_restart();
            }

            /* Check for a remote OTA update command. Execution runs on its own
             * task so a slow/blocking download never stalls this poll loop. */
            firebase_ota_command_t ota_cmd;
            if (firebase_check_for_ota_command(&ota_cmd)) {
                char *url_copy = strdup(ota_cmd.url);
                if (url_copy != NULL) {
                    ESP_LOGW(TAG, "OTA update command received (version %s): %s",
                             ota_cmd.version[0] ? ota_cmd.version : "unknown", url_copy);
                    xTaskCreate(firebase_ota_trigger_task, "fb_ota_trigger", 8192, url_copy, 4, NULL);
                } else {
                    ESP_LOGE(TAG, "Failed to allocate OTA URL buffer");
                }
            }
        }
        vTaskDelay(pdMS_TO_TICKS(5000)); // Check every 5 seconds
    }
}

/* Polls ota_update progress and mirrors it to /devices/{id}/ota_status so the
 * app can show a live progress bar. Exits once the OTA reaches a terminal
 * state (a successful OTA reboots the device before this would matter). */
static void firebase_ota_monitor_task(void *arg)
{
    while (1) {
        ota_state_t state = ota_update_get_state();
        firebase_post_ota_status(ota_update_get_state_string(),
                                  ota_update_get_progress(),
                                  ota_update_get_error_string());
        if (state == OTA_STATE_SUCCESS || state == OTA_STATE_FAILED) {
            break;
        }
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
    vTaskDelete(NULL);
}

/* One-shot task that performs an OTA update triggered remotely via Firebase.
 * Takes ownership of the heap-allocated url string and frees it. */
static void firebase_ota_trigger_task(void *arg)
{
    char *url = (char *)arg;
    xTaskCreate(firebase_ota_monitor_task, "fb_ota_monitor", 4096, NULL, 3, NULL);
    esp_err_t err = ota_update_start_url(url);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Remote OTA update failed: %s", esp_err_to_name(err));
        firebase_post_ota_status("failed", 0, esp_err_to_name(err));
    }
    free(url);
    vTaskDelete(NULL);
}

/* OTA task - waits for WiFi before starting OTA polling */
static void ota_wait_wifi_task(void *arg)
{
    ESP_LOGI(TAG, "OTA wait task waiting for WiFi...");
    while (!wifi_stream_is_connected()) {
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
    ESP_LOGI(TAG, "OTA wait task: WiFi connected, starting OTA task");
    ota_update_task_start();
    vTaskDelete(NULL);
}

/* Mount SPIFFS */
static void mount_spiffs(void)
{
    ESP_LOGI(TAG, "Mounting SPIFFS...");
    
    esp_vfs_spiffs_conf_t conf = {
        .base_path = SPIFFS_MOUNT_POINT,
        .partition_label = "storage",
        .max_files = 5,
        .format_if_mount_failed = false
    };
    
    esp_err_t ret = esp_vfs_spiffs_register(&conf);
    if (ret != ESP_OK) {
        if (ret == ESP_FAIL) {
            ESP_LOGE(TAG, "Failed to mount or format SPIFFS");
        } else if (ret == ESP_ERR_NOT_FOUND) {
            ESP_LOGE(TAG, "Failed to find SPIFFS partition");
        } else {
            ESP_LOGE(TAG, "Failed to initialize SPIFFS: %s", esp_err_to_name(ret));
        }
        return;
    }
    
    size_t total = 0, used = 0;
    ret = esp_spiffs_info("storage", &total, &used);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Failed to get SPIFFS partition information");
    } else {
        ESP_LOGI(TAG, "SPIFFS: %lu/%lu bytes used", (unsigned long)used, (unsigned long)total);
    }
}

/* WiFi configuration initialization */
static void wifi_config_init(void)
{
    ESP_LOGI(TAG, "Initializing WiFi...");
    
    /* Initialize NVS */
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);
}

/* Firebase configuration initialization */
static void firebase_config_init(void)
{
    ESP_LOGI(TAG, "Initializing Firebase...");
    
    firebase_config_t fb_config = {
        .database_url = CONFIG_Firebase_DATABASE_URL,
        .auth_token = CONFIG_Firebase_AUTH_TOKEN,
        .device_id = CONFIG_Firebase_DEVICE_ID,
        .push_interval_ms = CONFIG_Firebase_PUSH_INTERVAL_MS,
        .max_retry = CONFIG_Firebase_MAX_RETRY,
        .enable_temperature = CONFIG_Firebase_ENABLE_TEMPERATURE,
        .enable_reset_cmd = CONFIG_Firebase_ENABLE_RESET_CMD,
    };
    
    /* Only initialize if database URL is configured */
    if (fb_config.database_url != NULL && strlen(fb_config.database_url) > 0) {
        esp_err_t ret = firebase_init(&fb_config);
        if (ret == ESP_OK) {
            ESP_LOGI(TAG, "Firebase initialized successfully");
            ESP_LOGI(TAG, "  Temperature reporting: %s", CONFIG_Firebase_ENABLE_TEMPERATURE ? "enabled" : "disabled");
            ESP_LOGI(TAG, "  Reset command: %s", CONFIG_Firebase_ENABLE_RESET_CMD ? "enabled" : "disabled");
        } else {
            ESP_LOGE(TAG, "Firebase initialization failed: %s", esp_err_to_name(ret));
        }
    } else {
        ESP_LOGW(TAG, "Firebase not configured - set CONFIG_FIREBASE_DATABASE_URL");
    }
}

/* Button event handler */
static void button_event_handler(button_event_t event)
{
    switch (event) {
        case BUTTON_EVENT_LONG_PRESS:

            ESP_LOGI(TAG, "Button: Long press - Entering config mode");
            ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_GREEN);
            //ws2812_show();
			 blink_config_mode_led();
            web_server_set_device_mode(DEVICE_MODE_CONFIG);
            break;
            
        case BUTTON_EVENT_DOUBLE_PRESS:
            ESP_LOGI(TAG, "Button: Double press - Entering paired mode");
            ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_YELLOW);
            ws2812_show();
            web_server_set_device_mode(DEVICE_MODE_PAIRED);
            break;
            
        case BUTTON_EVENT_SHORT_PRESS:
            ESP_LOGI(TAG, "Button: Short press - Normal operation");
            ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_BLUE);
            ws2812_show();
            web_server_set_device_mode(DEVICE_MODE_NORMAL);
            break;
            
        default:
            break;
    }
}

/* Mode change callback from web server */
static void mode_change_callback(device_mode_t new_mode)
{
    s_current_mode = new_mode;
    
    // Reconfigure WiFi based on the new mode
    reconfigure_wifi_stream(new_mode);
    
    switch (new_mode) {
        case DEVICE_MODE_CONFIG:
            /* Config mode - start web server in AP mode */
            ESP_LOGI(TAG, "Mode changed to CONFIG - Starting AP for configuration");
            ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_GREEN);
            ws2812_show();
            break;
            
        case DEVICE_MODE_PAIRED:
            /* Paired mode - device is paired with gateway */
            ESP_LOGI(TAG, "Mode changed to PAIRED");
            ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_YELLOW);
            ws2812_show();
            break;
            
        case DEVICE_MODE_NORMAL:
        default:
            /* Normal operation mode */
            ESP_LOGI(TAG, "Mode changed to NORMAL");
            ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_BLUE);
            ws2812_show();
            break;
    }
}

static void blink_config_mode_led(void)
{
    for (int i = 0; i < CONFIG_MODE_LED_BLINKS; i++) {
        ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_GREEN);
        ws2812_show();
        vTaskDelay(pdMS_TO_TICKS(250));
        ws2812_clear();
        ws2812_show();
        vTaskDelay(pdMS_TO_TICKS(250));
    }
}

/* IP obtained callback - fires directly on the WiFi/IP driver's event loop
 * task. init_ntp_sync() can block for up to 10s waiting for time sync, and
 * firebase_post_device_info() is a blocking HTTPS call that also takes the
 * same s_http_mutex the frame-push task needs - doing either inline here
 * would stall the system event task AND block frame pushing (the radar
 * keeps enqueueing the whole time) for that entire window, right when the
 * network is least settled (just after acquiring an IP). Hand off to a
 * one-shot task instead so this callback returns immediately. */
static void on_ip_obtained(const char *ip_str)
{
    ESP_LOGI(TAG, "Device IP obtained: %s", ip_str);

    char *ip_copy = strdup(ip_str);
    if (ip_copy == NULL) {
        ESP_LOGE(TAG, "Failed to allocate IP string for ip_obtained_task");
        return;
    }
    if (xTaskCreate(ip_obtained_task, "ip_obtained", 4096, ip_copy, 3, NULL) != pdPASS) {
        ESP_LOGE(TAG, "Failed to create ip_obtained_task");
        free(ip_copy);
    }
}

/* Takes ownership of the heap-allocated ip_str and frees it. */
static void ip_obtained_task(void *arg)
{
    char *ip_str = (char *)arg;

    /* Initialize SNTP now that we have network connectivity */
    init_ntp_sync();

    /* Post device info to Firebase only after time sync succeeds */
    if (s_ntp_initialized && firebase_get_enabled()) {
        esp_err_t err = firebase_post_device_info(ip_str, "3333", OTA_FIRMWARE_VERSION, "fallsensex");
        if (err != ESP_OK) {
            ESP_LOGW(TAG, "Failed to post device info to Firebase: %s", esp_err_to_name(err));
        }
    }

    free(ip_str);
    vTaskDelete(NULL);
}

/* Initialize SNTP for time synchronization - must be called after WiFi is connected */
static void init_ntp_sync(void)
{
    if (s_ntp_initialized) {
        ESP_LOGI(TAG, "SNTP already initialized, skipping");
        return;
    }
    
    ESP_LOGI(TAG, "Initializing SNTP for time synchronization...");
    
    /* Set timezone to IST (UTC+5:30) */
    setenv("TZ", "IST-5:30", 1);
    tzset();
    
    /* Configure SNTP using the legacy API */
    sntp_setoperatingmode(SNTP_OPMODE_POLL);
    sntp_setservername(0, "pool.ntp.org");
    sntp_setservername(1, "time.google.com");
    sntp_setservername(2, "time.nist.gov");
    sntp_init();
    
    /* Wait for time to be synchronized (with timeout) */
    ESP_LOGI(TAG, "Waiting for time synchronization...");
    time_t now = 0;
    struct tm timeinfo = {0};
    int retry = 0;
    const int retry_count = 10;
    
    while (retry < retry_count) {
        now = time(NULL);
        localtime_r(&now, &timeinfo);
        if (timeinfo.tm_year >= (2020 - 1900)) {
            ESP_LOGI(TAG, "Time synchronized: %s", asctime(&timeinfo));
            s_ntp_initialized = true;
            return;
        }
        ESP_LOGW(TAG, "Time not yet synchronized, retrying... (%d/%d)", retry + 1, retry_count);
        vTaskDelay(pdMS_TO_TICKS(1000));
        retry++;
    }
    
    ESP_LOGW(TAG, "Time synchronization timeout - continuing anyway");
}

/* Firebase push throttle: while someone is present, this is a periodic
 * presence/posture heartbeat to the cloud, not a live feed - the LAN TCP
 * stream (wifi_stream_send, see radar_sensor.c) already serves real-time
 * point-cloud data for the app's "Live (LAN)" view. 5000ms gives generous
 * headroom over a single push's worst-case latency (fresh TLS handshake
 * each time, no keep-alive) so the push task can fully drain the queue
 * between enqueues even when one push is slow, instead of falling behind
 * and dropping frames. */
static uint32_t s_last_firebase_push_ms = 0;
#define FIREBASE_PUSH_MIN_INTERVAL_MS 5000

/* Frame ID counter for unique keys */
static uint32_t s_frame_id_counter = 0;

/* Radar detection callback */
static void radar_detection_callback(const human_target_t *targets, int target_count)
{
    // Pause detection/LED/Firebase work during an OTA flash: the LED is busy
    // showing OTA progress (see ota_led_task in ota_update.c), and we'd
    // rather not compete with the firmware download for WiFi bandwidth.
    if (ota_update_is_busy()) {
        return;
    }

    // Get LED brightness from config (convert 1-100 to 0-255)
    int brightness_percent = web_server_get_led_brightness();
    uint8_t brightness = (brightness_percent * 255) / 100;
    ws2812_set_brightness(brightness);

    // Update presence tracking with configurable debounce
    bool human_detected = (target_count > 0);
    uint32_t now_ms = esp_timer_get_time() / 1000; // Convert to ms

    // Force initial frame on startup (no previous data)
    bool force_send = (s_last_detection_time == 0);

    if (human_detected) {
        // Human present - update timestamp and reset absence flag
        s_last_detection_time = now_ms;
        s_human_present = true;
        s_absence_reported = false;
    } else {
        // No human detected - apply configurable debounce delay
        uint32_t time_since_last_human = now_ms - s_last_detection_time;
        bool timeout_expired = (time_since_last_human >= PRESENCE_CLEAR_DELAY_MS);
        
        if (timeout_expired && s_human_present && !s_absence_reported) {
            // Debounce period passed - human officially absent
            s_human_present = false;
            s_absence_reported = true;  // Mark absence as reported
            force_send = true;  // Force send "no presence" frame
        }
        // If still within debounce window, keep s_human_present=true until delay expires
    }

    // Determine if we should send a frame to Firebase
    bool should_send = (target_count > 0) || force_send;

    // If this is the initial send (startup), mark s_last_detection_time to prevent repeated force_send
    if (should_send && s_last_detection_time == 0) {
        s_last_detection_time = now_ms;
    }

    // A fall must reach the cloud immediately, not wait out the presence
    // heartbeat interval - the local LED/buzzer alert below is already
    // instant, but this is what gets the event (and any app notification
    // tied to it) to Firebase. Only the *new* fall (s_fall_alert_active not
    // already set) bypasses the throttle - the radar keeps reporting
    // POSTURE_FALL for several consecutive frames while its own
    // fall_recovery_frames cooldown is active, and unthrottling every one of
    // those would flood the push queue exactly when the system most needs
    // to stay responsive (see the fall_alert_task storm this fixed).
    bool any_fall = false;
    for (int i = 0; i < target_count; i++) {
        if (targets[i].posture == POSTURE_FALL) {
            any_fall = true;
            break;
        }
    }
    bool new_fall_event = any_fall && !s_fall_alert_active;

    /* Firebase push throttle to avoid WiFi watchdog trigger */
    uint32_t this_push_ms = esp_timer_get_time() / 1000;
    bool rate_limited = false;
    if (!new_fall_event && s_last_firebase_push_ms > 0 &&
        this_push_ms - s_last_firebase_push_ms < FIREBASE_PUSH_MIN_INTERVAL_MS) {
        rate_limited = true;
    }
    
    /* Push frame data to Firebase. wifi_stream_is_connected() (has an IP)
     * is checked separately from firebase_is_ready() (which only reflects
     * local init/enabled state, not actual network reachability) - without
     * it, the radar task starts pushing before WiFi finishes associating
     * and DNS resolution guaranteed-fails ("getaddrinfo() returns 202"). */
    if (!rate_limited && should_send && firebase_is_ready() && wifi_stream_is_connected()) {
        struct timeval tv;
        gettimeofday(&tv, NULL);
        time_t now_sec = (time_t)tv.tv_sec;
        uint32_t now_ms = (uint32_t)(tv.tv_usec / 1000);
        struct tm tm_info;
        localtime_r(&now_sec, &tm_info);
        char frame_id[64];
        uint32_t counter = s_frame_id_counter++;
        
        snprintf(frame_id, sizeof(frame_id), "%04d_%02d_%02d_%02dh%02dm%02ds_%06lu",
                 tm_info.tm_year + 1900,
                 tm_info.tm_mon + 1,
                 tm_info.tm_mday,
                 tm_info.tm_hour,
                 tm_info.tm_min,
                 tm_info.tm_sec,
                 counter);
        
        firebase_frame_t fb_frame = {
            .target_count = 0,
            .present = (target_count > 0),
            .timestamp = now_sec,
            .timestamp_ms = now_ms,
            .frame_id = frame_id,
            .temperature = firebase_read_cpu_temperature(),
        };

        int n = target_count;
        if (n > FIREBASE_MAX_TARGETS) {
            ESP_LOGW(TAG, "%d targets detected, reporting only the first %d to Firebase",
                     n, FIREBASE_MAX_TARGETS);
            n = FIREBASE_MAX_TARGETS;
        }
        for (int i = 0; i < n; i++) {
            fb_frame.targets[i] = (firebase_target_t){
                .track_id = targets[i].track_id,
                .x = targets[i].center_x,
                .y = targets[i].center_y,
                .z = targets[i].center_z,
                .velocity = targets[i].avg_velocity,
                .posture = (uint8_t)targets[i].posture,
                .confidence = targets[i].confidence,
            };
        }
        fb_frame.target_count = n;

        firebase_enqueue_frame(&fb_frame, frame_id);
        
        s_last_firebase_push_ms = this_push_ms;
    }
    
    if (target_count > 0) {
        /* Human detected */
        ESP_LOGD(TAG, "Human detected: %d target(s)", target_count);
        
        /* Check for fall first - highest priority. Only spawn one alert task
         * per fall event (s_fall_alert_active gates this) - the radar keeps
         * reporting POSTURE_FALL for multiple consecutive frames while its
         * fall_recovery_frames cooldown is active, and spawning a new
         * fall_alert_task on every one of those frames is what caused the
         * concurrent-RMT-access storm ("channel not in init state" spam). */
        for (int i = 0; i < target_count; i++) {
            if (targets[i].posture == POSTURE_FALL) {
                if (!s_fall_alert_active) {
                    s_fall_alert_active = true;
                    ESP_LOGW(TAG, "FALL DETECTED! Target %d at (%.2f, %.2f, %.2f)",
                        i, targets[i].center_x, targets[i].center_y, targets[i].center_z);

                    /* Start fall alert task (non-blocking) */
                    xTaskCreate(fall_alert_task, "fall_alert", 2048, NULL, 5, NULL);
                }
                break;
            }
        }
        
        /* Set LED based on primary target posture (not fall, already handled) */
        human_posture_t primary_posture = targets[0].posture;
        
        /* Find the most significant posture (excluding fall which is already handled) */
        for (int i = 1; i < target_count; i++) {
            if (targets[i].posture != POSTURE_FALL) {
                /* Prioritize standing > sitting > lying > other */
                if (targets[i].posture == POSTURE_STANDING) {
                    primary_posture = POSTURE_STANDING;
                    break;
                } else if (targets[i].posture == POSTURE_SITTING && primary_posture != POSTURE_STANDING) {
                    primary_posture = POSTURE_SITTING;
                } else if (targets[i].posture == POSTURE_LYING && primary_posture != POSTURE_STANDING && primary_posture != POSTURE_SITTING) {
                    primary_posture = POSTURE_LYING;
                }
            }
        }
        
        switch (primary_posture) {
            case POSTURE_STANDING:
                ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_PARROT_GREEN);
                break;
            case POSTURE_SITTING:
                ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_PURPLE);
                break;
            case POSTURE_LYING:
            case POSTURE_SLEEPING:
                ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_YELLOW);
                break;
            default:
                ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_GREEN);
                break;
        }
        ws2812_show();
    } else {
        /* No human detected - turn off LED */
        ws2812_clear();
        ws2812_show();
    }
}

/* Client connected callback - blink LED purple for 1 second */
static void on_client_connected(void)
{
    ESP_LOGI(TAG, "Client connected - blinking LED purple");
    
    /* Blink LED purple for 1 second (4 iterations of 250ms = 1 second) */
    for (int i = 0; i < 4; i++) {
        ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_PURPLE);
        ws2812_show();
        vTaskDelay(pdMS_TO_TICKS(100));
        ws2812_clear();
        ws2812_show();
        vTaskDelay(pdMS_TO_TICKS(100));
    }
    
    /* Restore LED to current mode color */
    switch (s_current_mode) {
        case DEVICE_MODE_CONFIG:
            ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_GREEN);
            break;
        case DEVICE_MODE_PAIRED:
            ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_YELLOW);
            break;
        case DEVICE_MODE_NORMAL:
        default:
            ws2812_clear();
            //ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_BLUE);
            break;
    }
    ws2812_show();
}

/* Client disconnected callback - blink LED purple once */
static void on_client_disconnected(void)
{
    ESP_LOGI(TAG, "Client disconnected - blinking LED purple once");
    
    /* Blink LED purple once (2 iterations of 250ms = 500ms total) */
    for (int i = 0; i < 2; i++) {
        ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_PURPLE);
        ws2812_show();
        vTaskDelay(pdMS_TO_TICKS(100));
        ws2812_clear();
        ws2812_show();
        vTaskDelay(pdMS_TO_TICKS(100));
    }
    
    /* Restore LED to current mode color */
    switch (s_current_mode) {
        case DEVICE_MODE_CONFIG:
            ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_GREEN);
            break;
        case DEVICE_MODE_PAIRED:
            ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_YELLOW);
            break;
        case DEVICE_MODE_NORMAL:
        default:
             ws2812_clear();
            //ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_BLUE);
            break;
    }
    ws2812_show();
}

/* Reconfigure WiFi stream based on device mode */
static void reconfigure_wifi_stream(device_mode_t mode)
{
    ESP_LOGI(TAG, "Reconfiguring WiFi for mode %d", mode);
    
    // Deinit existing WiFi stream if any (safe to call even if not initialized)
    wifi_stream_deinit();
    
    wifi_stream_config_t wifi_cfg;
    memset(&wifi_cfg, 0, sizeof(wifi_cfg));
    wifi_cfg.port = WIFI_STREAM_DEFAULT_PORT;
    wifi_cfg.on_client_connected = on_client_connected;
    wifi_cfg.on_client_disconnected = on_client_disconnected;
    wifi_cfg.on_ip_obtained = on_ip_obtained;
    
    if (mode == DEVICE_MODE_CONFIG) {
        // AP mode for configuration - device acts as hotspot
        wifi_cfg.ap_mode = true;
        wifi_cfg.ssid = CONFIG_MODE_AP_SSID;
        wifi_cfg.password = CONFIG_MODE_AP_PASSWORD;
        ESP_LOGI(TAG, "Starting WiFi in AP mode - SSID: %s", CONFIG_MODE_AP_SSID);
    } else {
        // NORMAL or PAIRED mode - AP+STA mode for Web UI + internet
        wifi_cfg.ap_mode = false;
        char ssid_buf[32];
        char password_buf[64];
        web_server_get_wifi_credentials(ssid_buf, sizeof(ssid_buf), password_buf, sizeof(password_buf));
        
        if (strlen(ssid_buf) == 0) {
            ESP_LOGW(TAG, "No WiFi credentials saved, falling back to AP mode");
            wifi_cfg.ap_mode = true;
            wifi_cfg.ssid = "FallSenseX";
            wifi_cfg.password = "fallsense123";
        } else {
            wifi_cfg.ssid = ssid_buf;
            wifi_cfg.password = password_buf;
            ESP_LOGI(TAG, "Connecting to WiFi SSID: %s", ssid_buf);
        }
    }
    
    esp_err_t err = wifi_stream_init(&wifi_cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to initialize WiFi stream: %s", esp_err_to_name(err));
    }
}

static uint32_t heartbeat_backoff_ms(int failures)
{
    uint32_t multiplier = 1;
    for (int i = 0; i < failures && i < 6; i++) {
        multiplier *= 2;
    }
    
    uint32_t delay_ms = HEARTBEAT_INTERVAL_MS * multiplier;
    if (delay_ms < 1000) {
        delay_ms = 1000;
    }
    if (delay_ms > 60000) {
        delay_ms = 60000;
    }
    return delay_ms;
}

/* Device heartbeat task - sends online status every 10 seconds */
static void device_heartbeat_task(void *arg)
{
    ESP_LOGI(TAG, "Device heartbeat task started - sending online ping every %dms", HEARTBEAT_INTERVAL_MS);
    
    // Wait for network connectivity and time sync before attempting Firebase HTTP requests
    while (!wifi_stream_is_connected() || !s_ntp_initialized) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        ESP_LOGD(TAG, "Heartbeat waiting for WiFi/time sync...");
    }
    ESP_LOGI(TAG, "Heartbeat: WiFi/time sync ready, starting heartbeat loop");
    
    if (!firebase_is_ready()) {
        ESP_LOGE(TAG, "Heartbeat: Firebase not initialized - exiting task");
        vTaskDelete(NULL);
        return;
    }
    
    int consecutive_failures = 0;
    uint32_t heartbeat_delay_ms = HEARTBEAT_INTERVAL_MS;
    
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(heartbeat_delay_ms));
        
        if (firebase_is_ready() && wifi_stream_is_connected()) {
            // Get current Unix timestamp in seconds and milliseconds
            struct timeval tv;
            gettimeofday(&tv, NULL);
            uint32_t now_sec = (uint32_t)tv.tv_sec;
            uint32_t now_ms = tv.tv_usec / 1000;
            
            esp_err_t err = firebase_post_heartbeat(now_sec, now_ms);
            if (err == ESP_OK) {
                s_last_heartbeat_ms = now_sec * 1000 + now_ms;
                consecutive_failures = 0;
                heartbeat_delay_ms = HEARTBEAT_INTERVAL_MS;
                ESP_LOGD(TAG, "Heartbeat sent - device online (ts=%lu)", now_sec);
            } else {
                consecutive_failures++;
                heartbeat_delay_ms = heartbeat_backoff_ms(consecutive_failures);
                ESP_LOGW(TAG, "Heartbeat failed: %s (%d), retry in %lu ms",
                         esp_err_to_name(err), err, (unsigned long)heartbeat_delay_ms);
            }
        }
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "=================================================");
    ESP_LOGI(TAG, "Fall Sense X - mmWave Radar Fall Detection");
    ESP_LOGI(TAG, "XIAO ESP32S3 Application Starting...");
    ESP_LOGI(TAG, "Compile time: %s %s", __DATE__, __TIME__);
    ESP_LOGI(TAG, "=================================================");

    /* Set timezone to IST (UTC+5:30) for human-readable timestamps */
    setenv("TZ", "IST-5:30", 1);
    tzset();

    /* Mount SPIFFS */
    mount_spiffs();

    /* Initialize audio */
    //ESP_LOGI(TAG, "Initializing audio...");
    //app_audio_init();

    /* Play boot sound */
    //app_play_boot_sound();

    /* Initialize WS2812 LED */
    ESP_LOGI(TAG, "Initializing WS2812 LED...");
    ws2812_config_t led_config = {
        .gpio_num = BSP_WS2812_LED_GPIO,
        .led_count = 1,
        .channel = 0
    };
    if (ws2812_init(&led_config) == ESP_OK) {
        ESP_LOGI(TAG, "WS2812 LED initialized successfully on GPIO%d", BSP_WS2812_LED_GPIO);
        
        /* Blink LED for 3 seconds then turn off */
        for (int i = 0; i < 6; i++) {
            ws2812_set_color_all((ws2812_color_t)WS2812_COLOR_BLUE);
            ws2812_show();
            vTaskDelay(pdMS_TO_TICKS(100));
            ws2812_clear();
            ws2812_show();
            vTaskDelay(pdMS_TO_TICKS(50));
        }
    } else {
        ESP_LOGE(TAG, "Failed to initialize WS2812 LED");
    }

    /* Initialize WiFi and network */
    wifi_config_init();

    /* Initialize Firebase for cloud streaming */
    firebase_config_init();

    /* Initialize web server (loads credentials from NVS) */
    ESP_LOGI(TAG, "Initializing web server...");
    web_server_config_t web_config = {
        .ssid = "FallSenseX_Config",
        .password = "fallsense123",
        .mode_change_callback = mode_change_callback,
    };
    
    esp_err_t web_err = web_server_init(&web_config);
    if (web_err != ESP_OK) {
        ESP_LOGE(TAG, "web_server_init failed: %s", esp_err_to_name(web_err));
        // Continue anyway - will use default credentials
    }

    /* Initialize button handler before WiFi wait */
    ESP_LOGI(TAG, "Initializing button handler...");
    button_config_t button_cfg = {
        .gpio_num = CONFIG_BUTTON_GPIO,
        .callback = button_event_handler,
    };
    button_init(&button_cfg);

    /* Initialize WiFi and set initial mode (triggers WiFi/netif initialization) */
    mode_change_callback(s_current_mode);
	
	/* Create Firebase command task if reset functionality is enabled */
    if (firebase_is_ready()) {
        xTaskCreate(firebase_command_task, "firebase_cmd_task", 6*1024, NULL, 5, NULL);
    }

    /* Firebase push queue + task: decouples slow/blocking HTTP pushes from radar_rx_task */
    s_firebase_queue = xQueueCreate(FIREBASE_QUEUE_LEN, sizeof(firebase_queue_item_t));
    if (s_firebase_queue == NULL) {
        ESP_LOGE(TAG, "Failed to create firebase queue");
    } else {
        xTaskCreate(firebase_push_task, "firebase_push_task", 6*1024, NULL, 4, NULL);
    }

    /* Start web server after WiFi stack is initialized */
    if (web_err == ESP_OK) {
        web_err = web_server_start();
        if (web_err != ESP_OK) {
            ESP_LOGE(TAG, "web_server_start failed: %s", esp_err_to_name(web_err));
        }
    }

    /* Start OTA task after WiFi is ready */
    ota_update_init();
    xTaskCreate(ota_wait_wifi_task, "ota_wait", 4096, NULL, 3, NULL);

    /* Create device online heartbeat task - signals ESP32 is powered on.
     * This is what the app's online/offline indicator actually depends on. */
    xTaskCreate(device_heartbeat_task, "dev_hb", 8192, NULL, 2, NULL);

    /* Initializing radar sensor (UART + detection) */
    ESP_LOGI(TAG, "Initializing radar sensor...");
    radar_config_t radar_cfg = RADAR_CONFIG_DEFAULT();
    radar_cfg.detection_cb = radar_detection_callback;
    esp_err_t radar_err = radar_sensor_init(&radar_cfg);
    if (radar_err == ESP_OK) {
        radar_start();
        /* Pushes any saved calibration/confidence settings into the live
         * detection config - radar_sensor_init() only ever applies
         * RADAR_CONFIG_DEFAULT(), so without this call, anything saved via
         * /radar_save or /radar_calibrate would be persisted to NVS but
         * never actually take effect. */
        web_server_apply_radar_config();
    } else {
        ESP_LOGE(TAG, "Radar initialization failed: %s", esp_err_to_name(radar_err));
    }

    ESP_LOGI(TAG, "App initialization complete!");
    ESP_LOGI(TAG, "Connect to WiFi AP '%s' and open http://192.168.4.1 for configuration", CONFIG_MODE_AP_SSID);
    ESP_LOGI(TAG, "Button: Long press (3s) = Config mode, Double press = Paired mode");
}
