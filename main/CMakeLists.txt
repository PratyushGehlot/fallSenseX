file(GLOB_RECURSE SRC_FILES "app/*.c")

idf_component_register(
    SRCS ${SRC_FILES}
    INCLUDE_DIRS "." "../components/ws2812_led/include" "../components/firebase/include"
    REQUIRES spiffs driver esp_wifi esp_netif nvs_flash ws2812_led esp_http_server json firebase esp_https_ota app_update mbedtls
)

target_compile_options(${COMPONENT_LIB} PRIVATE "-Wno-format" "-Wno-deprecated-declarations")

spiffs_create_partition_image(storage ../spiffs FLASH_IN_PROJECT)
