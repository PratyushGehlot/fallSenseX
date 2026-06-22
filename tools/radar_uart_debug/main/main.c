#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

#include "driver/gpio.h"
#include "driver/uart.h"
#include "esp_err.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define RADAR_UART_NUM          UART_NUM_1
#define RADAR_UART_BAUDRATE     115200
#define RADAR_UART_TX_PIN       GPIO_NUM_6
#define RADAR_UART_RX_PIN       GPIO_NUM_5
#define RADAR_UART_RX_BUF_SIZE  4096
#define RADAR_UART_TX_BUF_SIZE  1024
#define RADAR_LINE_BUF_SIZE     512
#define RADAR_CMD_BUF_SIZE      128
#define RADAR_MAX_POINTS        128

static const char *TAG = "radar_uart_debug";

typedef struct {
    float x, y, z, velocity, snr, abs_val, dpk;
} radar_point_t;

static radar_point_t s_points[RADAR_MAX_POINTS];
static int s_point_count = 0;
static int s_frame_counter = 0;

static void print_bytes(const char *prefix, const uint8_t *data, size_t len)
{
    ESP_LOGI(TAG, "%s %u bytes", prefix, (unsigned int)len);
    ESP_LOG_BUFFER_HEXDUMP(TAG, data, len, ESP_LOG_INFO);

    char text[RADAR_LINE_BUF_SIZE];
    size_t text_len = 0;
    for (size_t i = 0; i < len && text_len + 1 < sizeof(text); i++) {
        char ch = (char)data[i];
        text[text_len++] = (ch >= 32 && ch <= 126) ? ch : '.';
    }
    text[text_len] = '\0';
    if (text_len > 0) {
        ESP_LOGI(TAG, "%s ASCII: %s", prefix, text);
    }
}

static bool parse_and_print_point_line(const char *line)
{
    const char *px = strstr(line, "x=");
    const char *py = strstr(line, "y=");
    const char *pz = strstr(line, "z=");
    const char *pv = strstr(line, "v=");
    const char *psnr = strstr(line, "snr=");
    const char *pabs = strstr(line, "abs=");
    const char *pdpk = strstr(line, "dpk=");

    if (!px || !py || !pz || !pv || !psnr || !pabs || !pdpk) {
        return false;
    }

    radar_point_t p = {0};
    p.x = atof(px + 2);
    p.y = atof(py + 2);
    p.z = atof(pz + 2);
    p.velocity = atof(pv + 2);
    p.snr = atof(psnr + 4);
    p.abs_val = atof(pabs + 4);
    p.dpk = atof(pdpk + 4);

    ESP_LOGI(TAG, "Point[%d]: x=%.2f y=%.2f z=%.2f v=%.2f snr=%.1f abs=%.1f dpk=%.1f",
             s_point_count, p.x, p.y, p.z, p.velocity, p.snr, p.abs_val, p.dpk);

    if (s_point_count < RADAR_MAX_POINTS) {
        s_points[s_point_count++] = p;
    }
    return true;
}

static void send_command_raw(const char *cmd, size_t len);

static void radar_rx_task(void *arg)
{
    uint8_t *rx_buf = malloc(RADAR_LINE_BUF_SIZE);
    if (rx_buf == NULL) {
        ESP_LOGE(TAG, "Failed to allocate RX buffer");
        vTaskDelete(NULL);
        return;
    }

    char line[RADAR_LINE_BUF_SIZE];
    size_t line_len = 0;

    ESP_LOGI(TAG, "Radar RX task started on UART%d TX=%d RX=%d",
             RADAR_UART_NUM, RADAR_UART_TX_PIN, RADAR_UART_RX_PIN);

    while (1) {
        int rx_len = uart_read_bytes(RADAR_UART_NUM, rx_buf, RADAR_LINE_BUF_SIZE - 1, 100 / portTICK_PERIOD_MS);
        if (rx_len < 0) {
            ESP_LOGW(TAG, "Radar RX read error: %d", rx_len);
            vTaskDelay(100 / portTICK_PERIOD_MS);
            continue;
        }
        if (rx_len == 0) {
            continue;
        }

        for (int i = 0; i < rx_len; i++) {
            char ch = (char)rx_buf[i];
            if (ch == '\n' || ch == '\r') {
                if (line_len > 0) {
                    line[line_len] = '\0';
                    
                    if (strstr(line, "-----PointNum") != NULL) {
                        s_frame_counter++;
                        ESP_LOGW(TAG, "=== Frame #%d start ===", s_frame_counter);
                        s_point_count = 0;
                    } else if (parse_and_print_point_line(line)) {
                        // Point parsed and printed
                    } else if (strstr(line, "-----End") != NULL) {
                        ESP_LOGW(TAG, "=== Frame #%d end: %d points ===", s_frame_counter, s_point_count);
                        s_point_count = 0;
                    } else {
                        ESP_LOGI(TAG, "RX: %s", line);
                    }
                    line_len = 0;
                }
            } else if (line_len < RADAR_LINE_BUF_SIZE - 1) {
                line[line_len++] = ch;
            }
        }
    }
}

static void console_tx_task(void *arg)
{
    setvbuf(stdin, NULL, _IONBF, 0);

    char cmd[RADAR_CMD_BUF_SIZE];
    size_t len = 0;

    ESP_LOGI(TAG, "Interactive UART console ready. Type AT commands and press Enter.");
    ESP_LOGI(TAG, "Built-ins: help, ver, start, stop, dbg0, sens3");

    while (1) {
        int ch = getchar();
        if (ch == EOF) {
            vTaskDelay(10 / portTICK_PERIOD_MS);
            continue;
        }

        if (ch == '\r') {
            continue;
        }

        if (ch == '\n') {
            cmd[len] = '\0';
            if (len > 0) {
                ESP_LOGI(TAG, "> %s", cmd);
                if (strcmp(cmd, "help") == 0) {
                    ESP_LOGI(TAG, "Built-ins: ver, start, stop, dbg0, sens3. Type any AT command for raw TX.");
                } else if (strcmp(cmd, "ver") == 0) {
                    send_command_raw("AT+VER", 6);
                } else if (strcmp(cmd, "start") == 0) {
                    send_command_raw("AT+START", 8);
                } else if (strcmp(cmd, "stop") == 0) {
                    send_command_raw("AT+STOP", 7);
                } else if (strcmp(cmd, "dbg0") == 0) {
                    send_command_raw("AT+DBG=0", 8);
                } else if (strcmp(cmd, "sens3") == 0) {
                    send_command_raw("AT+SENS=3", 9);
                } else {
                    send_command_raw(cmd, len);
                }
                len = 0;
            }
            continue;
        }

        if (len < RADAR_CMD_BUF_SIZE - 2) {
            cmd[len++] = (char)ch;
        } else {
            ESP_LOGW(TAG, "Command buffer full");
            len = 0;
        }
    }
}

static void send_command_raw(const char *cmd, size_t len)
{
    uint8_t tx_buf[RADAR_CMD_BUF_SIZE];
    size_t tx_len = len;

    if (tx_len >= sizeof(tx_buf)) {
        tx_len = sizeof(tx_buf) - 1;
    }

    memcpy(tx_buf, cmd, tx_len);
    if (tx_len == 0 || tx_buf[tx_len - 1] != '\n') {
        tx_buf[tx_len++] = '\n';
    }

    ESP_LOGI(TAG, "TX: %.*s", tx_len, (char *)tx_buf);
    uart_write_bytes(RADAR_UART_NUM, (char *)tx_buf, tx_len);
}

void app_main(void)
{
    uart_config_t uart_config = {
        .baud_rate = RADAR_UART_BAUDRATE,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };

    ESP_ERROR_CHECK(uart_param_config(RADAR_UART_NUM, &uart_config));
    ESP_ERROR_CHECK(uart_set_pin(RADAR_UART_NUM,
                                 RADAR_UART_TX_PIN,
                                 RADAR_UART_RX_PIN,
                                 UART_PIN_NO_CHANGE,
                                 UART_PIN_NO_CHANGE));
    ESP_ERROR_CHECK(uart_driver_install(RADAR_UART_NUM,
                                        RADAR_UART_RX_BUF_SIZE,
                                        RADAR_UART_TX_BUF_SIZE,
                                        0,
                                        NULL,
                                        0));

    ESP_LOGI(TAG, "Radar UART initialized");

    xTaskCreate(radar_rx_task, "radar_rx", 4096, NULL, 5, NULL);
    xTaskCreate(console_tx_task, "radar_tx", 4096, NULL, 5, NULL);
}