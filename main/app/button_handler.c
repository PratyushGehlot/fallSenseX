/**
 * @file button_handler.c
 * @brief Button Handler Implementation for Fall Sense X
 */

#include "button_handler.h"
#include "esp_log.h"
#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/timers.h"

static const char *TAG = "button_handler";

/* Button state variables */
static button_event_cb_t s_callback = NULL;
static gpio_num_t s_gpio_num = CONFIG_BUTTON_GPIO;
static TimerHandle_t s_press_timer = NULL;
static TimerHandle_t s_double_press_timer = NULL;
static uint32_t s_press_start_time = 0;
static bool s_button_pressed = false;
static uint8_t s_press_count = 0;


/* GPIO interrupt handler */
static void IRAM_ATTR gpio_isr_handler(void *arg)
{
    uint32_t gpio_num = (uint32_t) arg;
    
    if (gpio_num == s_gpio_num) {
        bool current_level = gpio_get_level(s_gpio_num);
        
        if (current_level == 0) {
            /* Button pressed - start press timer */
            s_press_start_time = xTaskGetTickCount() * portTICK_PERIOD_MS;
            s_button_pressed = true;
            
            /* Start long press timer */
            if (s_press_timer) {
                xTimerStart(s_press_timer, 0);
            }
        } else {
            /* Button released */
            if (s_button_pressed) {
                uint32_t press_duration = (xTaskGetTickCount() * portTICK_PERIOD_MS) - s_press_start_time;
                s_button_pressed = false;
                
                /* Stop long press timer */
                if (s_press_timer) {
                    xTimerStop(s_press_timer, 0);
                }
                
                if (press_duration < BUTTON_LONG_PRESS_MS) {

                    /* Short press - count for double press detection */
                    s_press_count++;
                    
                    /* Start double press timer */
                    if (s_double_press_timer) {
                        xTimerStart(s_double_press_timer, 0);
                    }
                }
            }
        }
    }
}


/* Timer callbacks */
static void press_timer_callback(TimerHandle_t xTimer)
{
    (void)xTimer;
    
    /* Long press detected - button still pressed after threshold */
    if (s_button_pressed && s_callback) {
        ESP_LOGI(TAG, "Long press detected - entering config mode");
        s_callback(BUTTON_EVENT_LONG_PRESS);
    }
    
    /* Reset press count after timer fires (for long press case) */
    s_press_count = 0;
}

static void double_press_timer_callback(TimerHandle_t xTimer)
{
    (void)xTimer;
    
    /* Timer expired - determine press pattern */
    if (s_press_count >= 2 && s_callback) {
        /* Double press detected */
        ESP_LOGI(TAG, "Double press detected - entering paired mode");
        s_callback(BUTTON_EVENT_DOUBLE_PRESS);
    } else if (s_press_count == 1 && s_callback) {
        /* Single short press */
        ESP_LOGI(TAG, "Short press detected");
        s_callback(BUTTON_EVENT_SHORT_PRESS);
    }
    
    /* Reset press count */
    s_press_count = 0;
}

esp_err_t button_init(const button_config_t *config)
{
    if (config) {
        s_callback = config->callback;
        s_gpio_num = config->gpio_num;
    }
    
    /* Configure GPIO */
    gpio_config_t io_conf = {
        .pin_bit_mask = (1ULL << s_gpio_num),
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_ANYEDGE,
    };
    
    esp_err_t err = gpio_config(&io_conf);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to configure GPIO: %s", esp_err_to_name(err));
        return err;
    }
    
    /* Install GPIO ISR handler */
    err = gpio_install_isr_service(0);
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        ESP_LOGE(TAG, "Failed to install ISR service: %s", esp_err_to_name(err));
        return err;
    }
    
    err = gpio_isr_handler_add(s_gpio_num, gpio_isr_handler, (void *)s_gpio_num);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to add ISR handler: %s", esp_err_to_name(err));
        return err;
    }
    
    /* Create timers */
    s_press_timer = xTimerCreate(
        "press_timer",
        pdMS_TO_TICKS(BUTTON_LONG_PRESS_MS),
        pdFALSE,
        NULL,
        press_timer_callback
    );
    
    s_double_press_timer = xTimerCreate(
        "double_press_timer",
        pdMS_TO_TICKS(BUTTON_DOUBLE_PRESS_MAX_MS),
        pdFALSE,
        NULL,
        double_press_timer_callback
    );
    
    if (!s_press_timer || !s_double_press_timer) {
        ESP_LOGE(TAG, "Failed to create timers");
        return ESP_ERR_NO_MEM;
    }
    
    ESP_LOGI(TAG, "Button handler initialized on GPIO%d", s_gpio_num);
    return ESP_OK;
}

void button_deinit(void)
{
    if (s_press_timer) {
        xTimerDelete(s_press_timer, 0);
        s_press_timer = NULL;
    }
    
    if (s_double_press_timer) {
        xTimerDelete(s_double_press_timer, 0);
        s_double_press_timer = NULL;
    }
    
    gpio_isr_handler_remove(s_gpio_num);
    gpio_reset_pin(s_gpio_num);
    
    s_callback = NULL;
    ESP_LOGI(TAG, "Button handler deinitialized");
}

bool button_is_pressed(void)
{
    return gpio_get_level(s_gpio_num) == 0;
}
