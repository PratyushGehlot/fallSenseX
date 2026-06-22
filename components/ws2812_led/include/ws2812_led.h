/**
 * @file ws2812_led.h
 * @brief WS2812 RGB LED Driver using ESP32 RMT peripheral
 * @description This module provides control for WS2812/NeoPixel RGB LEDs
 *              using the ESP32's RMT (Remote Control) peripheral.
 */

#pragma once

#include <stdint.h>
#include "esp_err.h"
#include "driver/gpio.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief WS2812 LED color structure
 */
typedef struct {
    uint8_t r;  /**< Red component (0-255) */
    uint8_t g;  /**< Green component (0-255) */
    uint8_t b;  /**< Blue component (0-255) */
} ws2812_color_t;

/**
 * @brief WS2812 LED configuration
 */
typedef struct {
    gpio_num_t gpio_num;      /**< GPIO pin connected to WS2812 data line */
    uint8_t led_count;        /**< Number of LEDs in the strip */
    uint8_t channel;         /**< RMT channel to use (0-7) */
} ws2812_config_t;

/**
 * @brief Predefined LED colors
 */
#define WS2812_COLOR_RED       {255, 0, 0}
#define WS2812_COLOR_GREEN     {0, 255, 0}
#define WS2812_COLOR_BLUE      {0, 0, 255}
#define WS2812_COLOR_WHITE     {255, 255, 255}
#define WS2812_COLOR_YELLOW    {255, 255, 0}
#define WS2812_COLOR_CYAN     {0, 255, 255}
#define WS2812_COLOR_MAGENTA  {255, 0, 255}
#define WS2812_COLOR_ORANGE    {255, 165, 0}
#define WS2812_COLOR_PURPLE   {128, 0, 128}
#define WS2812_COLOR_PINK     {255, 192, 203}
#define WS2812_COLOR_PARROT_GREEN {0, 255, 127}
#define WS2812_COLOR_OFF      {0, 0, 0}

/**
 * @brief Default WS2812 configuration
 */
#define WS2812_CONFIG_DEFAULT() \
    {                           \
        .gpio_num = GPIO_NUM_2,\
        .led_count = 1,        \
        .channel = 0            \
    }

/**
 * @brief Initialize the WS2812 LED strip
 *
 * @param config Pointer to WS2812 configuration
 * @return ESP_OK on success, error code on failure
 */
esp_err_t ws2812_init(const ws2812_config_t *config);

/**
 * @brief Deinitialize the WS2812 LED strip
 *
 * @return ESP_OK on success, error code on failure
 */
esp_err_t ws2812_deinit(void);

/**
 * @brief Set color for a single LED
 *
 * @param led_index Index of the LED (0 to led_count-1)
 * @param color Color to set
 * @return ESP_OK on success, error code on failure
 */
esp_err_t ws2812_set_color(uint8_t led_index, ws2812_color_t color);

/**
 * @brief Set color for all LEDs in the strip
 *
 * @param color Color to set for all LEDs
 * @return ESP_OK on success, error code on failure
 */
esp_err_t ws2812_set_color_all(ws2812_color_t color);

/**
 * @brief Set RGB values directly for a single LED
 *
 * @param led_index Index of the LED (0 to led_count-1)
 * @param r Red component (0-255)
 * @param g Green component (0-255)
 * @param b Blue component (0-255)
 * @return ESP_OK on success, error code on failure
 */
esp_err_t ws2812_set_rgb(uint8_t led_index, uint8_t r, uint8_t g, uint8_t b);

/**
 * @brief Set RGB values for all LEDs
 *
 * @param r Red component (0-255)
 * @param g Green component (0-255)
 * @param b Blue component (0-255)
 * @return ESP_OK on success, error code on failure
 */
esp_err_t ws2812_set_rgb_all(uint8_t r, uint8_t g, uint8_t b);

/**
 * @brief Clear (turn off) all LEDs
 *
 * @return ESP_OK on success, error code on failure
 */
esp_err_t ws2812_clear(void);

/**
 * @brief Show/refresh the LED strip (send data to LEDs)
 *
 * @return ESP_OK on success, error code on failure
 */
esp_err_t ws2812_show(void);

/**
 * @brief Set brightness for all LEDs
 *
 * @param brightness Brightness level (0-255)
 * @return ESP_OK on success, error code on failure
 */
esp_err_t ws2812_set_brightness(uint8_t brightness);

/**
 * @brief Rainbow effect - cycle through colors
 *
 * @param delay_ms Delay between color changes in milliseconds
 * @return ESP_OK on success, error code on failure
 */
esp_err_t ws2812_rainbow(uint32_t delay_ms);

/**
 * @brief Show status with LED - used for system status indication
 *
 * @param status Status type: 0=Off, 1=Green(Safe), 2=Red(Fall Detected), 3=Blue(Detecting)
 * @return ESP_OK on success, error code on failure
 */
esp_err_t ws2812_show_status(uint8_t status);

#ifdef __cplusplus
}
#endif
