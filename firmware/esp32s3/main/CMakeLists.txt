idf_component_register(
  SRCS
    "main.c"
    "llspi.c"
    "i2s.c"
    "dac.c"
    "emutimer.c"
    "fpga.c"
    "audiodev.c"
    "bluemsx//fifo.c"
    "bluemsx//Board.c"
    "bluemsx//AY8910.c"
    "bluemsx//AudioMixer.c"
    "bluemsx//IoPort.c"
    "bluemsx//OpenMsxYM2413.cpp"
    "bluemsx//OpenMsxYM2413_2.cpp"
    "bluemsx//YM2413.cpp"
    "bluemsx//MsxAudio.cpp"
    "bluemsx//OpenMsxY8950.cpp"
    "bluemsx//OpenMsxY8950Adpcm.cpp"
    "bluemsx//OpenMsxYMF262.cpp"
    "bluemsx//OpenMsxYMF278.cpp"
    "bluemsx//Moonsound.cpp"
    "openmsx//YM2413Burczynski.cc"
  PRIV_REQUIRES
    nvs_flash
    esp_eth
    esp_psram
    esp_driver_uart
    esp_driver_gpio
    esp_driver_spi
    esp_driver_i2s
  INCLUDE_DIRS
    "."
    "openmsx"
  EMBED_FILES
    "MOONSOUND.rom"
)

target_compile_options(${COMPONENT_LIB} PRIVATE -Wno-error -Wno-error=narrowing -Wno-narrowing -mtext-section-literals)

set(CXX_STANDARD C++23)
