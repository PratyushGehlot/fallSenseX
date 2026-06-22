/**
 * @file button_handler.h
 * @brief Button Handler for Fall Sense X
 * @details Handles button press events for config mode and paired mode
 */

#ifndef BUTTON_HANDLER_H
#define BUTTON_HANDLER_H

#include "esp_err.h"
#include "driver/gpio.h"
#include <stdbool.h>
#include <stdint.h>

/* Button GPIO pin - using GPIO0 for XIAO ESP32S3 */
#define CONFIG_BUTTON_GPIO GPIO_NUM_3

/* Timing definitions */
#define BUTTON_SHORT_PRESS_MS      100
#define BUTTON_LONG_PRESS_MS       3000    /* 3 seconds for config sequence */
#define BUTTON_DOUBLE_PRESS_MAX_MS 500     /* Max time between double presses */

/* Button events */
typedef enum {
    BUTTON_EVENT_NONE = 0,
    BUTTON_EVENT_SHORT_PRESS,
    BUTTON_EVENT_LONG_PRESS,
    BUTTON_EVENT_DOUBLE_PRESS,
} button_event_t;

/* Button callback type */
typedef void (*button_event_cb_t)(button_event_t event);

typedef struct {
    button_event_cb_t callback;
    gpio_num_t gpio_num;
} button_config_t;

/**
 * @brief Initialize button handler
 * @param config Button configuration
 * @return ESP_OK on success
 */
esp_err_t button_init(const button_config_t *config);

/**
 * @brief Deinitialize button handler
 */
void button_deinit(void);

/**
 * @brief Get current button state (for polling if needed)
 * @return true if button is pressed
 */
bool button_is_pressed(void);

#endif /* BUTTON_HANDLER_H */
