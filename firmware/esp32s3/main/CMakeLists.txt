idf_component_register(
  SRCS
    "main.c"
    "spitest.c"
    "llspi.c"
  PRIV_REQUIRES
    nvs_flash
    esp_eth
    esp_driver_uart
    esp_driver_gpio
    esp_driver_spi
  INCLUDE_DIRS
    "."
    "include"
)

set_target_properties(${COMPONENT_LIB} PROPERTIES COMPILE_FLAGS -Werror)
