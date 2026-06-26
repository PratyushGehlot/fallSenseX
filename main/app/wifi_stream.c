/**
 * @file wifi_stream.c
 * @brief Radar Human Detection & Fall Monitor
 * @details ESP32-S3-BOX-3 based real-time human presence detection and fall
 *          monitoring system using LD6001 mmWave radar sensor.
 * @author PratyushGehlot
 * @see https://github.com/PratyushGehlot/radar_human_detectmon
 */

#include "wifi_stream.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "esp_mac.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "nvs_flash.h"
#include "lwip/sockets.h"
#include "lwip/err.h"
#include "string.h"

static const char *TAG = "wifi_stream";

static int s_clients[WIFI_STREAM_MAX_CLIENTS];
static char s_client_ips[WIFI_STREAM_MAX_CLIENTS][INET_ADDRSTRLEN];
static SemaphoreHandle_t s_client_mutex;
static int s_server_fd = -1;
static TaskHandle_t s_accept_task_handle = NULL;
static bool s_running = false;
static EventGroupHandle_t s_wifi_event_group = NULL;
static esp_event_handler_instance_t s_wifi_event_handler_instance = 0;
static esp_event_handler_instance_t s_ip_event_handler_instance = 0;
static bool s_global_initialized = false;  // Track one-time global init (netif, event loop, mutex)
static bool s_stream_initialized = false; // Track whether wifi_stream is fully initialized
static bool s_wifi_driver_initialized = false;

/* Client callbacks */
static wifi_stream_client_cb_t s_on_client_connected = NULL;
static wifi_stream_client_cb_t s_on_client_disconnected = NULL;
static wifi_stream_ip_cb_t s_on_ip_obtained = NULL;
static char s_device_ip[INET_ADDRSTRLEN] = {0};

#define WIFI_CONNECTED_BIT BIT0

static void destroy_default_wifi_netif(const char *ifkey)
{
    esp_netif_t *netif = esp_netif_get_handle_from_ifkey(ifkey);
    if (netif) {
        esp_netif_destroy(netif);
        ESP_LOGI(TAG, "Default WiFi netif destroyed: %s", ifkey);
    }
}

static void destroy_default_wifi_netifs(void)
{
    destroy_default_wifi_netif("WIFI_STA_DEF");
    destroy_default_wifi_netif("WIFI_AP_DEF");
}

static void create_default_wifi_sta_if_needed(void)
{
    if (esp_netif_get_handle_from_ifkey("WIFI_STA_DEF") == NULL) {
        esp_netif_create_default_wifi_sta();
    }
}

static void create_default_wifi_ap_if_needed(void)
{
    if (esp_netif_get_handle_from_ifkey("WIFI_AP_DEF") == NULL) {
        esp_netif_create_default_wifi_ap();
    }
}

static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                               int32_t event_id, void *event_data)
{
    if (event_base == WIFI_EVENT) {
        switch (event_id) {
        case WIFI_EVENT_AP_STACONNECTED: {
            wifi_event_ap_staconnected_t *event = (wifi_event_ap_staconnected_t *)event_data;
            ESP_LOGI(TAG, "Station " MACSTR " joined, AID=%d", MAC2STR(event->mac), event->aid);
            if (s_on_client_connected != NULL) {
                s_on_client_connected();
            }
            break;
        }
        case WIFI_EVENT_AP_STADISCONNECTED: {
            wifi_event_ap_stadisconnected_t *event = (wifi_event_ap_stadisconnected_t *)event_data;
            ESP_LOGI(TAG, "Station " MACSTR " left, AID=%d", MAC2STR(event->mac), event->aid);
            if (s_on_client_disconnected != NULL) {
                s_on_client_disconnected();
            }
            break;
        }
        case WIFI_EVENT_AP_START: {
            ESP_LOGI(TAG, "AP mode started");
            esp_netif_t *netif = esp_netif_get_handle_from_ifkey("WIFI_AP_DEF");
            if (netif) {
                esp_netif_ip_info_t ip_info;
                esp_netif_get_ip_info(netif, &ip_info);
                ESP_LOGI(TAG, "AP IP Address: " IPSTR, IP2STR(&ip_info.ip));
                snprintf(s_device_ip, sizeof(s_device_ip), IPSTR, IP2STR(&ip_info.ip));
            }
            break;
        }
        case WIFI_EVENT_STA_START:
            esp_wifi_connect();
            break;
        case WIFI_EVENT_STA_DISCONNECTED:
            ESP_LOGW(TAG, "Disconnected from AP, retrying...");
            esp_wifi_connect();
            break;
        default:
            break;
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
        ESP_LOGI(TAG, "Got IP address: " IPSTR, IP2STR(&event->ip_info.ip));
        xEventGroupSetBits(s_wifi_event_group, WIFI_CONNECTED_BIT);

        /* Store IP string */
        snprintf(s_device_ip, sizeof(s_device_ip), IPSTR, IP2STR(&event->ip_info.ip));

        /* Call IP obtained callback if registered */
        if (s_on_ip_obtained != NULL) {
            s_on_ip_obtained(s_device_ip);
        }
    }
}

static void wifi_init_ap(const wifi_stream_config_t *config)
{
    create_default_wifi_ap_if_needed();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    s_wifi_driver_initialized = true;

    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT,
                                                        ESP_EVENT_ANY_ID,
                                                        &wifi_event_handler,
                                                        NULL,
                                                        &s_wifi_event_handler_instance));

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP));

    wifi_config_t wifi_cfg = {
        .ap = {
            .channel = 1,
            .max_connection = WIFI_STREAM_MAX_CLIENTS,
            .authmode = WIFI_AUTH_WPA2_PSK,
        },
    };
    strncpy((char *)wifi_cfg.ap.ssid, config->ssid, sizeof(wifi_cfg.ap.ssid));
    wifi_cfg.ap.ssid_len = strlen(config->ssid);
    strncpy((char *)wifi_cfg.ap.password, config->password, sizeof(wifi_cfg.ap.password));

    if (strlen(config->password) == 0) {
        wifi_cfg.ap.authmode = WIFI_AUTH_OPEN;
    }

    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &wifi_cfg));
    ESP_ERROR_CHECK(esp_wifi_start());

    ESP_LOGI(TAG, "WiFi AP started. SSID:%s Password:%s", config->ssid, config->password);
}

static void wifi_init_sta(const wifi_stream_config_t *config)
{
    create_default_wifi_sta_if_needed();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    s_wifi_driver_initialized = true;

    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT,
                                                        ESP_EVENT_ANY_ID,
                                                        &wifi_event_handler,
                                                        NULL,
                                                        &s_wifi_event_handler_instance));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(IP_EVENT,
                                                        IP_EVENT_STA_GOT_IP,
                                                        &wifi_event_handler,
                                                        NULL,
                                                        &s_ip_event_handler_instance));

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));

    wifi_config_t wifi_cfg = {0};
    strncpy((char *)wifi_cfg.sta.ssid, config->ssid, sizeof(wifi_cfg.sta.ssid));
    strncpy((char *)wifi_cfg.sta.password, config->password, sizeof(wifi_cfg.sta.password));

    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi_cfg));
    ESP_ERROR_CHECK(esp_wifi_start());

    /* Default modem-sleep power save ("wifi:pm start, type: 1" in the log)
     * lets the radio sleep between beacon intervals to save power. That's
     * fine for the small periodic Firebase pushes this device normally
     * does, but it has caused the whole radio to go unresponsive for
     * extended stretches during a sustained OTA download - timing out
     * everything else (Firebase, DNS, even this device's own /ota_status
     * endpoint) at the same time the download itself stalls. This is a
     * mains-powered sensor, not a battery device, so there's no real
     * power-saving benefit worth the reliability cost. */
    esp_err_t ps_err = esp_wifi_set_ps(WIFI_PS_NONE);
    if (ps_err != ESP_OK) {
        ESP_LOGW(TAG, "Failed to disable WiFi power save: %s", esp_err_to_name(ps_err));
    }

    ESP_LOGI(TAG, "WiFi STA started, connecting to SSID: %s", config->ssid);
    // Connection will be handled asynchronously; no blocking wait
}

static void tcp_accept_task(void *arg)
{
    s_server_fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s_server_fd < 0) {
        ESP_LOGE(TAG, "Failed to create socket: errno %d", errno);
        vTaskDelete(NULL);
        return;
    }

    int opt = 1;
    setsockopt(s_server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons((uint16_t)(uintptr_t)arg),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };

    if (bind(s_server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        ESP_LOGE(TAG, "Socket bind failed: errno %d", errno);
        close(s_server_fd);
        s_server_fd = -1;
        vTaskDelete(NULL);
        return;
    }

    if (listen(s_server_fd, 2) < 0) {
        ESP_LOGE(TAG, "Socket listen failed: errno %d", errno);
        close(s_server_fd);
        s_server_fd = -1;
        vTaskDelete(NULL);
        return;
    }

    ESP_LOGI(TAG, "TCP server listening on port %d", (int)(uintptr_t)arg);

    while (s_running) {
        fd_set read_fds;
        FD_ZERO(&read_fds);
        FD_SET(s_server_fd, &read_fds);

        struct timeval timeout = {
            .tv_sec = 0,
            .tv_usec = 100000, // 100 ms
        };

        int sel = select(s_server_fd + 1, &read_fds, NULL, NULL, &timeout);
        if (sel < 0) {
            ESP_LOGE(TAG, "select() failed: errno %d", errno);
            break;
        }
        if (sel == 0) {
            continue;
        }
        // Check if still running before accepting (may have been stopped during select)
        if (!s_running) {
            break;
        }

        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        int client_fd = accept(s_server_fd, (struct sockaddr *)&client_addr, &client_len);
        if (client_fd < 0) {
            ESP_LOGE(TAG, "accept() failed: errno %d", errno);
            continue;
        }

        char addr_str[INET_ADDRSTRLEN];
        inet_ntoa_r(client_addr.sin_addr, addr_str, sizeof(addr_str));

        /* wifi_stream_send() runs on radar_rx_task, the highest-priority
         * task in the system - a plain blocking send() to a stalled client
         * (weak WiFi, backgrounded app) would freeze the entire radar
         * pipeline until the OS-level TCP retransmit timeout gives up
         * (can be tens of seconds to minutes). Capping the send timeout
         * means a stuck client gets dropped quickly instead of stalling
         * detection and Firebase pushes along with it. */
        struct timeval send_timeout = { .tv_sec = 1, .tv_usec = 0 };
        setsockopt(client_fd, SOL_SOCKET, SO_SNDTIMEO, &send_timeout, sizeof(send_timeout));

        xSemaphoreTake(s_client_mutex, portMAX_DELAY);
        int slot = -1;
        for (int i = 0; i < WIFI_STREAM_MAX_CLIENTS; i++) {
            if (s_clients[i] < 0) {
                s_clients[i] = client_fd;
                strncpy(s_client_ips[i], addr_str, INET_ADDRSTRLEN);
                slot = i;
                break;
            }
        }
        xSemaphoreGive(s_client_mutex);

        if (slot < 0) {
            ESP_LOGW(TAG, "No free client slot, rejecting %s", addr_str);
            close(client_fd);
        } else {
            ESP_LOGI(TAG, "Client connected from %s (slot %d)", addr_str, slot);
        }
    }

    close(s_server_fd);
    s_server_fd = -1;
    vTaskDelete(NULL);
}

esp_err_t wifi_stream_init(const wifi_stream_config_t *config)
{
    for (int i = 0; i < WIFI_STREAM_MAX_CLIENTS; i++) {
        s_clients[i] = -1;
        s_client_ips[i][0] = '\0';
    }

    /* Store client callbacks */
    if (config->on_client_connected != NULL) {
        s_on_client_connected = config->on_client_connected;
    }
    if (config->on_client_disconnected != NULL) {
        s_on_client_disconnected = config->on_client_disconnected;
    }
    if (config->on_ip_obtained != NULL) {
        s_on_ip_obtained = config->on_ip_obtained;
    }

    // One-time global initializations (netif, event loop, and mutex)
    if (!s_global_initialized) {
        ESP_ERROR_CHECK(esp_netif_init());
        ESP_ERROR_CHECK(esp_event_loop_create_default());
        s_client_mutex = xSemaphoreCreateMutex();
        if (s_client_mutex == NULL) {
            ESP_LOGE(TAG, "Failed to create mutex");
            return ESP_FAIL;
        }
        s_global_initialized = true;
    }

    s_wifi_event_group = xEventGroupCreate();

    if (config->ap_mode) {
        wifi_init_ap(config);
    } else {
        wifi_init_sta(config);
    }

    s_running = true;

    BaseType_t task_ret = xTaskCreate(tcp_accept_task, "tcp_accept", 4096,
                (void *)(uintptr_t)config->port, 5, &s_accept_task_handle);
    if (task_ret != pdPASS) {
        ESP_LOGE(TAG, "Failed to create TCP accept task");
        s_running = false;
        return ESP_FAIL;
    }

    s_stream_initialized = true;
    ESP_LOGI(TAG, "WiFi stream server started on port %d", config->port);
    return ESP_OK;
}

esp_err_t wifi_stream_send(const char *data, size_t len)
{
    if (!s_running || s_client_mutex == NULL) {
        return ESP_ERR_INVALID_STATE;
    }

    xSemaphoreTake(s_client_mutex, portMAX_DELAY);
    for (int i = 0; i < WIFI_STREAM_MAX_CLIENTS; i++) {
        if (s_clients[i] >= 0) {
            int ret = send(s_clients[i], data, len, 0);
            if (ret < 0) {
                ESP_LOGW(TAG, "Client slot %d send failed, disconnecting", i);
                close(s_clients[i]);
                s_clients[i] = -1;
                s_client_ips[i][0] = '\0';
            }
        }
    }
    xSemaphoreGive(s_client_mutex);
    return ESP_OK;
}

void wifi_stream_deinit(void)
{
    s_running = false;

    // Wait for accept task to exit (it will close its server socket and delete itself)
    if (s_accept_task_handle != NULL) {
        // Task checks s_running every 100ms (select timeout), so wait a bit longer
        vTaskDelay(pdMS_TO_TICKS(300));
        s_accept_task_handle = NULL;
    }

    // Close any remaining client sockets (task is gone)
    if (s_client_mutex != NULL) {
        xSemaphoreTake(s_client_mutex, portMAX_DELAY);
        for (int i = 0; i < WIFI_STREAM_MAX_CLIENTS; i++) {
            if (s_clients[i] >= 0) {
                close(s_clients[i]);
                s_clients[i] = -1;
                s_client_ips[i][0] = '\0';
            }
        }
        xSemaphoreGive(s_client_mutex);
    }

    // Unregister event handlers
    if (s_wifi_event_handler_instance) {
        esp_event_handler_instance_unregister(WIFI_EVENT, ESP_EVENT_ANY_ID, s_wifi_event_handler_instance);
        s_wifi_event_handler_instance = 0;
    }
    if (s_ip_event_handler_instance) {
        esp_event_handler_instance_unregister(IP_EVENT, IP_EVENT_STA_GOT_IP, s_ip_event_handler_instance);
        s_ip_event_handler_instance = 0;
    }

    // Delete event group
    if (s_wifi_event_group != NULL) {
        vEventGroupDelete(s_wifi_event_group);
        s_wifi_event_group = NULL;
    }

    if (s_wifi_driver_initialized) {
        esp_wifi_stop();
        esp_wifi_deinit();
        s_wifi_driver_initialized = false;
    }

    s_device_ip[0] = '\0';
    destroy_default_wifi_netifs();

    s_stream_initialized = false;
    ESP_LOGI(TAG, "WiFi stream deinitialized");
}

const char *wifi_stream_get_client_ip(void)
{
    if (!s_running || s_client_mutex == NULL) return NULL;

    const char *ip = NULL;
    xSemaphoreTake(s_client_mutex, portMAX_DELAY);
    for (int i = 0; i < WIFI_STREAM_MAX_CLIENTS; i++) {
        if (s_clients[i] >= 0 && s_client_ips[i][0] != '\0') {
            ip = s_client_ips[i];
            break;
        }
    }
    xSemaphoreGive(s_client_mutex);
    return ip;
}

const char *wifi_stream_get_device_ip(void)
{
    if (s_device_ip[0] == '\0') {
        return NULL;
    }
    return s_device_ip;
}

bool wifi_stream_is_connected(void)
{
    // Consider connected if device has obtained a STA IP address
    // This works for STA mode and AP+STA mode
    if (!s_running || s_device_ip[0] == '\0') {
        return false;
    }
    return true;
}
