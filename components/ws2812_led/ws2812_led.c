/**
 * @file ws2812_led.c
 * @brief WS2812 RGB LED Driver using ESP-IDF led_strip component
 * @description This module provides control for WS2812/NeoPixel RGB LEDs
 *              using the official ESP-IDF led_strip component.
 */

#include "ws2812_led.h"
#include "led_strip.h"
#include "esp_log.h"
#include "esp_check.h"
#include "driver/rmt.h"
#include <stdlib.h>

static const char *TAG = "ws2812_led";

/**
 * @brief Internal data structure for LED strip
 */
typedef struct {
    led_strip_handle_t strip;
    uint8_t led_count;
    uint8_t brightness;
    bool initialized;
} ws2812_dev_t;

static ws2812_dev_t *ws2812_device = NULL;

esp_err_t ws2812_init(const ws2812_config_t *config)
{
    esp_err_t ret = ESP_OK;
    
    ESP_GOTO_ON_FALSE(config, ESP_ERR_INVALID_ARG, err, TAG, "Config pointer is NULL");
    ESP_GOTO_ON_FALSE(config->led_count > 0, ESP_ERR_INVALID_ARG, err, TAG, "LED count must be > 0");
    ESP_GOTO_ON_FALSE(config->gpio_num < GPIO_NUM_MAX, ESP_ERR_INVALID_ARG, err, TAG, "Invalid GPIO number");

    if (ws2812_device != NULL) {
        ESP_LOGW(TAG, "WS2812 already initialized, deinitializing first");
        ws2812_deinit();
    }

    // Allocate device structure
    ws2812_device = (ws2812_dev_t *)malloc(sizeof(ws2812_dev_t));
    ESP_GOTO_ON_FALSE(ws2812_device, ESP_ERR_NO_MEM, err, TAG, "Failed to allocate memory");

    // Configure LED strip
    led_strip_config_t strip_config = {
        .strip_gpio_num = config->gpio_num,
        .max_leds = config->led_count,
        .led_pixel_format = LED_PIXEL_FORMAT_GRB,
        .led_model = LED_MODEL_WS2812,
        .flags = {
            .invert_out = false,
        }
    };

    led_strip_rmt_config_t rmt_config = {
        .clk_src = RMT_CLK_SRC_DEFAULT,
        .resolution_hz = 10 * 1000 * 1000,  // 10MHz
        .mem_block_symbols = 64,
        .flags = {
            .with_dma = false,
        }
    };

    // Initialize LED strip
    ESP_GOTO_ON_ERROR(led_strip_new_rmt_device(&strip_config, &rmt_config, &ws2812_device->strip), 
                     err_free, TAG, "Failed to initialize LED strip");

    // Clear the strip
    ESP_GOTO_ON_ERROR(led_strip_clear(ws2812_device->strip), err_del, TAG, "Failed to clear LED strip");
    ESP_GOTO_ON_ERROR(led_strip_refresh(ws2812_device->strip), err_del, TAG, "Failed to refresh LED strip");

    // Store configuration
    ws2812_device->led_count = config->led_count;
    ws2812_device->brightness = 255;  // Full brightness by default
    ws2812_device->initialized = true;

    ESP_LOGI(TAG, "WS2812 initialized: GPIO=%d, LEDs=%d, Channel=%d", 
             config->gpio_num, config->led_count, config->channel);

    return ESP_OK;

err_del:
    led_strip_del(ws2812_device->strip);
err_free:
    free(ws2812_device);
    ws2812_device = NULL;
err:
    return ret;
}

esp_err_t ws2812_deinit(void)
{
    if (ws2812_device == NULL) {
        return ESP_OK;
    }

    // Clear all LEDs
    ws2812_clear();

    // Deinitialize LED strip
    if (ws2812_device->strip) {
        led_strip_del(ws2812_device->strip);
    }

    // Free memory
    free(ws2812_device);
    ws2812_device = NULL;

    ESP_LOGI(TAG, "WS2812 deinitialized");
    return ESP_OK;
}

esp_err_t ws2812_set_color(uint8_t led_index, ws2812_color_t color)
{
    esp_err_t ret = ESP_OK;
    
    ESP_GOTO_ON_FALSE(ws2812_device, ESP_ERR_INVALID_STATE, err, TAG, "WS2812 not initialized");
    ESP_GOTO_ON_FALSE(ws2812_device->strip, ESP_ERR_INVALID_STATE, err, TAG, "LED strip not initialized");
    ESP_GOTO_ON_FALSE(led_index < ws2812_device->led_count, ESP_ERR_INVALID_ARG, err, TAG, "Invalid LED index");

    // Apply brightness
    uint32_t r = (color.r * ws2812_device->brightness) / 255;
    uint32_t g = (color.g * ws2812_device->brightness) / 255;
    uint32_t b = (color.b * ws2812_device->brightness) / 255;
    
    ESP_GOTO_ON_ERROR(led_strip_set_pixel(ws2812_device->strip, led_index, r, g, b), 
                     err, TAG, "Failed to set pixel");

err:
    return ret;
}

esp_err_t ws2812_set_color_all(ws2812_color_t color)
{
    esp_err_t ret = ESP_OK;
    
    ESP_GOTO_ON_FALSE(ws2812_device, ESP_ERR_INVALID_STATE, err, TAG, "WS2812 not initialized");
    ESP_GOTO_ON_FALSE(ws2812_device->strip, ESP_ERR_INVALID_STATE, err, TAG, "LED strip not initialized");

    // Apply brightness
    uint32_t r = (color.r * ws2812_device->brightness) / 255;
    uint32_t g = (color.g * ws2812_device->brightness) / 255;
    uint32_t b = (color.b * ws2812_device->brightness) / 255;

    for (uint8_t i = 0; i < ws2812_device->led_count; i++) {
        ESP_GOTO_ON_ERROR(led_strip_set_pixel(ws2812_device->strip, i, r, g, b), 
                         err, TAG, "Failed to set pixel at index %d", i);
    }

err:
    return ret;
}

esp_err_t ws2812_set_rgb(uint8_t led_index, uint8_t r, uint8_t g, uint8_t b)
{
    ws2812_color_t color = {r, g, b};
    return ws2812_set_color(led_index, color);
}

esp_err_t ws2812_set_rgb_all(uint8_t r, uint8_t g, uint8_t b)
{
    ws2812_color_t color = {r, g, b};
    return ws2812_set_color_all(color);
}

esp_err_t ws2812_clear(void)
{
    ESP_RETURN_ON_FALSE(ws2812_device, ESP_ERR_INVALID_STATE, TAG, "WS2812 not initialized");
    ESP_RETURN_ON_FALSE(ws2812_device->strip, ESP_ERR_INVALID_STATE, TAG, "LED strip not initialized");

    return led_strip_clear(ws2812_device->strip);
}

esp_err_t ws2812_show(void)
{
    ESP_RETURN_ON_FALSE(ws2812_device, ESP_ERR_INVALID_STATE, TAG, "WS2812 not initialized");
    ESP_RETURN_ON_FALSE(ws2812_device->strip, ESP_ERR_INVALID_STATE, TAG, "LED strip not initialized");

    return led_strip_refresh(ws2812_device->strip);
}

esp_err_t ws2812_set_brightness(uint8_t brightness)
{
    ESP_RETURN_ON_FALSE(ws2812_device, ESP_ERR_INVALID_STATE, TAG, "WS2812 not initialized");

    ws2812_device->brightness = brightness;
    return ESP_OK;
}

esp_err_t ws2812_rainbow(uint32_t delay_ms)
{
    ESP_RETURN_ON_FALSE(ws2812_device, ESP_ERR_INVALID_STATE, TAG, "WS2812 not initialized");
    ESP_RETURN_ON_FALSE(ws2812_device->strip, ESP_ERR_INVALID_STATE, TAG, "LED strip not initialized");

    for (uint16_t hue = 0; hue < 256; hue++) {
        // Convert hue to RGB
        uint8_t r, g, b;
        
        if (hue < 85) {
            r = (255 - hue * 3);
            g = (hue * 3);
            b = 0;
        } else if (hue < 170) {
            r = 0;
            g = (255 - (hue - 85) * 3);
            b = ((hue - 85) * 3);
        } else {
            r = ((hue - 170) * 3);
            g = 0;
            b = (255 - (hue - 170) * 3);
        }

        ws2812_set_rgb_all(r, g, b);
        ws2812_show();
        vTaskDelay(pdMS_TO_TICKS(delay_ms));
    }

    return ESP_OK;
}

esp_err_t ws2812_show_status(uint8_t status)
{
    ESP_RETURN_ON_FALSE(ws2812_device, ESP_ERR_INVALID_STATE, TAG, "WS2812 not initialized");

    ws2812_color_t color;

    switch (status) {
        case 0: // Off
            color = (ws2812_color_t)WS2812_COLOR_OFF;
            break;
        case 1: // Green - Safe
            color = (ws2812_color_t)WS2812_COLOR_GREEN;
            break;
        case 2: // Red - Fall Detected
            color = (ws2812_color_t)WS2812_COLOR_RED;
            break;
        case 3: // Blue - Detecting
            color = (ws2812_color_t)WS2812_COLOR_BLUE;
            break;
        case 4: // Yellow - Warning
            color = (ws2812_color_t)WS2812_COLOR_YELLOW;
            break;
        case 5: // Orange - Human Present
            color = (ws2812_color_t)WS2812_COLOR_ORANGE;
            break;
        default:
            color = (ws2812_color_t)WS2812_COLOR_OFF;
            break;
    }

    ws2812_set_color_all(color);
    return ws2812_show();
}
