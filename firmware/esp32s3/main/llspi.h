/*****************************************************************************
**  Low-Latency SPI master driver extension
**
**  Copyright (C) 2025 Tim Brugman
**
**  This program is free software; you can redistribute it and/or modify
**  it under the terms of the GNU General Public License as published by
**  the Free Software Foundation; either version 2 of the License, or
**  (at your option) any later version.
** 
**  This program is distributed in the hope that it will be useful,
**  but WITHOUT ANY WARRANTY; without even the implied warranty of
**  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
**  GNU General Public License for more details.
**
**  You should have received a copy of the GNU General Public License
**  along with this program; if not, write to the Free Software
**  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
**
******************************************************************************/
#pragma once

#include <hal/spi_hal.h>
#include <driver/spi_master.h>

void llspi_set_address(spi_device_handle_t handle, uint8_t addr);
void llspi_hal_setup_trans(spi_device_handle_t handle, const spi_hal_trans_config_t* trans);
esp_err_t llspi_transmit(spi_device_handle_t handle, uint8_t *send_buffer, uint16_t bitlen);
void llspi_setup_device(spi_device_handle_t handle);
void llspi_setup_transfer(spi_device_handle_t handle, spi_transaction_t* trans_desc);
esp_err_t llspi_device_polling_transmit(spi_device_handle_t handle, spi_transaction_t* trans_desc);
void llspi_device_wait_ready(spi_device_handle_t handle);
