idf_component_register(
    SRCS "firebase.c"
    INCLUDE_DIRS "include"
    REQUIRES esp_http_client nvs_flash mbedtls esp_driver_tsens json
    PRIV_REQUIRES driver esp_wifi
)
