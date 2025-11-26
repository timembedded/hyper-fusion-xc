/*****************************************************************************
**  FPGA interface handling
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

#include <stdint.h>

#include "bluemsx/IoPort.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*reset_callback_t)(void* ref);

struct fpga_context_t;
typedef struct fpga_context_t* fpga_handle_t;

fpga_handle_t fpga_create(void);
void fpga_destroy(fpga_handle_t timer);

void fpga_set_reset_callback(fpga_handle_t ctx, reset_callback_t reset_callback, void* ref);

void fpga_io_start(fpga_handle_t fpga_handle);
void fpga_io_stop(fpga_handle_t fpga_handle);

void fpga_io_reset(fpga_handle_t fpga_handle);
void fpga_io_register(fpga_handle_t fpga_handle, uint8_t port, IoPortProperties_t prop);
void fpga_io_unregister(fpga_handle_t fpga_handle, uint8_t port);

void fpga_irq_set(fpga_handle_t fpga_handle);
void fpga_irq_reset(fpga_handle_t fpga_handle);


#ifdef __cplusplus
}
#endif
