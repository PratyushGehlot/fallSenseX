idf_component_register(
    SRCS "ws2812_led.c"
    INCLUDE_DIRS "include"
    REQUIRES driver freertos led_strip
)
