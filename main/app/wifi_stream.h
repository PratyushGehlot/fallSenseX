/**
 * @file wifi_stream.h
 * @brief Radar Human Detection & Fall Monitor
 * @details ESP32-S3-BOX-3 based real-time human presence detection and fall
 *          monitoring system using LD6001 mmWave radar sensor.
 * @author PratyushGehlot
 * @see https://github.com/PratyushGehlot/radar_human_detectmon
 */

#ifndef WIFI_STREAM_H
#define WIFI_STREAM_H

#include "esp_err.h"
#include <stdbool.h>
#include <stddef.h>

#define WIFI_STREAM_DEFAULT_PORT 3333
#define WIFI_STREAM_MAX_CLIENTS 3

/* Client connection callback */
typedef void (*wifi_stream_client_cb_t)(void);

/* IP address obtained callback */
typedef void (*wifi_stream_ip_cb_t)(const char *ip_str);

typedef struct {
    const char *ssid;
    const char *password;
    uint16_t port;
    bool ap_mode;
    wifi_stream_client_cb_t on_client_connected;    /* Called when a client connects */
    wifi_stream_client_cb_t on_client_disconnected; /* Called when a client disconnects */
    wifi_stream_ip_cb_t on_ip_obtained;             /* Called when IP address is obtained (STA mode only) */
} wifi_stream_config_t;

#define WIFI_STREAM_CONFIG_DEFAULT() { \
    .ssid = "FallSenseX", \
    .password = "fallsense123", \
    .port = WIFI_STREAM_DEFAULT_PORT, \
    .ap_mode = true, \
}

esp_err_t wifi_stream_init(const wifi_stream_config_t *config);
esp_err_t wifi_stream_send(const char *data, size_t len);
void wifi_stream_deinit(void);

/* Get the IP address string of the first connected client, or NULL if none */
const char *wifi_stream_get_client_ip(void);

/* Get the device's own IP address (STA mode only), or NULL if not obtained */
const char *wifi_stream_get_device_ip(void);

/* Check if WiFi is connected (has IP address in STA mode or AP mode with clients) */
bool wifi_stream_is_connected(void);

#endif
