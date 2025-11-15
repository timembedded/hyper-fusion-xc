/*
    Low-Latency SPI master driver extension
*/
#include <hal/spi_hal.h>
#include <driver/spi_master.h>

void llspi_set_address(spi_device_handle_t handle, uint8_t addr);
void llspi_hal_setup_trans(spi_device_handle_t handle, const spi_hal_trans_config_t* trans);
esp_err_t llspi_transmit(spi_device_handle_t handle, uint8_t *send_buffer, uint16_t bitlen);
void llspi_setup_device(spi_device_handle_t handle);
void llspi_setup_transfer(spi_device_handle_t handle, spi_transaction_t* trans_desc);
esp_err_t llspi_device_polling_transmit(spi_device_handle_t handle, spi_transaction_t* trans_desc);
